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
    public var diagnostic: DiagnosticSessionMode = .none
    public var largeTags = false
    public var smoke = false
    public var smokeResize = false
    public var smokePause = false
    public var windowed = false
    public var autoStart = false
    public var outputDirectory: URL?
    public var profile: ExperimentProfile = .m59S1
    public var geometryProfile: GeometryProfile = .f68G6x12
    public var layoutProfile: LayoutProfile { geometryProfile.layoutProfile }
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
            case "--diagnostic":
                let value = try next(argument)
                guard let mode = DiagnosticSessionMode(rawValue: value.uppercased()), mode != .none else {
                    throw AppOptionError.invalidValue(option: argument, value: value)
                }
                options.diagnostic = mode
            case "--large-tags": options.largeTags = true
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
                guard let layout = GeometryProfile(rawValue: value.uppercased().replacingOccurrences(of: "X", with: "x")),
                      GeometryProfile.macOSCases.contains(layout) else {
                    throw AppOptionError.invalidValue(option: argument, value: value)
                }
                options.geometryProfile = layout
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
        if options.largeTags && options.diagnostic != .none {
            throw AppOptionError.invalidValue(option: "--large-tags", value: "with --diagnostic")
        }
        return options
    }

    public static let usage = """
    Lumaphase — OPTC-1 macOS display

    Usage: Lumaphase [options]
      --profile <M59-S1|M120-S1|M59-E20|M-CAL>   experiment profile (default M59-S1)
      --layout <F68-G6x12|C52-G5x12|F68|C52>       geometry (default F68-G6x12)
      --large-tags                                operator-confirmed large Tag stage before RUN
      --diagnostic <A|B>                          static 1+3s stages / 60s VSync BW (separate session)
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

public struct DiagnosticStep {
    public let pattern: DiagnosticPattern
    public let profile: ExperimentProfile
    public let durationNanoseconds: Int64
}

public enum DiagnosticSessionMode: String {
    case none = "NONE"
    case staticA = "A"
    case dynamicBW = "B"

    public var steps: [DiagnosticStep] {
        switch self {
        case .none: return []
        case .dynamicBW:
            return [DiagnosticStep(pattern: .vsyncBlackWhite,
                profile: ExperimentProfile(rawValue: "CR002-B-BW"), durationNanoseconds: 60_000_000_000)]
        case .staticA:
            return [(DiagnosticPattern.white, "WHITE"), (.black, "BLACK"), (.checkerboard, "GRID")].flatMap { pattern, name in
                [DiagnosticStep(pattern: pattern, profile: ExperimentProfile(rawValue: "CR002-A-\(name)-SETTLE"), durationNanoseconds: 1_000_000_000),
                 DiagnosticStep(pattern: pattern, profile: ExperimentProfile(rawValue: "CR002-A-\(name)"), durationNanoseconds: 3_000_000_000)]
            }
        }
    }
}
