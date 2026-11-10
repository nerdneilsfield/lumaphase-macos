import Foundation

/// Builds one `display_events.jsonl` object. All identity fields were captured
/// at submission time; nothing is re-read from the current segment.
struct DisplayEventPayload {
    let eventType: DisplayEventType
    let identity: FrameIdentity
    let evidence: Evidence
    let presentKind: PresentKind?
    let unconfirmedReason: UnconfirmedReason?
    let platformIDs: PlatformIDs
    let recordedRawNanoseconds: Int64
    let timeBase: SessionTimeBase

    func json(eventSeq: Int) -> JSONObject {
        var members = evidence.jsonRaw(timeBase)
        members["event_seq"] = .int(Int64(eventSeq))
        members["event_type"] = .string(eventType.rawValue)
        members["session_id"] = .string(identity.sessionID.description)
        members["segment_id"] = .string(identity.segmentID.description)
        members["layout_id"] = .string(identity.layoutID)
        members["native_frame_id"] = .string(identity.nativeFrameID.description)
        members["frame_kind"] = .string(identity.frameKind.rawValue)
        members["phase"] = .string(identity.phase.rawValue)
        members["render_seq"] = identity.renderSeq.map { .string($0.description) } ?? .null
        members["payload_n"] = identity.pattern.map { .int(Int64($0.payloadN)) } ?? .null
        members["crc8"] = identity.pattern.map { .int(Int64($0.crc8)) } ?? .null
        members["recorded_raw_ns"] = .int(recordedRawNanoseconds)
        members["recorded_ns"] = .int(timeBase.relative(recordedRawNanoseconds))
        members["timestamp_status"] = evidence.jsonStatus()
        members["present_kind"] = presentKind.map { .string($0.rawValue) } ?? .null
        members["unconfirmed_reason"] = unconfirmedReason.map { .string($0.rawValue) } ?? .null
        members["platform_ids"] = platformIDs.json()
        members["platform_timestamps"] = evidence.jsonPlatformTimestamps()
        return members
    }
}

/// Single writer of `configuration_events.jsonl`. The same instance is used by
/// the recorder (render failures) and by the app (segments, phases, overflow,
/// close) so `event_seq` stays contiguous per file.
public final class SessionEventWriter {
    public let sessionID: SessionID
    public let timeBase: SessionTimeBase
    public let log: EventLog
    private let clock: MonotonicClock

    public init(sessionID: SessionID, timeBase: SessionTimeBase, log: EventLog, clock: MonotonicClock) {
        self.sessionID = sessionID
        self.timeBase = timeBase
        self.log = log
        self.clock = clock
    }

    @discardableResult
    public func append(
        _ type: ConfigurationEventType,
        segmentID: SegmentID?,
        details: JSONObject,
        recordedRawNanoseconds: Int64? = nil
    ) -> Bool {
        let raw = recordedRawNanoseconds ?? clock.rawNanoseconds()
        return log.append { eventSeq in
            [
                "event_seq": .int(Int64(eventSeq)),
                "event_type": .string(type.rawValue),
                "session_id": .string(self.sessionID.description),
                "segment_id": segmentID.map { .string($0.description) } ?? .null,
                "recorded_raw_ns": .int(raw),
                "recorded_ns": .int(self.timeBase.relative(raw)),
                "details": .object(details)
            ]
        }
    }

    @discardableResult
    public func segmentStarted(_ config: SegmentConfig, reason: SegmentStartReason) -> Bool {
        append(.segmentStarted, segmentID: config.segmentID, details: [
            "configuration": config.json(),
            "reason": .string(reason.rawValue)
        ])
    }

    @discardableResult
    public func segmentEnded(_ segmentID: SegmentID, reason: SegmentEndReason, message: String? = nil) -> Bool {
        var details: JSONObject = ["reason": .string(reason.rawValue)]
        if let message { details["message"] = .string(message) }
        return append(.segmentEnded, segmentID: segmentID, details: details)
    }

    @discardableResult
    public func phaseChanged(
        from previous: SessionPhase?,
        to phase: SessionPhase,
        plannedDurationNanoseconds: Int64?
    ) -> Bool {
        append(.phaseChanged, segmentID: nil, details: [
            "previous_phase": previous.map { .string($0.rawValue) } ?? .null,
            "phase": .string(phase.rawValue),
            "planned_duration_ns": plannedDurationNanoseconds.map { .int($0) } ?? .null
        ])
    }

    /// Used both for pre-submit failures and for post-submit GPU command-buffer
    /// failures. In the latter case the earlier SUBMITTED row stays.
    @discardableResult
    public func renderFailure(
        identity: FrameIdentity?,
        segmentID: SegmentID?,
        operation: String,
        errorCode: String?,
        message: String
    ) -> Bool {
        let details: JSONObject = [
            "native_frame_id": identity.map { .string($0.nativeFrameID.description) } ?? .null,
            "render_seq": identity?.renderSeq.map { .string($0.description) } ?? .null,
            "operation": .string(operation),
            "error_code": errorCode.map(JSONValue.string) ?? .null,
            "message": .string(message)
        ]
        return append(.renderFailure, segmentID: segmentID ?? identity?.segmentID, details: details)
    }

    @discardableResult
    public func logOverflow(_ overflow: LogOverflow) -> Bool {
        append(.logOverflow, segmentID: nil, details: overflow.json().objectValue ?? [:])
    }

    @discardableResult
    public func sessionClosed(
        reason: SessionCloseReason,
        dataIntegrity: DataIntegrity,
        pendingFrameCount: Int,
        recordedRawNanoseconds: Int64
    ) -> Bool {
        append(.sessionClosed, segmentID: nil, details: [
            "reason": .string(reason.rawValue),
            "data_integrity": .string(dataIntegrity.rawValue),
            "pending_frame_count": .int(Int64(pendingFrameCount))
        ], recordedRawNanoseconds: recordedRawNanoseconds)
    }
}
