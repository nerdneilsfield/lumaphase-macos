import Foundation

/// Calibration key that a display profile was measured under. Field names reuse
/// the manifest/layout names so the two ends cannot drift into synonyms.
/// `calibration_version` is the version string required by contract §9.
public struct CalibrationKey: Equatable {
    public var sourceDeviceID: String?
    public var osBuild: String?
    public var displayModeID: String?
    public var drawableWidthPx: Int?
    public var drawableHeightPx: Int?
    public var displayRotationDeg: Int?
    public var patternRotationDeg: Int?
    public var brightnessSetting: Double?
    public var colorSpace: String?
    public var pixelFormat: String?
    public var colorMode: String?
    public var dimmingMode: String?
    public var calibrationVersion: String
    /// Free-form note about which fields could not be read at import.
    public var calibrationNote: String?

    public init(
        sourceDeviceID: String? = nil,
        osBuild: String? = nil,
        displayModeID: String? = nil,
        drawableWidthPx: Int? = nil,
        drawableHeightPx: Int? = nil,
        displayRotationDeg: Int? = nil,
        patternRotationDeg: Int? = nil,
        brightnessSetting: Double? = nil,
        colorSpace: String? = nil,
        pixelFormat: String? = nil,
        colorMode: String? = nil,
        dimmingMode: String? = nil,
        calibrationVersion: String,
        calibrationNote: String? = nil
    ) {
        self.sourceDeviceID = sourceDeviceID
        self.osBuild = osBuild
        self.displayModeID = displayModeID
        self.drawableWidthPx = drawableWidthPx
        self.drawableHeightPx = drawableHeightPx
        self.displayRotationDeg = displayRotationDeg
        self.patternRotationDeg = patternRotationDeg
        self.brightnessSetting = brightnessSetting
        self.colorSpace = colorSpace
        self.pixelFormat = pixelFormat
        self.colorMode = colorMode
        self.dimmingMode = dimmingMode
        self.calibrationVersion = calibrationVersion
        self.calibrationNote = calibrationNote
    }

    public init(json: JSONValue) throws {
        guard case .object = json else { throw CalibrationError.invalidKey }
        guard let version = json["calibration_version"]?.stringValue else {
            throw CalibrationError.missingCalibrationVersion
        }
        self.init(
            sourceDeviceID: json["source_device_id"]?.stringValue,
            osBuild: json["os_build"]?.stringValue,
            displayModeID: json["display_mode_id"]?.stringValue,
            drawableWidthPx: json["drawable_width_px"]?.intValue.map(Int.init),
            drawableHeightPx: json["drawable_height_px"]?.intValue.map(Int.init),
            displayRotationDeg: json["display_rotation_deg"]?.intValue.map(Int.init),
            patternRotationDeg: json["pattern_rotation_deg"]?.intValue.map(Int.init),
            brightnessSetting: json["brightness_setting"]?.doubleValue,
            colorSpace: json["color_space"]?.stringValue,
            pixelFormat: json["pixel_format"]?.stringValue,
            colorMode: json["color_mode"]?.stringValue,
            dimmingMode: json["dimming_mode"]?.stringValue,
            calibrationVersion: version,
            calibrationNote: json["calibration_note"]?.stringValue
        )
    }

    public func json() -> JSONValue {
        .object([
            "source_device_id": sourceDeviceID.map(JSONValue.string) ?? .null,
            "os_build": osBuild.map(JSONValue.string) ?? .null,
            "display_mode_id": displayModeID.map(JSONValue.string) ?? .null,
            "drawable_width_px": drawableWidthPx.map { .int(Int64($0)) } ?? .null,
            "drawable_height_px": drawableHeightPx.map { .int(Int64($0)) } ?? .null,
            "display_rotation_deg": displayRotationDeg.map { .int(Int64($0)) } ?? .null,
            "pattern_rotation_deg": patternRotationDeg.map { .int(Int64($0)) } ?? .null,
            "brightness_setting": brightnessSetting.map(JSONValue.double) ?? .null,
            "color_space": colorSpace.map(JSONValue.string) ?? .null,
            "pixel_format": pixelFormat.map(JSONValue.string) ?? .null,
            "color_mode": colorMode.map(JSONValue.string) ?? .null,
            "dimming_mode": dimmingMode.map(JSONValue.string) ?? .null,
            "calibration_version": .string(calibrationVersion),
            "calibration_note": calibrationNote.map(JSONValue.string) ?? .null
        ])
    }
}

/// Imported profile. `model` is opaque: the display app preserves it and never
/// fits or interprets a screen model.
public struct ImportedCalibrationProfile: Equatable {
    public var profileID: String
    public var key: CalibrationKey
    public var model: JSONValue

    public init(profileID: String, key: CalibrationKey, model: JSONValue) {
        self.profileID = profileID
        self.key = key
        self.model = model
    }

    public func json() -> JSONValue {
        .object([
            "profile_id": .string(profileID),
            "calibration_key": key.json(),
            "model": model
        ])
    }
}

public enum CalibrationBindingStatus: String {
    case missing = "MISSING"
    case importedUnverified = "IMPORTED_UNVERIFIED"
    case compatible = "COMPATIBLE"
    case incompatible = "INCOMPATIBLE"
}

public struct SegmentProfileBinding {
    public var segmentID: SegmentID
    public var profileID: String?
    public var status: CalibrationBindingStatus
    public var mismatchFields: [String]

    public func json() -> JSONValue {
        .object([
            "segment_id": .string(segmentID.description),
            "profile_id": profileID.map(JSONValue.string) ?? .null,
            "status": .string(status.rawValue),
            "mismatch_fields": .array(mismatchFields.map { .string($0) })
        ])
    }
}

public enum CalibrationError: Error, Equatable {
    case invalidKey
    case missingCalibrationVersion
}

public enum CalibrationMatcher {
    /// Compares the imported key against the segment and its layout. A missing
    /// profile is `MISSING`; unknown key fields prevent `COMPATIBLE` but do not
    /// by themselves mean a mismatch.
    public static func binding(
        segment: SegmentConfig,
        layout: LayoutSpec,
        profile: ImportedCalibrationProfile?,
        sourceDeviceID: String,
        osBuild: String
    ) -> SegmentProfileBinding {
        guard let profile else {
            return SegmentProfileBinding(segmentID: segment.segmentID, profileID: nil,
                                         status: .missing, mismatchFields: [])
        }
        let key = profile.key
        var mismatches: [String] = []
        var unknown: [String] = []

        func compare<T: Equatable>(_ field: String, _ keyValue: T?, _ segmentValue: T?) {
            guard let keyValue else {
                unknown.append(field)
                return
            }
            guard let segmentValue else {
                unknown.append(field)
                return
            }
            if keyValue != segmentValue {
                mismatches.append(field)
            }
        }

        compare("source_device_id", key.sourceDeviceID, sourceDeviceID)
        compare("os_build", key.osBuild, osBuild)
        compare("display_mode_id", key.displayModeID, segment.displayModeID)
        compare("drawable_width_px", key.drawableWidthPx, segment.drawableWidthPx)
        compare("drawable_height_px", key.drawableHeightPx, segment.drawableHeightPx)
        compare("display_rotation_deg", key.displayRotationDeg, segment.displayRotationDeg)
        compare("pattern_rotation_deg", key.patternRotationDeg, layout.patternRotationDeg)
        compare("brightness_setting", key.brightnessSetting, segment.brightnessSetting)
        compare("color_space", key.colorSpace, segment.colorSpace)
        compare("pixel_format", key.pixelFormat, segment.pixelFormat)
        compare("color_mode", key.colorMode, segment.colorMode)
        compare("dimming_mode", key.dimmingMode, segment.dimmingMode)

        if !mismatches.isEmpty {
            return SegmentProfileBinding(segmentID: segment.segmentID, profileID: profile.profileID,
                                         status: .incompatible, mismatchFields: mismatches.sorted())
        }
        if !unknown.isEmpty {
            return SegmentProfileBinding(segmentID: segment.segmentID, profileID: profile.profileID,
                                         status: .importedUnverified, mismatchFields: unknown.sorted())
        }
        return SegmentProfileBinding(segmentID: segment.segmentID, profileID: profile.profileID,
                                     status: .compatible, mismatchFields: [])
    }
}

public struct DisplayProfileDocument {
    public var profiles: [ImportedCalibrationProfile]
    public var bindings: [SegmentProfileBinding]

    public init(profiles: [ImportedCalibrationProfile] = [], bindings: [SegmentProfileBinding] = []) {
        self.profiles = profiles
        self.bindings = bindings
    }

    public func json() -> JSONValue {
        .object([
            "schema_version": .string("1.0"),
            "profiles": .array(profiles.map { $0.json() }),
            "segment_bindings": .array(bindings.map { $0.json() })
        ])
    }
}
