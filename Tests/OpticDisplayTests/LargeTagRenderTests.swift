import XCTest
import Metal
import OpticCore
@testable import OpticDisplay

final class LargeTagRenderTests: XCTestCase {
    func testActualMetalPixelsAgainstOfficialBitsAllRotations() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONParser.parse(Data(contentsOf: root.appendingPathComponent(
            "third_party/opencv-4.10.0/aruco-4x4-50-first4.json")))
        let officialMarkers = try XCTUnwrap(fixture["markers"]?.arrayValue)
        let renderer = try MetalRenderer(device: device)
        for angle in [0, 90, 180, 270] {
            let size = PixelSize(width: 1512, height: 982)
            let run = try LayoutBuilder.make(layoutID: "run", geometryProfile: .f68G6x12,
                                            drawable: size, rotationDeg: angle)
            let target = try LargeTagCalibrationTarget.make(layoutID: "large", runLayout: run)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: size.width, height: size.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let scene = SceneBuilder.largeTagCalibrationScene(target)
            XCTAssertTrue(scene.text.isEmpty)
            let buffer = try XCTUnwrap(renderer.makeCommandBuffer(into: texture, scene: scene, text: nil))
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
            texture.getBytes(&pixels, bytesPerRow: size.width * 4,
                from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
            func matches(_ x: Int, _ y: Int, _ value: UInt8) -> Bool {
                let i = (y * size.width + x) * 4
                return pixels[i] == value && pixels[i+1] == value && pixels[i+2] == value && pixels[i+3] == 255
            }
            for marker in target.markers {
                let official = try XCTUnwrap(officialMarkers.first { $0["id"]?.intValue == Int64(marker.id) })
                let bytes = try XCTUnwrap(official["bytes"]?.arrayValue).compactMap { $0.intValue.map(UInt8.init) }
                let black = SceneBuilder.boundingBox(marker.cornersPx)
                var bad = 0
                for y in black.y0..<black.y1 {
                    for x in black.x0..<black.x1 {
                        let column = (x-black.x0)/marker.cellSizePx
                        let row = (y-black.y0)/marker.cellSizePx
                        let sourceRow: Int, sourceColumn: Int
                        switch angle {
                        case 0: (sourceRow, sourceColumn) = (row, column)
                        case 90: (sourceRow, sourceColumn) = (5-column, row)
                        case 180: (sourceRow, sourceColumn) = (5-row, 5-column)
                        default: (sourceRow, sourceColumn) = (column, 5-row)
                        }
                        let value: UInt8
                        if sourceRow == 0 || sourceRow == 5 || sourceColumn == 0 || sourceColumn == 5 {
                            value = 0
                        } else {
                            let index = (sourceRow-1)*4+sourceColumn-1
                            value = ((bytes[index/8] >> UInt8(7-index%8)) & 1) == 1 ? 255 : 0
                        }
                        if !matches(x, y, value) { bad += 1 }
                    }
                }
                XCTAssertEqual(bad, 0, "official 6x6 pixels ID \(marker.id), rotation \(angle)")
                let quiet = marker.quietZonePx
                var badQuiet = 0
                for y in (black.y0-quiet)..<(black.y1+quiet) {
                    for x in (black.x0-quiet)..<(black.x1+quiet) {
                        if x >= black.x0 && x < black.x1 && y >= black.y0 && y < black.y1 { continue }
                        if !matches(x, y, 255) { badQuiet += 1 }
                    }
                }
                XCTAssertEqual(badQuiet, 0, "white quiet ID \(marker.id), rotation \(angle)")
            }
            for reference in target.references {
                var badReference = 0
                for y in reference.rectPx.y0..<reference.rectPx.y1 {
                    for x in reference.rectPx.x0..<reference.rectPx.x1 {
                        if !matches(x, y, reference.level) { badReference += 1 }
                    }
                }
                XCTAssertEqual(badReference, 0, "reference \(reference.level), rotation \(angle)")
            }
            XCTAssertTrue(matches(0, 0, 0))
        }
    }
}
