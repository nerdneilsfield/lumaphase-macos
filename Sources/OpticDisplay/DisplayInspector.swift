import AppKit
import CoreGraphics
import OpticCore

/// Public-API description of the display a segment is running on.
public struct DisplayInfo {
    public let screen: NSScreen
    public let displayID: CGDirectDisplayID
    public let modeID: String?
    public let modePixelSize: PixelSize
    public let refreshHz: Double?
    public let maximumFramesPerSecond: Int
    /// Raw `CGDisplayRotation` value. Its direction is physical clockwise; the
    /// contract's `display_rotation_deg` is a draw-compensation label, so the
    /// standard field is left null until the mapping is proven.
    public let rotationRawDegrees: Double
    public let colorSpace: CGColorSpace?
    public let colorSpaceName: String
    public let platformConfiguration: [String: String]

    public init(
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        modeID: String?,
        modePixelSize: PixelSize,
        refreshHz: Double?,
        maximumFramesPerSecond: Int,
        rotationRawDegrees: Double,
        colorSpace: CGColorSpace?,
        colorSpaceName: String,
        platformConfiguration: [String: String]
    ) {
        self.screen = screen
        self.displayID = displayID
        self.modeID = modeID
        self.modePixelSize = modePixelSize
        self.refreshHz = refreshHz
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.rotationRawDegrees = rotationRawDegrees
        self.colorSpace = colorSpace
        self.colorSpaceName = colorSpaceName
        self.platformConfiguration = platformConfiguration
    }

    /// The built-in panel, else the main screen. The design targets the internal
    /// 16-inch display; an external screen is allowed but visible in the log.
    public static func preferredScreen() -> NSScreen? {
        if let builtIn = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }) {
            return builtIn
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

public enum DisplayInspector {
    /// Fixed named SDR target: bgra8Unorm (no `_srgb` format) with an explicit
    /// sRGB colour space, so the exported code values are the 8-bit codes the
    /// shader writes.
    public static let renderColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public static var renderColorSpaceName: String {
        (renderColorSpace.name as String?) ?? "CGColorSpace.sRGB"
    }

    public static func info(for screen: NSScreen) -> DisplayInfo {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = CGDirectDisplayID(number?.uint32Value ?? CGMainDisplayID())
        let mode = CGDisplayCopyDisplayMode(displayID)
        let modeID: String?
        let pixelSize: PixelSize
        if let mode {
            modeID = String(mode.ioDisplayModeID)
            pixelSize = PixelSize(width: mode.pixelWidth, height: mode.pixelHeight)
        } else {
            modeID = nil
            pixelSize = PixelSize(width: 0, height: 0)
        }
        let refresh = mode.map(\.refreshRate) ?? 0
        let colorSpace: CGColorSpace? = CGDisplayCopyColorSpace(displayID)
        let colorSpaceName = (colorSpace?.name as String?) ?? "unavailable"
        // The display profile is recorded for provenance only; it is not the
        // render target's colour space and is never used for calibration
        // matching.
        let iccData = colorSpace?.copyICCData() as Data?
        let iccBase64 = iccData?.base64EncodedString()
        let rotation = CGDisplayRotation(displayID)

        var platform: [String: String] = [
            "display_id": String(displayID),
            "cg_display_rotation_deg_raw": String(format: "%.3f", rotation),
            "ns_screen_maximum_frames_per_second": String(screen.maximumFramesPerSecond),
            "color_space_source": "CGDisplayCopyColorSpace",
            "brightness_api": "not-public-on-macos"
        ]
        if let mode {
            platform["cg_display_mode_pixel_width"] = String(mode.pixelWidth)
            platform["cg_display_mode_pixel_height"] = String(mode.pixelHeight)
            platform["cg_display_mode_refresh_hz_raw"] = String(format: "%.6f", refresh)
            platform["cg_display_mode_usable_for_desktop_gui"] = mode.isUsableForDesktopGUI() ? "true" : "false"
        }
        platform["is_builtin_display"] = CGDisplayIsBuiltin(displayID) != 0 ? "true" : "false"
        platform["display_color_space_name"] = colorSpaceName
        platform["render_color_space_name"] = renderColorSpaceName
        platform["render_pixel_format"] = "BGRA8Unorm"
        platform["render_color_space_choice"] = "explicit-sRGB"
        if let iccBase64 {
            platform["display_color_space_icc_base64"] = iccBase64
        }

        return DisplayInfo(
            screen: screen,
            displayID: displayID,
            modeID: modeID,
            modePixelSize: pixelSize,
            refreshHz: refresh > 0 ? refresh : nil,
            maximumFramesPerSecond: screen.maximumFramesPerSecond,
            rotationRawDegrees: rotation,
            colorSpace: colorSpace,
            colorSpaceName: colorSpaceName,
            platformConfiguration: platform
        )
    }

    /// Builds the per-segment snapshot. Unknown settings stay null/UNKNOWN; no
    /// private API is used to fill brightness, True Tone or Night Shift.
    public static func snapshot(
        drawableSize: PixelSize,
        info: DisplayInfo,
        brightness: Double?,
        colorSpaceName: String,
        operatorNote: String
    ) -> DisplaySnapshot {
        var platform = info.platformConfiguration
        platform["drawable_width_px"] = String(drawableSize.width)
        platform["drawable_height_px"] = String(drawableSize.height)
        platform["pattern_drawable_vs_panel"] = "not-verified"
        // Only a zero rotation is proven to have the same meaning as the
        // contract's draw-compensation label; other values stay null.
        let rotation: Int? = info.rotationRawDegrees == 0 ? 0 : nil
        return DisplaySnapshot(
            displayModeID: info.modeID,
            drawableSize: drawableSize,
            displayRotationDeg: rotation,
            reportedRefreshHz: info.refreshHz,
            colorSpaceName: colorSpaceName,
            pixelFormatName: "BGRA8Unorm",
            brightnessSetting: brightness,
            brightnessSource: brightness == nil ? .unknown : .operatorReported,
            platformConfiguration: platform
        )
    }
}
