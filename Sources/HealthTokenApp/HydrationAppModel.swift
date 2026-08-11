import AppKit
import Foundation
import HealthTokenCore

@MainActor
final class HydrationAppModel: ObservableObject {
    @Published private(set) var snapshot: HydrationSnapshot
    @Published private(set) var persistenceError: String?
    @Published private(set) var integrationHealth: CodexIntegrationHealth
    @Published private(set) var integrationError: String?
    @Published private(set) var isCodexObservationEnabled: Bool
    @Published private(set) var hasObservedCodexEvent = false

    private let engine: HydrationEngine
    private let hookInstaller: CodexHookInstaller
    private let eventInbox: CodexEventInbox
    private let rolloutMonitor: CodexRolloutMonitor
    private let hookCommand: String
    private var configurationError: String?
    private var inboxError: String?
    private var observationActivity = CodexObservationActivity()

    private let connectionFreshnessInterval: TimeInterval = 2 * 60

    init() {
        let clock = SystemHydrationClock()
        let fileURL = Self.applicationSupportURL
        let fileManager = FileManager.default
        let codexHomeURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        hookCommand = Self.shellQuoted(Self.hookHelperURL.path)
        hookInstaller = CodexHookInstaller(
            hooksURL: codexHomeURL.appendingPathComponent("hooks.json"),
            sessionsURL: codexHomeURL.appendingPathComponent(
                "sessions",
                isDirectory: true
            )
        )
        eventInbox = CodexEventInbox(
            directoryURL: CodexEventInbox.defaultDirectoryURL()
        )
        rolloutMonitor = CodexRolloutMonitor(
            sessionsURL: codexHomeURL.appendingPathComponent(
                "sessions",
                isDirectory: true
            )
        )
        integrationHealth = hookInstaller.health(command: hookCommand)
        isCodexObservationEnabled = hookInstaller.isInstalled(
            command: hookCommand
        )

        do {
            engine = try HydrationEngine(
                clock: clock,
                store: FileHydrationStore(fileURL: fileURL)
            )
            snapshot = engine.snapshot
        } catch {
            let fallbackStore = InMemoryHydrationStore()
            engine = try! HydrationEngine(clock: clock, store: fallbackStore)
            snapshot = engine.snapshot
            persistenceError = "本地记录暂时无法读取；本次运行不会写入磁盘。"
        }
    }

    init(
        engine: HydrationEngine,
        integrationHealth: CodexIntegrationHealth
    ) {
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-token-window-integration", isDirectory: true)
        let sessionsURL = isolatedRoot.appendingPathComponent("sessions", isDirectory: true)
        self.engine = engine
        hookCommand = ""
        hookInstaller = CodexHookInstaller(
            hooksURL: isolatedRoot.appendingPathComponent("hooks.json"),
            sessionsURL: sessionsURL
        )
        eventInbox = CodexEventInbox(
            directoryURL: isolatedRoot.appendingPathComponent("events", isDirectory: true)
        )
        rolloutMonitor = CodexRolloutMonitor(sessionsURL: sessionsURL)
        self.integrationHealth = integrationHealth
        isCodexObservationEnabled = false
        snapshot = engine.snapshot
    }

    func refresh() {
        let observedAt = Date()
        do {
            isCodexObservationEnabled = hookInstaller.isInstalled(
                command: hookCommand
            )
            let drainedHookEvents = try eventInbox.drain()
            let hookEvents = isCodexObservationEnabled ? drainedHookEvents : []
            let rolloutEvents = try isCodexObservationEnabled
                ? rolloutMonitor.poll(observedAt: observedAt)
                : []
            observationActivity.record(
                hookEventCount: hookEvents.count,
                rolloutEventCount: rolloutEvents.count,
                observedAt: observedAt
            )
            if !hookEvents.isEmpty || !rolloutEvents.isEmpty {
                hasObservedCodexEvent = true
            }
            let events = (hookEvents + rolloutEvents)
                .enumerated()
                .sorted { left, right in
                    if left.element.timestamp == right.element.timestamp {
                        return left.offset < right.offset
                    }
                    return left.element.timestamp < right.element.timestamp
                }
                .map { $0.element }
            for event in events {
                snapshot = try engine.send(.agentEvent(event))
            }
            if !isCodexObservationEnabled {
                snapshot = try engine.send(.agentObservationUnavailable)
            }
            inboxError = nil
        } catch {
            inboxError = "Codex 事件暂时无法读取；饮水提醒保持低干扰兜底。"
            snapshot = (try? engine.send(.agentObservationUnavailable)) ?? snapshot
        }
        updateIntegrationError()
        send(.timeAdvanced)
        integrationHealth = currentIntegrationHealth(at: observedAt)
    }

    func refreshTemporalState() {
        send(.timeAdvanced)
    }

    func openReminder() {
        send(.openReminder)
    }

    func closeReminder() {
        send(.closeReminder)
    }

    func confirmSip() {
        send(.confirmSip)
    }

    func recordProactiveSip() {
        send(.recordProactiveSip)
    }

    func completeBottle() {
        send(.completeBottle)
    }

    func dismissConfirmation() {
        send(.dismissConfirmation)
    }

    func enableCodexObservation() {
        guard FileManager.default.isExecutableFile(atPath: Self.hookHelperURL.path) else {
            configurationError = "未找到 Health Token 的 Codex 观察组件。"
            updateIntegrationError()
            integrationHealth = .unavailable
            return
        }

        configureCodexObservation(
            { try hookInstaller.enable(command: hookCommand) },
            failureMessage: "无法更新 ~/.codex/hooks.json；未更改其他 Codex 设置。"
        )
    }

    func disableCodexObservation() {
        configureCodexObservation(
            { try hookInstaller.disable(command: hookCommand) },
            failureMessage: "无法从 ~/.codex/hooks.json 移除 Health Token 观察项。"
        )
    }

    private func configureCodexObservation(
        _ operation: () throws -> Void,
        failureMessage: String
    ) {
        do {
            try operation()
            observationActivity.reset()
            hasObservedCodexEvent = false
            rolloutMonitor.reset()
            configurationError = nil
        } catch {
            configurationError = failureMessage
        }
        isCodexObservationEnabled = hookInstaller.isInstalled(
            command: hookCommand
        )
        if !isCodexObservationEnabled {
            snapshot = (try? engine.send(.agentObservationUnavailable)) ?? snapshot
        }
        integrationHealth = currentIntegrationHealth(at: Date())
        updateIntegrationError()
    }

    func snooze() {
        send(.snooze)
    }

    func setPaused(_ isPaused: Bool) {
        send(.setPaused(isPaused))
    }

    func setSipEstimate(_ estimate: SipEstimate) {
        send(.setSipEstimate(estimate))
    }

    func setBottleCapacityMilliliters(_ milliliters: Int) {
        send(.setBottleCapacityMilliliters(milliliters))
    }

    func setReminderInterval(_ interval: TimeInterval) {
        send(.setReminderInterval(interval))
    }

    func setNoAgentFallbackEnabled(_ isEnabled: Bool) {
        send(.setNoAgentFallbackEnabled(isEnabled))
    }

    func undoDrink(_ recordID: UUID) {
        send(.undoDrink(recordID))
    }

    func send(_ action: HydrationEngine.Action) {
        do {
            snapshot = try engine.send(action)
            persistenceError = nil
        } catch {
            persistenceError = "无法保存本地记录，请稍后重试。"
        }
    }

    private func updateIntegrationError() {
        integrationError = configurationError ?? inboxError
    }

    private func currentIntegrationHealth(at evaluatedAt: Date) -> CodexIntegrationHealth {
        return hookInstaller.health(
            command: hookCommand,
            recentlyObservedEvent: observationActivity.wasObservedRecently(
                at: evaluatedAt,
                freshnessInterval: connectionFreshnessInterval
            ),
            observationFailed: inboxError != nil
        )
    }

    private static var applicationSupportURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return baseURL
            .appendingPathComponent("HealthToken", isDirectory: true)
            .appendingPathComponent("hydration.json")
    }

    private static var hookHelperURL: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent("HealthTokenHook")
        }
        let executableDirectory = Bundle.main.executableURL?
            .deletingLastPathComponent() ?? Bundle.main.bundleURL
        return executableDirectory
            .appendingPathComponent("HealthTokenHook")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

struct CodexObservationActivity {
    private var lastObservedAt: Date?

    mutating func record(
        hookEventCount: Int,
        rolloutEventCount: Int,
        observedAt: Date
    ) {
        guard hookEventCount > 0 || rolloutEventCount > 0 else { return }
        lastObservedAt = observedAt
    }

    mutating func reset() {
        lastObservedAt = nil
    }

    func wasObservedRecently(
        at evaluatedAt: Date,
        freshnessInterval: TimeInterval
    ) -> Bool {
        guard let lastObservedAt else { return false }
        let elapsed = evaluatedAt.timeIntervalSince(lastObservedAt)
        return elapsed >= 0 && elapsed <= freshnessInterval
    }
}
