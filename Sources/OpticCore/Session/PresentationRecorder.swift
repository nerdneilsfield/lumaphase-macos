import Foundation

public enum BeginOutcome: Equatable {
    /// The frame is tracked; a later presented callback can be correlated.
    case tracking
    /// The bounded tracking table is full. The caller should still commit and
    /// then call `submitted`, which writes SUBMITTED + UNCONFIRMED(PENDING_QUEUE_FULL).
    case pendingQueueFull
    /// A dynamic state was requested after a log overflow; no new dynamic state
    /// may be generated.
    case blockedByOverflow
    case duplicateFrameID
    case sealed
}

public struct SealResult: Equatable {
    /// Submitted frames without valid presentation evidence at seal time.
    public let pendingFrameCount: Int
    /// Presented callbacks that arrived after sealing; never written.
    public let lateAfterSealCount: Int
    /// Presented callbacks for frames that were never tracked.
    public let untrackedResultCount: Int
}

public struct SegmentStatistics: Equatable {
    public var segmentID: SegmentID
    public var generated: Int
    public var submitted: Int
    public var presented: Int
    public var unconfirmed: Int
    public var dataIntegrity: DataIntegrity
    public var unconfirmedReasons: [UnconfirmedReason: Int]

    public func json() -> JSONValue {
        var reasons: JSONObject = [:]
        for (reason, count) in unconfirmedReasons {
            reasons[reason.rawValue] = .int(Int64(count))
        }
        return .object([
            "segment_id": .string(segmentID.description),
            "generated": .int(Int64(generated)),
            "submitted": .int(Int64(submitted)),
            "presented": .int(Int64(presented)),
            "unconfirmed": .int(Int64(unconfirmed)),
            "data_integrity": .string(dataIntegrity.rawValue),
            "unconfirmed_reasons": .object(reasons)
        ])
    }
}

public struct SessionStatistics: Equatable {
    public var segments: [SegmentStatistics]
    public var lostEventCount: Int
    public var dataIntegrity: DataIntegrity
}

/// Serializes SUBMITTED / PRESENTED / UNCONFIRMED per submission identity.
///
/// Guarantees, in order of importance:
/// 1. `SUBMITTED` precedes any result event for the same `(session_id, native_frame_id)`.
/// 2. A result that arrives before the submission path finishes is buffered.
/// 3. Identity, segment and layout are captured at submission and never re-read.
/// 4. Duplicate valid results are ignored; conflicting valid results are kept.
/// 5. Nothing writes to disk on the calling thread.
public final class PresentationRecorder {
    private struct Frame {
        let identity: FrameIdentity
        var evidence: Evidence
        var platformIDs: PlatformIDs
        var submitted: Bool
        /// Results that arrived before the submission path finished. They are
        /// written in arrival order after SUBMITTED, preserving every
        /// diagnostic (an early invalid callback followed by a real one keeps
        /// both rows).
        var buffered: [BufferedOutcome] = []
        var lastReason: UnconfirmedReason?
        var presentedRawNanoseconds: Int64?
        var ordinal: UInt64
    }

    private enum BufferedOutcome {
        case presented(systemPresent: FieldSample, renderComplete: FieldSample?, platformIDs: PlatformIDs, recordedRawNanoseconds: Int64)
        case unconfirmed(reason: UnconfirmedReason, systemPresent: FieldSample, renderComplete: FieldSample?, platformIDs: PlatformIDs, recordedRawNanoseconds: Int64)
    }

    private struct FrameTiming {
        var submit: Int64?
        var present: Int64?
        var renderComplete: Int64?
    }

    private struct Counters {
        var generated = 0
        var submitted = 0
        var presented = 0
        var unresolved: [String: UnconfirmedReason] = [:]
        var confirmed: Set<String> = []
        /// Final timing evidence per submission identity. Merged (not appended)
        /// so an UNCONFIRMED row later followed by a real presentation contributes
        /// once and duplicates cannot inflate the distributions.
        var timing: [String: FrameTiming] = [:]
    }

    public let sessionID: SessionID
    public let timeBase: SessionTimeBase
    public let displayLog: EventLog
    public let eventWriter: SessionEventWriter

    private let clock: MonotonicClock
    private let pendingCapacity: Int
    private let lock = NSLock()
    private var frames: [String: Frame] = [:]
    private var rejectedAwaitingSubmit: Set<String> = []
    /// Results that arrived between `begin` (capacity rejected) and `submitted`.
    /// Bounded by the number of frames that can be in flight in that window.
    private var untrackedBuffered: [String: BufferedOutcome] = [:]
    private let untrackedBufferLimit = 16
    private var counters: [SegmentID: Counters] = [:]
    private var nextOrdinal: UInt64 = 0
    private var sealed = false
    private var pendingFrameCount = 0
    private var lastSeal = SealResult(pendingFrameCount: 0, lateAfterSealCount: 0, untrackedResultCount: 0)
    private var lateAfterSealCount = 0
    private var untrackedResultCount = 0
    private var untrackedUnconfirmedCount = 0
    private var dynamicBlocked = false

    public init(
        sessionID: SessionID,
        timeBase: SessionTimeBase,
        displayLog: EventLog,
        eventWriter: SessionEventWriter,
        clock: MonotonicClock,
        pendingCapacity: Int = 8192
    ) {
        self.sessionID = sessionID
        self.timeBase = timeBase
        self.displayLog = displayLog
        self.eventWriter = eventWriter
        self.clock = clock
        self.pendingCapacity = max(1, pendingCapacity)
    }

    public var isSealed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sealed
    }

    public var isDynamicBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dynamicBlocked
    }

    public var trackedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    /// Stops new dynamic states, e.g. after a log overflow. Cards and
    /// calibration frames may still be recorded.
    public func blockDynamicStates() {
        lock.lock()
        dynamicBlocked = true
        lock.unlock()
    }

    // MARK: - Submission

    /// Reserves tracking before the commit call so a presented callback that
    /// fires before the submission path finishes can still be associated.
    public func begin(_ identity: FrameIdentity) -> BeginOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { return .sealed }
        if identity.frameKind == .dynamic {
            if dynamicBlocked || displayLog.overflow != nil {
                dynamicBlocked = true
                return .blockedByOverflow
            }
        }
        let key = identity.nativeFrameID.description
        if frames[key] != nil || rejectedAwaitingSubmit.contains(key) {
            return .duplicateFrameID
        }
        counters[identity.segmentID, default: Counters()].generated += 1
        // Capacity bounds frames without valid presentation evidence, not all
        // frames ever seen; completed frames stay only for identity checks.
        if pendingFrameCount >= pendingCapacity {
            rejectedAwaitingSubmit.insert(key)
            return .pendingQueueFull
        }
        pendingFrameCount += 1
        frames[key] = Frame(
            identity: identity,
            evidence: Evidence(),
            platformIDs: .none,
            submitted: false,
            buffered: [],
            lastReason: nil,
            presentedRawNanoseconds: nil,
            ordinal: nextOrdinal
        )
        nextOrdinal &+= 1
        return .tracking
    }

    /// Called after the platform accepted the commit. Writes SUBMITTED, then
    /// flushes any buffered presented result.
    public func submitted(
        _ identity: FrameIdentity,
        evidence: Evidence,
        platformIDs: PlatformIDs,
        at recordedRawNanoseconds: Int64? = nil
    ) {
        lock.lock()
        guard !sealed else {
            lock.unlock()
            return
        }
        let key = identity.nativeFrameID.description
        if rejectedAwaitingSubmit.contains(key) {
            rejectedAwaitingSubmit.remove(key)
            counters[identity.segmentID, default: Counters()].submitted += 1
            untrackedUnconfirmedCount += 1
            appendLocked(.submitted, identity: identity, evidence: evidence,
                         presentKind: nil, reason: nil, platformIDs: platformIDs,
                         recordedRaw: recordedRawNanoseconds ?? clock.rawNanoseconds())
            // The tracking record was dropped, so the row documents that loss.
            appendLocked(.unconfirmed, identity: identity, evidence: withSystemPresent(
                evidence, .pending(api: "MTLDrawable.presentedTime")
            ), presentKind: .unconfirmed, reason: .pendingQueueFull, platformIDs: platformIDs,
                         recordedRaw: clock.rawNanoseconds())
            counters[identity.segmentID, default: Counters()].unresolved[key] = .pendingQueueFull

            // A real result may already have arrived before commit() returned.
            if let buffered = untrackedBuffered.removeValue(forKey: key),
               case let .presented(systemPresent, renderComplete, bufferedIDs, recordedRaw) = buffered {
                var merged = withSystemPresent(evidence, systemPresent)
                if let renderComplete { merged[.renderComplete] = renderComplete }
                appendLocked(.presented, identity: identity, evidence: merged,
                             presentKind: .systemReported, reason: nil,
                             platformIDs: bufferedIDs, recordedRaw: recordedRaw)
                counters[identity.segmentID, default: Counters()].presented += 1
                counters[identity.segmentID, default: Counters()].confirmed.insert(key)
                counters[identity.segmentID, default: Counters()].unresolved.removeValue(forKey: key)
                // This frame is confirmed now; it must not be counted as pending
                // at seal.
                if untrackedUnconfirmedCount > 0 { untrackedUnconfirmedCount -= 1 }
            }
            lock.unlock()
            return
        }
        guard var frame = frames[key] else {
            lock.unlock()
            return
        }
        frame.submitted = true
        frame.evidence = evidence
        frame.platformIDs = platformIDs
        frames[key] = frame
        counters[identity.segmentID, default: Counters()].submitted += 1
        appendLocked(.submitted, identity: identity, evidence: evidence,
                     presentKind: nil, reason: nil, platformIDs: platformIDs,
                     recordedRaw: recordedRawNanoseconds ?? clock.rawNanoseconds())
        if !frame.buffered.isEmpty {
            let buffered = frame.buffered
            frame.buffered.removeAll()
            for outcome in buffered {
                switch outcome {
                case let .presented(systemPresent, renderComplete, platformIDs, recordedRaw):
                    var merged = withSystemPresent(evidence, systemPresent)
                    if let renderComplete { merged[.renderComplete] = renderComplete }
                    appendLocked(.presented, identity: identity, evidence: merged,
                                 presentKind: .systemReported, reason: nil,
                                 platformIDs: platformIDs, recordedRaw: recordedRaw)
                    if frame.presentedRawNanoseconds == nil {
                        frame.presentedRawNanoseconds = systemPresent.rawNanoseconds
                        if pendingFrameCount > 0 { pendingFrameCount -= 1 }
                        counters[identity.segmentID, default: Counters()].presented += 1
                        counters[identity.segmentID, default: Counters()].confirmed.insert(key)
                        counters[identity.segmentID, default: Counters()].unresolved.removeValue(forKey: key)
                    }
                case let .unconfirmed(reason, systemPresent, renderComplete, platformIDs, recordedRaw):
                    // A real presentation already buffered wins over an
                    // unconfirmed row for the same frame.
                    guard frame.presentedRawNanoseconds == nil else { continue }
                    var merged = withSystemPresent(evidence, systemPresent)
                    if let renderComplete { merged[.renderComplete] = renderComplete }
                    appendLocked(.unconfirmed, identity: identity, evidence: merged,
                                 presentKind: .unconfirmed, reason: reason,
                                 platformIDs: platformIDs, recordedRaw: recordedRaw)
                    frame.lastReason = reason
                    counters[identity.segmentID, default: Counters()].unresolved[key] = reason
                }
            }
            frames[key] = frame
        }
        lock.unlock()
    }

    /// Pre-submit failure (encoding error, no commit). No SUBMITTED is written;
    /// the consumed dynamic sequence number is preserved by the caller.
    public func abandon(
        _ identity: FrameIdentity,
        operation: String,
        errorCode: String?,
        message: String
    ) {
        lock.lock()
        let key = identity.nativeFrameID.description
        if let frame = frames.removeValue(forKey: key), frame.presentedRawNanoseconds == nil,
           pendingFrameCount > 0 {
            pendingFrameCount -= 1
        }
        rejectedAwaitingSubmit.remove(key)
        lock.unlock()
        eventWriter.renderFailure(identity: identity, segmentID: identity.segmentID,
                                  operation: operation, errorCode: errorCode, message: message)
    }

    /// Post-submit GPU failure. The SUBMITTED row stays; RENDER_FAILURE is an
    /// additional configuration event, and the frame remains pending so a real
    /// presentation can still be recorded.
    public func recordRenderFailureAfterSubmit(
        _ identity: FrameIdentity,
        operation: String = "MTLCommandBuffer.status",
        errorCode: String?,
        message: String
    ) {
        eventWriter.renderFailure(identity: identity, segmentID: identity.segmentID,
                                  operation: operation, errorCode: errorCode, message: message)
    }

    // MARK: - Results

    /// Records a real presentation. `evidence` is only needed for frames whose
    /// tracking record was dropped by the bounded queue; the display driver's
    /// presented closure captures the submission evidence for exactly that case.
    @discardableResult
    public func presented(
        _ identity: FrameIdentity,
        evidence: Evidence? = nil,
        systemPresent: FieldSample,
        renderComplete: FieldSample? = nil,
        platformIDs: PlatformIDs,
        at recordedRawNanoseconds: Int64
    ) -> Bool {
        lock.lock()
        let accepted = presentedLocked(identity, evidence, systemPresent, renderComplete,
                                       platformIDs, recordedRawNanoseconds)
        lock.unlock()
        return accepted
    }

    private func presentedLocked(
        _ identity: FrameIdentity,
        _ submissionEvidence: Evidence?,
        _ systemPresent: FieldSample,
        _ renderComplete: FieldSample?,
        _ platformIDs: PlatformIDs,
        _ recordedRawNanoseconds: Int64
    ) -> Bool {
        guard !sealed else {
            lateAfterSealCount += 1
            return false
        }
        let key = identity.nativeFrameID.description
        guard var frame = frames[key] else {
            if rejectedAwaitingSubmit.contains(key) {
                // Result arrived before the submission path finished: buffer it
                // (bounded) so SUBMITTED is still written first.
                bufferUntrackedLocked(key, outcome: .presented(
                    systemPresent: systemPresent,
                    renderComplete: renderComplete,
                    platformIDs: platformIDs,
                    recordedRawNanoseconds: recordedRawNanoseconds
                ))
                return true
            }
            if let submissionEvidence,
               let counter = counters[identity.segmentID],
               counter.unresolved[key] != nil {
                // The frame is known through the submission metadata already
                // recorded for it (capacity-rejected frames carry a
                // PENDING_QUEUE_FULL unresolved entry). The driver closure still
                // holds the submission evidence, so real late evidence is
                // accepted without an arbitrary identity ring.
                var merged = withSystemPresent(submissionEvidence, systemPresent)
                if let renderComplete { merged[.renderComplete] = renderComplete }
                let segmentID = identity.segmentID
                appendLocked(.presented, identity: identity, evidence: merged,
                             presentKind: .systemReported, reason: nil,
                             platformIDs: platformIDs, recordedRaw: recordedRawNanoseconds)
                counters[segmentID, default: Counters()].presented += 1
                counters[segmentID, default: Counters()].confirmed.insert(key)
                counters[segmentID, default: Counters()].unresolved.removeValue(forKey: key)
                if untrackedUnconfirmedCount > 0 { untrackedUnconfirmedCount -= 1 }
                return true
            }
            if counters[identity.segmentID]?.confirmed.contains(key) == true {
                // Duplicate notification for an already confirmed frame.
                return false
            }
            untrackedResultCount += 1
            return false
        }
        let raw = systemPresent.rawNanoseconds
        if let raw, frame.presentedRawNanoseconds == raw {
            // Duplicate notification for the same result: not appended again.
            return false
        }
        guard frame.submitted else {
            // The submission path has not finished yet; no result event may be
            // written before SUBMITTED. Buffer it instead.
            let duplicate = frame.buffered.contains { outcome in
                if case let .presented(sample, _, _, _) = outcome {
                    return raw != nil && sample.rawNanoseconds == raw
                }
                return false
            }
            if !duplicate {
                frame.buffered.append(.presented(systemPresent: systemPresent,
                                                 renderComplete: renderComplete,
                                                 platformIDs: platformIDs,
                                                 recordedRawNanoseconds: recordedRawNanoseconds))
                frames[key] = frame
            }
            return true
        }
        var merged = withSystemPresent(frame.evidence, systemPresent)
        if let renderComplete { merged[.renderComplete] = renderComplete }
        appendLocked(.presented, identity: frame.identity, evidence: merged,
                     presentKind: .systemReported, reason: nil, platformIDs: platformIDs,
                     recordedRaw: recordedRawNanoseconds)
        if frame.presentedRawNanoseconds == nil {
            if pendingFrameCount > 0 { pendingFrameCount -= 1 }
            counters[frame.identity.segmentID, default: Counters()].presented += 1
            counters[frame.identity.segmentID, default: Counters()].confirmed.insert(key)
            counters[frame.identity.segmentID, default: Counters()].unresolved.removeValue(forKey: key)
            // Keep the first valid time for duplicate suppression; a
            // conflicting valid time is appended as an extra row above.
            frame.presentedRawNanoseconds = raw
        }
        frames[key] = frame
        return true
    }

    /// Records "not confirmed as of this event" without giving up the frame.
    /// A later valid presentation is still accepted before sealing.
    public func unconfirmed(
        _ identity: FrameIdentity,
        reason: UnconfirmedReason,
        systemPresent: FieldSample,
        renderComplete: FieldSample? = nil,
        platformIDs: PlatformIDs,
        at recordedRawNanoseconds: Int64
    ) {
        lock.lock()
        unconfirmedLocked(identity, reason, systemPresent, renderComplete, platformIDs, recordedRawNanoseconds)
        lock.unlock()
    }

    private func unconfirmedLocked(
        _ identity: FrameIdentity,
        _ reason: UnconfirmedReason,
        _ systemPresent: FieldSample,
        _ renderComplete: FieldSample?,
        _ platformIDs: PlatformIDs,
        _ recordedRawNanoseconds: Int64
    ) {
        guard !sealed else {
            lateAfterSealCount += 1
            return
        }
        let key = identity.nativeFrameID.description
        guard var frame = frames[key] else {
            // A capacity-rejected frame already carries the PENDING_QUEUE_FULL
            // row at submit; an early invalid callback adds nothing.
            if rejectedAwaitingSubmit.contains(key)
                || counters[identity.segmentID]?.unresolved[key] != nil
                || counters[identity.segmentID]?.confirmed.contains(key) == true {
                return
            }
            untrackedResultCount += 1
            return
        }
        guard frame.submitted else {
            // Same rule as a valid result: invalid/unconfirmed evidence that
            // arrives before the submission path finishes (a macOS
            // presentedTime == 0 callback can be that early) is buffered and
            // written after SUBMITTED. An identical repeat is not buffered
            // twice, mirroring duplicate suppression for valid results.
            let duplicate = frame.buffered.contains { outcome in
                if case let .unconfirmed(bufferedReason, sample, _, _, _) = outcome {
                    return bufferedReason == reason && sample == systemPresent
                }
                return false
            }
            if !duplicate {
                frame.buffered.append(.unconfirmed(reason: reason,
                                                   systemPresent: systemPresent,
                                                   renderComplete: renderComplete,
                                                   platformIDs: platformIDs,
                                                   recordedRawNanoseconds: recordedRawNanoseconds))
                frames[key] = frame
            }
            return
        }
        guard frame.presentedRawNanoseconds == nil else {
            // Real presentation evidence already exists; an unconfirmed row
            // would contradict it.
            return
        }
        var merged = withSystemPresent(frame.evidence, systemPresent)
        if let renderComplete { merged[.renderComplete] = renderComplete }
        appendLocked(.unconfirmed, identity: frame.identity, evidence: merged,
                     presentKind: .unconfirmed, reason: reason, platformIDs: platformIDs,
                     recordedRaw: recordedRawNanoseconds)
        frame.lastReason = reason
        frames[key] = frame
        counters[frame.identity.segmentID, default: Counters()].unresolved[key] = reason
    }

    // MARK: - Seal

    /// Appends final UNCONFIRMED rows for frames still lacking valid evidence,
    /// then freezes the recorder. Call at the end of the 2 s drain window.
    @discardableResult
    public func seal(
        at recordedRawNanoseconds: Int64,
        defaultReason: UnconfirmedReason = .noCallbackAtSessionClose
    ) -> SealResult {
        lock.lock()
        if sealed {
            let result = lastSeal
            lock.unlock()
            return result
        }
        sealed = true
        let pending = frames.values
            .filter { $0.presentedRawNanoseconds == nil }
            .sorted { $0.ordinal < $1.ordinal }
        for frame in pending where frame.submitted {
            if frame.lastReason == nil {
                let sample = frame.evidence[.systemPresent]
                appendLocked(.unconfirmed, identity: frame.identity,
                             evidence: withSystemPresent(frame.evidence, sample),
                             presentKind: .unconfirmed, reason: defaultReason,
                             platformIDs: frame.platformIDs, recordedRaw: recordedRawNanoseconds)
                counters[frame.identity.segmentID, default: Counters()].unresolved[
                    frame.identity.nativeFrameID.description
                ] = defaultReason
            }
        }
        let result = SealResult(
            pendingFrameCount: pending.count + untrackedUnconfirmedCount,
            lateAfterSealCount: lateAfterSealCount,
            untrackedResultCount: untrackedResultCount
        )
        lastSeal = result
        lock.unlock()
        return result
    }

    public func statistics() -> SessionStatistics {
        lock.lock()
        defer { lock.unlock() }
        let displayLost = displayLog.overflow?.lostEventCount ?? 0
        let configLost = eventWriter.log.overflow?.lostEventCount ?? 0
        let lost = displayLost + configLost
        var segments: [SegmentStatistics] = []
        for segmentID in counters.keys.sorted() {
            guard let counter = counters[segmentID] else { continue }
            var reasons: [UnconfirmedReason: Int] = [:]
            for reason in counter.unresolved.values {
                reasons[reason, default: 0] += 1
            }
            segments.append(SegmentStatistics(
                segmentID: segmentID,
                generated: counter.generated,
                submitted: counter.submitted,
                presented: counter.presented,
                unconfirmed: counter.unresolved.count,
                dataIntegrity: .complete,
                unconfirmedReasons: reasons
            ))
        }
        return SessionStatistics(
            segments: segments,
            lostEventCount: lost,
            dataIntegrity: lost == 0 && displayLog.failure == nil && eventWriter.log.failure == nil
                ? .complete : .incomplete
        )
    }

    // MARK: - Private

    private func bufferUntrackedLocked(_ key: String, outcome: BufferedOutcome) {
        if untrackedBuffered[key] == nil, untrackedBuffered.count >= untrackedBufferLimit,
           let oldest = untrackedBuffered.keys.first {
            untrackedBuffered.removeValue(forKey: oldest)
        }
        untrackedBuffered[key] = outcome
    }

    /// Merges the timing fields of one result row into the final per-frame
    /// record. Called under the recorder lock.
    private func recordTimingLocked(_ identity: FrameIdentity, _ evidence: Evidence) {
        let key = identity.nativeFrameID.description
        var timing = counters[identity.segmentID, default: Counters()].timing[key] ?? FrameTiming()
        if let submit = evidence[.submit].rawNanoseconds { timing.submit = submit }
        if let present = evidence[.systemPresent].rawNanoseconds { timing.present = present }
        if let complete = evidence[.renderComplete].rawNanoseconds { timing.renderComplete = complete }
        counters[identity.segmentID, default: Counters()].timing[key] = timing
    }

    /// Recomputes all distributions from the final per-frame records, so late
    /// callbacks, duplicates and seal rows cannot contribute twice. Called once
    /// at close; `statistics()` stays cheap for UI polling.
    public func timingStatistics() -> TimingStatistics {
        lock.lock()
        var submitToPresent: [Int64] = []
        var submitToComplete: [Int64] = []
        var completeToPresent: [Int64] = []
        var presentedIntervals: [Int64] = []
        for counters in counters.values {
            var presentsPerSegment: [Int64] = []
            for timing in counters.timing.values {
                if let submit = timing.submit, let present = timing.present, present >= submit {
                    submitToPresent.append(present - submit)
                }
                if let submit = timing.submit, let complete = timing.renderComplete, complete >= submit {
                    submitToComplete.append(complete - submit)
                }
                if let complete = timing.renderComplete, let present = timing.present, present >= complete {
                    completeToPresent.append(present - complete)
                }
                if let present = timing.present {
                    presentsPerSegment.append(present)
                }
            }
            // Adjacent real presentation times inside one segment only; a
            // segment boundary is not a hold interval.
            let sorted = presentsPerSegment.sorted()
            if sorted.count > 1 {
                for index in 1..<sorted.count where sorted[index] > sorted[index - 1] {
                    presentedIntervals.append(sorted[index] - sorted[index - 1])
                }
            }
        }
        lock.unlock()
        return TimingStatistics(
            submitToPresent: submitToPresent.isEmpty ? nil : TimingDistribution(samples: submitToPresent),
            submitToRenderComplete: submitToComplete.isEmpty ? nil : TimingDistribution(samples: submitToComplete),
            renderCompleteToPresent: completeToPresent.isEmpty ? nil : TimingDistribution(samples: completeToPresent),
            presentedInterval: presentedIntervals.isEmpty ? nil : TimingDistribution(samples: presentedIntervals)
        )
    }

    private func withSystemPresent(_ evidence: Evidence, _ sample: FieldSample) -> Evidence {
        var merged = evidence
        merged[.systemPresent] = sample
        return merged
    }

    private func appendLocked(
        _ type: DisplayEventType,
        identity: FrameIdentity,
        evidence: Evidence,
        presentKind: PresentKind?,
        reason: UnconfirmedReason?,
        platformIDs: PlatformIDs,
        recordedRaw: Int64
    ) {
        let payload = DisplayEventPayload(
            eventType: type,
            identity: identity,
            evidence: evidence,
            presentKind: presentKind,
            unconfirmedReason: reason,
            platformIDs: platformIDs,
            recordedRawNanoseconds: recordedRaw,
            timeBase: timeBase
        )
        if type != .submitted {
            recordTimingLocked(identity, evidence)
        }
        let written = displayLog.append { payload.json(eventSeq: $0) }
        if !written {
            dynamicBlocked = true
        }
    }
}
