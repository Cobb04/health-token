import AppKit
import HealthTokenCore
import Testing
@testable import HealthTokenApp

@Test("notched displays center reminders below the physical notch")
func notchedDisplayPlacement() {
    let display = notchedDisplay

    let ambientFrame = ReminderPanelLayout.frame(
        for: CGSize(width: 48, height: 48),
        on: display
    )
    let strongFrame = ReminderPanelLayout.frame(
        for: CGSize(width: 330, height: 132),
        on: display
    )

    #expect(ambientFrame.midX == 756)
    #expect(strongFrame.midX == 756)
    #expect(ambientFrame.maxY == display.visibleFrame.maxY)
    #expect(strongFrame.maxY == display.visibleFrame.maxY)
}

@Test("fallback placement remains inside an asymmetric visible frame")
func fallbackPlacementIsClampedToVisibleFrame() {
    let display = ReminderDisplayGeometry(
        frame: CGRect(x: 1000, y: 0, width: 420, height: 900),
        visibleFrame: CGRect(x: 1050, y: 0, width: 300, height: 875),
        safeAreaInsets: .init(),
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil
    )

    let frame = ReminderPanelLayout.frame(
        for: CGSize(width: 330, height: 132),
        on: display
    )

    #expect(frame.minX == display.visibleFrame.minX)
    #expect(frame.maxX <= display.visibleFrame.maxX)
    #expect(frame.maxY == display.visibleFrame.maxY)
}

@MainActor
private func verifyRealPanelWindowBehavior() throws {
    _ = NSApplication.shared
    let clock = WindowTestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    let model = HydrationAppModel(
        engine: engine,
        integrationHealth: .unavailable
    )
    let displayState = ActiveDisplayState(geometry: notchedDisplay)
    let controller = AmbientReminderPanelController(
        model: model,
        activeDisplay: { displayState.geometry }
    )
    defer { controller.stop() }

    clock.now.addTimeInterval(30 * 60)
    model.send(.timeAdvanced)
    let panelIdentity = ObjectIdentifier(controller.panel)

    #expect(controller.panel.isVisible)
    #expect(!controller.panel.canBecomeKey)
    #expect(controller.panel.frame.midX == notchedDisplay.frame.midX)

    for _ in 0..<3 {
        model.send(.agentEvent(AgentEvent(
            kind: .toolUsed,
            sessionID: "window-root",
            timestamp: clock.now,
            role: .root,
            attention: .none,
            toolClassification: .ordinary
        )))
    }
    #expect(model.snapshot.reminderLevel == .strong)
    #expect(!controller.panel.canBecomeKey)
    model.send(.agentEvent(AgentEvent(
        kind: .attentionChanged,
        sessionID: "window-root",
        timestamp: clock.now,
        role: .root,
        attention: .required,
        toolClassification: .userInput
    )))
    #expect(model.snapshot.reminderLevel == .ambient)
    #expect(!controller.panel.canBecomeKey)

    displayState.geometry = externalDisplay
    controller.activeDisplayDidChange()
    #expect(ObjectIdentifier(controller.panel) == panelIdentity)
    #expect(controller.panel.frame.midX == externalDisplay.frame.midX)

    let corner = CGPoint(
        x: controller.panel.frame.minX + 1,
        y: controller.panel.frame.minY + 1
    )
    controller.updatePointerInterception(at: corner)
    #expect(controller.panel.ignoresMouseEvents)

    controller.updatePointerInterception(at: CGPoint(
        x: controller.panel.frame.midX,
        y: controller.panel.frame.midY
    ))
    #expect(!controller.panel.ignoresMouseEvents)
}

@MainActor
private func verifyRealPanelKeyboardOutput() throws {
    _ = NSApplication.shared
    let clock = WindowTestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    let model = HydrationAppModel(engine: engine, integrationHealth: .connected)
    let controller = AmbientReminderPanelController(
        model: model,
        activeDisplay: { notchedDisplay }
    )
    defer { controller.stop() }
    clock.now.addTimeInterval(30 * 60)
    model.send(.timeAdvanced)

    #expect(!controller.panel.canBecomeKey)
    controller.userDidIntentionallyInteract()
    model.openReminder()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    #expect(controller.panel.canBecomeKey)
    #expect(model.snapshot.detailsExpanded)
    sendKey("s", keyCode: 1, to: controller.panel)
    #expect(model.snapshot.status == .snoozed)
}

@MainActor
private func verifyStrongReminderKeyboardDrinkAndUndo() throws {
    _ = NSApplication.shared
    let clock = WindowTestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    let model = HydrationAppModel(engine: engine, integrationHealth: .connected)
    let controller = AmbientReminderPanelController(
        model: model,
        activeDisplay: { notchedDisplay }
    )
    defer { controller.stop() }
    clock.now.addTimeInterval(30 * 60)
    model.send(.timeAdvanced)
    for _ in 0..<3 {
        model.send(.agentEvent(AgentEvent(
            kind: .toolUsed,
            sessionID: "keyboard-root",
            timestamp: clock.now,
            role: .root,
            attention: .none,
            toolClassification: .ordinary
        )))
    }
    #expect(model.snapshot.reminderLevel == .strong)
    #expect(!controller.panel.canBecomeKey)

    controller.userDidIntentionallyInteract()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    #expect(controller.panel.canBecomeKey)
    sendKey("\r", keyCode: 36, to: controller.panel)
    #expect(model.snapshot.reminderLevel == .confirmation)
    #expect(model.snapshot.todayEstimatedMilliliters == 25)

    sendKey("z", keyCode: 6, to: controller.panel)
    #expect(model.snapshot.records.isEmpty)
    #expect(model.snapshot.reminderLevel == .strong)
}

@MainActor
@Suite(.serialized)
struct ReminderWindowAppKitTests {
    @Test("one real panel moves across displays without passive focus or transparent hits")
    func realPanelWindowBehavior() throws {
        try verifyRealPanelWindowBehavior()
    }

    @Test("intentional expansion makes the real panel key and enables snooze by keyboard")
    func realPanelKeyboardOutput() throws {
        try verifyRealPanelKeyboardOutput()
    }

    @Test("intentional C interaction supports drink and undo by keyboard")
    func strongReminderKeyboardDrinkAndUndo() throws {
        try verifyStrongReminderKeyboardDrinkAndUndo()
    }
}

@Test("Reduce Motion uses opacity while standard transitions may scale")
func reduceMotionTransition() {
    #expect(ReminderTransitionPolicy(reduceMotion: true).usesScale == false)
    #expect(ReminderTransitionPolicy(reduceMotion: false).usesScale == true)
    #expect(ReminderTransitionPolicy(reduceMotion: false).scale == 0.98)
    #expect(ReminderTransitionPolicy(reduceMotion: true).duration < 0.2)
}

@Test("increased contrast removes glow and makes edges opaque")
func increasedContrastAppearance() {
    let standard = ReminderAppearancePolicy(increasedContrast: false)
    let increased = ReminderAppearancePolicy(increasedContrast: true)

    #expect(standard.showsGlow)
    #expect(standard.cardBorderOpacity < 1)
    #expect(!increased.showsGlow)
    #expect(increased.dropBackgroundOpacity == 0.95)
    #expect(increased.cardBorderOpacity == 1)
}

@Test("compact reminder keeps hydration context on one quiet line")
func compactReminderPresentation() {
    let presentation = HydrationReminderPresentation(
        sipMilliliters: 35,
        todayEstimatedMilliliters: 175
    )

    #expect(presentation.title == "喝一口，继续专注")
    #expect(presentation.summary == "本次约 35 mL · 今日已记录 175 mL")
    #expect(presentation.primaryActionTitle == "＋ 一口")
    #expect(presentation.primaryAmount == "35 mL")
    #expect(presentation.snoozeActionTitle == "15 分钟")
}

@Test("a privacy-safe rollout event establishes Codex connection freshness")
func rolloutEventEstablishesConnectionFreshness() {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var activity = CodexObservationActivity()

    activity.record(
        hookEventCount: 0,
        rolloutEventCount: 1,
        observedAt: observedAt
    )

    #expect(
        activity.wasObservedRecently(
            at: observedAt.addingTimeInterval(119),
            freshnessInterval: 120
        )
    )
    #expect(
        !activity.wasObservedRecently(
            at: observedAt.addingTimeInterval(121),
            freshnessInterval: 120
        )
    )
}

@Test("non-color cues name all reminder and integration states")
func nonColorStateCues() {
    let states: [(HydrationStatus, ReminderLevel, CodexIntegrationHealth, String)] = [
        (.dueAmbient, .ambient, .connected, "低干扰提醒"),
        (.dueStrong, .strong, .connected, "Codex 合格信号，强提醒"),
        (.paused, .hidden, .connected, "已暂停"),
        (.snoozed, .ambient, .connected, "已稍后"),
        (.dueAmbient, .ambient, .unavailable, "Codex 观察不可用")
    ]
    for (status, level, health, expected) in states {
        let cue = ReminderAccessibilityCue(
            status: status,
            reminderLevel: level,
            integrationHealth: health
        )
        #expect(cue.nonColorCue == expected)
    }
}

@Test("menu status presents the existing cycle as a blue numeric countdown")
func hydrationMenuCountdownPresentation() {
    let accumulating = HydrationMenuStatusPresentation(
        status: .accumulating,
        remainingTimeUntilReminder: 12 * 60 + 34
    )
    let due = HydrationMenuStatusPresentation(
        status: .dueAmbient,
        remainingTimeUntilReminder: 0
    )
    let strong = HydrationMenuStatusPresentation(
        status: .dueStrong,
        remainingTimeUntilReminder: 0
    )
    let snoozed = HydrationMenuStatusPresentation(
        status: .snoozed,
        remainingTimeUntilReminder: 0
    )
    let paused = HydrationMenuStatusPresentation(
        status: .paused,
        remainingTimeUntilReminder: 0
    )

    #expect(accumulating.text == "12:34")
    #expect(accumulating.usesCountdownAccent)
    #expect(due.text == "该喝水了")
    #expect(!due.usesCountdownAccent)
    #expect(strong.text == "Codex 忙碌中")
    #expect(snoozed.text == "已稍后")
    #expect(paused.text == "已暂停")
}

@Test("Codex observation setup states use plain actionable language")
func codexIntegrationUsesActionableLanguage() {
    let waiting = CodexIntegrationPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasObservedEvent: false,
        noAgentFallbackEnabled: true
    )
    let fallback = CodexIntegrationPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasObservedEvent: true,
        noAgentFallbackEnabled: true
    )
    let disabled = CodexIntegrationPresentation(
        health: .fallbackOnly,
        isObservationEnabled: false,
        hasObservedEvent: false,
        noAgentFallbackEnabled: true
    )
    let connected = CodexIntegrationPresentation(
        health: .connected,
        isObservationEnabled: true,
        hasObservedEvent: true,
        noAgentFallbackEnabled: true
    )
    let unavailable = CodexIntegrationPresentation(
        health: .unavailable,
        isObservationEnabled: false,
        hasObservedEvent: false,
        noAgentFallbackEnabled: true
    )

    #expect(waiting.status == "Codex 观察：等待首次事件")
    #expect(waiting.detail.contains("配置已完成"))
    #expect(waiting.detail.contains("开始一个 Codex 任务"))
    #expect(waiting.detail.contains("普通定时饮水提醒仍会工作"))
    #expect(!waiting.detail.contains("/hooks"))
    #expect(!waiting.detail.contains("允许 Health Token"))
    #expect(!waiting.detail.contains("生命周期"))
    #expect(!waiting.detail.contains("保持 B"))
    #expect(disabled.status == "Codex 观察：未启用")
    #expect(disabled.detail.contains("自动配置本地连接"))
    #expect(!disabled.detail.contains("/hooks"))
    #expect(fallback.status == "Codex 观察：仅低干扰兜底")
    #expect(connected.status == "Codex 观察：已连接")
    #expect(unavailable.status == "Codex 观察：不可用")
    let distinctStatuses = Set([
        waiting.status,
        fallback.status,
        disabled.status,
        connected.status,
        unavailable.status
    ])
    #expect(distinctStatuses.count == 5)
}

@Test("compact Codex status stops nagging after a trusted event")
func compactCodexStatusUsesDurableSessionTrust() {
    let waiting = CodexCompactAttentionPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasObservedEvent: false,
        hasError: false
    )
    let confirmed = CodexCompactAttentionPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasObservedEvent: true,
        hasError: false
    )
    let failed = CodexCompactAttentionPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasObservedEvent: true,
        hasError: true
    )

    #expect(waiting.shouldShow)
    #expect(!confirmed.shouldShow)
    #expect(failed.shouldShow)
}

@Test("Custom bottle capacities accept only integer milliliters in the supported range")
func customBottleCapacityValidation() {
    #expect(BottleCapacityInput.parse(" 600 ") == 600)
    #expect(BottleCapacityInput.parse("1200") == 1_200)
    #expect(BottleCapacityInput.parse("99") == nil)
    #expect(BottleCapacityInput.parse("5001") == nil)
    #expect(BottleCapacityInput.parse("1.2 L") == nil)
}

@MainActor
@Test("settings entry activates the accessory app before opening its single window")
func settingsEntryMakesTheSettingsWindowVisible() {
    var actions: [String] = []
    let presentation = SettingsWindowPresentation(
        activateApplication: { actions.append("activate") },
        openWindow: { actions.append("open") }
    )

    presentation.present()

    #expect(actions == ["activate", "open"])
}

private let notchedDisplay = ReminderDisplayGeometry(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
    safeAreaInsets: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0),
    auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 644, height: 38),
    auxiliaryTopRightArea: CGRect(x: 868, y: 944, width: 644, height: 38)
)

private let externalDisplay = ReminderDisplayGeometry(
    frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
    safeAreaInsets: .init(),
    auxiliaryTopLeftArea: nil,
    auxiliaryTopRightArea: nil
)

private final class WindowTestClock: HydrationClock {
    var now: Date
    init(now: Date) { self.now = now }
}

@MainActor
private func sendKey(_ characters: String, keyCode: UInt16, to panel: NSPanel) {
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
    #expect(panel.performKeyEquivalent(with: event))
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

@MainActor
private final class ActiveDisplayState {
    var geometry: ReminderDisplayGeometry
    init(geometry: ReminderDisplayGeometry) { self.geometry = geometry }
}
