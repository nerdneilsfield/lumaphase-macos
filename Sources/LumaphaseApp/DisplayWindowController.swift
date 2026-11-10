import AppKit
import Metal
import OpticCore
import OpticDisplay

/// Owns the borderless/fullscreen Metal window for one session or preview.
@MainActor
final class DisplayWindowController {
    let window: NSWindow
    let hostView: MetalHostView
    let surfaceInstanceID = UUID().uuidString
    private let wantsFullscreen: Bool

    init(screen: NSScreen, windowed: Bool, verification: Bool, device: MTLDevice) {
        self.wantsFullscreen = !windowed && !verification
        let rect = (windowed || verification)
            ? (verification ? screen.frame : NSRect(x: 0, y: 0, width: 1280, height: 720))
            : screen.frame
        let style: NSWindow.StyleMask = verification ? [.borderless] : [.titled, .closable, .resizable]
        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = "Lumaphase"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = windowed || verification ? [.canJoinAllSpaces] : [.fullScreenPrimary]
        // Verification runs must stay visible above the terminal while the app
        // is not the active application; native fullscreen does not need this.
        // The smoke run must be composited even when the terminal is frontmost;
        // it is short, windowed content rather than a fullscreen Space.
        window.level = verification ? .screenSaver : (windowed ? .floating : .normal)
        window.backgroundColor = .black
        hostView = MetalHostView(device: device, colorSpace: DisplayInspector.renderColorSpace)
        window.contentView = hostView
        if windowed {
            window.center()
        } else {
            window.setFrame(screen.frame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        if wantsFullscreen {
            window.toggleFullScreen(nil)
        }
    }

    var isFullscreen: Bool { window.styleMask.contains(.fullScreen) }

    var currentScreen: NSScreen? { window.screen }

    func resizeForSmoke() {
        guard !isFullscreen else { return }
        var frame = window.frame
        frame.size.width = max(640, frame.width - 160)
        frame.size.height = max(400, frame.height - 80)
        window.setFrame(frame, display: true)
    }

    func close() {
        if isFullscreen { window.toggleFullScreen(nil) }
        window.orderOut(nil)
        window.close()
    }
}
