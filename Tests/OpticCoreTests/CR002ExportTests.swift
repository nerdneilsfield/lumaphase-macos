import XCTest
@testable import OpticCore

final class CR002ExportTests: XCTestCase {
    func testTypedLayoutsHaveOnlyTheirActualFields() throws {
        let run = try LayoutBuilder.make(layoutID: "run", geometryProfile: .f68G6x12,
            drawable: PixelSize(width: 1512, height: 982), rotationDeg: 90)
        let target = try LargeTagCalibrationTarget.make(layoutID: "tag", runLayout: run)
        let diagnostic = try FullscreenDiagnosticLayout(layoutID: "bw", drawable: run.drawableSize,
            rotationDeg: 90, pattern: .vsyncBlackWhite)
        let layouts: [DisplayLayout] = [.optc(run), .calibrationTarget(target), .fullscreenDiagnostic(diagnostic)]
        let forbidden = ["layout_profile", "geometry_profile", "modules", "padding", "dynamic_rect_px", "grid_rows", "grid_cols"]
        for layout in layouts {
            let json = try JSONParser.parse(layout.json().serialized())
            XCTAssertEqual(json["layout_id"]?.stringValue, layout.layoutID)
            XCTAssertEqual(json["drawable_width_px"]?.intValue, 1512)
            if layout.optcLayout == nil {
                for field in forbidden { XCTAssertNil(json[field]) }
            }
        }
        XCTAssertEqual(layouts[0].json()["layout_type"]?.stringValue, "OPTC")
        XCTAssertEqual(layouts[1].json()["reference_regions"]?.arrayValue?.map { $0["level"]?.intValue }, [0,128,255])
        XCTAssertNil(layouts[2].json()["markers"])
        XCTAssertNil(layouts[2].json()["reference_regions"])
        let key = CalibrationKey(calibrationVersion: "old-model")
        let profile = ImportedCalibrationProfile(profileID: "p", key: key, model: .object([:]))
        for layout in layouts.dropFirst() {
            let segment = SegmentConfig(segmentID: .zero, layoutID: layout.layoutID,
                experimentProfile: ExperimentProfile(rawValue: "CR002-TAG"), snapshot: TestFixtures.displaySnapshot())
            XCTAssertEqual(CalibrationMatcher.binding(segment: segment, layout: layout, profile: profile,
                sourceDeviceID: "Mac", osBuild: "build").status, .importedUnverified)
        }
    }

    func testRealSixFileExportsForRunStaticAndVSyncSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumaphase-cr002-export-\(UUID().uuidString)")
        var samples: [String: String] = [:]
        for mode in ["RUN", "A", "B"] {
            let clock = FakeClock(start: 1_000_000_000)
            let base = SessionTimeBase(originRawNanoseconds: 1_000_000_000)
            let sessionID = SessionID()
            let package = try SessionPackage(root: root, manifest: TestFixtures.manifest(timeBase: base, sessionID: sessionID), timeBase: base, clock: clock)
            let recorder = PresentationRecorder(sessionID: sessionID, timeBase: base, displayLog: package.displayLog,
                eventWriter: package.eventWriter, clock: clock)
            let size = PixelSize(width: 1512, height: 982)
            let run = try LayoutBuilder.make(layoutID: "run", geometryProfile: .f68G6x12, drawable: size, rotationDeg: 0)
            let target = try LargeTagCalibrationTarget.make(layoutID: "tag", runLayout: run)
            let allocator = FrameIdentityAllocator()
            var late: (FrameIdentity, Int64)?
            var diagnosticLayouts: [DiagnosticPattern: DisplayLayout] = [:]
            let patterns: [DiagnosticPattern] = [.white, .white, .black, .black, .checkerboard, .checkerboard]
            let names = ["CR002-A-WHITE-SETTLE","CR002-A-WHITE","CR002-A-BLACK-SETTLE","CR002-A-BLACK","CR002-A-GRID-SETTLE","CR002-A-GRID"]
            let count = mode == "A" ? 6 : mode == "RUN" ? 2 : 1
            for index in 0..<count {
                let layout: DisplayLayout
                let experiment: String
                if mode == "RUN" {
                    layout = index == 0 ? .calibrationTarget(target) : .optc(run)
                    experiment = index == 0 ? "CR002-TAG" : "M59-S1"
                } else {
                    let pattern = mode == "B" ? DiagnosticPattern.vsyncBlackWhite : patterns[index]
                    experiment = mode == "B" ? "CR002-B-BW" : names[index]
                    if let existing = diagnosticLayouts[pattern] { layout = existing }
                    else {
                        layout = .fullscreenDiagnostic(try FullscreenDiagnosticLayout(layoutID: "diag-\(index)", drawable: size, rotationDeg: 0, pattern: pattern))
                        diagnosticLayouts[pattern] = layout
                    }
                }
                try package.addLayout(layout)
                var config = SegmentConfig(segmentID: SegmentID(UInt32(index)), layoutID: layout.layoutID,
                    experimentProfile: ExperimentProfile(rawValue: experiment),
                    snapshot: TestFixtures.displaySnapshot(width: size.width, height: size.height))
                config.requestedRefresh = .hz60000_1001
                try package.addSegment(config)
                package.eventWriter.segmentStarted(config, reason: index == 0 ? .sessionStart : .configurationChanged)
                package.eventWriter.phaseChanged(from: index == 0 ? .configured : .calibration,
                    to: mode == "RUN" && index == 1 ? .running : .calibration,
                    plannedDurationNanoseconds: mode == "A" ? (index%2 == 0 ? 1_000_000_000 : 3_000_000_000) : mode == "B" ? 60_000_000_000 : nil)
                let frameCount = mode == "B" ? 5 : 2
                for frame in 0..<frameCount {
                    let nativeID = allocator.allocate()
                    let identity: FrameIdentity
                    if mode == "RUN" && index == 1 {
                        identity = try FrameIdentity(sessionID: sessionID, segmentID: config.segmentID, layoutID: layout.layoutID,
                            nativeFrameID: nativeID, frameKind: .dynamic, phase: .running,
                            renderSeq: RenderSeq(UInt64(frame)), pattern: PatternEncoder.encode(RenderSeq(UInt64(frame)), profile: .f68))
                    } else {
                        identity = try FrameIdentity(sessionID: sessionID, segmentID: config.segmentID, layoutID: layout.layoutID,
                            nativeFrameID: nativeID, frameKind: .calibration, phase: .calibration)
                    }
                    _ = recorder.begin(identity)
                    let raw = clock.rawNanoseconds()
                    if mode == "B" && frame == 2 {
                        recorder.abandon(identity, operation: "makeCommandBuffer", errorCode: nil, message: "synthetic pre-submit failure")
                        clock.advance(20_000_000)
                        continue
                    }
                    let evidence = Evidence.submission(
                        targetPresent: .validSeconds(Double(raw+16_000_000)/1e9, api: "CAMetalDisplayLink.Update.targetPresentationTimestamp"),
                        deadline: .validSeconds(Double(raw+15_000_000)/1e9, api: "CAMetalDisplayLink.Update.targetTimestamp"),
                        submit: .valid(rawNanoseconds: raw, nativeValue: .int(raw), api: "CLOCK_UPTIME_RAW"))
                    recorder.submitted(identity, evidence: evidence, platformIDs: .none, at: raw)
                    clock.advance(20_000_000)
                    if mode == "RUN" && index == 0 && frame == 0 { late = (identity, raw); continue }
                    recorder.presented(identity, systemPresent: .validSeconds(Double(raw+17_000_000)/1e9, api: "MTLDrawable.presentedTime"),
                        renderComplete: .validSeconds(Double(raw+9_000_000)/1e9, api: "MTLCommandBuffer.gpuEndTime"),
                        platformIDs: .none, at: clock.rawNanoseconds())
                }
                if mode == "RUN" && index == 1, let late {
                    recorder.presented(late.0, systemPresent: .validSeconds(Double(late.1+17_000_000)/1e9, api: "MTLDrawable.presentedTime"),
                        renderComplete: .validSeconds(Double(late.1+9_000_000)/1e9, api: "MTLCommandBuffer.gpuEndTime"),
                        platformIDs: .none, at: clock.rawNanoseconds())
                }
                let planned: Int64 = mode == "A" ? (index%2 == 0 ? 1_000_000_000 : 3_000_000_000) : mode == "B" ? 60_000_000_000 : 100_000_000
                clock.advance(planned - Int64(frameCount) * 20_000_000)
                package.eventWriter.segmentEnded(config.segmentID, reason: index+1 == count ? .normalEnd : .configurationChanged)
            }
            if mode == "A" {
                XCTAssertEqual(package.registeredLayouts.count, 3)
                let segments = package.registeredSegments
                for index in stride(from: 0, to: 6, by: 2) {
                    XCTAssertEqual(segments[index].layoutID, segments[index+1].layoutID)
                }
            }
            clock.advance(2_000_000_000)
            let seal = recorder.seal(at: clock.rawNanoseconds())
            try package.finish(close: SessionClose(reason: .normalEnd, closedAtRawNanoseconds: clock.rawNanoseconds(),
                pendingFrameCount: seal.pendingFrameCount), statistics: recorder.statistics(), timing: recorder.timingStatistics())
            let manifest = try JSONParser.parse(Data(contentsOf: package.directory.appendingPathComponent("manifest.json")))
            XCTAssertEqual(manifest["schema_version"]?.stringValue, "1.2")
            let display = try String(contentsOf: package.directory.appendingPathComponent("display_events.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONParser.parse(String($0)) }
            let dynamic = display.filter { $0["event_type"]?.stringValue == "SUBMITTED" && $0["frame_kind"]?.stringValue == "DYNAMIC" }
            XCTAssertEqual(dynamic.compactMap { $0["render_seq"]?.stringValue }, mode == "RUN" ? ["0","1"] : [])
            for event in display where event["frame_kind"]?.stringValue == "CALIBRATION" {
                XCTAssertEqual(event["render_seq"], .null)
                XCTAssertEqual(event["payload_n"], .null)
                XCTAssertEqual(event["crc8"], .null)
            }
            if mode == "B" {
                XCTAssertEqual(display.filter { $0["event_type"]?.stringValue == "SUBMITTED" }
                    .compactMap { $0["native_frame_id"]?.stringValue }, ["0","1","3","4"])
            }
            if mode == "RUN" {
                let last = try XCTUnwrap(display.last)
                XCTAssertEqual(last["event_type"]?.stringValue, "PRESENTED")
                XCTAssertEqual(last["layout_id"]?.stringValue, "tag")
                XCTAssertEqual(last["segment_id"]?.stringValue, "0")
            }
            samples[mode] = package.directory.path
        }
        let data = try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("samples.json"))
        print("CR002 session samples: \(root.path)")
    }
}
