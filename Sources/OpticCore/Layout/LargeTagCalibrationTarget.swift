import Foundation

/// A static positioning target, separate from the OPTC payload layout. References
/// are actual display rectangles, not protocol modules. Export is deliberately
/// absent until the shared calibration schema is defined.
public struct LargeTagCalibrationTarget: Equatable {
    public struct ReferencePatch: Equatable {
        public let rectPx: RectPx
        public let level: UInt8
    }

    public let layoutID: String
    public let runLayoutID: String
    public let drawableSize: PixelSize
    public let patternSize: PixelSize
    public let patternRotationDeg: Int
    public let runCellSizePx: Int
    public let markers: [MarkerPlacement]
    public let references: [ReferencePatch]

    public func matrixRowMajor() -> [[Double]] {
        PatternRotation.matrix(degrees: patternRotationDeg, patternSize: patternSize)
    }

    /// Uses the existing RUN drawable and logical canvas; never resizes a window
    /// or changes the normal Builder's marker size/ROI. Failure does not mutate
    /// the immutable RUN layout and never clamps the requested 3x cell size.
    public static func make(layoutID: String, runLayout: LayoutSpec) throws -> LargeTagCalibrationTarget {
        guard !layoutID.isEmpty else { throw LargeTagCalibrationError.emptyLayoutID }
        guard layoutID != runLayout.layoutID else { throw LargeTagCalibrationError.reusedRunLayoutID }
        guard runLayout.markers.map(\.id) == [0, 1, 2, 3],
              let runCell = runLayout.markers.first?.cellSizePx,
              runCell >= LayoutBuilder.minimumCellSizePx,
              runLayout.markers.allSatisfy({ $0.cellSizePx == runCell }) else {
            throw LargeTagCalibrationError.invalidRunMarkers
        }
        let size = runLayout.patternSize
        let angle = runLayout.patternRotationDeg
        guard PatternRotation.isSupported(angle) else { throw LayoutError.unsupportedRotation(angle) }
        let cell = 3 * runCell
        let margin = 9 * cell
        // Three distinct static reference bands need at least one pixel each.
        guard size.width - 2 * margin >= 3, size.height - 2 * margin >= 1 else {
            throw LargeTagCalibrationError.doesNotFit(patternSize: size, cellSizePx: cell)
        }

        let quietSquares = [
            RectPx(x0: cell, y0: cell, x1: margin, y1: margin),
            RectPx(x0: size.width - margin, y0: cell, x1: size.width - cell, y1: margin),
            RectPx(x0: size.width - margin, y0: size.height - margin,
                   x1: size.width - cell, y1: size.height - cell),
            RectPx(x0: cell, y0: size.height - margin, x1: margin, y1: size.height - cell)
        ]
        let markers = quietSquares.enumerated().map { id, square in
            let black = RectPx(x0: square.x0 + cell, y0: square.y0 + cell,
                               x1: square.x1 - cell, y1: square.y1 - cell)
            return MarkerPlacement(id: id, cellSizePx: cell, quietZonePx: cell,
                cornersPx: black.corners.map { PatternRotation.map($0, degrees: angle, patternSize: size) })
        }
        let referenceWidth = size.width - 2 * margin
        let references = [UInt8(0), 128, 255].enumerated().map { index, level in
            let rect = RectPx(x0: margin + index * referenceWidth / 3, y0: margin,
                              x1: margin + (index + 1) * referenceWidth / 3, y1: size.height - margin)
            return ReferencePatch(rectPx: PatternRotation.rect(rect, degrees: angle, patternSize: size), level: level)
        }
        return LargeTagCalibrationTarget(layoutID: layoutID, runLayoutID: runLayout.layoutID,
            drawableSize: runLayout.drawableSize, patternSize: size, patternRotationDeg: angle,
            runCellSizePx: runCell, markers: markers, references: references)
    }
}

public enum LargeTagCalibrationError: Error, Equatable, CustomStringConvertible {
    case emptyLayoutID
    case reusedRunLayoutID
    case invalidRunMarkers
    case doesNotFit(patternSize: PixelSize, cellSizePx: Int)

    public var description: String {
        switch self {
        case .emptyLayoutID: return "大 Tag 定位目标需要独立且非空的 layout_id。"
        case .reusedRunLayoutID: return "大 Tag 定位目标不能复用 RUN 的 layout_id。"
        case .invalidRunMarkers: return "RUN 布局需包含 ID 0–3 且码元尺寸一致的四个标记。"
        case let .doesNotFit(size, cell):
            return "当前逻辑画布 \(size.width)×\(size.height) 无法容纳固定 3 倍 Tag；码元 \(cell) px，至少需要 \(18 * cell + 3)×\(18 * cell + 1) px。保留普通 RUN，不缩小 Tag。"
        }
    }
}
