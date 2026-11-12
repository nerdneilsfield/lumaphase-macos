import Foundation

public enum DiagnosticPattern: String, CaseIterable {
    case white = "WHITE"
    case black = "BLACK"
    case checkerboard = "CHECKERBOARD_2X2"
    case vsyncBlackWhite = "VSYNC_BLACK_WHITE"
}

public struct FullscreenDiagnosticLayout: Equatable {
    public let layoutID: String
    public let drawableSize: PixelSize
    public let patternSize: PixelSize
    public let patternRotationDeg: Int
    public let pattern: DiagnosticPattern

    public init(layoutID: String, drawable: PixelSize, rotationDeg: Int, pattern: DiagnosticPattern) throws {
        guard !layoutID.isEmpty else { throw LayoutError.emptyLayoutID }
        guard drawable.width > 0, drawable.height > 0 else { throw LayoutError.invalidDrawableSize(drawable) }
        guard PatternRotation.isSupported(rotationDeg) else { throw LayoutError.unsupportedRotation(rotationDeg) }
        self.layoutID = layoutID
        self.drawableSize = drawable
        self.patternSize = rotationDeg % 180 == 0 ? drawable : PixelSize(width: drawable.height, height: drawable.width)
        self.patternRotationDeg = rotationDeg
        self.pattern = pattern
    }
}

/// The actual displayed geometry. Only OPTC carries payload-module geometry.
public enum DisplayLayout: Equatable {
    case optc(LayoutSpec)
    case calibrationTarget(LargeTagCalibrationTarget)
    case fullscreenDiagnostic(FullscreenDiagnosticLayout)

    public var layoutID: String {
        switch self {
        case .optc(let x): return x.layoutID
        case .calibrationTarget(let x): return x.layoutID
        case .fullscreenDiagnostic(let x): return x.layoutID
        }
    }
    public var drawableSize: PixelSize {
        switch self {
        case .optc(let x): return x.drawableSize
        case .calibrationTarget(let x): return x.drawableSize
        case .fullscreenDiagnostic(let x): return x.drawableSize
        }
    }
    public var patternSize: PixelSize {
        switch self {
        case .optc(let x): return x.patternSize
        case .calibrationTarget(let x): return x.patternSize
        case .fullscreenDiagnostic(let x): return x.patternSize
        }
    }
    public var patternRotationDeg: Int {
        switch self {
        case .optc(let x): return x.patternRotationDeg
        case .calibrationTarget(let x): return x.patternRotationDeg
        case .fullscreenDiagnostic(let x): return x.patternRotationDeg
        }
    }
    public var optcLayout: LayoutSpec? {
        if case .optc(let x) = self { return x }
        return nil
    }
    public func json() -> JSONValue {
        if case .optc(let x) = self {
            var fields = x.json().objectValue!
            fields["layout_type"] = .string("OPTC")
            return .object(fields)
        }
        var fields: JSONObject = [
            "layout_id": .string(layoutID),
            "drawable_width_px": .int(Int64(drawableSize.width)),
            "drawable_height_px": .int(Int64(drawableSize.height)),
            "coordinate_system": .string("DRAWABLE_TOP_LEFT_PIXEL_EDGES"),
            "pattern_width_px": .int(Int64(patternSize.width)),
            "pattern_height_px": .int(Int64(patternSize.height)),
            "pattern_rotation_deg": .int(Int64(patternRotationDeg)),
            "pattern_to_drawable": .array(PatternRotation.matrix(degrees: patternRotationDeg, patternSize: patternSize)
                .map { .array($0.map(JSONValue.double)) })
        ]
        switch self {
        case .optc: break
        case .calibrationTarget(let x):
            fields["layout_type"] = .string("CALIBRATION_TARGET")
            fields["markers"] = .array(x.markers.map { $0.json() })
            fields["reference_regions"] = .array(x.references.enumerated().map { index, patch in
                .object(["index": .int(Int64(index)), "rect_px": .array(patch.rectPx.jsonArray),
                         "level": .int(Int64(patch.level))])
            })
        case .fullscreenDiagnostic(let x):
            fields["layout_type"] = .string("FULLSCREEN_DIAGNOSTIC")
            fields["diagnostic_pattern"] = .string(x.pattern.rawValue)
            fields["level_low"] = .int(0)
            fields["level_high"] = .int(255)
        }
        return .object(fields)
    }
}
