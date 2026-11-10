import Foundation

/// Exact refresh-rate rational. Sourced from an operator choice or a system
/// report; never from a software callback cadence.
public struct RefreshRate: Equatable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public var hertz: Double {
        Double(numerator) / Double(denominator)
    }

    public static let hz60000_1001 = RefreshRate(numerator: 60000, denominator: 1001)
    public static let hz120 = RefreshRate(numerator: 120, denominator: 1)
}

/// Operator-selectable experiment profile. The four presets are the only ones
/// the macOS app offers; custom names are allowed and must explain themselves
/// in `operator_note`.
public struct ExperimentProfile: RawRepresentable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let m59S1 = ExperimentProfile(rawValue: "M59-S1")
    public static let m120S1 = ExperimentProfile(rawValue: "M120-S1")
    public static let m59E20 = ExperimentProfile(rawValue: "M59-E20")
    public static let mCal = ExperimentProfile(rawValue: "M-CAL")

    public static let presets: [ExperimentProfile] = [.m59S1, .m120S1, .m59E20, .mCal]

    /// The refresh rate the app asks the system for. `M-CAL` leaves refresh
    /// mode to the calibration task, so it asks for nothing.
    public var requestedRefresh: RefreshRate? {
        switch self {
        case .m59S1, .m59E20: return .hz60000_1001
        case .m120S1: return .hz120
        default: return nil
        }
    }

    /// Planned RUNNING duration. `M-CAL` has no planned duration.
    public var plannedRunningNanoseconds: Int64? {
        switch self {
        case .m59S1, .m120S1, .m59E20: return 90 * 1_000_000_000
        default: return nil
        }
    }

    /// Long drift runs are a duration choice, not another profile name.
    public static let driftRunningNanoseconds: Int64 = 1200 * 1_000_000_000
}

/// A plain, platform-neutral snapshot of the current display configuration.
/// T2's `DisplayInspector` fills it; T1 tests construct it directly.
public struct DisplaySnapshot: Equatable {
    public var displayModeID: String?
    public var drawableSize: PixelSize
    public var displayRotationDeg: Int?
    public var reportedRefreshHz: Double?
    public var colorSpaceName: String
    public var pixelFormatName: String
    public var colorMode: String?
    public var dimmingMode: String?
    public var hdrEnabled: Bool?
    public var trueToneEnabled: Bool?
    public var nightShiftEnabled: Bool?
    public var brightnessSetting: Double?
    public var brightnessSource: BrightnessSource
    public var autoBrightnessEnabled: Bool?
    public var platformConfiguration: [String: String]

    public init(
        displayModeID: String?,
        drawableSize: PixelSize,
        displayRotationDeg: Int?,
        reportedRefreshHz: Double?,
        colorSpaceName: String,
        pixelFormatName: String,
        colorMode: String? = nil,
        dimmingMode: String? = nil,
        hdrEnabled: Bool? = nil,
        trueToneEnabled: Bool? = nil,
        nightShiftEnabled: Bool? = nil,
        brightnessSetting: Double? = nil,
        brightnessSource: BrightnessSource = .unknown,
        autoBrightnessEnabled: Bool? = nil,
        platformConfiguration: [String: String] = [:]
    ) {
        self.displayModeID = displayModeID
        self.drawableSize = drawableSize
        self.displayRotationDeg = displayRotationDeg
        self.reportedRefreshHz = reportedRefreshHz
        self.colorSpaceName = colorSpaceName
        self.pixelFormatName = pixelFormatName
        self.colorMode = colorMode
        self.dimmingMode = dimmingMode
        self.hdrEnabled = hdrEnabled
        self.trueToneEnabled = trueToneEnabled
        self.nightShiftEnabled = nightShiftEnabled
        self.brightnessSetting = brightnessSource == .unknown ? nil : brightnessSetting
        self.brightnessSource = brightnessSource
        self.autoBrightnessEnabled = autoBrightnessEnabled
        self.platformConfiguration = platformConfiguration
    }
}

/// Platform-native frame identities. On macOS `surfaceInstanceID` identifies the
/// CAMetalLayer instance and `drawableID` the pooled drawable; neither is a
/// correlation key.
public struct PlatformIDs: Equatable {
    public var surfaceInstanceID: String?
    public var eglFrameID: String?
    public var vsyncID: String?
    public var drawableID: String?

    public init(
        surfaceInstanceID: String? = nil,
        eglFrameID: String? = nil,
        vsyncID: String? = nil,
        drawableID: String? = nil
    ) {
        self.surfaceInstanceID = surfaceInstanceID
        self.eglFrameID = eglFrameID
        self.vsyncID = vsyncID
        self.drawableID = drawableID
    }

    public static let none = PlatformIDs()

    public func json() -> JSONValue {
        .object([
            "surface_instance_id": surfaceInstanceID.map(JSONValue.string) ?? .null,
            "egl_frame_id": eglFrameID.map(JSONValue.string) ?? .null,
            "vsync_id": vsyncID.map(JSONValue.string) ?? .null,
            "drawable_id": drawableID.map(JSONValue.string) ?? .null
        ])
    }
}

/// Immutable per-segment configuration snapshot (contract §2.2).
public struct SegmentConfig: Equatable {
    public var segmentID: SegmentID
    public var layoutID: String
    public var displayModeID: String?
    public var experimentProfile: ExperimentProfile
    public var drawableWidthPx: Int
    public var drawableHeightPx: Int
    public var displayRotationDeg: Int?
    public var requestedRefresh: RefreshRate?
    public var nominalRefresh: RefreshRate?
    public var reportedRefreshHz: Double?
    public var brightnessSetting: Double?
    public var brightnessSource: BrightnessSource
    public var autoBrightnessEnabled: Bool?
    public var colorSpace: String
    public var pixelFormat: String
    public var colorMode: String?
    public var dimmingMode: String?
    public var hdrEnabled: Bool?
    public var trueToneEnabled: Bool?
    public var nightShiftEnabled: Bool?
    public var displayProfileID: String?
    public var operatorNote: String
    public var platformConfiguration: [String: String]

    public init(
        segmentID: SegmentID,
        layoutID: String,
        experimentProfile: ExperimentProfile,
        snapshot: DisplaySnapshot,
        nominalRefresh: RefreshRate? = nil,
        displayProfileID: String? = nil,
        operatorNote: String = ""
    ) {
        self.segmentID = segmentID
        self.layoutID = layoutID
        self.displayModeID = snapshot.displayModeID
        self.experimentProfile = experimentProfile
        self.drawableWidthPx = snapshot.drawableSize.width
        self.drawableHeightPx = snapshot.drawableSize.height
        self.displayRotationDeg = snapshot.displayRotationDeg
        self.requestedRefresh = experimentProfile.requestedRefresh
        self.nominalRefresh = nominalRefresh
        self.reportedRefreshHz = snapshot.reportedRefreshHz
        self.brightnessSetting = snapshot.brightnessSource == .unknown ? nil : snapshot.brightnessSetting
        self.brightnessSource = snapshot.brightnessSource
        self.autoBrightnessEnabled = snapshot.autoBrightnessEnabled
        self.colorSpace = snapshot.colorSpaceName
        self.pixelFormat = snapshot.pixelFormatName
        self.colorMode = snapshot.colorMode
        self.dimmingMode = snapshot.dimmingMode
        self.hdrEnabled = snapshot.hdrEnabled
        self.trueToneEnabled = snapshot.trueToneEnabled
        self.nightShiftEnabled = snapshot.nightShiftEnabled
        self.displayProfileID = displayProfileID
        self.operatorNote = operatorNote
        self.platformConfiguration = snapshot.platformConfiguration
    }

    public func json() -> JSONValue {
        var members: JSONObject = [
            "segment_id": .string(segmentID.description),
            "layout_id": .string(layoutID),
            "display_mode_id": displayModeID.map(JSONValue.string) ?? .null,
            "experiment_profile": .string(experimentProfile.rawValue),
            "drawable_width_px": .int(Int64(drawableWidthPx)),
            "drawable_height_px": .int(Int64(drawableHeightPx)),
            "display_rotation_deg": displayRotationDeg.map { .int(Int64($0)) } ?? .null,
            "requested_refresh_num": requestedRefresh.map { .int(Int64($0.numerator)) } ?? .null,
            "requested_refresh_den": requestedRefresh.map { .int(Int64($0.denominator)) } ?? .null,
            "nominal_refresh_num": nominalRefresh.map { .int(Int64($0.numerator)) } ?? .null,
            "nominal_refresh_den": nominalRefresh.map { .int(Int64($0.denominator)) } ?? .null,
            "reported_refresh_hz": reportedRefreshHz.map(JSONValue.double) ?? .null,
            "brightness_setting": brightnessSetting.map(JSONValue.double) ?? .null,
            "brightness_source": .string(brightnessSource.rawValue),
            "auto_brightness_enabled": autoBrightnessEnabled.map(JSONValue.bool) ?? .null,
            "color_space": .string(colorSpace),
            "pixel_format": .string(pixelFormat),
            "color_mode": colorMode.map(JSONValue.string) ?? .null,
            "dimming_mode": dimmingMode.map(JSONValue.string) ?? .null,
            "hdr_enabled": hdrEnabled.map(JSONValue.bool) ?? .null,
            "true_tone_enabled": trueToneEnabled.map(JSONValue.bool) ?? .null,
            "night_shift_enabled": nightShiftEnabled.map(JSONValue.bool) ?? .null,
            "display_profile_id": displayProfileID.map(JSONValue.string) ?? .null,
            "operator_note": .string(operatorNote)
        ]
        if !platformConfiguration.isEmpty {
            members["platform_configuration"] = .object(
                platformConfiguration.mapValues { JSONValue.string($0) }
            )
        }
        return .object(members)
    }
}
