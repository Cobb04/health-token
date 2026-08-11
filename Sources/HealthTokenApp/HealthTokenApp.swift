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
        .menuBarExtraStyle(.window)

        Window("Health Token 设置", id: HealthTokenSettingsWindow.id) {
            HealthTokenSettingsView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class HealthTokenAppDelegate: NSObject, NSApplicationDelegate {
    let model = HydrationAppModel()

    private var panelController: AmbientReminderPanelController?
    private var temporalRefreshCoordinator: TemporalRefreshCoordinator?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        panelController = AmbientReminderPanelController(model: model)
        temporalRefreshCoordinator = TemporalRefreshCoordinator { [weak self] in
            self?.model.refreshTemporalState()
        }
        temporalRefreshCoordinator?.start()
        model.refresh()
        let timer = Timer(
            timeInterval: CodexObservationPolicy.presentationPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        temporalRefreshCoordinator?.stop()
        panelController?.stop()
    }
}
