import Foundation
import OpticCore

public enum AppOptionError: Error, CustomStringConvertible {
    case unknownOption(String)
    case missingValue(String)
    case invalidValue(option: String, value: String)

    public var description: String {
        switch self {
        case .unknownOption(let option): return "unknown option: \(option)"
        case .missingValue(let option): return "missing value for \(option)"
        case .invalidValue(let option, let value): return "invalid value for \(option): \(value)"
        }
    }
}

/// Command-line options. Kept in OpticDisplay so the display/app target can be
/// tested without launching the application.
public struct AppOptions {
    public var smoke = false
    public var smokeResize = false
    public var smokePause = false
    public var windowed = false
    public var autoStart = false
    public var outputDirectory: URL?
    public var profile: ExperimentProfile = .m59S1
    public var layoutProfile: LayoutProfile = .f68
    public var rotationDeg = 0
    public var runningSeconds: Double?
    public var showHelp = false

    public init() {}

    public var smokePhases: (warmup: Double, card: Double, running: Double, endCard: Double) {
        let running = smokePause ? 5.0 : (smokeResize ? 5.0 : 3.0)
        return (warmup: 1.0, card: 0.6, running: running, endCard: 0.6)
    }

    public static func parse(arguments: [String]) throws -> AppOptions {
        var options = AppOptions()
        var index = 1
        func next(_ name: String) throws -> String {
            guard index + 1 < arguments.count else { throw AppOptionError.missingValue(name) }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--smoke":
                options.smoke = true
                options.autoStart = true
            case "--smoke-resize":
                options.smokeResize = true
            case "--smoke-pause":
                options.smokePause = true
            case "--windowed":
                options.windowed = true
            case "--auto-start":
                options.autoStart = true
            case "--output":
                let value = try next(argument)
                options.outputDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            case "--profile":
                let value = try next(argument)
                guard ExperimentProfile.presets.contains(ExperimentProfile(rawValue: value)) || !value.isEmpty else {
                    throw AppOptionError.invalidValue(option: argument, value: value)
                }
                options.profile = ExperimentProfile(rawValue: value)
            case "--layout":
                let value = try next(argument)
                guard let layout = LayoutProfile(rawValue: value.uppercased()) else {
                    throw AppOptionError.invalidValue(option: argument, value: value)
                }
                options.layoutProfile = layout
            case "--rotation":
                let value = try next(argument)
                guard let degrees = Int(value), PatternRotation.isSupported(degrees) else {
                    throw AppOptionError.invalidValue(option: argument, value: value)
                }
                options.rotationDeg = degrees
            case "--duration":
                let value = try next(argument)
                guard let seconds = Double(value), seconds > 0, seconds.isFinite else {
                    throw AppOptionError.invalidValue(option: argument, value: value)
                }
                options.runningSeconds = seconds
            case "--help", "-h":
                options.showHelp = true
            default:
                if argument.hasPrefix("-") {
                    throw AppOptionError.unknownOption(argument)
                }
            }
            index += 1
        }
        return options
    }

    public static let usage = """
    Lumaphase — OPTC-1 macOS display

    Usage: Lumaphase [options]
      --profile <M59-S1|M120-S1|M59-E20|M-CAL>   experiment profile (default M59-S1)
      --layout <F68|C52>                          layout profile (default F68)
      --rotation <0|90|180|270>                   pattern rotation (default 0)
      --duration <seconds>                        RUNNING duration (default 90)
      --output <dir>                              session export root
      --windowed                                  normal window instead of fullscreen
      --auto-start                                start the session on launch
      --smoke                                     short windowed run, auto export and quit
      --smoke-resize                              with --smoke: resize during RUNNING (new segment)
      --smoke-pause                               with --smoke: pause/resume during RUNNING
      --help                                      this text
    """
}
