import Foundation

/// Identity of one export session. JSON uses the lowercase hyphenated UUID.
public struct SessionID: Hashable, CustomStringConvertible {
    public let uuid: UUID

    public init(uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString.lowercased() }
}

/// Segment identity inside a session. Decimal string in JSON, never reused.
public struct SegmentID: Hashable, Comparable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    public static let zero = SegmentID(0)

    public func successor() -> SegmentID {
        SegmentID(value &+ 1)
    }

    public var description: String { String(value) }

    public static func < (lhs: SegmentID, rhs: SegmentID) -> Bool {
        lhs.value < rhs.value
    }
}

/// Application-assigned frame identity. It is the only correlation primary key;
/// platform drawable IDs are diagnostics and never an index.
public struct NativeFrameID: Hashable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    public var description: String { String(value) }
}

/// Allocates session-unique frame identities. Intended to be driven from the
/// single render context; the display link callback in T2 is the only caller.
public final class FrameIdentityAllocator {
    private var nextValue: UInt64 = 0

    public init() {}

    public func allocate() -> NativeFrameID {
        let value = nextValue
        nextValue &+= 1
        return NativeFrameID(value)
    }

    public var allocatedCount: UInt64 { nextValue }
}

public enum DisplayFrameKind: String, CaseIterable {
    case warmup = "WARMUP"
    case sessionCard = "SESSION_CARD"
    case dynamic = "DYNAMIC"
    case endCard = "END_CARD"
    case calibration = "CALIBRATION"
}

public enum SessionPhase: String, CaseIterable {
    case idle = "IDLE"
    case configured = "CONFIGURED"
    case warmup = "WARMUP"
    case sessionCard = "SESSION_CARD"
    case running = "RUNNING"
    case endCard = "END_CARD"
    case calibration = "CALIBRATION"
    case paused = "PAUSED"
    case export = "EXPORT"

    /// Display events only use the phases that render frames.
    public var isDisplayPhase: Bool {
        switch self {
        case .warmup, .sessionCard, .running, .calibration, .endCard: return true
        case .idle, .configured, .paused, .export: return false
        }
    }
}

public enum TimestampStatus: String, CaseIterable {
    case valid = "VALID"
    case pending = "PENDING"
    case invalid = "INVALID"
    case unsupported = "UNSUPPORTED"
    case notApplicable = "NOT_APPLICABLE"
    case queryFailed = "QUERY_FAILED"
    case clockDomainUnverified = "CLOCK_DOMAIN_UNVERIFIED"
}

public enum TimestampField: String, CaseIterable, Hashable {
    case targetPresent = "target_present"
    case systemPresent = "system_present"
    case submit = "submit"
    case deadline = "deadline"
    case renderComplete = "render_complete"
    case latch = "latch"
}

public enum NativeTimeUnit: String {
    case nanoseconds = "NS"
    case seconds = "SECONDS"
}

public enum PresentKind: String {
    case systemReported = "SYSTEM_REPORTED"
    case expectedOnly = "EXPECTED_ONLY"
    case referenceFitted = "REFERENCE_FITTED"
    case unconfirmed = "UNCONFIRMED"
}

public enum DisplayEventType: String {
    case submitted = "SUBMITTED"
    case presented = "PRESENTED"
    case unconfirmed = "UNCONFIRMED"
}

public enum UnconfirmedReason: String, CaseIterable {
    case timestampUnsupported = "TIMESTAMP_UNSUPPORTED"
    case timestampInvalid = "TIMESTAMP_INVALID"
    case queryFailed = "QUERY_FAILED"
    case clockDomainUnverified = "CLOCK_DOMAIN_UNVERIFIED"
    case historyExpired = "HISTORY_EXPIRED"
    case pendingQueueFull = "PENDING_QUEUE_FULL"
    case surfaceDestroyed = "SURFACE_DESTROYED"
    case pendingAtSessionClose = "PENDING_AT_SESSION_CLOSE"
    case noCallbackAtSessionClose = "NO_CALLBACK_AT_SESSION_CLOSE"
}

public enum ConfigurationEventType: String {
    case segmentStarted = "SEGMENT_STARTED"
    case segmentEnded = "SEGMENT_ENDED"
    case phaseChanged = "PHASE_CHANGED"
    case renderFailure = "RENDER_FAILURE"
    case logOverflow = "LOG_OVERFLOW"
    case sessionClosed = "SESSION_CLOSED"
}

public enum SegmentStartReason: String {
    case sessionStart = "SESSION_START"
    case resume = "RESUME"
    case configurationChanged = "CONFIGURATION_CHANGED"
}

public enum SegmentEndReason: String, CaseIterable {
    case normalEnd = "NORMAL_END"
    case paused = "PAUSED"
    case background = "BACKGROUND"
    case fullscreenExit = "FULLSCREEN_EXIT"
    case systemSleep = "SYSTEM_SLEEP"
    case displayChanged = "DISPLAY_CHANGED"
    case surfaceChanged = "SURFACE_CHANGED"
    case configurationChanged = "CONFIGURATION_CHANGED"
    case logOverflow = "LOG_OVERFLOW"
    case renderFailure = "RENDER_FAILURE"
    case userStop = "USER_STOP"
}

public enum SessionCloseReason: String {
    case normalEnd = "NORMAL_END"
    case userStop = "USER_STOP"
    case logOverflow = "LOG_OVERFLOW"
    case renderFailure = "RENDER_FAILURE"
}

public enum DataIntegrity: String {
    case complete = "COMPLETE"
    case incomplete = "INCOMPLETE"
}

public enum Platform: String {
    case macOS = "MACOS"
    case android = "ANDROID"
}

public enum BrightnessSource: String {
    case systemReported = "SYSTEM_REPORTED"
    case operatorReported = "OPERATOR_REPORTED"
    case unknown = "UNKNOWN"
}
