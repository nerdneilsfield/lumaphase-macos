import XCTest
import Metal
import OpticCore
@testable import OpticDisplay

final class CR002DiagnosticTests: XCTestCase {
    func testExactDiagnosticProgramAndCLI() throws {
        let steps = DiagnosticSessionMode.staticA.steps
        XCTAssertEqual(steps.map(\.profile.rawValue), ["CR002-A-WHITE-SETTLE","CR002-A-WHITE","CR002-A-BLACK-SETTLE","CR002-A-BLACK","CR002-A-GRID-SETTLE","CR002-A-GRID"])
        XCTAssertEqual(steps.map(\.durationNanoseconds), [1,3,1,3,1,3].map { Int64($0)*1_000_000_000 })
        XCTAssertEqual(DiagnosticSessionMode.dynamicBW.steps[0].profile.rawValue, "CR002-B-BW")
        XCTAssertEqual(DiagnosticSessionMode.dynamicBW.steps[0].durationNanoseconds, 60_000_000_000)
        XCTAssertEqual(try AppOptions.parse(arguments: ["app","--diagnostic","B"]).diagnostic, .dynamicBW)
        XCTAssertTrue(try AppOptions.parse(arguments: ["app","--large-tags"]).largeTags)
        XCTAssertThrowsError(try AppOptions.parse(arguments: ["app","--large-tags","--diagnostic","A"]))
    }

    func testFullDrawablePixelsAllPatternsRotationsAndIdentityGaps() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let renderer = try MetalRenderer(device: device)
        let size = PixelSize(width: 9, height: 7)
        for angle in [0,90,180,270] {
            for pattern in DiagnosticPattern.allCases {
                let layout = try FullscreenDiagnosticLayout(layoutID: "full", drawable: size, rotationDeg: angle, pattern: pattern)
                let ids: [UInt64] = pattern == .vsyncBlackWhite ? [0,1,3,4,UInt64.max] : [0]
                for id in ids {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                        width: size.width, height: size.height, mipmapped: false)
                    descriptor.usage = [.renderTarget, .shaderRead]
                    descriptor.storageMode = .shared
                    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
                    let scene = SceneBuilder.fullscreenDiagnosticScene(layout, nativeFrameID: NativeFrameID(id))
                    XCTAssertTrue(scene.text.isEmpty)
                    let buffer = try XCTUnwrap(renderer.makeCommandBuffer(into: texture, scene: scene, text: nil))
                    buffer.commit(); buffer.waitUntilCompleted()
                    XCTAssertNil(buffer.error)
                    var pixels = [UInt8](repeating: 127, count: size.width*size.height*4)
                    texture.getBytes(&pixels, bytesPerRow: size.width*4,
                        from: MTLRegionMake2D(0,0,size.width,size.height), mipmapLevel: 0)
                    for y in 0..<size.height {
                        for x in 0..<size.width {
                            let value: UInt8
                            switch pattern {
                            case .white: value = 255
                            case .black: value = 0
                            case .vsyncBlackWhite: value = id%2 == 0 ? 255 : 0
                            case .checkerboard:
                                let sx: Int, sy: Int
                                switch angle {
                                case 0: (sx,sy) = (x,y)
                                case 90: (sx,sy) = (y,layout.patternSize.height-1-x)
                                case 180: (sx,sy) = (layout.patternSize.width-1-x,layout.patternSize.height-1-y)
                                default: (sx,sy) = (layout.patternSize.width-1-y,x)
                                }
                                value = (sx < layout.patternSize.width/2) == (sy < layout.patternSize.height/2) ? 255 : 0
                            }
                            let offset = (y*size.width+x)*4
                            XCTAssertEqual(Array(pixels[offset..<offset+4]), [value,value,value,255], "\(pattern) r\(angle) id\(id) (\(x),\(y))")
                        }
                    }
                }
            }
        }
    }
}
