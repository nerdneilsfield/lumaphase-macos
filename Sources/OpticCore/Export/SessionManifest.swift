import Foundation

/// Session-level manifest (contract §2.1). Segments are appended by
/// `SessionPackage`; the file is written once at finish.
public struct SessionManifest {
    public var schemaVersion: String
    public var protocolVersion: String
    public var sessionID: SessionID
    public var platform: Platform
    public var sourceDeviceID: String
    public var appID: String
    public var appVersion: String
    public var appBuild: String
    public var osVersion: String
    public var osBuild: String
    public var clockDomain: String
    public var timeOrigin: SessionTimeBase
    public var presentationDrainTimeoutNanoseconds: Int64
    public var segments: [SegmentConfig]

    public init(
        sessionID: SessionID,
        sourceDeviceID: String,
        appID: String,
        appVersion: String,
        appBuild: String,
        osVersion: String,
        osBuild: String,
        timeOrigin: SessionTimeBase,
        platform: Platform = .macOS,
        clockDomain: String = SessionClockDomain.macOSHostTime,
        presentationDrainTimeoutNanoseconds: Int64 = SessionClockDomain.presentationDrainTimeoutNanoseconds,
        segments: [SegmentConfig] = []
    ) {
        self.schemaVersion = "1.1"
        self.protocolVersion = "OPTC-1"
        self.sessionID = sessionID
        self.platform = platform
        self.sourceDeviceID = sourceDeviceID
        self.appID = appID
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.clockDomain = clockDomain
        self.timeOrigin = timeOrigin
        self.presentationDrainTimeoutNanoseconds = presentationDrainTimeoutNanoseconds
        self.segments = segments
    }

    public func json() -> JSONValue {
        .object([
            "schema_version": .string(schemaVersion),
            "protocol_version": .string(protocolVersion),
            "session_id": .string(sessionID.description),
            "platform": .string(platform.rawValue),
            "source_device_id": .string(sourceDeviceID),
            "app_id": .string(appID),
            "app_version": .string(appVersion),
            "app_build": .string(appBuild),
            "os_version": .string(osVersion),
            "os_build": .string(osBuild),
            "clock_domain": .string(clockDomain),
            "time_origin": timeOrigin.json(),
            "presentation_drain_timeout_ns": .int(presentationDrainTimeoutNanoseconds),
            "segments": .array(segments.map { $0.json() })
        ])
    }
}

public struct SessionClose {
    public var reason: SessionCloseReason
    public var closedAtRawNanoseconds: Int64
    public var pendingFrameCount: Int

    public init(reason: SessionCloseReason, closedAtRawNanoseconds: Int64, pendingFrameCount: Int) {
        self.reason = reason
        self.closedAtRawNanoseconds = closedAtRawNanoseconds
        self.pendingFrameCount = pendingFrameCount
    }
}

/// `session_summary.json` (contract §10). Counts are merged by submission
/// identity before they are summarised, so a frame that was unconfirmed and then
/// presented is only counted as presented.
public struct SessionSummary {
    public var sessionID: SessionID
    public var closedRawNanoseconds: Int64
    public var closedNanoseconds: Int64
    public var dataIntegrity: DataIntegrity
    public var lostEventCount: Int
    public var segments: [SegmentStatistics]
    /// Measured submit/GPU/presentation intervals (design §10). Omitted from the
    /// JSON when no valid samples exist.
    public var timing: TimingStatistics

    public init(
        sessionID: SessionID,
        closedRawNanoseconds: Int64,
        closedNanoseconds: Int64,
        dataIntegrity: DataIntegrity,
        lostEventCount: Int,
        segments: [SegmentStatistics],
        timing: TimingStatistics = .empty
    ) {
        self.timing = timing
        self.sessionID = sessionID
        self.closedRawNanoseconds = closedRawNanoseconds
        self.closedNanoseconds = closedNanoseconds
        self.dataIntegrity = dataIntegrity
        self.lostEventCount = lostEventCount
        self.segments = segments
    }

    public func json() -> JSONValue {
        var members: JSONObject = [
            "session_id": .string(sessionID.description),
            "closed_raw_ns": .int(closedRawNanoseconds),
            "closed_ns": .int(closedNanoseconds),
            "data_integrity": .string(dataIntegrity.rawValue),
            "lost_event_count": .int(Int64(lostEventCount)),
            "segments": .array(segments.map { $0.json() })
        ]
        if !timing.isEmpty {
            members["timing"] = timing.json()
        }
        return .object(members)
    }
}
