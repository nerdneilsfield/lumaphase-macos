import XCTest
import Metal
import OpticCore
@testable import OpticDisplay

final class ArucoMarkerTests: XCTestCase {
    private func oracle() throws -> [String: JSONValue] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("third_party/opencv-4.10.0/aruco-4x4-50-first4.json")
        let data = try Data(contentsOf: url)
        return try JSONParser.parse(data).objectValue ?? [:]
    }

    func testBytesMatchIndependentOpenCVFixture() throws {
        // The fixture is the external oracle: it records the OpenCV 4.10.0 bytes,
        // so a changed constant here cannot silently pass.
        let document = try oracle()
        XCTAssertEqual(document["dictionary"]?.stringValue, "DICT_4X4_50")
        guard let markers = document["markers"]?.arrayValue else {
            return XCTFail("markers missing")
        }
        XCTAssertEqual(markers.count, 4)
        for marker in markers {
            let id = try XCTUnwrap(marker["id"]?.intValue)
            let bytes = try XCTUnwrap(marker["bytes"]?.arrayValue).compactMap { $0.intValue.map(UInt8.init) }
            XCTAssertEqual(ArucoMarkers.rawBytes[Int(id)], bytes, "id \(id)")
        }
        XCTAssertEqual(ArucoMarkers.rawBytes.count, 4)
    }

    func testBitsAreRowMajorMsbWhiteIsOne() {
        guard let bits = ArucoMarkers.bits(for: 0) else { return XCTFail("missing id 0") }
        XCTAssertEqual(bits.count, 16)
        // 181 = 1011 0101, 50 = 0011 0010, MSB first, 1 = white.
        XCTAssertEqual(Array(bits[0..<4]), [1, 0, 1, 1])
        XCTAssertEqual(Array(bits[4..<8]), [0, 1, 0, 1])
        XCTAssertEqual(Array(bits[8..<12]), [0, 0, 1, 1])
        XCTAssertEqual(Array(bits[12..<16]), [0, 0, 1, 0])
        XCTAssertNil(ArucoMarkers.bits(for: 4))
    }

    func testMarkerVerticesContainQuietZoneBorderAndDataCells() throws {
        let layout = try LayoutBuilder.make(
            layoutID: "layout-0", profile: .f68,
            drawable: PixelSize(width: 3456, height: 2234), rotationDeg: 0
        )
        for marker in layout.markers {
            let vertices = SceneBuilder.markerVertices(marker)
            // 1 quiet zone quad + 6x6 grid quads, 6 vertices each.
            XCTAssertEqual(vertices.count, (1 + 36) * 6)
            let quiet = SceneBuilder.rect(
                RectPx(x0: SceneBuilder.boundingBox(marker.cornersPx).x0 - marker.quietZonePx,
                       y0: SceneBuilder.boundingBox(marker.cornersPx).y0 - marker.quietZonePx,
                       x1: SceneBuilder.boundingBox(marker.cornersPx).x1 + marker.quietZonePx,
                       y1: SceneBuilder.boundingBox(marker.cornersPx).y1 + marker.quietZonePx),
                color: .white
            )
            XCTAssertEqual(Array(vertices.prefix(6)), quiet)
            // Border ring is black, one data cell is white for a 1 bit.
            let bits = try XCTUnwrap(ArucoMarkers.bits(for: marker.id))
            let borderVertices = Array(vertices[6..<(6 + 6)])
            XCTAssertEqual(borderVertices.first?.color, SceneVertex.pack(.black))
            // Grid is row-major: row 1 column 1 is the first 4x4 data cell.
            let dataStart = 6 + 7 * 6
            let firstDataCell = Array(vertices[dataStart..<(dataStart + 6)])
            XCTAssertEqual(firstDataCell.first?.color,
                           SceneVertex.pack(bits[0] == 1 ? .white : .black))
        }
    }
}

final class SceneBuilderTests: XCTestCase {
    func testDynamicSceneUsesLayoutRectsAndCodeValues() throws {
        let layout = try LayoutBuilder.make(
            layoutID: "layout-0", profile: .c52,
            drawable: PixelSize(width: 1512, height: 982), rotationDeg: 90,
            levels: PatternLevels(low: 40, high: 200)
        )
        let bits = PatternEncoder.encode(RenderSeq(7), profile: .c52)
        let scene = SceneBuilder.dynamicScene(layout, bits: bits)
        let expected = 6 + layout.markers.count * (1 + 36) * 6 + layout.modules.count * 6
        XCTAssertEqual(scene.solid.count, expected)
        XCTAssertTrue(scene.text.isEmpty)

        let codes = bits.codes(layout.levels)
        let moduleStart = 6 + layout.markers.count * (1 + 36) * 6
        for (index, rect) in layout.modules.enumerated() {
            let quad = Array(scene.solid[(moduleStart + index * 6)..<(moduleStart + index * 6 + 6)])
            let expectedRect = SceneBuilder.rect(rect, color: RGBA8(code: codes[index]))
            XCTAssertEqual(quad, expectedRect)
        }
    }

    func testEveryVertexIsInsideDrawable() throws {
        for rotation in [0, 90, 180, 270] {
            let layout = try LayoutBuilder.make(
                layoutID: "layout", profile: .f68,
                drawable: PixelSize(width: 1024, height: 768), rotationDeg: rotation
            )
            let bits = PatternEncoder.encode(RenderSeq(3), profile: .f68)
            let scene = SceneBuilder.dynamicScene(layout, bits: bits)
            for vertex in scene.solid {
                XCTAssertGreaterThanOrEqual(vertex.position.x, 0)
                XCTAssertGreaterThanOrEqual(vertex.position.y, 0)
                XCTAssertLessThanOrEqual(vertex.position.x, Float(layout.drawableSize.width))
                XCTAssertLessThanOrEqual(vertex.position.y, Float(layout.drawableSize.height))
            }
        }
    }

    func testCardTextRectAvoidsMarkersAndDynamicArea() throws {
        for size in [PixelSize(width: 3456, height: 2234), PixelSize(width: 1280, height: 720)] {
            for rotation in [0, 90, 180, 270] {
                let layout = try LayoutBuilder.make(
                    layoutID: "layout", profile: .f68, drawable: size, rotationDeg: rotation
                )
                let patternRect = SceneBuilder.patternTextRect(layout)
                XCTAssertGreaterThan(patternRect.width, 0)
                XCTAssertGreaterThan(patternRect.height, 0)
                // Pattern-space text band stays above the dynamic area and
                // between the corner markers; the rotated quad must remain
                // inside the drawable.
                let quad = SceneBuilder.textQuad(patternRect: patternRect,
                                                 patternSize: layout.patternSize,
                                                 rotationDeg: layout.patternRotationDeg)
                for vertex in quad {
                    XCTAssertGreaterThanOrEqual(vertex.position.x, 0)
                    XCTAssertGreaterThanOrEqual(vertex.position.y, 0)
                    XCTAssertLessThanOrEqual(vertex.position.x, Float(layout.drawableSize.width))
                    XCTAssertLessThanOrEqual(vertex.position.y, Float(layout.drawableSize.height))
                }
                let box = SceneBuilder.boundingBox(quad.map {
                    PixelPoint(x: Int($0.position.x), y: Int($0.position.y))
                })
                XCTAssertFalse(box.intersects(layout.dynamicRectPx))
                for marker in layout.markers {
                    let markerBox = SceneBuilder.boundingBox(marker.cornersPx)
                    XCTAssertFalse(box.intersects(markerBox), "text overlaps marker \(marker.id)")
                }
            }
        }
    }

    func testStaircaseCoversDynamicAreaWithEqualWidthBands() throws {
        let layout = try LayoutBuilder.make(
            layoutID: "layout", profile: .f68,
            drawable: PixelSize(width: 1200, height: 900), rotationDeg: 0
        )
        let levels: [UInt8] = [0, 36, 73, 109, 146, 182, 219, 255]
        let scene = SceneBuilder.calibrationScene(layout, .staircase(levels: levels))
        let bandStart = 6 + layout.markers.count * (1 + 36) * 6
        let bandVertices = Array(scene.solid[bandStart...])
        XCTAssertEqual(bandVertices.count, levels.count * 6)
        var widths: [Int] = []
        for index in 0..<levels.count {
            let quad = Array(bandVertices[(index * 6)..<(index * 6 + 6)])
            let xs = quad.map { Int($0.position.x) }
            widths.append(xs.max()! - xs.min()!)
            XCTAssertEqual(quad.first?.color, SceneVertex.pack(RGBA8(code: levels[index])))
        }
        XCTAssertLessThanOrEqual(widths.max()! - widths.min()!, 1)
    }
}

final class OffscreenRenderTests: XCTestCase {
    func testOffscreenRenderWritesExactSDRCodeValues() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        let renderer = try MetalRenderer(device: device)
        let size = PixelSize(width: 256, height: 256)
        let layout = try LayoutBuilder.make(layoutID: "offscreen", profile: .f68,
                                            drawable: size, rotationDeg: 0)
        let bits = PatternEncoder.encode(RenderSeq(0), profile: .f68)
        let scene = SceneBuilder.dynamicScene(layout, bits: bits)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let buffer = try XCTUnwrap(renderer.makeCommandBuffer(into: texture, scene: scene, text: nil))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)

        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        texture.getBytes(&pixels, bytesPerRow: size.width * 4,
                         from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
        func code(_ x: Int, _ y: Int) -> UInt8 {
            let offset = (y * size.width + x) * 4
            // bgra8Unorm with equal channels: B is the code value.
            XCTAssertEqual(pixels[offset], pixels[offset + 1])
            XCTAssertEqual(pixels[offset], pixels[offset + 2])
            XCTAssertEqual(pixels[offset + 3], 255)
            return pixels[offset]
        }

        let codes = bits.codes(layout.levels)
        for index in [0, 1, 2, 3, 10, 35, 52] {
            let rect = layout.modules[index]
            let x = rect.x0 + rect.width / 2
            let y = rect.y0 + rect.height / 2
            XCTAssertEqual(code(x, y), codes[index], "module \(index) centre")
        }
        // Background and marker structure: black background, white quiet zone,
        // black border cell.
        XCTAssertEqual(code(0, 0), 0)
        let marker = layout.markers[0]
        let box = SceneBuilder.boundingBox(marker.cornersPx)
        XCTAssertEqual(code(box.x0 - marker.quietZonePx + 1, box.y0 - marker.quietZonePx + 1), 255)
        XCTAssertEqual(code(box.x0 + 1, box.y0 + 1), 0)
    }
    func testMacGridPixelsAndCalibrationAcrossFourRotations() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = try MetalRenderer(device: device)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONParser.parse(Data(contentsOf: root.appendingPathComponent("docs/cw/fixtures/cr-001-layouts.json")))
        let oracles = try XCTUnwrap(fixture["placement_oracles"]?.arrayValue)
        for geometry in [GeometryProfile.f68G6x12, .c52G5x12] {
            let oracle = try XCTUnwrap(oracles.first { $0["geometry_profile"]?.stringValue == geometry.rawValue })
            let expectedCodes = try XCTUnwrap(oracle["slot_codes"]?.arrayValue).compactMap { $0.intValue.map(UInt8.init) }
            for angle in [0, 90, 180, 270] {
                let size = PixelSize(width: 259, height: 257)
                let layout = try LayoutBuilder.make(layoutID: "gpu", geometryProfile: geometry,
                                                     drawable: size, rotationDeg: angle)
                let rects = layout.modules + layout.padding.map(\.rectPx)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .shared
                let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
                func render(_ scene: Scene) throws -> [UInt8] {
                    let buffer = try XCTUnwrap(renderer.makeCommandBuffer(into: texture, scene: scene, text: nil))
                    buffer.commit()
                    buffer.waitUntilCompleted()
                    XCTAssertNil(buffer.error)
                    var pixels = [UInt8](repeating: 0, count: size.width*size.height*4)
                    texture.getBytes(&pixels, bytesPerRow: size.width*4,
                        from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
                    return pixels
                }
                func assertCode(_ pixels: [UInt8], _ x: Int, _ y: Int, _ value: UInt8) {
                    let i = (y*size.width+x)*4
                    XCTAssertEqual(Array(pixels[i..<i+4]), [value, value, value, 255],
                                   "\(geometry) r\(angle) (\(x),\(y))")
                }
                let dynamic = try render(SceneBuilder.dynamicScene(layout,
                    bits: PatternEncoder.encode(RenderSeq(1), profile: geometry.layoutProfile)))
                for (index, rect) in rects.enumerated() {
                    for (x,y) in [(rect.x0,rect.y0),(rect.x1-1,rect.y1-1),
                                  (rect.x0+rect.width/2,rect.y0+rect.height/2)] {
                        assertCode(dynamic, x, y, expectedCodes[index])
                    }
                }
                for flip in [false, true] {
                    let pixels = try render(SceneBuilder.calibrationScene(layout, .complementary(flip: flip)))
                    for (index, rect) in rects.enumerated() {
                        assertCode(pixels, rect.x0+rect.width/2, rect.y0+rect.height/2,
                                   (index%2 == 0) != flip ? 224 : 32)
                    }
                }
                let outlines = try render(SceneBuilder.calibrationScene(layout, .geometry(moduleCount: layout.modules.count)))
                for rect in rects {
                    assertCode(outlines, rect.x0, rect.y0, 255)
                    assertCode(outlines, rect.x1-1, rect.y1-1, 255)
                    assertCode(outlines, rect.x0+rect.width/2, rect.y0+rect.height/2, 0)
                }
                let card = try render(SceneBuilder.cardScene(layout))
                for rect in rects { assertCode(card, rect.x0+rect.width/2, rect.y0+rect.height/2, 128) }
            }
        }
    }

}

final class AppOptionsTests: XCTestCase {
    func testSmokeAndOutputOptions() throws {
        let options = try AppOptions.parse(arguments: [
            "Lumaphase", "--smoke", "--smoke-resize", "--smoke-pause",
            "--output", "/tmp/lumaphase-smoke", "--profile", "M120-S1",
            "--layout", "C52", "--rotation", "90", "--duration", "5"
        ])
        XCTAssertTrue(options.smoke)
        XCTAssertTrue(options.smokeResize)
        XCTAssertTrue(options.smokePause)
        XCTAssertTrue(options.autoStart)
        XCTAssertEqual(options.outputDirectory?.path, "/tmp/lumaphase-smoke")
        XCTAssertEqual(options.profile, .m120S1)
        XCTAssertEqual(options.layoutProfile, .c52)
        XCTAssertEqual(options.geometryProfile, .c52)
        XCTAssertEqual(options.rotationDeg, 90)
        XCTAssertEqual(options.runningSeconds, 5)
        XCTAssertGreaterThan(options.smokePhases.running, 3)
    }

    func testRejectsInvalidValues() {
        XCTAssertThrowsError(try AppOptions.parse(arguments: ["Lumaphase", "--rotation", "45"]))
        XCTAssertThrowsError(try AppOptions.parse(arguments: ["Lumaphase", "--duration", "0"]))
        XCTAssertThrowsError(try AppOptions.parse(arguments: ["Lumaphase", "--layout", "F70"]))
        XCTAssertThrowsError(try AppOptions.parse(arguments: ["Lumaphase", "--nope"]))
        XCTAssertThrowsError(try AppOptions.parse(arguments: ["Lumaphase", "--output"]))
    }

    func testHelpAndDefaults() throws {
        let defaults = try AppOptions.parse(arguments: ["Lumaphase"])
        XCTAssertFalse(defaults.smoke)
        XCTAssertEqual(defaults.profile, .m59S1)
        XCTAssertEqual(defaults.layoutProfile, .f68)
        XCTAssertEqual(defaults.geometryProfile, .f68G6x12)
        XCTAssertEqual(defaults.rotationDeg, 0)
        let help = try AppOptions.parse(arguments: ["Lumaphase", "--help"])
        XCTAssertTrue(help.showHelp)
    }
    func testMacGridCLISelection() throws {
        for geometry in GeometryProfile.macOSCases {
            let options = try AppOptions.parse(arguments: ["Lumaphase", "--layout", geometry.rawValue])
            XCTAssertEqual(options.geometryProfile, geometry)
            XCTAssertEqual(options.layoutProfile, geometry.layoutProfile)
        }
        XCTAssertThrowsError(try AppOptions.parse(arguments: ["Lumaphase", "--layout", "F68-G9x8"]))
    }

}
