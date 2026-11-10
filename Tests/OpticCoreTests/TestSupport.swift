import Foundation
import XCTest
@testable import OpticCore

final class FakeClock: MonotonicClock {
    private(set) var now: Int64

    init(start: Int64 = 1_000_000_000) {
        self.now = start
    }

    func rawNanoseconds() -> Int64 { now }

    func advance(_ nanoseconds: Int64) {
        now += nanoseconds
    }
}

/// Collects JSONL text written through the real `EventLog` path.
final class MemorySink: EventLogSink {
    private let lock = NSLock()
    private var chunks: [String] = []
    private(set) var closed = false

    func write(_ data: Data) throws {
        lock.lock()
        chunks.append(String(decoding: data, as: UTF8.self))
        lock.unlock()
    }

    func close() throws {
        lock.lock()
        closed = true
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return chunks.joined()
    }

    var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func events() throws -> [JSONValue] {
        try lines.map { try JSONParser.parse($0) }
    }
}

/// Blocks the first write until released. Used to force real queue overflow
/// through the production append path.
final class BlockingSink: EventLogSink {
    let writeStarted = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var chunks: [String] = []
    private var didBlock = false

    func write(_ data: Data) throws {
        lock.lock()
        chunks.append(String(decoding: data, as: UTF8.self))
        let shouldBlock = !didBlock
        didBlock = true
        lock.unlock()
        if shouldBlock {
            writeStarted.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }

    func close() throws {}

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return chunks.joined().split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func releaseAndWait() {
        release.signal()
    }
}

func throwingSink() -> EventLogSink {
    FailingSink()
}

final class FailingSink: EventLogSink {
    func write(_ data: Data) throws { throw EventLogError.writeFailed("test sink") }
    func close() throws {}
}

enum TestFixtures {
    static func vectors() throws -> JSONValue {
        guard let url = Bundle.module.url(forResource: "protocol_test_vectors", withExtension: "json") else {
            throw XCTSkip("protocol_test_vectors.json missing from test bundle")
        }
        return try JSONParser.parse(Data(contentsOf: url))
    }

    static func displaySnapshot(
        width: Int = 3456,
        height: Int = 2234,
        profile: ExperimentProfile = .m59S1
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            displayModeID: "mode-\(width)x\(height)",
            drawableSize: PixelSize(width: width, height: height),
            displayRotationDeg: 0,
            reportedRefreshHz: 59.94,
            colorSpaceName: "kCGColorSpaceSRGB",
            pixelFormatName: "BGRA8Unorm",
            brightnessSource: .unknown
        )
    }

    static func manifest(timeBase: SessionTimeBase, sessionID: SessionID) -> SessionManifest {
        SessionManifest(
            sessionID: sessionID,
            sourceDeviceID: "Mac16,5-test",
            appID: "dev.lumaphase.app",
            appVersion: "0.0.0",
            appBuild: "1",
            osVersion: "14.0",
            osBuild: "23A344",
            timeOrigin: timeBase
        )
    }

    static func submissionEvidence(
        targetPresent: Int64 = 1_016_000_000,
        deadline: Int64 = 1_015_000_000,
        submit: Int64 = 1_000_000_000
    ) -> Evidence {
        .submission(
            targetPresent: .validSeconds(1.016, api: "CAMetalDisplayLink.Update.targetPresentationTimestamp"),
            deadline: .validSeconds(1.015, api: "CAMetalDisplayLink.Update.targetTimestamp"),
            submit: .valid(rawNanoseconds: submit, nativeValue: .int(submit), api: "CLOCK_UPTIME_RAW")
        )
    }

    static func dynamicIdentity(
        sessionID: SessionID,
        segmentID: SegmentID,
        layoutID: String,
        frameOrdinal: UInt64,
        seqValue: UInt64,
        profile: LayoutProfile = .f68,
        layout: LayoutSpec? = nil
    ) throws -> FrameIdentity {
        let bits = PatternEncoder.encode(RenderSeq(seqValue), profile: profile)
        let spec = try layout ?? LayoutBuilder.make(
            layoutID: layoutID,
            profile: profile,
            drawable: PixelSize(width: 3456, height: 2234),
            rotationDeg: 0
        )
        return try FrameIdentity(
            sessionID: sessionID,
            segmentID: segmentID,
            layoutID: spec.layoutID,
            nativeFrameID: NativeFrameID(frameOrdinal),
            frameKind: .dynamic,
            phase: .running,
            renderSeq: RenderSeq(seqValue),
            pattern: bits
        )
    }
}
