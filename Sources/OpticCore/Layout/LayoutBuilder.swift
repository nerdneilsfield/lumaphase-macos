import Foundation

/// One ArUco placement. `cornersPx` are the four boundary corners of the black
/// border, in marker-local order (top-left, top-right, bottom-right,
/// bottom-left) and then rotated into output coordinates.
public struct MarkerPlacement: Equatable {
    public static let dictionary = "DICT_4X4_50"
    public static let markerSizeBits = 4
    public static let borderBits = 1

    public let id: Int
    public let cellSizePx: Int
    public let quietZonePx: Int
    public let cornersPx: [PixelPoint]

    public init(id: Int, cellSizePx: Int, quietZonePx: Int, cornersPx: [PixelPoint]) {
        self.id = id
        self.cellSizePx = cellSizePx
        self.quietZonePx = quietZonePx
        self.cornersPx = cornersPx
    }

    /// Outer black-border size in output pixels: 4 data cells + 1 border cell
    /// on each side.
    public var markerSizePx: Int { cellSizePx * (MarkerPlacement.markerSizeBits + 2 * MarkerPlacement.borderBits) }

    public func json() -> JSONValue {
        .object([
            "id": .int(Int64(id)),
            "dictionary": .string(MarkerPlacement.dictionary),
            "marker_size_bits": .int(Int64(MarkerPlacement.markerSizeBits)),
            "border_bits": .int(Int64(MarkerPlacement.borderBits)),
            "cell_size_px": .int(Int64(cellSizePx)),
            "quiet_zone_px": .int(Int64(quietZonePx)),
            "corners_px": .array(cornersPx.map { .array([.int(Int64($0.x)), .int(Int64($0.y))]) })
        ])
    }
}

/// Immutable layout of one segment's optical target.
public struct LayoutSpec: Equatable {
    public let layoutID: String
    public let profile: LayoutProfile
    public let drawableSize: PixelSize
    /// Pre-rotation logical canvas. For 90/270 this is the drawable size with
    /// width and height swapped.
    public let patternSize: PixelSize
    public let patternRotationDeg: Int
    public let levels: PatternLevels
    /// Bounding rectangle of the dynamic area after rotation.
    public let dynamicRectPx: RectPx
    /// One entry per protocol module; each rect is the full-height column
    /// strip of that module after rotation.
    public let modules: [RectPx]
    public let markers: [MarkerPlacement]

    public init(
        layoutID: String,
        profile: LayoutProfile,
        drawableSize: PixelSize,
        patternSize: PixelSize,
        patternRotationDeg: Int,
        levels: PatternLevels,
        dynamicRectPx: RectPx,
        modules: [RectPx],
        markers: [MarkerPlacement]
    ) {
        self.layoutID = layoutID
        self.profile = profile
        self.drawableSize = drawableSize
        self.patternSize = patternSize
        self.patternRotationDeg = patternRotationDeg
        self.levels = levels
        self.dynamicRectPx = dynamicRectPx
        self.modules = modules
        self.markers = markers
    }

    public func matrixRowMajor() -> [[Double]] {
        PatternRotation.matrix(degrees: patternRotationDeg, patternSize: patternSize)
    }

    public func json() -> JSONValue {
        .object([
            "layout_id": .string(layoutID),
            "layout_profile": .string(profile.rawValue),
            "drawable_width_px": .int(Int64(drawableSize.width)),
            "drawable_height_px": .int(Int64(drawableSize.height)),
            "coordinate_system": .string("DRAWABLE_TOP_LEFT_PIXEL_EDGES"),
            "pattern_rotation_deg": .int(Int64(patternRotationDeg)),
            "pattern_width_px": .int(Int64(patternSize.width)),
            "pattern_height_px": .int(Int64(patternSize.height)),
            "pattern_to_drawable": .array(matrixRowMajor().map { row in
                .array(row.map { .double($0) })
            }),
            "dynamic_rect_px": .array(dynamicRectPx.jsonArray),
            "modules": .array(modules.enumerated().map { index, rect in
                .object([
                    "index": .int(Int64(index)),
                    "rect_px": .array(rect.jsonArray)
                ])
            }),
            "markers": .array(markers.map { $0.json() }),
            "level_low": .int(Int64(levels.low)),
            "level_high": .int(Int64(levels.high))
        ])
    }
}

public enum LayoutError: Error, Equatable {
    case invalidDrawableSize(PixelSize)
    case unsupportedRotation(Int)
    case dynamicWidthTooSmall(drawableWidthPx: Int, moduleCount: Int)
    case markersDoNotFit(drawable: PixelSize, cellSizePx: Int)
    case emptyLayoutID
}

/// Builds integer layouts from the contract formulas. No anti-aliasing and no
/// percentage rescaling at read time: the exported rects are the truth.
public enum LayoutBuilder {
    public static let dynamicWidthPercent = 96
    public static let dynamicHeightPercent = 68
    /// Cell size divisor used to pick a starting integer ArUco cell size.
    public static let markerCellDivisor = 64
    public static let minimumCellSizePx = 2

    public static func make(
        layoutID: String,
        profile: LayoutProfile,
        drawable: PixelSize,
        rotationDeg: Int,
        levels: PatternLevels = .sdrDefault
    ) throws -> LayoutSpec {
        guard !layoutID.isEmpty else { throw LayoutError.emptyLayoutID }
        guard drawable.width > 0, drawable.height > 0 else {
            throw LayoutError.invalidDrawableSize(drawable)
        }
        guard PatternRotation.isSupported(rotationDeg) else {
            throw LayoutError.unsupportedRotation(rotationDeg)
        }

        let patternSize: PixelSize
        switch rotationDeg {
        case 0, 180:
            patternSize = drawable
        default:
            patternSize = PixelSize(width: drawable.height, height: drawable.width)
        }

        let moduleCount = profile.moduleCount
        let bw = patternSize.width * dynamicWidthPercent / 100
        let bh = patternSize.height * dynamicHeightPercent / 100
        guard bw >= moduleCount else {
            throw LayoutError.dynamicWidthTooSmall(drawableWidthPx: bw, moduleCount: moduleCount)
        }
        let a = (patternSize.width - bw) / 2
        let b = a + bw
        let c = (patternSize.height - bh) / 2
        let d = c + bh
        let patternDynamic = RectPx(x0: a, y0: c, x1: b, y1: d)

        // Integer module boundaries in pre-rotation coordinates.
        var moduleRects: [RectPx] = []
        moduleRects.reserveCapacity(moduleCount)
        for index in 0..<moduleCount {
            let x0 = a + index * (b - a) / moduleCount
            let x1 = a + (index + 1) * (b - a) / moduleCount
            let preRotation = RectPx(x0: x0, y0: c, x1: x1, y1: d)
            moduleRects.append(PatternRotation.rect(preRotation, degrees: rotationDeg, patternSize: patternSize))
        }

        // Static markers live in the top and bottom margins; the margins above
        // are at least as large as below because the dynamic area is centred.
        let topMargin = c
        var cell = max(1, min(patternSize.width, patternSize.height) / markerCellDivisor)
        while cell > 1, 9 * cell > topMargin {
            cell /= 2
        }
        guard cell >= minimumCellSizePx,
              9 * cell <= topMargin,
              3 * cell + 2 * 8 * cell <= patternSize.width
        else {
            throw LayoutError.markersDoNotFit(drawable: drawable, cellSizePx: cell)
        }
        let quiet = cell
        let inset = cell
        let outer = 8 * cell
        let black = 6 * cell
        let quietSquares = [
            RectPx(x0: inset, y0: inset, x1: inset + outer, y1: inset + outer),
            RectPx(x0: patternSize.width - inset - outer, y0: inset,
                   x1: patternSize.width - inset, y1: inset + outer),
            RectPx(x0: patternSize.width - inset - outer, y0: patternSize.height - inset - outer,
                   x1: patternSize.width - inset, y1: patternSize.height - inset),
            RectPx(x0: inset, y0: patternSize.height - inset - outer,
                   x1: inset + outer, y1: patternSize.height - inset)
        ]
        var markers: [MarkerPlacement] = []
        markers.reserveCapacity(4)
        for (index, quietSquare) in quietSquares.enumerated() {
            let border = RectPx(
                x0: quietSquare.x0 + quiet,
                y0: quietSquare.y0 + quiet,
                x1: quietSquare.x0 + quiet + black,
                y1: quietSquare.y0 + quiet + black
            )
            let localCorners = [
                PixelPoint(x: border.x0, y: border.y0),
                PixelPoint(x: border.x1, y: border.y0),
                PixelPoint(x: border.x1, y: border.y1),
                PixelPoint(x: border.x0, y: border.y1)
            ]
            markers.append(MarkerPlacement(
                id: index,
                cellSizePx: cell,
                quietZonePx: quiet,
                cornersPx: localCorners.map {
                    PatternRotation.map($0, degrees: rotationDeg, patternSize: patternSize)
                }
            ))
        }

        return LayoutSpec(
            layoutID: layoutID,
            profile: profile,
            drawableSize: drawable,
            patternSize: patternSize,
            patternRotationDeg: rotationDeg,
            levels: levels,
            dynamicRectPx: PatternRotation.rect(patternDynamic, degrees: rotationDeg, patternSize: patternSize),
            modules: moduleRects,
            markers: markers
        )
    }
}
