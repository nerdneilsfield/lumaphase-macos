import Foundation

public enum SessionPackageError: Error, Equatable {
    case directoryExists(String)
    case duplicateSegment(String)
    case duplicateLayout(String)
    case duplicateProfile(String)
    case missingLayout(String)
    case missingProfile(String)
    case alreadyFinished
    case writeFailed(String)
}

/// One exported session directory (contract §2 layout of files).
///
/// The package owns the two JSONL logs and the configuration event writer, and
/// writes `manifest.json`, `layout.json`, `display_profile.json` and
/// `session_summary.json` exactly once at finish. Logs are written directly to
/// the directory from the first event, so a crash never invents a complete
/// session.
public final class SessionPackage {
    public static let displayEventsFileName = "display_events.jsonl"
    public static let configurationEventsFileName = "configuration_events.jsonl"
    public static let manifestFileName = "manifest.json"
    public static let layoutFileName = "layout.json"
    public static let displayProfileFileName = "display_profile.json"
    public static let summaryFileName = "session_summary.json"

    public let sessionID: SessionID
    public let directory: URL
    public let displayLog: EventLog
    public let configurationLog: EventLog
    public let eventWriter: SessionEventWriter
    public let timeBase: SessionTimeBase

    private var manifest: SessionManifest
    private var layouts: [LayoutSpec] = []
    private var profiles: [ImportedCalibrationProfile] = []
    private var segmentIDs: Set<SegmentID> = []
    private var finished = false

    public init(
        root: URL,
        manifest: SessionManifest,
        timeBase: SessionTimeBase,
        clock: MonotonicClock,
        displayCapacity: Int = 4096,
        configurationCapacity: Int = 1024
    ) throws {
        let directory = root.appendingPathComponent("session_\(manifest.sessionID.description)", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            throw SessionPackageError.directoryExists(directory.path)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.sessionID = manifest.sessionID
        self.directory = directory
        self.manifest = manifest
        self.timeBase = timeBase

        let displaySink = try FileEventLogSink(
            fileURL: directory.appendingPathComponent(SessionPackage.displayEventsFileName)
        )
        let configurationSink = try FileEventLogSink(
            fileURL: directory.appendingPathComponent(SessionPackage.configurationEventsFileName)
        )
        self.displayLog = EventLog(logName: SessionPackage.displayEventsFileName, sink: displaySink,
                                   capacity: displayCapacity, batchSize: 64,
                                   queueLabel: "optic.eventlog.display.\(manifest.sessionID.description)")
        self.configurationLog = EventLog(logName: SessionPackage.configurationEventsFileName,
                                         sink: configurationSink,
                                         capacity: configurationCapacity, batchSize: 32,
                                         queueLabel: "optic.eventlog.config.\(manifest.sessionID.description)")
        self.eventWriter = SessionEventWriter(sessionID: manifest.sessionID, timeBase: timeBase,
                                              log: configurationLog, clock: clock)
        // Persist the session identity before any display starts.
        try write(manifest.json(), name: SessionPackage.manifestFileName)
    }

    /// Registers a layout object and persists `layout.json` immediately, as the
    /// design requires configuration and layout to be on disk before display.
    /// Identical re-registration is allowed; the referenced object stays
    /// immutable.
    public func addLayout(_ layout: LayoutSpec) throws {
        guard !finished else { throw SessionPackageError.alreadyFinished }
        if let existing = layouts.first(where: { $0.layoutID == layout.layoutID }) {
            guard existing == layout else { throw SessionPackageError.duplicateLayout(layout.layoutID) }
            return
        }
        layouts.append(layout)
        try writeLayoutDocument()
    }

    public func addSegment(_ config: SegmentConfig) throws {
        guard !finished else { throw SessionPackageError.alreadyFinished }
        guard !segmentIDs.contains(config.segmentID) else {
            throw SessionPackageError.duplicateSegment(config.segmentID.description)
        }
        guard layouts.contains(where: { $0.layoutID == config.layoutID }) else {
            throw SessionPackageError.missingLayout(config.layoutID)
        }
        if let profileID = config.displayProfileID,
           !profiles.contains(where: { $0.profileID == profileID }) {
            throw SessionPackageError.missingProfile(profileID)
        }
        segmentIDs.insert(config.segmentID)
        manifest.segments.append(config)
        try write(manifest.json(), name: SessionPackage.manifestFileName)
        try writeProfileDocument()
    }

    public func addProfile(_ profile: ImportedCalibrationProfile) throws {
        guard !finished else { throw SessionPackageError.alreadyFinished }
        if let existing = profiles.first(where: { $0.profileID == profile.profileID }) {
            guard existing == profile else { throw SessionPackageError.duplicateProfile(profile.profileID) }
            return
        }
        profiles.append(profile)
        try writeProfileDocument()
    }

    public var registeredSegments: [SegmentConfig] { manifest.segments }
    public var registeredLayouts: [LayoutSpec] { layouts }

    /// Flushes both logs, writes LOG_OVERFLOW rows from the latches, then the
    /// closing events and the four JSON documents. Returns the session
    /// directory. Never rewrites events.
    @discardableResult
    public func finish(
        close: SessionClose,
        statistics: SessionStatistics,
        timing: TimingStatistics = .empty
    ) throws -> URL {
        guard !finished else { throw SessionPackageError.alreadyFinished }

        // Drain first: the contract requires LOG_OVERFLOW to be written after
        // the writer has caught up, so the latch itself is not lost.
        try flushQuietly(displayLog)
        try flushQuietly(configurationLog)

        let displayOverflow = displayLog.overflow
        let configurationOverflow = configurationLog.overflow
        // The recorder derives its count from the same latches; take the
        // larger value so a package-only overflow (configuration log) still
        // shows up without double counting.
        let latchLost = (displayOverflow?.lostEventCount ?? 0)
            + (configurationOverflow?.lostEventCount ?? 0)
        let lostEventCount = max(statistics.lostEventCount, latchLost)
        var integrity: DataIntegrity = lostEventCount == 0
            && displayLog.failure == nil
            && configurationLog.failure == nil
            ? .complete : .incomplete
        if displayOverflow == nil && configurationOverflow == nil && statistics.dataIntegrity == .incomplete {
            integrity = .incomplete
        }

        var affectedSegments: Set<SegmentID> = []
        var closingWritesSucceeded = true
        if let displayOverflow {
            affectedSegments.formUnion(displayOverflow.affectedSegmentIDs)
            closingWritesSucceeded = eventWriter.logOverflow(displayOverflow) && closingWritesSucceeded
        }
        if let configurationOverflow {
            affectedSegments.formUnion(configurationOverflow.affectedSegmentIDs)
            closingWritesSucceeded = eventWriter.logOverflow(configurationOverflow) && closingWritesSucceeded
        }
        closingWritesSucceeded = eventWriter.sessionClosed(
            reason: close.reason,
            dataIntegrity: integrity,
            pendingFrameCount: close.pendingFrameCount,
            recordedRawNanoseconds: close.closedAtRawNanoseconds
        ) && closingWritesSucceeded

        try flushQuietly(configurationLog)
        try flushQuietly(displayLog)
        guard closingWritesSucceeded else {
            // Without a trustworthy closing sequence the package would claim a
            // complete session it cannot prove; report an export failure.
            throw SessionPackageError.writeFailed("closing configuration events were dropped")
        }
        try configurationLog.close()
        try displayLog.close()

        // Per-segment integrity is INCOMPLETE if that segment lost events.
        var segmentStats = statistics.segments
        for index in segmentStats.indices {
            if affectedSegments.contains(segmentStats[index].segmentID)
                || configurationLog.failure != nil
                || displayLog.failure != nil {
                segmentStats[index].dataIntegrity = .incomplete
            } else {
                segmentStats[index].dataIntegrity = .complete
            }
        }
        var bySegment: [SegmentID: SegmentStatistics] = [:]
        for stats in segmentStats {
            bySegment[stats.segmentID] = stats
        }
        var orderedStats: [SegmentStatistics] = []
        for segment in manifest.segments {
            if let stats = bySegment.removeValue(forKey: segment.segmentID) {
                orderedStats.append(stats)
            } else {
                orderedStats.append(SegmentStatistics(
                    segmentID: segment.segmentID, generated: 0, submitted: 0, presented: 0,
                    unconfirmed: 0, dataIntegrity: .complete, unconfirmedReasons: [:]
                ))
            }
        }
        orderedStats.append(contentsOf: bySegment.values.sorted { $0.segmentID < $1.segmentID })

        let summary = SessionSummary(
            sessionID: sessionID,
            closedRawNanoseconds: close.closedAtRawNanoseconds,
            closedNanoseconds: timeBase.relative(close.closedAtRawNanoseconds),
            dataIntegrity: integrity,
            lostEventCount: lostEventCount,
            segments: orderedStats,
            timing: timing
        )

        try writeLayoutDocument()
        try writeProfileDocument()
        try write(manifest.json(), name: SessionPackage.manifestFileName)
        try write(summary.json(), name: SessionPackage.summaryFileName)
        finished = true
        return directory
    }

    // MARK: - Private

    private func writeLayoutDocument() throws {
        let document = JSONValue.object([
            "schema_version": .string("1.1"),
            "layouts": .array(layouts.map { $0.json() })
        ])
        try write(document, name: SessionPackage.layoutFileName)
    }

    private func writeProfileDocument() throws {
        let bindings = manifest.segments.map { segment -> SegmentProfileBinding in
            guard let layout = layouts.first(where: { $0.layoutID == segment.layoutID }) else {
                return SegmentProfileBinding(segmentID: segment.segmentID, profileID: nil,
                                             status: .missing, mismatchFields: [])
            }
            let profile = segment.displayProfileID.flatMap { id in
                profiles.first { $0.profileID == id }
            }
            return CalibrationMatcher.binding(
                segment: segment,
                layout: layout,
                profile: profile,
                sourceDeviceID: manifest.sourceDeviceID,
                osBuild: manifest.osBuild
            )
        }
        let referencedProfiles = profiles.filter { profile in
            manifest.segments.contains { $0.displayProfileID == profile.profileID }
        }
        let document = DisplayProfileDocument(profiles: referencedProfiles, bindings: bindings)
        try write(document.json(), name: SessionPackage.displayProfileFileName)
    }

    private func flushQuietly(_ log: EventLog) throws {
        // A flush error is recorded on the log and reflected in data_integrity;
        // an unreadable sink must still not produce a "complete" package.
        do {
            try log.flush()
        } catch {
            throw SessionPackageError.writeFailed(String(describing: error))
        }
    }

    private func write(_ value: JSONValue, name: String) throws {
        let text = try value.serialized()
        guard let data = (text + "\n").data(using: .utf8) else {
            throw SessionPackageError.writeFailed(name)
        }
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SessionPackageError.writeFailed("\(name): \(error)")
        }
    }
}
