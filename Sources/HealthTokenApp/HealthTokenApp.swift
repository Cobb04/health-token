import AppKit
import HealthTokenCore
import SwiftUI

@main
struct HealthTokenApp: App {
    @NSApplicationDelegateAdaptor(HealthTokenAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            HealthTokenSettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class HealthTokenAppDelegate: NSObject, NSApplicationDelegate {
    let model = HydrationAppModel()

    private lazy var settingsWindowController = HealthTokenSettingsWindowController(model: model)
    private var healthConsolePanelController: HealthConsolePanelController?
    private var panelController: AmbientReminderPanelController?
    private var temporalRefreshCoordinator: TemporalRefreshCoordinator?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let consoleController = HealthConsolePanelController(
            model: model,
            presentSettings: presentSettings
        )
        healthConsolePanelController = consoleController
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

    private func presentSettings() {
        settingsWindowController.present()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        temporalRefreshCoordinator?.stop()
        panelController?.stop()
        healthConsolePanelController?.stop()
        settingsWindowController.close()
        healthConsolePanelController = nil
    }
}
