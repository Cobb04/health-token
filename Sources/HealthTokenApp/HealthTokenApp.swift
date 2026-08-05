import AppKit
import HealthTokenCore
import SwiftUI

@main
struct HealthTokenApp: App {
    @NSApplicationDelegateAdaptor(HealthTokenAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Health Token", systemImage: "drop.fill") {
            MenuBarContentView(model: appDelegate.model)
        }
    }
}

@MainActor
final class HealthTokenAppDelegate: NSObject, NSApplicationDelegate {
    let model = HydrationAppModel()

    private var panelController: AmbientReminderPanelController?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        panelController = AmbientReminderPanelController(model: model)
        model.refresh()
        timer = Timer.scheduledTimer(
            withTimeInterval: CodexObservationPolicy.presentationPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        panelController?.stop()
    }
}
