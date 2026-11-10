import XCTest
@testable import OpticCore

final class EventLogConcurrencyTests: XCTestCase {
    /// Two producers used to take a batch under the lock, unlock, and only then
    /// call `writeQueue.async`; a slower producer could therefore enqueue batch
    /// N+1 before batch N, and a concurrent `flush` barrier could pass a batch
    /// that was taken but not yet enqueued. Both would break `event_seq`
    /// ordering in the file.
    func testConcurrentProducersKeepSequenceOrderAndFlushCoversPriorBatches() throws {
        let sink = MemorySink()
        let log = EventLog(logName: "display_events.jsonl", sink: sink,
                           capacity: 100_000, batchSize: 1, queueLabel: "concurrency.test")
        let producerCount = 4
        let perProducer = 500
        let total = producerCount * perProducer

        let done = DispatchGroup()
        for producer in 0..<producerCount {
            DispatchQueue.global().async(group: done) {
                for index in 0..<perProducer {
                    XCTAssertTrue(log.append { seq in
                        [
                            "event_seq": .int(Int64(seq)),
                            "producer": .int(Int64(producer)),
                            "index": .int(Int64(index))
                        ]
                    })
                }
            }
        }

        // A concurrent flusher: every completed flush must leave a prefix of
        // the final file, never a hole that a later batch fills.
        let stateLock = NSLock()
        var producing = true
        var snapshots: [[String]] = []
        let flusherDone = DispatchGroup()
        DispatchQueue.global().async(group: flusherDone) {
            while true {
                stateLock.lock()
                let active = producing
                stateLock.unlock()
                if !active { break }
                try? log.flush()
                let snapshot = sink.lines
                stateLock.lock()
                snapshots.append(snapshot)
                stateLock.unlock()
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }

        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        stateLock.lock()
        producing = false
        stateLock.unlock()
        XCTAssertEqual(flusherDone.wait(timeout: .now() + 10), .success)
        try log.flush()

        let lines = sink.lines
        XCTAssertEqual(lines.count, total)
        let seqs = try lines.map { try JSONParser.parse($0)["event_seq"]?.intValue }
        XCTAssertEqual(seqs, (0..<Int64(total)).map { Optional($0) },
                       "file order must equal event_seq order")

        // Flush snapshots are prefixes of the final file.
        for (index, snapshot) in snapshots.enumerated() {
            XCTAssertLessThanOrEqual(snapshot.count, lines.count)
            XCTAssertEqual(Array(lines.prefix(snapshot.count)), snapshot,
                           "flush snapshot \(index) is not a prefix of the final file")
        }

        // Each producer's own events keep their append order.
        var lastIndex: [Int: Int64] = [:]
        for line in lines {
            let object = try JSONParser.parse(line)
            let producer = Int(try XCTUnwrap(object["producer"]?.intValue))
            let index = try XCTUnwrap(object["index"]?.intValue)
            if let previous = lastIndex[producer] {
                XCTAssertGreaterThan(index, previous, "producer \(producer) reordered")
            }
            lastIndex[producer] = index
        }
        XCTAssertEqual(lastIndex.count, producerCount)
        for producer in 0..<producerCount {
            XCTAssertEqual(lastIndex[producer], Int64(perProducer - 1))
        }
    }

    /// A batch below `batchSize` is only written by `flush`, and a flush that
    /// runs while the writer is busy must not return before that batch lands.
    func testFlushWaitsForInFlightWriteAndIncludesPendingBatch() throws {
        let sink = BlockingSink()
        let log = EventLog(logName: "display_events.jsonl", sink: sink, capacity: 8, batchSize: 1)
        XCTAssertTrue(log.append { seq in ["event_seq": .int(Int64(seq))] })
        XCTAssertEqual(sink.writeStarted.wait(timeout: .now() + 5), .success)

        let flushFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? log.flush()
            flushFinished.signal()
        }
        // The flusher cannot pass the blocked write.
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 0.2), .timedOut)
        sink.releaseAndWait()
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(sink.lines.count, 1)
    }
}
