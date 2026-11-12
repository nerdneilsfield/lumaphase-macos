import XCTest
@testable import OpticCore

final class LargeTagCalibrationTests: XCTestCase {
    func testSameCanvasThreeTimesCellsAndNoOverlaps() throws {
        for geometry in GeometryProfile.macOSCases {
            for size in [PixelSize(width: 1512, height: 982), PixelSize(width: 1003, height: 709)] {
                for angle in [0, 90, 180, 270] {
                    let run = try LayoutBuilder.make(layoutID: "run", geometryProfile: geometry,
                                                     drawable: size, rotationDeg: angle)
                    let before = try run.json().serialized()
                    let target = try LargeTagCalibrationTarget.make(layoutID: "large", runLayout: run)
                    XCTAssertEqual(target.layoutID, "large")
                    XCTAssertEqual(target.runLayoutID, run.layoutID)
                    XCTAssertEqual(target.drawableSize, run.drawableSize)
                    XCTAssertEqual(target.patternSize, run.patternSize)
                    XCTAssertEqual(target.patternRotationDeg, run.patternRotationDeg)
                    XCTAssertEqual(target.matrixRowMajor(), run.matrixRowMajor())
                    XCTAssertEqual(target.markers.map(\.id), [0, 1, 2, 3])
                    XCTAssertEqual(target.references.map(\.level), [0, 128, 255])
                    let drawable = RectPx(x0: 0, y0: 0, x1: size.width, y1: size.height)
                    var quietRects: [RectPx] = []
                    for (marker, original) in zip(target.markers, run.markers) {
                        XCTAssertEqual(marker.cellSizePx, 3 * original.cellSizePx)
                        XCTAssertEqual(marker.markerSizePx, 3 * original.markerSizePx)
                        XCTAssertEqual(marker.quietZonePx, marker.cellSizePx)
                        let xs = marker.cornersPx.map(\.x), ys = marker.cornersPx.map(\.y)
                        let quiet = marker.quietZonePx
                        let box = RectPx(x0: xs.min()! - quiet, y0: ys.min()! - quiet,
                                         x1: xs.max()! + quiet, y1: ys.max()! + quiet)
                        XCTAssertTrue(drawable.contains(box))
                        for previous in quietRects { XCTAssertFalse(box.intersects(previous)) }
                        quietRects.append(box)
                    }
                    for (index, patch) in target.references.enumerated() {
                        XCTAssertGreaterThan(patch.rectPx.width, 0)
                        XCTAssertGreaterThan(patch.rectPx.height, 0)
                        XCTAssertTrue(drawable.contains(patch.rectPx))
                        for quiet in quietRects { XCTAssertFalse(quiet.intersects(patch.rectPx)) }
                        for other in target.references.dropFirst(index + 1) {
                            XCTAssertFalse(patch.rectPx.intersects(other.rectPx))
                        }
                    }
                    XCTAssertEqual(try run.json().serialized(), before)
                }
            }
        }
    }

    func testGoldenUnrotatedAndRotatedReferenceGeometry() throws {
        let run = try LayoutBuilder.make(layoutID: "run", geometryProfile: .f68G6x12,
                                        drawable: PixelSize(width: 1512, height: 982), rotationDeg: 0)
        let target = try LargeTagCalibrationTarget.make(layoutID: "cal", runLayout: run)
        // CR-002 fixed 3x rule and integer reference bands, computed by hand.
        XCTAssertEqual(target.runCellSizePx, 15)
        XCTAssertEqual(target.markers[0].cellSizePx, 45)
        XCTAssertEqual(target.markers[0].cornersPx, [
            PixelPoint(x: 90, y: 90), PixelPoint(x: 360, y: 90),
            PixelPoint(x: 360, y: 360), PixelPoint(x: 90, y: 360)])
        XCTAssertEqual(target.references.map(\.rectPx), [
            RectPx(x0: 405, y0: 405, x1: 639, y1: 577),
            RectPx(x0: 639, y0: 405, x1: 873, y1: 577),
            RectPx(x0: 873, y0: 405, x1: 1107, y1: 577)])
        let rotatedRun = try LayoutBuilder.make(layoutID: "run90", geometryProfile: .f68G6x12,
            drawable: PixelSize(width: 982, height: 1512), rotationDeg: 90)
        let rotated = try LargeTagCalibrationTarget.make(layoutID: "cal90", runLayout: rotatedRun)
        XCTAssertEqual(rotated.markers[0].cornersPx, [
            PixelPoint(x: 892, y: 90), PixelPoint(x: 892, y: 360),
            PixelPoint(x: 622, y: 360), PixelPoint(x: 622, y: 90)])
        XCTAssertEqual(rotated.references[0].rectPx, RectPx(x0: 405, y0: 405, x1: 577, y1: 639))
        let oddRun = try LayoutBuilder.make(layoutID: "odd", geometryProfile: .c52G5x12,
            drawable: PixelSize(width: 1003, height: 709), rotationDeg: 0)
        let odd = try LargeTagCalibrationTarget.make(layoutID: "odd-cal", runLayout: oddRun)
        XCTAssertEqual(odd.references.map(\.rectPx), [
            RectPx(x0: 297, y0: 297, x1: 433, y1: 412),
            RectPx(x0: 433, y0: 297, x1: 569, y1: 412),
            RectPx(x0: 569, y0: 297, x1: 706, y1: 412)])
    }

    func testExplicitFitFailureAndIndependentIdentity() throws {
        let run = try LayoutBuilder.make(layoutID: "run", geometryProfile: .f68G6x12,
            drawable: PixelSize(width: 1512, height: 982), rotationDeg: 0)
        XCTAssertThrowsError(try LargeTagCalibrationTarget.make(layoutID: "run", runLayout: run)) {
            XCTAssertEqual($0 as? LargeTagCalibrationError, .reusedRunLayoutID)
        }
        // The public LayoutSpec can describe a narrower custom RUN target.
        // Preserve its requested cell size: the calibration builder must fail,
        // not clamp to a smaller Tag. Normal Builder outputs are unchanged.
        let narrow = LayoutSpec(layoutID: "narrow", geometryProfile: run.geometryProfile,
            drawableSize: PixelSize(width: 600, height: 600),
            patternSize: PixelSize(width: 600, height: 600), patternRotationDeg: 0,
            levels: run.levels, dynamicRectPx: run.dynamicRectPx,
            modules: run.modules, padding: run.padding, markers: run.markers)
        XCTAssertThrowsError(try LargeTagCalibrationTarget.make(layoutID: "large", runLayout: narrow)) {
            XCTAssertEqual($0 as? LargeTagCalibrationError,
                .doesNotFit(patternSize: PixelSize(width: 600, height: 600), cellSizePx: 45))
        }
        XCTAssertEqual(run.markers[0].cellSizePx, 15)
        XCTAssertEqual(try LayoutBuilder.make(layoutID: "run", geometryProfile: .f68G6x12,
            drawable: run.drawableSize, rotationDeg: 0), run)
    }
}
