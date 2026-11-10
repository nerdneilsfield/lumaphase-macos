import AppKit
import SwiftUI
import OpticDisplay

/// A bare SwiftPM executable has no storyboard; the app owns its windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: AppOptions
    private var controller: SessionController?
    private var settingsWindow: NSWindow?

    init(options: AppOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let controller = SessionController(options: options)
        self.controller = controller

        let hosting = NSHostingView(rootView: SettingsView(controller: controller))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lumaphase"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        if options.autoStart {
            controller.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Normal Cmd-Q / menu quit finishes the session through the normal stop,
    /// seal and export path before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        controller.requestQuit { proceed in
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: proceed)
            }
        }
        return .terminateLater
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lumaphase"
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
