import AppKit
import Combine
import SwiftUI
import OpticDisplay
import OpticCore

/// A bare SwiftPM executable has no storyboard; the app owns its windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let options: AppOptions
    private var controller: SessionController?
    private var settingsWindow: NSWindow?
    private var busyObservation: AnyCancellable?

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
        // Keep our controls out of the measured drawable in every window mode.
        // Session commands remain reachable without raising another window.
        busyObservation = controller.$isBusy.removeDuplicates().sink { [weak window] busy in
            if busy {
                window?.orderOut(nil)
            } else {
                window?.makeKeyAndOrderFront(nil)
            }
        }

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

    @objc private func continueRun(_ sender: Any?) {
        controller?.continueAfterLargeTags()
    }

    @objc private func pauseOrResume(_ sender: Any?) {
        controller?.pauseOrResume()
    }

    @objc private func stopSession(_ sender: Any?) {
        controller?.stop()
    }

    @objc private func changeGeometry(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let geometry = GeometryProfile(rawValue: name) else { return }
        controller?.changeGeometry(geometry)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(continueRun(_:)): return controller?.awaitingGeometryConfirmation == true
        case #selector(pauseOrResume(_:)):
            return controller?.canPause == true || controller?.phase == .paused
        case #selector(stopSession(_:)): return controller?.isBusy == true
        case #selector(changeGeometry(_:)):
            menuItem.state = menuItem.representedObject as? String == controller?.geometryProfile.rawValue ? .on : .off
            return controller?.canChangeGeometry == true
        default: return true
        }
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

        let sessionMenuItem = NSMenuItem()
        mainMenu.addItem(sessionMenuItem)
        let sessionMenu = NSMenu(title: "会话")
        let commands: [(String, Selector, String)] = [
            ("外部定位已核对，继续 RUN", #selector(continueRun(_:)), "\r"),
            ("暂停 / 恢复", #selector(pauseOrResume(_:)), "p"),
            ("停止并导出", #selector(stopSession(_:)), ".")
        ]
        for (title, action, key) in commands {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.keyEquivalentModifierMask = [.command]
            sessionMenu.addItem(item)
        }
        sessionMenu.addItem(.separator())
        for geometry in GeometryProfile.macOSCases {
            let item = NSMenuItem(title: "切换布局：\(geometry.rawValue)", action: #selector(changeGeometry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = geometry.rawValue
            sessionMenu.addItem(item)
        }
        sessionMenuItem.submenu = sessionMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
