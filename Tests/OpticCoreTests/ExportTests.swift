import XCTest
@testable import OpticCore

final class ExportTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("optic-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private struct Session {
        let package: SessionPackage
        let recorder: PresentationRecorder
        let clock: FakeClock
        let sessionID: SessionID
        let timeBase: SessionTimeBase
    }

    private func makeSession(
        root: URL,
        sessionID: SessionID = SessionID(string: "6bd9ff04-8b4c-4df4-a5d9-86baa7c86d30")!,
        displayCapacity: Int = 4096,
        includeProfile: Bool = false
    ) throws -> Session {
        let clock = FakeClock(start: 1_000_000_000)
        let timeBase = SessionTimeBase(originRawNanoseconds: clock.rawNanoseconds())
        var manifest = TestFixtures.manifest(timeBase: timeBase, sessionID: sessionID)
        manifest.segments = []
        let package = try SessionPackage(root: root, manifest: manifest, timeBase: timeBase,
                                         clock: clock, displayCapacity: displayCapacity)
        if includeProfile {
            let profile = ImportedCalibrationProfile(
                profileID: "profile-0",
                key: CalibrationKey(
                    sourceDeviceID: "Mac16,5-test",
                    osBuild: "23A344",
                    displayModeID: "mode-3456x2234",
                    drawableWidthPx: 3456,
                    drawableHeightPx: 2234,
                    displayRotationDeg: 0,
                    patternRotationDeg: 0,
                    brightnessSetting: 0.5,
                    colorSpace: "kCGColorSpaceSRGB",
                    pixelFormat: "BGRA8Unorm",
                    colorMode: "sRGB",
                    dimmingMode: "fixed",
                    calibrationVersion: "test-1"
                ),
                model: .object(["tau": .array([.double(0.0)]), "note": .string("opaque test model")])
            )
            try package.addProfile(profile)
        }
        let recorder = PresentationRecorder(
            sessionID: sessionID, timeBase: timeBase, displayLog: package.displayLog,
            eventWriter: package.eventWriter, clock: clock
        )
        return Session(package: package, recorder: recorder, clock: clock,
                       sessionID: sessionID, timeBase: timeBase)
    }

    private func snapshot(width: Int, height: Int) -> DisplaySnapshot {
        DisplaySnapshot(
            displayModeID: "mode-\(width)x\(height)",
            drawableSize: PixelSize(width: width, height: height),
            displayRotationDeg: 0,
            reportedRefreshHz: 59.94,
            colorSpaceName: "kCGColorSpaceSRGB",
            pixelFormatName: "BGRA8Unorm",
            colorMode: "sRGB",
            dimmingMode: "fixed",
            brightnessSetting: 0.5,
            brightnessSource: .operatorReported,
            autoBrightnessEnabled: false
        )
    }

    /// Builds a short synthetic session with two segments, a cross-segment late
    /// result, one invalid-then-presented frame and one never-confirmed frame.
    private func runSyntheticSession(_ session: Session, includeProfile: Bool) throws {
        let package = session.package
        let clock = session.clock
        let writer = package.eventWriter

        let layout0 = try LayoutBuilder.make(layoutID: "layout-0", profile: .f68,
                                             drawable: PixelSize(width: 3456, height: 2234), rotationDeg: 0)
        let layout1 = try LayoutBuilder.make(layoutID: "layout-1", profile: .c52,
                                             drawable: PixelSize(width: 1512, height: 982), rotationDeg: 0)
        try package.addLayout(layout0)
        try package.addLayout(layout1)

        let segment0 = SegmentConfig(
            segmentID: .zero, layoutID: "layout-0", experimentProfile: .m59S1,
            snapshot: snapshot(width: 3456, height: 2234),
            displayProfileID: includeProfile ? "profile-0" : nil
        )
        let segment1 = SegmentConfig(
            segmentID: SegmentID(1), layoutID: "layout-1", experimentProfile: .m59S1,
            snapshot: snapshot(width: 1512, height: 982),
            displayProfileID: includeProfile ? "profile-0" : nil,
            operatorNote: "C52 after layout change"
        )
        try package.addSegment(segment0)
        try package.addSegment(segment1)

        writer.segmentStarted(segment0, reason: .sessionStart)
        writer.phaseChanged(from: .configured, to: .running, plannedDurationNanoseconds: 90_000_000_000)

        func identity(_ sequence: UInt64, _ frame: UInt64, _ segment: SegmentConfig, _ layout: LayoutSpec) throws -> FrameIdentity {
            try TestFixtures.dynamicIdentity(
                sessionID: session.sessionID, segmentID: segment.segmentID,
                layoutID: layout.layoutID, frameOrdinal: frame, seqValue: sequence,
                profile: layout.profile, layout: layout
            )
        }

        // Synthetic evidence keeps the contract relations: submit precedes the
        // estimated presentation, and the actual presentation follows submit by
        // roughly one 59.94 Hz interval.
        func submission(submit raw: Int64) -> Evidence {
            .submission(
                targetPresent: .valid(rawNanoseconds: raw + 16_683_000,
                                      nativeValue: .double(Double(raw + 16_683_000) / 1_000_000_000),
                                      api: "CAMetalDisplayLink.Update.targetPresentationTimestamp",
                                      nativeUnit: .seconds),
                deadline: .valid(rawNanoseconds: raw + 15_000_000,
                                 nativeValue: .double(Double(raw + 15_000_000) / 1_000_000_000),
                                 api: "CAMetalDisplayLink.Update.targetTimestamp",
                                 nativeUnit: .seconds),
                submit: .valid(rawNanoseconds: raw, nativeValue: .int(raw), api: "CLOCK_UPTIME_RAW")
            )
        }

        func presentedSample(_ raw: Int64) -> FieldSample {
            .validSeconds(Double(raw) / 1_000_000_000, api: "MTLDrawable.presentedTime")
        }

        // Segment 0: three confirmed dynamic states.
        for offset in 0..<3 {
            let identity = try identity(UInt64(offset), UInt64(offset), segment0, layout0)
            XCTAssertEqual(session.recorder.begin(identity), .tracking)
            let submit = clock.rawNanoseconds()
            session.recorder.submitted(identity, evidence: submission(submit: submit), platformIDs: .none)
            clock.advance(16_700_000)
            session.recorder.presented(identity,
                                       systemPresent: presentedSample(submit + 16_700_000),
                                       renderComplete: .validSeconds(Double(submit + 9_000_000) / 1_000_000_000,
                                                                     api: "MTLCommandBuffer.gpuEndTime"),
                                       platformIDs: .none, at: clock.rawNanoseconds())
        }

        // Frame 3: explicitly invalid presentation time, later recovered.
        let recovered = try identity(3, 3, segment0, layout0)
        session.recorder.begin(recovered)
        let recoveredSubmit = clock.rawNanoseconds()
        session.recorder.submitted(recovered, evidence: submission(submit: recoveredSubmit), platformIDs: .none)
        session.recorder.unconfirmed(recovered, reason: .timestampInvalid,
                                     systemPresent: .invalid(nativeValue: .double(0),
                                                             api: "MTLDrawable.presentedTime", nativeUnit: .seconds),
                                     platformIDs: .none, at: clock.rawNanoseconds())

        // Configuration change ends segment 0 and starts segment 1.
        writer.segmentEnded(.zero, reason: .configurationChanged)
        writer.segmentStarted(segment1, reason: .configurationChanged)
        for offset in 0..<2 {
            let identity = try identity(UInt64(4 + offset), UInt64(4 + offset), segment1, layout1)
            session.recorder.begin(identity)
            let submit = clock.rawNanoseconds()
            session.recorder.submitted(identity, evidence: submission(submit: submit), platformIDs: .none)
            clock.advance(16_700_000)
            session.recorder.presented(identity,
                                       systemPresent: presentedSample(submit + 16_700_000),
                                       renderComplete: .validSeconds(Double(submit + 9_000_000) / 1_000_000_000,
                                                                     api: "MTLCommandBuffer.gpuEndTime"),
                                       platformIDs: .none, at: clock.rawNanoseconds())
        }

        // Late real result for a segment-0 frame, after segment 1 started.
        clock.advance(5_000_000)
        session.recorder.presented(recovered,
                                   systemPresent: presentedSample(recoveredSubmit + 16_900_000),
                                   renderComplete: .validSeconds(Double(recoveredSubmit + 9_000_000) / 1_000_000_000,
                                                                 api: "MTLCommandBuffer.gpuEndTime"),
                                   platformIDs: .none, at: clock.rawNanoseconds())

        // Frame 6 is submitted but never confirmed.
        let silent = try identity(6, 6, segment1, layout1)
        session.recorder.begin(silent)
        session.recorder.submitted(silent, evidence: submission(submit: clock.rawNanoseconds()), platformIDs: .none)

        writer.phaseChanged(from: .running, to: .endCard, plannedDurationNanoseconds: 2_000_000_000)
        writer.segmentEnded(SegmentID(1), reason: .normalEnd)
        clock.advance(2_000_000_000)
        let seal = session.recorder.seal(at: clock.rawNanoseconds())
        XCTAssertEqual(seal.pendingFrameCount, 1)

        let statistics = session.recorder.statistics()
        let close = SessionClose(reason: .normalEnd,
                                 closedAtRawNanoseconds: clock.rawNanoseconds(),
                                 pendingFrameCount: seal.pendingFrameCount)
        try package.finish(close: close, statistics: statistics,
                           timing: session.recorder.timingStatistics())
    }

    func testExportedDirectoryMatchesContractShape() throws {
        let root = try makeRoot()
        let session = try makeSession(root: root)
        try runSyntheticSession(session, includeProfile: false)
        let directory = root.appendingPathComponent("session_\(session.sessionID.description)")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, [
            "configuration_events.jsonl",
            "display_events.jsonl",
            "display_profile.json",
            "layout.json",
            "manifest.json",
            "session_summary.json"
        ])

        // manifest
        let manifest = try JSONParser.parse(Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest["schema_version"]?.stringValue, "1.0")
        XCTAssertEqual(manifest["protocol_version"]?.stringValue, "OPTC-1")
        XCTAssertEqual(manifest["platform"]?.stringValue, "MACOS")
        XCTAssertEqual(manifest["clock_domain"]?.stringValue, "MACOS_HOST_TIME")
        XCTAssertEqual(manifest["time_origin"]?["raw_ns"]?.intValue, 1_000_000_000)
        XCTAssertEqual(manifest["time_origin"]?["native_clock"]?.stringValue, "MACOS_HOST_TIME")
        XCTAssertEqual(manifest["presentation_drain_timeout_ns"]?.intValue, 2_000_000_000)
        let segments = try XCTUnwrap(manifest["segments"]?.arrayValue)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0]["segment_id"]?.stringValue, "0")
        XCTAssertEqual(segments[0]["layout_id"]?.stringValue, "layout-0")
        XCTAssertEqual(segments[0]["experiment_profile"]?.stringValue, "M59-S1")
        XCTAssertEqual(segments[0]["drawable_width_px"]?.intValue, 3456)
        XCTAssertEqual(segments[0]["requested_refresh_num"]?.intValue, 60000)
        XCTAssertEqual(segments[0]["requested_refresh_den"]?.intValue, 1001)
        XCTAssertEqual(segments[0]["brightness_source"]?.stringValue, "OPERATOR_REPORTED")
        XCTAssertEqual(segments[0]["brightness_setting"]?.doubleValue, 0.5)
        XCTAssertEqual(segments[0]["display_profile_id"]?.stringValue, nil)
        // Optional fields are present and explicitly null.
        XCTAssertNotNil(segments[0].objectValue?["nominal_refresh_num"])
        XCTAssertEqual(segments[0]["nominal_refresh_num"]?.stringValue, nil)
        XCTAssertNotNil(segments[0].objectValue?["hdr_enabled"])

        // layout collection keeps both referenced layouts.
        let layouts = try JSONParser.parse(Data(contentsOf: directory.appendingPathComponent("layout.json")))
        XCTAssertEqual(layouts["schema_version"]?.stringValue, "1.0")
        let layoutList = try XCTUnwrap(layouts["layouts"]?.arrayValue)
        XCTAssertEqual(layoutList.compactMap { $0["layout_id"]?.stringValue }, ["layout-0", "layout-1"])
        XCTAssertEqual(layoutList[0]["modules"]?.arrayValue?.count, 68)
        XCTAssertEqual(layoutList[1]["modules"]?.arrayValue?.count, 52)
        XCTAssertEqual(layoutList[1]["drawable_width_px"]?.intValue, 1512)

        // No calibration imported: the document still exists with MISSING bindings.
        let profiles = try JSONParser.parse(Data(contentsOf: directory.appendingPathComponent("display_profile.json")))
        XCTAssertEqual(profiles["profiles"]?.arrayValue?.count, 0)
        let bindings = try XCTUnwrap(profiles["segment_bindings"]?.arrayValue)
        XCTAssertEqual(bindings.count, 2)
        XCTAssertEqual(bindings.map { $0["status"]?.stringValue }, ["MISSING", "MISSING"])
        XCTAssertEqual(bindings.map { $0["profile_id"]?.stringValue }, [nil, nil])

        // Display events: identity, ordering and merge semantics.
        let displayEvents = try readJSONLines(directory.appendingPathComponent("display_events.jsonl"))
        XCTAssertEqual(displayEvents.compactMap { $0["event_seq"]?.intValue },
                       Array(0..<Int64(displayEvents.count)))
        XCTAssertEqual(displayEvents.filter { $0["event_type"]?.stringValue == "PRESENTED" }.count, 6)
        // Segment-0 frame 3 was recovered after the segment change.
        let recovered = displayEvents.filter { $0["native_frame_id"]?.stringValue == "3" }
        XCTAssertEqual(recovered.compactMap { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "UNCONFIRMED", "PRESENTED"])
        XCTAssertEqual(recovered.last?["segment_id"]?.stringValue, "0")
        XCTAssertEqual(recovered.last?["layout_id"]?.stringValue, "layout-0")
        // Frame 6 was sealed as not confirmed.
        let silent = displayEvents.filter { $0["native_frame_id"]?.stringValue == "6" }
        XCTAssertEqual(silent.compactMap { $0["event_type"]?.stringValue },
                       ["SUBMITTED", "UNCONFIRMED"])
        XCTAssertEqual(silent.last?["unconfirmed_reason"]?.stringValue, "NO_CALLBACK_AT_SESSION_CLOSE")
        // Every result has a preceding SUBMITTED in file order.
        var submitted: Set<String> = []
        for event in displayEvents {
            let id = event["native_frame_id"]?.stringValue ?? ""
            switch event["event_type"]?.stringValue {
            case "SUBMITTED": submitted.insert(id)
            default: XCTAssertTrue(submitted.contains(id), "result before SUBMITTED for \(id)")
            }
            if event["event_type"]?.stringValue != "SUBMITTED" {
                XCTAssertNotNil(event.objectValue?["timestamp_status"])
                XCTAssertNotNil(event.objectValue?["platform_timestamps"])
                XCTAssertNotNil(event.objectValue?["platform_ids"])
            }
        }
        // render_seq is a decimal string and payload/crc match the encoder.
        for event in displayEvents where event["frame_kind"]?.stringValue == "DYNAMIC" {
            let seqText = try XCTUnwrap(event["render_seq"]?.stringValue)
            XCTAssertNil(event["render_seq"]?.intValue, "render_seq must be a string")
            let seq = try RenderSeq(decimalString: seqText)
            let bits = PatternEncoder.encode(seq, profile: .f68)
            XCTAssertEqual(event["payload_n"]?.intValue, Int64(bits.payloadN))
            XCTAssertEqual(event["crc8"]?.intValue, Int64(bits.crc8))
            XCTAssertEqual(event["recorded_ns"]?.intValue,
                           event["recorded_raw_ns"]?.intValue.map { $0 - 1_000_000_000 })
        }

        // Configuration events: closure is last, integrity complete, pending 1.
        let configurationEvents = try readJSONLines(directory.appendingPathComponent("configuration_events.jsonl"))
        XCTAssertEqual(configurationEvents.compactMap { $0["event_seq"]?.intValue },
                       Array(0..<Int64(configurationEvents.count)))
        XCTAssertEqual(configurationEvents.filter { $0["event_type"]?.stringValue == "SEGMENT_STARTED" }.count, 2)
        XCTAssertEqual(configurationEvents.filter { $0["event_type"]?.stringValue == "SEGMENT_ENDED" }.count, 2)
        let close = try XCTUnwrap(configurationEvents.last)
        XCTAssertEqual(close["event_type"]?.stringValue, "SESSION_CLOSED")
        XCTAssertEqual(close["details"]?["reason"]?.stringValue, "NORMAL_END")
        XCTAssertEqual(close["details"]?["data_integrity"]?.stringValue, "COMPLETE")
        XCTAssertEqual(close["details"]?["pending_frame_count"]?.intValue, 1)

        // Summary counts are merged by submission identity.
        let summary = try JSONParser.parse(Data(contentsOf: directory.appendingPathComponent("session_summary.json")))
        XCTAssertEqual(summary["data_integrity"]?.stringValue, "COMPLETE")
        XCTAssertEqual(summary["lost_event_count"]?.intValue, 0)
        XCTAssertEqual(summary["closed_raw_ns"]?.intValue, close["recorded_raw_ns"]?.intValue)
        let summarySegments = try XCTUnwrap(summary["segments"]?.arrayValue)
        XCTAssertEqual(summarySegments.count, 2)
        XCTAssertEqual(summarySegments[0]["generated"]?.intValue, 4)
        XCTAssertEqual(summarySegments[0]["submitted"]?.intValue, 4)
        XCTAssertEqual(summarySegments[0]["presented"]?.intValue, 4)
        XCTAssertEqual(summarySegments[0]["unconfirmed"]?.intValue, 0)
        XCTAssertEqual(summarySegments[1]["generated"]?.intValue, 3)
        XCTAssertEqual(summarySegments[1]["presented"]?.intValue, 2)
        XCTAssertEqual(summarySegments[1]["unconfirmed"]?.intValue, 1)
        XCTAssertEqual(summarySegments[1]["unconfirmed_reasons"]?["NO_CALLBACK_AT_SESSION_CLOSE"]?.intValue, 1)
        XCTAssertEqual(summarySegments[0]["data_integrity"]?.stringValue, "COMPLETE")
    }

    func testLayoutAndManifestArePersistedBeforeDisplayStarts() throws {
        let root = try makeRoot()
        let session = try makeSession(root: root)
        let directory = root.appendingPathComponent("session_\(session.sessionID.description)")
        // The design requires configuration and layout on disk before display.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        let layout = try LayoutBuilder.make(layoutID: "layout-0", profile: .f68,
                                            drawable: PixelSize(width: 3456, height: 2234), rotationDeg: 0)
        try session.package.addLayout(layout)
        let document = try JSONParser.parse(Data(contentsOf: directory.appendingPathComponent("layout.json")))
        XCTAssertEqual(document["layouts"]?.arrayValue?.count, 1)
        XCTAssertEqual(document["layouts"]?.arrayValue?.first?["layout_id"]?.stringValue, "layout-0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session_summary.json").path),
                       "summary exists only after sealing")
    }

    func testCancelledEmptySessionExportsWithoutFabricatedFrames() throws {
        let root = try makeRoot()
        let session = try makeSession(root: root)
        let statistics = session.recorder.statistics()
        XCTAssertTrue(statistics.segments.isEmpty)
        let close = SessionClose(reason: .userStop,
                                 closedAtRawNanoseconds: session.clock.rawNanoseconds(),
                                 pendingFrameCount: 0)
        try session.package.finish(close: close, statistics: statistics,
                                   timing: session.recorder.timingStatistics())
        let directory = root.appendingPathComponent("session_\(session.sessionID.description)")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names.count, 6)
        let display = try readJSONLines(directory.appendingPathComponent("display_events.jsonl"))
        XCTAssertTrue(display.isEmpty, "cancel before the first frame must not invent frames")
        let configuration = try readJSONLines(directory.appendingPathComponent("configuration_events.jsonl"))
        let closeEvent = try XCTUnwrap(configuration.last)
        XCTAssertEqual(closeEvent["event_type"]?.stringValue, "SESSION_CLOSED")
        XCTAssertEqual(closeEvent["details"]?["reason"]?.stringValue, "USER_STOP")
        XCTAssertEqual(closeEvent["details"]?["pending_frame_count"]?.intValue, 0)
        let summary = try JSONParser.parse(Data(contentsOf: directory.appendingPathComponent("session_summary.json")))
        XCTAssertEqual(summary["segments"]?.arrayValue?.count, 0)
        XCTAssertNil(summary.objectValue?["timing"], "no timing samples for a cancelled session")
    }

    func testSealedPackageRejectsFurtherMutations() throws {
        let root = try makeRoot()
        let session = try makeSession(root: root)
        try runSyntheticSession(session, includeProfile: false)
        let directory = root.appendingPathComponent("session_\(session.sessionID.description)")

        func fileSnapshot() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
            }
            return result
        }
        let before = try fileSnapshot()

        let extraLayout = try LayoutBuilder.make(layoutID: "layout-2", profile: .f68,
                                                 drawable: PixelSize(width: 1024, height: 768), rotationDeg: 0)
        XCTAssertThrowsError(try session.package.addLayout(extraLayout)) { error in
            XCTAssertEqual(error as? SessionPackageError, .alreadyFinished)
        }
        let extraSegment = SegmentConfig(segmentID: SegmentID(9), layoutID: "layout-0",
                                         experimentProfile: .m59S1,
                                         snapshot: snapshot(width: 3456, height: 2234))
        XCTAssertThrowsError(try session.package.addSegment(extraSegment)) { error in
            XCTAssertEqual(error as? SessionPackageError, .alreadyFinished)
        }
        let profile = ImportedCalibrationProfile(
            profileID: "late-profile",
            key: CalibrationKey(calibrationVersion: "late"),
            model: .null
        )
        XCTAssertThrowsError(try session.package.addProfile(profile)) { error in
            XCTAssertEqual(error as? SessionPackageError, .alreadyFinished)
        }
        XCTAssertEqual(try fileSnapshot(), before, "a sealed package must stay byte-identical")
    }

    func testImportedProfileBindingStatuses() throws {
        let root = try makeRoot()
        let session = try makeSession(root: root, includeProfile: true)
        try runSyntheticSession(session, includeProfile: true)
        let directory = root.appendingPathComponent("session_\(session.sessionID.description)")
        let document = try JSONParser.parse(Data(contentsOf: directory.appendingPathComponent("display_profile.json")))
        let profiles = try XCTUnwrap(document["profiles"]?.arrayValue)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0]["profile_id"]?.stringValue, "profile-0")
        XCTAssertEqual(profiles[0]["model"]?["note"]?.stringValue, "opaque test model")
        let bindings = try XCTUnwrap(document["segment_bindings"]?.arrayValue)
        XCTAssertEqual(bindings.map { $0["status"]?.stringValue }, ["COMPATIBLE", "INCOMPATIBLE"])
        // Second segment has a different drawable size than the imported key.
        XCTAssertEqual(bindings[1]["mismatch_fields"]?.arrayValue?.compactMap { $0.stringValue },
                       ["display_mode_id", "drawable_height_px", "drawable_width_px"])
    }

    func testCalibrationMatcherUnknownFieldsAreUnverified() throws {
        let layout = try LayoutBuilder.make(layoutID: "layout-0", profile: .f68,
                                            drawable: PixelSize(width: 3456, height: 2234), rotationDeg: 0)
        let segment = SegmentConfig(segmentID: .zero, layoutID: "layout-0", experimentProfile: .m59S1,
                                    snapshot: snapshot(width: 3456, height: 2234))
        let complete = CalibrationKey(
            sourceDeviceID: "Mac16,5-test", osBuild: "23A344", displayModeID: "mode-3456x2234",
            drawableWidthPx: 3456, drawableHeightPx: 2234, displayRotationDeg: 0,
            patternRotationDeg: 0, brightnessSetting: 0.5, colorSpace: "kCGColorSpaceSRGB",
            pixelFormat: "BGRA8Unorm", colorMode: "sRGB", dimmingMode: "fixed",
            calibrationVersion: "v1"
        )
        let match = CalibrationMatcher.binding(
            segment: segment, layout: layout,
            profile: ImportedCalibrationProfile(profileID: "p", key: complete, model: .null),
            sourceDeviceID: "Mac16,5-test", osBuild: "23A344"
        )
        XCTAssertEqual(match.status, .compatible)
        XCTAssertTrue(match.mismatchFields.isEmpty)

        var unknown = complete
        unknown.displayModeID = nil
        let unverified = CalibrationMatcher.binding(
            segment: segment, layout: layout,
            profile: ImportedCalibrationProfile(profileID: "p", key: unknown, model: .null),
            sourceDeviceID: "Mac16,5-test", osBuild: "23A344"
        )
        XCTAssertEqual(unverified.status, .importedUnverified)
        XCTAssertEqual(unverified.mismatchFields, ["display_mode_id"])

        var wrong = complete
        wrong.pixelFormat = "RGBA16Float"
        let incompatible = CalibrationMatcher.binding(
            segment: segment, layout: layout,
            profile: ImportedCalibrationProfile(profileID: "p", key: wrong, model: .null),
            sourceDeviceID: "Mac16,5-test", osBuild: "23A344"
        )
        XCTAssertEqual(incompatible.status, .incompatible)
        XCTAssertEqual(incompatible.mismatchFields, ["pixel_format"])
    }

    func testLogOverflowIsExportedAsIncompleteWithLatchDetails() throws {
        // Deterministic location so the overflow export can be inspected by an
        // independent reader after the test run.
        let root = URL(fileURLWithPath: "/tmp/lumaphase-t1-overflow", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Tiny display queue: the second event cannot be written.
        let session = try makeSession(root: root, displayCapacity: 1)
        let layout = try LayoutBuilder.make(layoutID: "layout-0", profile: .f68,
                                            drawable: PixelSize(width: 3456, height: 2234), rotationDeg: 0)
        try session.package.addLayout(layout)
        let segment = SegmentConfig(segmentID: .zero, layoutID: "layout-0", experimentProfile: .m59S1,
                                    snapshot: snapshot(width: 3456, height: 2234))
        try session.package.addSegment(segment)
        session.package.eventWriter.segmentStarted(segment, reason: .sessionStart)
        for offset in 0..<3 {
            let identity = try TestFixtures.dynamicIdentity(
                sessionID: session.sessionID, segmentID: .zero, layoutID: "layout-0",
                frameOrdinal: UInt64(offset), seqValue: UInt64(offset)
            )
            session.recorder.begin(identity)
            session.recorder.submitted(identity, evidence: TestFixtures.submissionEvidence(), platformIDs: .none)
        }
        let seal = session.recorder.seal(at: session.clock.rawNanoseconds())
        try session.package.finish(
            close: SessionClose(reason: .logOverflow, closedAtRawNanoseconds: session.clock.rawNanoseconds(),
                                pendingFrameCount: seal.pendingFrameCount),
            statistics: session.recorder.statistics()
        )
        let directory = root.appendingPathComponent("session_\(session.sessionID.description)")
        let summary = try JSONParser.parse(Data(contentsOf: directory.appendingPathComponent("session_summary.json")))
        XCTAssertEqual(summary["data_integrity"]?.stringValue, "INCOMPLETE")
        XCTAssertGreaterThanOrEqual(summary["lost_event_count"]?.intValue ?? 0, 1)
        XCTAssertEqual(summary["segments"]?.arrayValue?.first?["data_integrity"]?.stringValue, "INCOMPLETE")

        let configurationEvents = try readJSONLines(directory.appendingPathComponent("configuration_events.jsonl"))
        let overflow = try XCTUnwrap(configurationEvents.first { $0["event_type"]?.stringValue == "LOG_OVERFLOW" })
        XCTAssertEqual(overflow["details"]?["affected_log"]?.stringValue, "display_events.jsonl")
        XCTAssertEqual(overflow["details"]?["lost_event_count"]?.intValue,
                       summary["lost_event_count"]?.intValue)
        XCTAssertEqual(overflow["details"]?["affected_segment_ids"]?.arrayValue?.compactMap { $0.stringValue },
                       ["0"])
        XCTAssertNotNil(overflow["details"]?["first_lost_event_seq"]?.intValue)
        XCTAssertNotNil(overflow["details"]?["last_lost_event_seq"]?.intValue)
        // LOG_OVERFLOW precedes SESSION_CLOSED and both follow the drained events.
        XCTAssertEqual(configurationEvents.last?["event_type"]?.stringValue, "SESSION_CLOSED")
        XCTAssertEqual(configurationEvents.last?["details"]?["data_integrity"]?.stringValue, "INCOMPLETE")

        // Written events keep a contiguous prefix; the gap is documented.
        let displayEvents = try readJSONLines(directory.appendingPathComponent("display_events.jsonl"))
        XCTAssertEqual(displayEvents.compactMap { $0["event_seq"]?.intValue },
                       Array(0..<Int64(displayEvents.count)))
    }

    /// Exports the same synthetic session to /tmp so the next agent (or an
    /// independent reader) can inspect a real directory without running tests.
    func testExportSampleSessionToTemporaryDirectory() throws {
        let root = URL(fileURLWithPath: "/tmp/lumaphase-t1-sample", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = try makeSession(root: root)
        try runSyntheticSession(session, includeProfile: false)
        let directory = root.appendingPathComponent("session_\(session.sessionID.description)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 6)
        print("T1 sample session: \(directory.path)")
    }

    private func readJSONLines(_ url: URL) throws -> [JSONValue] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n", omittingEmptySubsequences: true).map {
            try JSONParser.parse(String($0))
        }
    }
}
