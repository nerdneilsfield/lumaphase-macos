import XCTest
@testable import OpticCore

final class LayoutTests: XCTestCase {
    private let sizes = [
        PixelSize(width: 3456, height: 2234),
        PixelSize(width: 1512, height: 982),
        PixelSize(width: 1024, height: 768)
    ]
    private let rotations = [0, 90, 180, 270]

    func testEveryModuleRectIsIntegerInsideDynamicArea() throws {
        for profile in LayoutProfile.allCases {
            for size in sizes {
                for rotation in rotations {
                    let layout = try LayoutBuilder.make(
                        layoutID: "layout-\(profile.rawValue)-\(size.width)-\(rotation)",
                        profile: profile,
                        drawable: size,
                        rotationDeg: rotation
                    )
                    XCTAssertEqual(layout.modules.count, profile.moduleCount)
                    XCTAssertEqual(layout.drawableSize, size)
                    for (index, rect) in layout.modules.enumerated() {
                        XCTAssertTrue(layout.dynamicRectPx.contains(rect),
                                      "module \(index) escapes dynamic rect at \(rotation)")
                        XCTAssertGreaterThanOrEqual(rect.width, 1)
                        XCTAssertGreaterThanOrEqual(rect.height, 1)
                        for module in layout.modules[(index + 1)...] {
                            XCTAssertFalse(rect.intersects(module),
                                           "modules overlap at \(profile) \(size) \(rotation)")
                        }
                    }
                }
            }
        }
    }

    func testModuleWidthsDifferByAtMostOnePixel() throws {
        for profile in LayoutProfile.allCases {
            for size in sizes {
                for rotation in [0, 180] {
                    let layout = try LayoutBuilder.make(
                        layoutID: "layout",
                        profile: profile,
                        drawable: size,
                        rotationDeg: rotation
                    )
                    let widths = layout.modules.map(\.width)
                    XCTAssertLessThanOrEqual(widths.max()! - widths.min()!, 1)
                    XCTAssertEqual(widths.reduce(0, +), layout.dynamicRectPx.width)
                }
                for rotation in [90, 270] {
                    let layout = try LayoutBuilder.make(
                        layoutID: "layout",
                        profile: profile,
                        drawable: size,
                        rotationDeg: rotation
                    )
                    let heights = layout.modules.map(\.height)
                    XCTAssertLessThanOrEqual(heights.max()! - heights.min()!, 1)
                    XCTAssertEqual(heights.reduce(0, +), layout.dynamicRectPx.height)
                }
            }
        }
    }

    func testGoldenIntegerGeometryForSixteenInchPanel() throws {
        // Hand-computed from the contract formulas for 3456x2234, rotation 0.
        let layout = try LayoutBuilder.make(
            layoutID: "layout-0",
            profile: .f68,
            drawable: PixelSize(width: 3456, height: 2234),
            rotationDeg: 0
        )
        XCTAssertEqual(layout.patternSize, PixelSize(width: 3456, height: 2234))
        XCTAssertEqual(layout.dynamicRectPx, RectPx(x0: 69, y0: 357, x1: 3386, y1: 1876))
        XCTAssertEqual(layout.markers.count, 4)
        XCTAssertEqual(layout.markers[0].cellSizePx, 34)
        XCTAssertEqual(layout.markers[0].quietZonePx, 34)
        XCTAssertEqual(layout.markers[0].markerSizePx, 204)
        XCTAssertEqual(layout.markers[0].cornersPx, [
            PixelPoint(x: 68, y: 68),
            PixelPoint(x: 272, y: 68),
            PixelPoint(x: 272, y: 272),
            PixelPoint(x: 68, y: 272)
        ])
        XCTAssertEqual(layout.matrixRowMajor(), [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
    }

    func testRotationMapsPreRotationBoundsToExportedRect() throws {
        // 90 degrees: pattern canvas is the drawable with width/height swapped,
        // (xd, yd) = (Hp - y, x). Expected rect computed by hand from that table.
        let layout = try LayoutBuilder.make(
            layoutID: "layout-90",
            profile: .f68,
            drawable: PixelSize(width: 3456, height: 2234),
            rotationDeg: 90
        )
        XCTAssertEqual(layout.patternSize, PixelSize(width: 2234, height: 3456))
        XCTAssertEqual(layout.dynamicRectPx, RectPx(x0: 553, y0: 45, x1: 2903, y1: 2189))
        XCTAssertEqual(layout.matrixRowMajor(), [[0, -1, 3456], [1, 0, 0], [0, 0, 1]])
        // Module 0 starts at pattern x = 45 and is ordered downwards after the
        // rotation.
        XCTAssertEqual(layout.modules.first?.y0, 45)
        XCTAssertEqual(layout.modules.last?.y1, 2189)
    }

    func testMarkersAreCrispAndClearOfDynamicArea() throws {
        for size in sizes {
            for rotation in rotations {
                let layout = try LayoutBuilder.make(
                    layoutID: "layout",
                    profile: .f68,
                    drawable: size,
                    rotationDeg: rotation
                )
                XCTAssertEqual(layout.markers.map(\.id), [0, 1, 2, 3])
                let dynamic = layout.dynamicRectPx
                for marker in layout.markers {
                    XCTAssertGreaterThanOrEqual(marker.cellSizePx, LayoutBuilder.minimumCellSizePx)
                    XCTAssertGreaterThanOrEqual(marker.quietZonePx, marker.cellSizePx)
                    XCTAssertEqual(marker.cornersPx.count, 4)
                    let xs = marker.cornersPx.map(\.x)
                    let ys = marker.cornersPx.map(\.y)
                    let box = RectPx(x0: xs.min()!, y0: ys.min()!, x1: xs.max()!, y1: ys.max()!)
                    XCTAssertEqual(box.width, marker.markerSizePx)
                    XCTAssertEqual(box.height, marker.markerSizePx)
                    XCTAssertFalse(box.intersects(dynamic), "marker overlaps dynamic area")
                    XCTAssertGreaterThanOrEqual(box.x0, 0)
                    XCTAssertGreaterThanOrEqual(box.y0, 0)
                    XCTAssertLessThanOrEqual(box.x1, size.width)
                    XCTAssertLessThanOrEqual(box.y1, size.height)
                }
            }
        }
    }

    func testRejectsUnsupportedGeometry() {
        XCTAssertThrowsError(try LayoutBuilder.make(
            layoutID: "layout", profile: .f68,
            drawable: PixelSize(width: 3456, height: 2234), rotationDeg: 45
        ))
        XCTAssertThrowsError(try LayoutBuilder.make(
            layoutID: "layout", profile: .f68,
            drawable: PixelSize(width: 0, height: 2234), rotationDeg: 0
        ))
        // 60 px wide dynamic area cannot hold 68 one-pixel modules.
        XCTAssertThrowsError(try LayoutBuilder.make(
            layoutID: "layout", profile: .f68,
            drawable: PixelSize(width: 60, height: 200), rotationDeg: 0
        ))
    }

    func testLayoutDocumentKeysAndTypes() throws {
        let layout = try LayoutBuilder.make(
            layoutID: "layout-0",
            profile: .c52,
            drawable: PixelSize(width: 1512, height: 982),
            rotationDeg: 270
        )
        let document = JSONValue.object([
            "schema_version": .string("1.1"),
            "layouts": .array([layout.json()])
        ])
        let parsed = try JSONParser.parse(document.serialized())
        let object = try XCTUnwrap(parsed["layouts"]?.arrayValue?.first)
        XCTAssertEqual(object["layout_id"]?.stringValue, "layout-0")
        XCTAssertEqual(object["layout_profile"]?.stringValue, "C52")
        XCTAssertEqual(object["coordinate_system"]?.stringValue, "DRAWABLE_TOP_LEFT_PIXEL_EDGES")
        XCTAssertEqual(object["pattern_rotation_deg"]?.intValue, 270)
        XCTAssertEqual(object["drawable_width_px"]?.intValue, 1512)
        XCTAssertEqual(object["drawable_height_px"]?.intValue, 982)
        XCTAssertEqual(object["level_low"]?.intValue, 32)
        XCTAssertEqual(object["level_high"]?.intValue, 224)
        XCTAssertEqual(object["modules"]?.arrayValue?.count, 52)
        XCTAssertEqual(object["modules"]?.arrayValue?.first?["index"]?.intValue, 0)
        XCTAssertEqual(object["modules"]?.arrayValue?.first?["rect_px"]?.arrayValue?.count, 4)
        XCTAssertEqual(object["markers"]?.arrayValue?.count, 4)
        XCTAssertEqual(object["markers"]?.arrayValue?.first?["dictionary"]?.stringValue, "DICT_4X4_50")
        XCTAssertEqual(object["markers"]?.arrayValue?.first?["marker_size_bits"]?.intValue, 4)
        XCTAssertEqual(object["markers"]?.arrayValue?.first?["border_bits"]?.intValue, 1)
        XCTAssertEqual(object["dynamic_rect_px"]?.arrayValue?.count, 4)
        let rows = try XCTUnwrap(object["pattern_to_drawable"]?.arrayValue)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].arrayValue?.count, 3)
    }

    func testRotationPreservesModuleIndexOrder() throws {
        // The contract states that rotation never renumbers modules. Verify the
        // exported order follows the logical index, not the screen corner.
        let zero = try LayoutBuilder.make(layoutID: "a", profile: .f68,
                                          drawable: PixelSize(width: 3456, height: 2234), rotationDeg: 0)
        let ninety = try LayoutBuilder.make(layoutID: "b", profile: .f68,
                                            drawable: PixelSize(width: 3456, height: 2234), rotationDeg: 90)
        XCTAssertEqual(zero.modules.count, ninety.modules.count)
        XCTAssertLessThan(zero.modules.first!.x0, zero.modules.last!.x0)
        XCTAssertLessThan(ninety.modules.first!.y0, ninety.modules.last!.y0)
    }
    private func gridFixture() throws -> JSONValue {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONParser.parse(Data(contentsOf: root.appendingPathComponent("docs/cw/fixtures/cr-001-layouts.json")))
    }

    func testSharedPlacementFixtureAllGeometriesAndRotations() throws {
        let fixture = try gridFixture()
        let cases = try XCTUnwrap(fixture["cases"]?.arrayValue)
        XCTAssertEqual(cases.count, 24)
        for expected in cases {
            let geometry = try XCTUnwrap(GeometryProfile(rawValue: XCTUnwrap(expected["geometry_profile"]?.stringValue)))
            let angle = Int(try XCTUnwrap(expected["pattern_rotation_deg"]?.intValue))
            let canvas = PixelSize(width: 121, height: 109)
            let slots = try LayoutBuilder.slotRects(geometryProfile: geometry,
                dynamicRect: RectPx(x0: 7, y0: 11, x1: 108, y1: 94), rotationDeg: angle, patternSize: canvas)
            let count = geometry.layoutProfile.moduleCount
            let layout = LayoutSpec(layoutID: try XCTUnwrap(expected["layout_id"]?.stringValue),
                geometryProfile: geometry,
                drawableSize: PixelSize(width: Int(try XCTUnwrap(expected["drawable_width_px"]?.intValue)),
                                        height: Int(try XCTUnwrap(expected["drawable_height_px"]?.intValue))),
                patternSize: canvas, patternRotationDeg: angle, levels: .sdrDefault,
                dynamicRectPx: PatternRotation.rect(RectPx(x0: 7, y0: 11, x1: 108, y1: 94), degrees: angle, patternSize: canvas),
                modules: Array(slots.prefix(count)),
                padding: (count..<slots.count).map { PaddingPlacement(slotIndex: $0, rectPx: slots[$0], level: ($0-count)%2 == 0 ? 32 : 224) },
                markers: [])
            let actual = layout.json()
            for field in try XCTUnwrap(expected.objectValue).keys where field != "case_id" {
                if field == "pattern_to_drawable" {
                    XCTAssertEqual(actual[field]?.arrayValue?.flatMap { $0.arrayValue ?? [] }.compactMap(\.doubleValue),
                                   expected[field]?.arrayValue?.flatMap { $0.arrayValue ?? [] }.compactMap(\.doubleValue))
                } else {
                    XCTAssertEqual(actual[field], expected[field], "\(geometry) r\(angle) \(field)")
                }
            }
        }
        for oracle in try XCTUnwrap(fixture["payload_oracles"]?.arrayValue) {
            let seq = try XCTUnwrap(UInt64(XCTUnwrap(oracle["render_seq"]?.stringValue)))
            let codes = try XCTUnwrap(oracle["module_codes"]?.arrayValue).compactMap { $0.intValue.map(UInt8.init) }
            for profile in LayoutProfile.allCases {
                XCTAssertEqual(PatternEncoder.encode(RenderSeq(seq), profile: profile).codes(.sdrDefault),
                               Array(codes.prefix(profile.moduleCount)))
            }
        }
    }

    func testMacGridKeepsOriginalBoundaryMarkersAndCustomLevels() throws {
        for geometry in GeometryProfile.macOSCases {
            for rotation in rotations {
                let size = PixelSize(width: 1003, height: 709)
                let old = try LayoutBuilder.make(layoutID: "old", profile: geometry.layoutProfile,
                                                 drawable: size, rotationDeg: rotation)
                let grid = try LayoutBuilder.make(layoutID: "grid", geometryProfile: geometry,
                                                  drawable: size, rotationDeg: rotation,
                                                  levels: PatternLevels(low: 40, high: 200))
                XCTAssertEqual(grid.dynamicRectPx, old.dynamicRectPx)
                XCTAssertEqual(grid.markers, old.markers)
                XCTAssertEqual(grid.padding.map(\.level), (0..<geometry.paddingCount).map { $0%2 == 0 ? 40 : 200 })
                XCTAssertEqual(grid.modules.count, geometry.layoutProfile.moduleCount)
                let all = grid.modules + grid.padding.map(\.rectPx)
                XCTAssertEqual(all.reduce(0) { $0 + $1.width*$1.height }, grid.dynamicRectPx.width*grid.dynamicRectPx.height)
                for (index, rect) in all.enumerated() {
                    XCTAssertTrue(grid.dynamicRectPx.contains(rect))
                    XCTAssertGreaterThan(rect.width, 0)
                    XCTAssertGreaterThan(rect.height, 0)
                    for other in all.dropFirst(index+1) { XCTAssertFalse(rect.intersects(other)) }
                }
            }
        }
    }

    func testAllPayloadsReorderWithoutChangingTheProtocolArray() throws {
        // Independent raster ordering recovers data from each physical grid.
        for geometry in [GeometryProfile.f68G6x12, .c52G5x12] {
            let layout = try LayoutBuilder.make(layoutID: "grid", geometryProfile: geometry,
                drawable: PixelSize(width: 1003, height: 709), rotationDeg: 0)
            let rects = layout.modules + layout.padding.map(\.rectPx)
            let rasterOrder = rects.indices.sorted {
                rects[$0].y0 == rects[$1].y0 ? rects[$0].x0 < rects[$1].x0 : rects[$0].y0 < rects[$1].y0
            }
            var raster = [UInt8](repeating: 0, count: rects.count)
            for n in UInt64(0)..<65536 {
                let codes = PatternEncoder.encode(RenderSeq(n), profile: layout.profile).codes(layout.levels)
                for (slot, source) in rasterOrder.enumerated() {
                    raster[slot] = source < codes.count ? codes[source] : layout.padding[source-codes.count].level
                }
                XCTAssertEqual(Array(raster.prefix(codes.count)), codes)
                XCTAssertEqual(Array(raster.dropFirst(codes.count)), layout.padding.map(\.level))
            }
        }
    }

}
