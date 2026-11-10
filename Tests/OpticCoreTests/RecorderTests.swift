import XCTest
@testable import OpticCore

final class RecorderTests: XCTestCase {
    struct Harness {
        let clock = FakeClock(start: 1_000_000_000)
        let displaySink = MemorySink()
        let configurationSink = MemorySink()
        let timeBase: SessionTimeBase
        let sessionID = SessionID(string: "6bd9ff04-8b4c-4df4-a5d9-86baa7c86d30")!
        let displayLog: EventLog
        let configurationLog: EventLog
        let writer: SessionEventWriter
        let recorder: PresentationRecorder

        init(pendingCapacity: Int = 8) {
            let timeBase = SessionTimeBase(originRawNanoseconds: 1_000_000_000)
            self.timeBase = timeBase
            self.displayLog = EventLog(logName: "display_events.jsonl", sink: displaySink,
                                       capacity: 4096, batchSize: 1)
            self.configurationLog = EventLog(logName: "configuration_events.jsonl", sink: configurationSink,
                                             capacity: 4096, batchSize: 1)
            self.writer = SessionEventWriter(sessionID: sessionID, timeBase: timeBase,
                                             log: configurationLog, clock: clock)
            self.recorder = PresentationRecorder(
                sessionID: sessionID, timeBase: timeBase, displayLog: displayLog,
                eventWriter: writer, clock: clock, pendingCapacity: pendingCapacity
            )
        }

        func displayEvents() throws -> [JSONValue] {
            try displayLog.flush()
            return try displaySink.events()
        }

        func configurationEvents() throws -> [JSONValue] {
            try configurationLog.flush()
            return try configurationSink.events()
        }
    }

    func testSubmittedThenPresentedKeepsIdentityAndRelativeTime() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 42, seqValue: 65_536
        )
        XCTAssertEqual(harness.recorder.begin(identity), .tracking)
        harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: PlatformIDs(
            surfaceInstanceID: "layer-A", drawableID: "7"
        ))
        harness.clock.advance(16_700_000)
        harness.recorder.presented(identity,
                                   systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
                                   platformIDs: PlatformIDs(surfaceInstanceID: "layer-A", drawableID: "7"),
                                   at: harness.clock.rawNanoseconds())

        let events = try harness.displayEvents()
        XCTAssertEqual(events.count, 2)
        let submitted = events[0]
        XCTAssertEqual(submitted["event_type"]?.stringValue, "SUBMITTED")
        XCTAssertEqual(submitted["event_seq"]?.intValue, 0)
        XCTAssertEqual(submitted["session_id"]?.stringValue, "6bd9ff04-8b4c-4df4-a5d9-86baa7c86d30")
        XCTAssertEqual(submitted["segment_id"]?.stringValue, "0")
        XCTAssertEqual(submitted["layout_id"]?.stringValue, "layout-0")
        XCTAssertEqual(submitted["native_frame_id"]?.stringValue, "42")
        XCTAssertEqual(submitted["render_seq"]?.stringValue, "65536")
        XCTAssertEqual(submitted["payload_n"]?.intValue, 0)
        XCTAssertEqual(submitted["crc8"]?.intValue, 0)
        XCTAssertEqual(submitted["frame_kind"]?.stringValue, "DYNAMIC")
        XCTAssertEqual(submitted["phase"]?.stringValue, "RUNNING")
        XCTAssertEqual(submitted["recorded_raw_ns"]?.intValue, 1_000_000_000)
        XCTAssertEqual(submitted["recorded_ns"]?.intValue, 0)
        XCTAssertEqual(submitted["present_kind"]?.stringValue, nil)
        XCTAssertEqual(submitted["platform_ids"]?["drawable_id"]?.stringValue, "7")
        XCTAssertEqual(submitted["platform_ids"]?["egl_frame_id"]?.stringValue, nil)
        XCTAssertEqual(submitted["timestamp_status"]?["submit"]?.stringValue, "VALID")
        XCTAssertEqual(submitted["timestamp_status"]?["system_present"]?.stringValue, "PENDING")
        XCTAssertEqual(submitted["timestamp_status"]?["latch"]?.stringValue, "UNSUPPORTED")
        XCTAssertEqual(submitted["submit_raw_ns"]?.intValue, 1_000_000_000)
        XCTAssertEqual(submitted["submit_ns"]?.intValue, 0)
        XCTAssertEqual(submitted["platform_timestamps"]?["submit"]?["api"]?.stringValue, "CLOCK_UPTIME_RAW")

        let presented = events[1]
        XCTAssertEqual(presented["event_type"]?.stringValue, "PRESENTED")
        XCTAssertEqual(presented["present_kind"]?.stringValue, "SYSTEM_REPORTED")
        XCTAssertEqual(presented["system_present_raw_ns"]?.intValue, 1_016_700_000)
        XCTAssertEqual(presented["system_present_ns"]?.intValue, 16_700_000)
        XCTAssertEqual(presented["timestamp_status"]?["system_present"]?.stringValue, "VALID")
        // Submission-time fields survive into the result event.
        XCTAssertEqual(presented["submit_raw_ns"]?.intValue, 1_000_000_000)
        XCTAssertEqual(presented["deadline_ns"]?.intValue, 15_000_000)
        XCTAssertEqual(presented["segment_id"]?.stringValue, "0")

        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.generated, 1)
        XCTAssertEqual(stats.segments.first?.submitted, 1)
        XCTAssertEqual(stats.segments.first?.presented, 1)
        XCTAssertEqual(stats.segments.first?.unconfirmed, 0)
    }

    func testPresentedCallbackBeforeSubmissionIsBuffered() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        XCTAssertEqual(harness.recorder.begin(identity), .tracking)
        // Drawable callback can fire before commit() returns.
        harness.recorder.presented(identity,
                                   systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())
        XCTAssertTrue(try harness.displayEvents().isEmpty)
        harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)

        let events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue }, ["SUBMITTED", "PRESENTED"])
        XCTAssertEqual(events.map { $0["event_seq"]?.intValue }, [0, 1])
    }

    func testLateResultKeepsOldSegmentAndLayout() throws {
        let harness = Harness()
        let layout0 = try LayoutBuilder.make(layoutID: "layout-0", profile: .f68,
                                             drawable: PixelSize(width: 3456, height: 2234), rotationDeg: 0)
        let layout1 = try LayoutBuilder.make(layoutID: "layout-1", profile: .c52,
                                             drawable: PixelSize(width: 1512, height: 982), rotationDeg: 0)
        let old = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 10, layout: layout0
        )
        let new = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: SegmentID(1), layoutID: "layout-1",
            frameOrdinal: 2, seqValue: 11, profile: .c52, layout: layout1
        )
        harness.recorder.begin(old)
        harness.recorder.submitted(old, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        // Segment 0 ends; a new segment with a new layout starts.
        harness.recorder.begin(new)
        harness.recorder.submitted(new, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        // The old frame's callback arrives after the new segment started.
        harness.clock.advance(40_000_000)
        harness.recorder.presented(old, systemPresent: .validSeconds(1.0400, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())

        let events = try harness.displayEvents()
        let late = try XCTUnwrap(events.last)
        XCTAssertEqual(late["event_type"]?.stringValue, "PRESENTED")
        XCTAssertEqual(late["native_frame_id"]?.stringValue, "1")
        XCTAssertEqual(late["segment_id"]?.stringValue, "0")
        XCTAssertEqual(late["layout_id"]?.stringValue, "layout-0")
        XCTAssertEqual(late["payload_n"]?.intValue, 10)
        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.count, 2)
        XCTAssertEqual(stats.segments[0].segmentID, .zero)
        XCTAssertEqual(stats.segments[0].presented, 1)
        XCTAssertEqual(stats.segments[1].segmentID, SegmentID(1))
        XCTAssertEqual(stats.segments[1].presented, 0)
        XCTAssertEqual(stats.segments[1].unconfirmed, 0)
    }

    func testDuplicateResultsAreNotAppendedButConflictsAreKept() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        harness.recorder.begin(identity)
        harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        harness.recorder.presented(identity, systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())
        harness.recorder.presented(identity, systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())
        var events = try harness.displayEvents()
        XCTAssertEqual(events.compactMap { $0["event_type"]?.stringValue }, ["SUBMITTED", "PRESENTED"])

        // A contradicting valid time is preserved rather than silently dropped.
        harness.recorder.presented(identity, systemPresent: .validSeconds(1.0170, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())
        events = try harness.displayEvents()
        XCTAssertEqual(events.compactMap { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "PRESENTED", "PRESENTED"])
        XCTAssertEqual(events.last?["system_present_ns"]?.intValue, 17_000_000)
        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.presented, 1)
    }

    func testUnconfirmedThenRealPresentationBeforeSeal() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        harness.recorder.begin(identity)
        harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        // presentedTime == 0: explicitly invalid, native value preserved.
        harness.recorder.unconfirmed(identity, reason: .timestampInvalid,
                                     systemPresent: .invalid(nativeValue: .double(0), api: "MTLDrawable.presentedTime",
                                                             nativeUnit: .seconds),
                                     platformIDs: .none, at: harness.clock.rawNanoseconds())
        harness.clock.advance(10_000_000)
        harness.recorder.presented(identity, systemPresent: .validSeconds(1.0200, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())
        let events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "UNCONFIRMED", "PRESENTED"])
        XCTAssertEqual(events[1]["unconfirmed_reason"]?.stringValue, "TIMESTAMP_INVALID")
        XCTAssertEqual(events[1]["platform_timestamps"]?["system_present"]?["native_value"]?.doubleValue, 0)
        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.presented, 1)
        XCTAssertEqual(stats.segments.first?.unconfirmed, 0)

        let seal = harness.recorder.seal(at: harness.clock.rawNanoseconds())
        XCTAssertEqual(seal.pendingFrameCount, 0)
        XCTAssertEqual(try harness.displayEvents().count, 3, "sealing a confirmed frame writes nothing")
    }

    func testUnconfirmedBeforeSubmissionIsBufferedUntilSubmitted() throws {
        // On macOS a presentedTime == 0 callback (explicitly invalid) can fire
        // before commit() returns. It must not be written before SUBMITTED.
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 7, seqValue: 2
        )
        XCTAssertEqual(harness.recorder.begin(identity), .tracking)
        harness.recorder.unconfirmed(identity, reason: .timestampInvalid,
                                     systemPresent: .invalid(nativeValue: .double(0),
                                                             api: "MTLDrawable.presentedTime",
                                                             nativeUnit: .seconds),
                                     platformIDs: PlatformIDs(surfaceInstanceID: "layer-A", drawableID: "3"),
                                     at: harness.clock.rawNanoseconds())
        // An identical repeat of the same invalid callback is not buffered twice.
        harness.recorder.unconfirmed(identity, reason: .timestampInvalid,
                                     systemPresent: .invalid(nativeValue: .double(0),
                                                             api: "MTLDrawable.presentedTime",
                                                             nativeUnit: .seconds),
                                     platformIDs: PlatformIDs(surfaceInstanceID: "layer-A", drawableID: "3"),
                                     at: harness.clock.rawNanoseconds())
        XCTAssertTrue(try harness.displayEvents().isEmpty, "no result may precede SUBMITTED")

        harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(),
                                   platformIDs: PlatformIDs(surfaceInstanceID: "layer-A", drawableID: "3"))
        let events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue }, ["SUBMITTED", "UNCONFIRMED"])
        XCTAssertEqual(events[1]["native_frame_id"]?.stringValue, "7")
        XCTAssertEqual(events[1]["unconfirmed_reason"]?.stringValue, "TIMESTAMP_INVALID")
        XCTAssertEqual(events[1]["timestamp_status"]?["system_present"]?.stringValue, "INVALID")
        XCTAssertEqual(events[1]["system_present_ns"]?.intValue, nil)
        XCTAssertEqual(events[1]["platform_ids"]?["drawable_id"]?.stringValue, "3")
        XCTAssertEqual(events[1]["platform_timestamps"]?["system_present"]?["native_value"]?.doubleValue, 0)

        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.generated, 1)
        XCTAssertEqual(stats.segments.first?.submitted, 1)
        XCTAssertEqual(stats.segments.first?.unconfirmed, 1)
        XCTAssertEqual(stats.segments.first?.unconfirmedReasons[.timestampInvalid], 1)
    }

    func testInvalidThenValidBeforeSubmissionKeepsBothRowsInOrder() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 8, seqValue: 3
        )
        harness.recorder.begin(identity)
        harness.recorder.unconfirmed(identity, reason: .timestampInvalid,
                                     systemPresent: .invalid(nativeValue: .double(0),
                                                             api: "MTLDrawable.presentedTime",
                                                             nativeUnit: .seconds),
                                     platformIDs: .none, at: harness.clock.rawNanoseconds())
        harness.recorder.presented(identity, systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())
        XCTAssertTrue(try harness.displayEvents().isEmpty)
        harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)

        let events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "UNCONFIRMED", "PRESENTED"],
                       "the invalid diagnostic is preserved, then the real result is accepted")
        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.presented, 1)
        XCTAssertEqual(stats.segments.first?.unconfirmed, 0)
    }

    func testValidBeforeInvalidBeforeSubmissionSuppressesTheContradiction() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 9, seqValue: 4
        )
        harness.recorder.begin(identity)
        harness.recorder.presented(identity, systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())
        harness.recorder.unconfirmed(identity, reason: .timestampInvalid,
                                     systemPresent: .invalid(nativeValue: .double(0),
                                                             api: "MTLDrawable.presentedTime",
                                                             nativeUnit: .seconds),
                                     platformIDs: .none, at: harness.clock.rawNanoseconds())
        harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)

        let events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue }, ["SUBMITTED", "PRESENTED"],
                       "a real presentation wins; no contradicting UNCONFIRMED row is written")
        XCTAssertEqual(harness.recorder.statistics().segments.first?.presented, 1)
    }

    func testPendingQueueFullStillWritesSubmittedAndUnconfirmed() throws {
        let harness = Harness(pendingCapacity: 1)
        let first = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        let second = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 2, seqValue: 1
        )
        XCTAssertEqual(harness.recorder.begin(first), .tracking)
        XCTAssertEqual(harness.recorder.begin(second), .pendingQueueFull)
        harness.recorder.submitted(first, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        harness.recorder.submitted(second, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)

        let events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "SUBMITTED", "UNCONFIRMED"])
        XCTAssertEqual(events.last?["native_frame_id"]?.stringValue, "2")
        XCTAssertEqual(events.last?["unconfirmed_reason"]?.stringValue, "PENDING_QUEUE_FULL")
        XCTAssertEqual(events.last?["timestamp_status"]?["system_present"]?.stringValue, "PENDING")
        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.generated, 2)
        XCTAssertEqual(stats.segments.first?.submitted, 2)
        XCTAssertEqual(stats.segments.first?.unconfirmed, 1)
        XCTAssertEqual(stats.dataIntegrity, .complete, "tracking loss alone must not mark the session incomplete")

        // Untracked frames still count as pending at close, per contract.
        let seal = harness.recorder.seal(at: harness.clock.rawNanoseconds())
        XCTAssertEqual(seal.pendingFrameCount, 2)
    }

    func testPendingQueueFullLateValidResultIsAppendedAfterUnconfirmed() throws {
        // R1: a frame rejected by the bounded tracking queue still gets a real
        // presented callback, because the driver registered it before commit.
        let harness = Harness(pendingCapacity: 1)
        let tracked = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        let rejected = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 2, seqValue: 1
        )
        XCTAssertEqual(harness.recorder.begin(tracked), .tracking)
        XCTAssertEqual(harness.recorder.begin(rejected), .pendingQueueFull)
        harness.recorder.submitted(tracked, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        harness.recorder.submitted(rejected, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)

        var events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "SUBMITTED", "UNCONFIRMED"])
        XCTAssertEqual(events.last?["unconfirmed_reason"]?.stringValue, "PENDING_QUEUE_FULL")

        // The real result arrives later and must be preserved, contract §7.2.4.
        let accepted = harness.recorder.presented(
            rejected,
            evidence: TestFixtures.submissionEvidence(),
            systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
            platformIDs: .none,
            at: harness.clock.rawNanoseconds()
        )
        XCTAssertTrue(accepted)
        events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "SUBMITTED", "UNCONFIRMED", "PRESENTED"],
                       "the old PENDING_QUEUE_FULL row stays and the real result is appended")
        XCTAssertEqual(events.last?["native_frame_id"]?.stringValue, "2")
        XCTAssertEqual(events.last?["present_kind"]?.stringValue, "SYSTEM_REPORTED")

        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.submitted, 2)
        XCTAssertEqual(stats.segments.first?.presented, 1)
        XCTAssertEqual(stats.segments.first?.unconfirmed, 0, "a late real result clears the final unconfirmed count")
        let seal = harness.recorder.seal(at: harness.clock.rawNanoseconds())
        XCTAssertEqual(seal.pendingFrameCount, 1, "only the never-answered tracked frame remains")
    }

    func testPendingQueueFullResultArrivingBeforeSubmitIsBuffered() throws {
        let harness = Harness(pendingCapacity: 1)
        let tracked = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        let rejected = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 2, seqValue: 1
        )
        XCTAssertEqual(harness.recorder.begin(tracked), .tracking)
        XCTAssertEqual(harness.recorder.begin(rejected), .pendingQueueFull)
        harness.recorder.submitted(tracked, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)

        // presentedTime callback fires before commit() returns for frame 2.
        XCTAssertTrue(harness.recorder.presented(
            rejected,
            evidence: TestFixtures.submissionEvidence(),
            systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
            platformIDs: .none,
            at: harness.clock.rawNanoseconds()
        ))
        var events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue }, ["SUBMITTED"],
                       "no result may be written before SUBMITTED")

        harness.recorder.submitted(rejected, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "SUBMITTED", "UNCONFIRMED", "PRESENTED"])
        XCTAssertEqual(events.last?["native_frame_id"]?.stringValue, "2")
        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.presented, 1)
        XCTAssertEqual(stats.segments.first?.unconfirmed, 0)
    }

    func testUntrackedResultWithoutPriorSubmissionIsNotWritten() throws {
        let harness = Harness()
        let ghost = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 99, seqValue: 9
        )
        // No begin()/submitted() at all: a real callback must not fabricate a
        // SUBMITTED or PRESENTED row.
        XCTAssertFalse(harness.recorder.presented(
            ghost,
            evidence: TestFixtures.submissionEvidence(),
            systemPresent: .validSeconds(1.0, api: "MTLDrawable.presentedTime"),
            platformIDs: .none,
            at: harness.clock.rawNanoseconds()
        ))
        XCTAssertTrue(try harness.displayEvents().isEmpty)
    }

    func testRenderCompleteEvidenceIsWrittenAndMeasured() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        harness.recorder.begin(identity)
        harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        harness.clock.advance(16_700_000)
        // E1 verified MTLCommandBuffer.gpuEndTime is host seconds in the same
        // domain; the recorder only stores what the platform returned.
        harness.recorder.presented(
            identity,
            systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
            renderComplete: .validSeconds(1.010, api: "MTLCommandBuffer.gpuEndTime"),
            platformIDs: .none,
            at: harness.clock.rawNanoseconds()
        )
        let events = try harness.displayEvents()
        let presented = try XCTUnwrap(events.last)
        XCTAssertEqual(presented["timestamp_status"]?["render_complete"]?.stringValue, "VALID")
        XCTAssertEqual(presented["render_complete_raw_ns"]?.intValue, 1_010_000_000)
        XCTAssertEqual(presented["render_complete_ns"]?.intValue, 10_000_000)
        XCTAssertEqual(presented["platform_timestamps"]?["render_complete"]?["native_value"]?.doubleValue, 1.010)
        XCTAssertEqual(presented["platform_timestamps"]?["render_complete"]?["native_unit"]?.stringValue, "SECONDS")
        XCTAssertEqual(presented["platform_timestamps"]?["render_complete"]?["api"]?.stringValue,
                       "MTLCommandBuffer.gpuEndTime")

        let timing = harness.recorder.timingStatistics()
        XCTAssertEqual(timing.submitToPresent?.count, 1)
        XCTAssertEqual(timing.submitToPresent?.p50NS, 16_700_000)
        XCTAssertEqual(timing.submitToRenderComplete?.p50NS, 10_000_000)
        XCTAssertEqual(timing.renderCompleteToPresent?.p50NS, 6_700_000)
    }

    func testLateValidEvidenceAcceptedAfterManyCapacityRejections() throws {
        // No arbitrary identity ring: a frame rejected long ago is still known
        // through its unresolved submission metadata.
        let harness = Harness(pendingCapacity: 1)
        let tracked = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        XCTAssertEqual(harness.recorder.begin(tracked), .tracking)
        harness.recorder.submitted(tracked, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)

        var rejected: [FrameIdentity] = []
        for index in 0..<70 {
            let identity = try TestFixtures.dynamicIdentity(
                sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
                frameOrdinal: UInt64(index + 2), seqValue: UInt64(index + 1)
            )
            XCTAssertEqual(harness.recorder.begin(identity), .pendingQueueFull)
            harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
            rejected.append(identity)
        }
        let oldest = rejected[0]
        XCTAssertTrue(harness.recorder.presented(
            oldest,
            evidence: TestFixtures.submissionEvidence(),
            systemPresent: .validSeconds(5.0, api: "MTLDrawable.presentedTime"),
            platformIDs: .none,
            at: harness.clock.rawNanoseconds()
        ), "evidence for an old capacity-rejected frame must still be accepted")
        let events = try harness.displayEvents()
        let late = try XCTUnwrap(events.last)
        XCTAssertEqual(late["event_type"]?.stringValue, "PRESENTED")
        XCTAssertEqual(late["native_frame_id"]?.stringValue, oldest.nativeFrameID.description)
        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.presented, 1)
        XCTAssertEqual(stats.segments.first?.unconfirmed, 69)
        let seal = harness.recorder.seal(at: harness.clock.rawNanoseconds())
        XCTAssertEqual(seal.pendingFrameCount, 70)
    }

    func testEarlyValidForRejectedFrameDoesNotCountAsPendingAtSeal() throws {
        let harness = Harness(pendingCapacity: 1)
        let tracked = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        let rejected = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 2, seqValue: 1
        )
        XCTAssertEqual(harness.recorder.begin(tracked), .tracking)
        XCTAssertEqual(harness.recorder.begin(rejected), .pendingQueueFull)
        harness.recorder.submitted(tracked, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        // Valid result before commit() returns.
        XCTAssertTrue(harness.recorder.presented(
            rejected,
            evidence: TestFixtures.submissionEvidence(),
            systemPresent: .validSeconds(1.0167, api: "MTLDrawable.presentedTime"),
            platformIDs: .none,
            at: harness.clock.rawNanoseconds()
        ))
        harness.recorder.submitted(rejected, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        let stats = harness.recorder.statistics()
        XCTAssertEqual(stats.segments.first?.presented, 1)
        XCTAssertEqual(stats.segments.first?.unconfirmed, 0)
        let seal = harness.recorder.seal(at: harness.clock.rawNanoseconds())
        XCTAssertEqual(seal.pendingFrameCount, 1,
                       "only the never-answered tracked frame is pending; the confirmed rejected frame is not")
    }

    func testTimingMergesPerFrameAndKeepsIntervalsInsideSegments() throws {
        let harness = Harness()
        func submission(_ raw: Int64) -> Evidence {
            .submission(
                targetPresent: .valid(rawNanoseconds: raw + 16_683_000, nativeValue: .double(Double(raw + 16_683_000) / 1e9),
                                      api: "CAMetalDisplayLink.Update.targetPresentationTimestamp", nativeUnit: .seconds),
                deadline: .valid(rawNanoseconds: raw + 15_000_000, nativeValue: .double(Double(raw + 15_000_000) / 1e9),
                                 api: "CAMetalDisplayLink.Update.targetTimestamp", nativeUnit: .seconds),
                submit: .valid(rawNanoseconds: raw, nativeValue: .int(raw), api: "CLOCK_UPTIME_RAW"),
                renderComplete: .pending(api: "MTLCommandBuffer.gpuEndTime")
            )
        }
        func gpuEnd(_ raw: Int64) -> FieldSample {
            .valid(rawNanoseconds: raw, nativeValue: .double(Double(raw) / 1e9),
                   api: "MTLCommandBuffer.gpuEndTime", nativeUnit: .seconds)
        }
        let clock = harness.clock
        let sessionID = harness.sessionID

        // Segment 0, frame 1: invalid row then a real presentation (same frame).
        let frame1 = try TestFixtures.dynamicIdentity(sessionID: sessionID, segmentID: .zero,
                                                      layoutID: "layout-0", frameOrdinal: 1, seqValue: 0)
        harness.recorder.begin(frame1)
        harness.recorder.submitted(frame1, evidence: submission(1_000_000_000), platformIDs: .none)
        harness.recorder.unconfirmed(frame1, reason: .timestampInvalid,
                                     systemPresent: .invalid(nativeValue: .double(0), api: "MTLDrawable.presentedTime",
                                                             nativeUnit: .seconds),
                                     renderComplete: gpuEnd(1_009_000_000),
                                     platformIDs: .none, at: clock.rawNanoseconds())
        harness.recorder.presented(frame1,
                                   systemPresent: .valid(rawNanoseconds: 1_016_700_000, nativeValue: .double(1.0167),
                                                         api: "MTLDrawable.presentedTime", nativeUnit: .seconds),
                                   renderComplete: gpuEnd(1_009_000_000),
                                   platformIDs: .none, at: clock.rawNanoseconds())

        // Segment 0, frame 2.
        let frame2 = try TestFixtures.dynamicIdentity(sessionID: sessionID, segmentID: .zero,
                                                      layoutID: "layout-0", frameOrdinal: 2, seqValue: 1)
        harness.recorder.begin(frame2)
        harness.recorder.submitted(frame2, evidence: submission(1_020_000_000), platformIDs: .none)
        harness.recorder.presented(frame2,
                                   systemPresent: .valid(rawNanoseconds: 1_033_400_000, nativeValue: .double(1.0334),
                                                         api: "MTLDrawable.presentedTime", nativeUnit: .seconds),
                                   renderComplete: gpuEnd(1_025_000_000),
                                   platformIDs: .none, at: clock.rawNanoseconds())

        // Segment 1, frame 3: a segment boundary must not create an interval.
        let frame3 = try TestFixtures.dynamicIdentity(sessionID: sessionID, segmentID: SegmentID(1),
                                                      layoutID: "layout-0", frameOrdinal: 3, seqValue: 2)
        harness.recorder.begin(frame3)
        harness.recorder.submitted(frame3, evidence: submission(1_100_000_000), platformIDs: .none)
        harness.recorder.presented(frame3,
                                   systemPresent: .valid(rawNanoseconds: 1_116_700_000, nativeValue: .double(1.1167),
                                                         api: "MTLDrawable.presentedTime", nativeUnit: .seconds),
                                   renderComplete: gpuEnd(1_108_000_000),
                                   platformIDs: .none, at: clock.rawNanoseconds())

        let timing = harness.recorder.timingStatistics()
        XCTAssertEqual(timing.submitToPresent?.count, 3, "frames, not rows: the invalid row must not double count")
        XCTAssertEqual(timing.submitToRenderComplete?.count, 3)
        XCTAssertEqual(timing.submitToPresent?.p50NS, 16_700_000)
        XCTAssertEqual(timing.presentedInterval?.count, 1, "only the two presents inside segment 0 form an interval")
        XCTAssertEqual(timing.presentedInterval?.p50NS, 16_700_000)
        XCTAssertEqual(timing.presentedInterval?.maxNS, 16_700_000)
    }

    func testSealWritesOnlyMissingResultsAndFreezesTheLog() throws {
        let harness = Harness()
        let invalid = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        let silent = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 2, seqValue: 1
        )
        for identity in [invalid, silent] {
            harness.recorder.begin(identity)
            harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        }
        harness.recorder.unconfirmed(invalid, reason: .timestampInvalid,
                                     systemPresent: .invalid(nativeValue: .int(0), api: "MTLDrawable.presentedTime",
                                                             nativeUnit: .seconds),
                                     platformIDs: .none, at: harness.clock.rawNanoseconds())
        harness.clock.advance(2_000_000_000)
        let seal = harness.recorder.seal(at: harness.clock.rawNanoseconds())
        XCTAssertEqual(seal.pendingFrameCount, 2)
        XCTAssertTrue(harness.recorder.isSealed)

        let events = try harness.displayEvents()
        XCTAssertEqual(events.map { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "SUBMITTED", "UNCONFIRMED", "UNCONFIRMED"])
        XCTAssertEqual(events[2]["unconfirmed_reason"]?.stringValue, "TIMESTAMP_INVALID")
        XCTAssertEqual(events[3]["native_frame_id"]?.stringValue, "2")
        XCTAssertEqual(events[3]["unconfirmed_reason"]?.stringValue, "NO_CALLBACK_AT_SESSION_CLOSE")

        let countAfterSeal = events.count
        harness.clock.advance(1_000_000)
        harness.recorder.presented(silent, systemPresent: .validSeconds(3.0, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())
        XCTAssertEqual(try harness.displayEvents().count, countAfterSeal, "sealed package must not change")
        XCTAssertEqual(harness.recorder.seal(at: harness.clock.rawNanoseconds()).pendingFrameCount, 2)
    }

    func testPreSubmitFailureWritesRenderFailureWithoutSubmitted() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 9, seqValue: 3
        )
        harness.recorder.begin(identity)
        harness.recorder.abandon(identity, operation: "makeCommandBuffer", errorCode: "MTL_ERROR", message: "boom")
        XCTAssertTrue(try harness.displayEvents().isEmpty)
        let configEvents = try harness.configurationEvents()
        XCTAssertEqual(configEvents.count, 1)
        XCTAssertEqual(configEvents[0]["event_type"]?.stringValue, "RENDER_FAILURE")
        XCTAssertEqual(configEvents[0]["details"]?["native_frame_id"]?.stringValue, "9")
        XCTAssertEqual(configEvents[0]["details"]?["render_seq"]?.stringValue, "3")
        XCTAssertEqual(configEvents[0]["details"]?["operation"]?.stringValue, "makeCommandBuffer")
        XCTAssertEqual(configEvents[0]["details"]?["error_code"]?.stringValue, "MTL_ERROR")
    }

    func testPostSubmitFailureKeepsSubmittedAndAcceptsLaterPresentation() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 5, seqValue: 4
        )
        harness.recorder.begin(identity)
        harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        harness.recorder.recordRenderFailureAfterSubmit(identity, errorCode: "3", message: "command buffer error")
        harness.recorder.presented(identity, systemPresent: .validSeconds(1.02, api: "MTLDrawable.presentedTime"),
                                   platformIDs: .none, at: harness.clock.rawNanoseconds())
        let displayEvents = try harness.displayEvents()
        XCTAssertEqual(displayEvents.map { $0["event_type"]?.stringValue }, ["SUBMITTED", "PRESENTED"])
        let configEvents = try harness.configurationEvents()
        XCTAssertEqual(configEvents.count, 1)
        XCTAssertEqual(configEvents[0]["details"]?["operation"]?.stringValue, "MTLCommandBuffer.status")
    }

    func testCompletedFramesDoNotConsumePendingCapacity() throws {
        // The bound applies to frames without valid presentation evidence. A
        // long session must not degrade into PENDING_QUEUE_FULL after the first
        // N confirmed frames.
        let harness = Harness(pendingCapacity: 2)
        for ordinal in 0..<12 {
            let identity = try TestFixtures.dynamicIdentity(
                sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
                frameOrdinal: UInt64(ordinal), seqValue: UInt64(ordinal)
            )
            XCTAssertEqual(harness.recorder.begin(identity), .tracking,
                           "frame \(ordinal) should still be tracked")
            harness.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
            harness.recorder.presented(identity, systemPresent: .validSeconds(1.02, api: "MTLDrawable.presentedTime"),
                                       platformIDs: .none, at: harness.clock.rawNanoseconds())
        }
        XCTAssertEqual(harness.recorder.statistics().segments.first?.presented, 12)
    }

    func testDuplicateFrameIdentityIsRejected() throws {
        let harness = Harness()
        let identity = try TestFixtures.dynamicIdentity(
            sessionID: harness.sessionID, segmentID: .zero, layoutID: "layout-0",
            frameOrdinal: 1, seqValue: 0
        )
        XCTAssertEqual(harness.recorder.begin(identity), .tracking)
        XCTAssertEqual(harness.recorder.begin(identity), .duplicateFrameID)
    }
}
