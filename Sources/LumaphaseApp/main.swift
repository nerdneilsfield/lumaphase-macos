import AppKit
import OpticDisplay

let options: AppOptions
do {
    options = try AppOptions.parse(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(AppOptions.usage)\n".utf8))
    exit(2)
}
if options.showHelp {
    print(AppOptions.usage)
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate(options: options)
    application.delegate = appDelegate
    application.setActivationPolicy(.regular)
    application.run()
}
