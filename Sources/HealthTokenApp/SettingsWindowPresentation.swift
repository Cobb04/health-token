enum HealthTokenSettingsWindow {
    static let id = "health-token-settings"
}

@MainActor
struct SettingsWindowPresentation {
    let activateApplication: () -> Void
    let openWindow: () -> Void

    func present() {
        activateApplication()
        openWindow()
    }
}
