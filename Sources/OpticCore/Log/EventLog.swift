import Foundation

/// Destination for serialized JSONL lines. Real runs use a file; tests use an
/// in-memory or blocking sink to exercise overflow through the real path.
public protocol EventLogSink: AnyObject {
    func write(_ data: Data) throws
    func close() throws
}

public final class FileEventLogSink: EventLogSink {
    private let handle: FileHandle

    public init(fileURL: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil) else {
                throw EventLogError.cannotCreateFile(fileURL.path)
            }
        }
        self.handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
    }

    public func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    public func close() throws {
        try handle.close()
    }
}

public enum EventLogError: Error, Equatable {
    case cannotCreateFile(String)
    case writeFailed(String)
    case nonObjectEvent
}

/// Loss range latched on the first dropped event. The range is a boundary, not
/// a claim that every sequence number inside it is missing.
public struct LogOverflow: Equatable {
    public let affectedLog: String
    public var firstLostEventSeq: Int
    public var lastLostEventSeq: Int
    public var lostEventCount: Int
    public var affectedSegmentIDs: Set<SegmentID>

    func json() -> JSONValue {
        .object([
            "affected_log": .string(affectedLog),
            "affected_segment_ids": .array(affectedSegmentIDs.sorted().map { .string($0.description) }),
            "first_lost_event_seq": .int(Int64(firstLostEventSeq)),
            "last_lost_event_seq": .int(Int64(lastLostEventSeq)),
            "lost_event_count": .int(Int64(lostEventCount))
        ])
    }
}

/// Bounded, non-blocking-for-disk event log.
///
/// `append` assigns `event_seq` under a short lock and only serializes in
/// memory; the file write happens on a serial background queue. When the queue
/// plus in-flight lines reach `capacity`, the event is dropped and the loss is
/// latched (no overwrite, no blocking, no silent gap).
public final class EventLog {
    public let logName: String
    private let sink: EventLogSink
    private let capacity: Int
    private let batchSize: Int
    private let lock = NSLock()
    private let writeQueue: DispatchQueue

    private var lines: [String] = []
    private var inFlightLines = 0
    private var nextEventSeq = 0
    private var overflowState: LogOverflow?
    private var writeFailure: Error?

    public init(
        logName: String,
        sink: EventLogSink,
        capacity: Int = 4096,
        batchSize: Int = 64,
        queueLabel: String = "optic.eventlog"
    ) {
        self.logName = logName
        self.sink = sink
        self.capacity = max(1, capacity)
        self.batchSize = max(1, batchSize)
        self.writeQueue = DispatchQueue(label: queueLabel)
    }

    public var overflow: LogOverflow? {
        lock.lock()
        defer { lock.unlock() }
        return overflowState
    }

    public var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return writeFailure
    }

    public var queuedEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count + inFlightLines
    }

    /// Appends one event. The builder runs under the lock so `event_seq`
    /// assignment and enqueueing cannot interleave; it must not perform I/O.
    ///
    /// The batch dispatch also happens under the lock. `DispatchQueue.async`
    /// does not block, and enqueueing in sequence-number order is the only way
    /// two producers cannot write batch N+1 before batch N. `flush` enqueues
    /// its own batch the same way, so a `writeQueue.sync` barrier always covers
    /// every batch taken before it.
    @discardableResult
    public func append(_ build: (Int) -> JSONObject) -> Bool {
        lock.lock()
        let seq = nextEventSeq
        nextEventSeq += 1
        let object = build(seq)
        if lines.count + inFlightLines >= capacity {
            recordLossLocked(seq: seq, object: object)
            lock.unlock()
            return false
        }
        guard let text = try? JSONValue.object(object).serialized() else {
            // A non-finite number is a programming error, but the consumed
            // sequence number must not create an unexplained gap.
            recordLossLocked(seq: seq, object: object)
            lock.unlock()
            return false
        }
        lines.append(text)
        if lines.count >= batchSize {
            enqueueBatchLocked()
        }
        lock.unlock()
        return true
    }

    /// Writes every event appended before this call. The pending batch is
    /// enqueued under the lock, then the barrier waits outside the lock so the
    /// running write can still acquire it.
    public func flush() throws {
        lock.lock()
        enqueueBatchLocked()
        lock.unlock()

        writeQueue.sync {}
        // A write failure is reported after the barrier: by then every batch
        // enqueued before it has run and recorded its result.
        lock.lock()
        let failure = writeFailure
        lock.unlock()
        if let failure { throw failure }
    }

    public func close() throws {
        try flush()
        try sink.close()
    }

    // MARK: - Private

    /// Takes the pending lines and enqueues them for writing. The caller holds
    /// `lock`; `DispatchQueue.async` is non-blocking, and the sink write runs
    /// later outside the lock, so this cannot deadlock against `write` (which
    /// re-takes the lock to update `inFlightLines`).
    private func enqueueBatchLocked() {
        let batch = takeBatchLocked()
        guard !batch.isEmpty else { return }
        writeQueue.async { self.write(batch) }
    }

    private func takeBatchLocked() -> [String] {
        guard !lines.isEmpty else { return [] }
        let batch = lines
        lines.removeAll(keepingCapacity: false)
        inFlightLines += batch.count
        return batch
    }

    private func write(_ batch: [String]) {
        defer {
            lock.lock()
            inFlightLines -= batch.count
            lock.unlock()
        }
        let data = Data(batch.joined(separator: "\n").utf8) + Data([0x0A])
        do {
            try sink.write(data)
        } catch {
            lock.lock()
            if writeFailure == nil { writeFailure = error }
            lock.unlock()
        }
    }

    private func recordLossLocked(seq: Int, object: JSONObject) {
        var affected: Set<SegmentID> = []
        if let segment = object["segment_id"]?.stringValue, let value = UInt32(segment) {
            affected.insert(SegmentID(value))
        }
        if var state = overflowState {
            state.lastLostEventSeq = seq
            state.lostEventCount += 1
            state.affectedSegmentIDs.formUnion(affected)
            overflowState = state
        } else {
            overflowState = LogOverflow(
                affectedLog: logName,
                firstLostEventSeq: seq,
                lastLostEventSeq: seq,
                lostEventCount: 1,
                affectedSegmentIDs: affected
            )
        }
    }
}
