import AppKit
import SwiftUI

@MainActor
final class HealthTokenSettingsWindowController {
    private let windowController: NSWindowController
    private let activateApplication: () -> Void

    init(
        model: HydrationAppModel,
        activateApplication: @escaping () -> Void
    ) {
        self.activateApplication = activateApplication

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Health Token 设置"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: HealthTokenSettingsView(model: model)
        )
        window.center()
        window.setFrameAutosaveName(HealthTokenSettingsWindow.id)
        windowController = NSWindowController(window: window)
    }

    convenience init(model: HydrationAppModel) {
        self.init(
            model: model,
            activateApplication: {
                if #available(macOS 14.0, *) {
                    NSApplication.shared.activate()
                } else {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
        )
    }

    var isVisible: Bool {
        windowController.window?.isVisible == true
    }

    func present() {
        activateApplication()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        windowController.close()
    }
}
