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

/// Placement is independent of the optical payload family. The shared grids are
/// supported by the core; the Mac operator chooses only `macOSCases`.
public enum GeometryProfile: String, CaseIterable {
    case f68 = "F68"
    case c52 = "C52"
    case f68G6x12 = "F68-G6x12"
    case c52G5x12 = "C52-G5x12"
    case f68G9x8 = "F68-G9x8"
    case c52G9x6 = "C52-G9x6"

    public static let macOSCases: [GeometryProfile] = [.f68G6x12, .c52G5x12, .f68, .c52]

    public var layoutProfile: LayoutProfile {
        switch self {
        case .f68, .f68G6x12, .f68G9x8: return .f68
        case .c52, .c52G5x12, .c52G9x6: return .c52
        }
    }

    public var rows: Int {
        switch self {
        case .f68, .c52: return 1
        case .f68G6x12: return 6
        case .c52G5x12: return 5
        case .f68G9x8, .c52G9x6: return 9
        }
    }

    public var columns: Int {
        switch self {
        case .f68: return 68
        case .c52: return 52
        case .f68G6x12, .c52G5x12: return 12
        case .f68G9x8: return 8
        case .c52G9x6: return 6
        }
    }

    public var paddingCount: Int { rows * columns - layoutProfile.moduleCount }
}

public struct PaddingPlacement: Equatable {
    public let slotIndex: Int
    public let rectPx: RectPx
    public let level: UInt8

    public func json() -> JSONValue {
        .object([
            "slot_index": .int(Int64(slotIndex)),
            "role": .string("padding"),
            "rect_px": .array(rectPx.jsonArray),
            "level": .int(Int64(level))
        ])
    }
}

/// Immutable layout of one segment's optical target.
public struct LayoutSpec: Equatable {
    public let layoutID: String
    public let geometryProfile: GeometryProfile
    public var profile: LayoutProfile { geometryProfile.layoutProfile }
    public let drawableSize: PixelSize
    /// Pre-rotation logical canvas. For 90/270 this is the drawable size with
    /// width and height swapped.
    public let patternSize: PixelSize
    public let patternRotationDeg: Int
    public let levels: PatternLevels
    /// Bounding rectangle of the dynamic area after rotation.
    public let dynamicRectPx: RectPx
    /// Protocol modules only, in unchanged encoder order, after rotation.
    public let modules: [RectPx]
    public let padding: [PaddingPlacement]
    public let markers: [MarkerPlacement]

    public init(
        layoutID: String,
        geometryProfile: GeometryProfile,
        drawableSize: PixelSize,
        patternSize: PixelSize,
        patternRotationDeg: Int,
        levels: PatternLevels,
        dynamicRectPx: RectPx,
        modules: [RectPx],
        padding: [PaddingPlacement],
        markers: [MarkerPlacement]
    ) {
        self.layoutID = layoutID
        self.geometryProfile = geometryProfile
        self.drawableSize = drawableSize
        self.patternSize = patternSize
        self.patternRotationDeg = patternRotationDeg
        self.levels = levels
        self.dynamicRectPx = dynamicRectPx
        self.modules = modules
        self.padding = padding
        self.markers = markers
    }

    public func matrixRowMajor() -> [[Double]] {
        PatternRotation.matrix(degrees: patternRotationDeg, patternSize: patternSize)
    }

    public func json() -> JSONValue {
        .object([
            "layout_id": .string(layoutID),
            "layout_profile": .string(profile.rawValue),
            "geometry_profile": .string(geometryProfile.rawValue),
            "grid_rows": .int(Int64(geometryProfile.rows)),
            "grid_cols": .int(Int64(geometryProfile.columns)),
            "module_count": .int(Int64(profile.moduleCount)),
            "padding_count": .int(Int64(padding.count)),
            "module_order": .string("row-major"),
            "sampling_inner_fraction": .double(0.6),
            "padding": .array(padding.map { $0.json() }),
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
    case dynamicHeightTooSmall(drawableHeightPx: Int, rows: Int)
    case invalidLevels
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
        try make(layoutID: layoutID,
                 geometryProfile: profile == .f68 ? .f68 : .c52,
                 drawable: drawable, rotationDeg: rotationDeg, levels: levels)
    }

    public static func make(
        layoutID: String,
        geometryProfile: GeometryProfile,
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

        guard levels.low < levels.high else { throw LayoutError.invalidLevels }
        let moduleCount = geometryProfile.layoutProfile.moduleCount
        let bw = patternSize.width * dynamicWidthPercent / 100
        let bh = patternSize.height * dynamicHeightPercent / 100
        let a = (patternSize.width - bw) / 2
        let b = a + bw
        let c = (patternSize.height - bh) / 2
        let d = c + bh
        let patternDynamic = RectPx(x0: a, y0: c, x1: b, y1: d)

        let slots = try slotRects(geometryProfile: geometryProfile, dynamicRect: patternDynamic,
                                  rotationDeg: rotationDeg, patternSize: patternSize)
        let moduleRects = Array(slots.prefix(moduleCount))
        let padding = (moduleCount..<slots.count).map { index in
            PaddingPlacement(slotIndex: index, rectPx: slots[index],
                             level: (index - moduleCount) % 2 == 0 ? levels.low : levels.high)
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
            geometryProfile: geometryProfile,
            drawableSize: drawable,
            patternSize: patternSize,
            patternRotationDeg: rotationDeg,
            levels: levels,
            dynamicRectPx: PatternRotation.rect(patternDynamic, degrees: rotationDeg, patternSize: patternSize),
            modules: moduleRects,
            padding: padding,
            markers: markers
        )
    }

    /// Placement arithmetic separated from the App's fixed ROI and markers.
    /// The common placement fixture supplies its own logical canvas and ROI.
    static func slotRects(
        geometryProfile: GeometryProfile,
        dynamicRect: RectPx,
        rotationDeg: Int,
        patternSize: PixelSize
    ) throws -> [RectPx] {
        guard PatternRotation.isSupported(rotationDeg) else {
            throw LayoutError.unsupportedRotation(rotationDeg)
        }
        let rows = geometryProfile.rows
        let cols = geometryProfile.columns
        guard dynamicRect.width >= cols else {
            throw LayoutError.dynamicWidthTooSmall(drawableWidthPx: dynamicRect.width, moduleCount: cols)
        }
        guard dynamicRect.height >= rows else {
            throw LayoutError.dynamicHeightTooSmall(drawableHeightPx: dynamicRect.height, rows: rows)
        }
        return (0..<(rows * cols)).map { index in
            let row = index / cols
            let column = index % cols
            let rect = RectPx(
                x0: dynamicRect.x0 + column * dynamicRect.width / cols,
                y0: dynamicRect.y0 + row * dynamicRect.height / rows,
                x1: dynamicRect.x0 + (column + 1) * dynamicRect.width / cols,
                y1: dynamicRect.y0 + (row + 1) * dynamicRect.height / rows
            )
            return PatternRotation.rect(rect, degrees: rotationDeg, patternSize: patternSize)
        }
    }

}
