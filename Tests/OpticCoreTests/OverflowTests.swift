import XCTest
@testable import OpticCore

final class OverflowTests: XCTestCase {
    func testRealQueueOverflowLatchesBoundaryAndKeepsWrittenEvents() throws {
        let sink = BlockingSink()
        let log = EventLog(logName: "display_events.jsonl", sink: sink, capacity: 3, batchSize: 1)
        // First append starts a write that blocks, so subsequent appends are
        // genuinely queued rather than written immediately.
        XCTAssertTrue(log.append { seq in ["event_seq": .int(Int64(seq)), "segment_id": .string("0")] })
        XCTAssertEqual(sink.writeStarted.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(log.append { seq in ["event_seq": .int(Int64(seq)), "segment_id": .string("0")] })
        XCTAssertTrue(log.append { seq in ["event_seq": .int(Int64(seq)), "segment_id": .string("0")] })
        // Capacity 3 is occupied by one in-flight line and two queued lines.
        XCTAssertFalse(log.append { seq in ["event_seq": .int(Int64(seq)), "segment_id": .string("0")] })
        XCTAssertFalse(log.append { seq in ["event_seq": .int(Int64(seq)), "segment_id": .string("1")] })

        let overflow = try XCTUnwrap(log.overflow)
        XCTAssertEqual(overflow.firstLostEventSeq, 3)
        XCTAssertEqual(overflow.lastLostEventSeq, 4)
        XCTAssertEqual(overflow.lostEventCount, 2)
        XCTAssertEqual(overflow.affectedSegmentIDs, [SegmentID(0), SegmentID(1)])
        XCTAssertEqual(overflow.affectedLog, "display_events.jsonl")

        sink.releaseAndWait()
        try log.flush()
        let seqs = sink.lines.compactMap { line -> Int64? in
            try? JSONParser.parse(line)["event_seq"]?.intValue
        }
        XCTAssertEqual(seqs, [0, 1, 2], "written events stay untouched; the gap is the latched range")
        XCTAssertFalse(sink.lines.contains { $0.contains("\"event_seq\":3,") })
    }

    func testRecorderBlocksNewDynamicStatesAfterLogOverflow() throws {
        let clock = FakeClock(start: 1_000_000_000)
        let sink = BlockingSink()
        let sessionID = SessionID(string: "11111111-2222-3333-4444-555555555555")!
        let timeBase = SessionTimeBase(originRawNanoseconds: 1_000_000_000)
        let displayLog = EventLog(logName: "display_events.jsonl", sink: sink, capacity: 2, batchSize: 1)
        let configurationSink = MemorySink()
        let configurationLog = EventLog(logName: "configuration_events.jsonl", sink: configurationSink,
                                        capacity: 16, batchSize: 1)
        let writer = SessionEventWriter(sessionID: sessionID, timeBase: timeBase,
                                        log: configurationLog, clock: clock)
        let recorder = PresentationRecorder(sessionID: sessionID, timeBase: timeBase,
                                            displayLog: displayLog, eventWriter: writer, clock: clock)

        let first = try TestFixtures.dynamicIdentity(sessionID: sessionID, segmentID: .zero,
                                                     layoutID: "layout-0", frameOrdinal: 1, seqValue: 0)
        let second = try TestFixtures.dynamicIdentity(sessionID: sessionID, segmentID: .zero,
                                                      layoutID: "layout-0", frameOrdinal: 2, seqValue: 1)
        let third = try TestFixtures.dynamicIdentity(sessionID: sessionID, segmentID: .zero,
                                                     layoutID: "layout-0", frameOrdinal: 3, seqValue: 2)
        // Keep the write queue busy first, then append until the bounded queue drops.
        XCTAssertEqual(recorder.begin(first), .tracking)
        // This append dispatches the first batch; the sink blocks it.
        recorder.submitted(first, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        XCTAssertEqual(sink.writeStarted.wait(timeout: .now() + 5), .success)
        recorder.presented(first, systemPresent: .validSeconds(1.02, api: "MTLDrawable.presentedTime"),
                           platformIDs: .none, at: clock.rawNanoseconds())
        // Queue (2 lines incl. in-flight) is full: this event is dropped.
        XCTAssertEqual(recorder.begin(second), .tracking)
        recorder.submitted(second, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)

        XCTAssertNotNil(displayLog.overflow)
        XCTAssertTrue(recorder.isDynamicBlocked)
        XCTAssertEqual(recorder.begin(third), .blockedByOverflow)
        let stats = recorder.statistics()
        XCTAssertEqual(stats.dataIntegrity, .incomplete)
        XCTAssertGreaterThanOrEqual(stats.lostEventCount, 1)

        sink.releaseAndWait()
        try displayLog.flush()
        XCTAssertNotNil(displayLog.overflow)
        XCTAssertNoThrow(try configurationLog.flush())
    }

    func testFlushReportsSinkFailure() throws {
        let log = EventLog(logName: "display_events.jsonl", sink: FailingSink(), capacity: 8, batchSize: 1)
        XCTAssertTrue(log.append { seq in ["event_seq": .int(Int64(seq))] })
        XCTAssertThrowsError(try log.flush())
        XCTAssertNotNil(log.failure)
    }
}
