import AppKit
import HealthTokenCore
import SwiftUI
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

@Test("rollout activity stays distinct from verified official hook activity")
func observationActivityTracksSourcesSeparately() {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var activity = CodexObservationActivity()

    activity.record(
        hookEventCount: 0,
        observedAt: observedAt
    )

    #expect(
        !activity.wasOfficialHookObservedRecently(
            at: observedAt.addingTimeInterval(119),
            freshnessInterval: 120
        )
    )
    activity.record(
        hookEventCount: 1,
        observedAt: observedAt.addingTimeInterval(120)
    )
    #expect(
        activity.wasOfficialHookObservedRecently(
            at: observedAt.addingTimeInterval(121),
            freshnessInterval: 120
        )
    )
}

@Test("recent official hooks suppress duplicate rollout work but not completion rescue")
func CodexEventSourceMergerPrefersOfficialHooks() {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let hookTools = (0..<3).map { offset in
        AgentEvent(
            kind: .toolUsed,
            sessionID: "root",
            timestamp: observedAt.addingTimeInterval(Double(offset)),
            role: .root,
            attention: .none,
            toolClassification: .ordinary
        )
    }
    let rolloutTools = hookTools.map {
        AgentEvent(
            kind: $0.kind,
            sessionID: $0.sessionID,
            timestamp: $0.timestamp.addingTimeInterval(0.1),
            role: $0.role,
            attention: $0.attention,
            toolClassification: $0.toolClassification
        )
    }
    let completion = AgentEvent(
        kind: .completed,
        sessionID: "root",
        timestamp: observedAt.addingTimeInterval(4),
        role: .root,
        attention: .none
    )
    var merger = CodexEventSourceMerger()

    let merged = merger.merge(
        hookEvents: hookTools,
        rolloutEvents: rolloutTools + [completion],
        observedAt: observedAt
    )

    #expect(merged.map(\.kind) == [.toolUsed, .toolUsed, .toolUsed, .completed])
    #expect(merged.filter { $0.kind == .toolUsed }.count == 3)
}

@Test("rollout remains active when no official hook has reached the app")
func CodexEventSourceMergerKeepsFallbackIndependent() {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutEvent = AgentEvent(
        kind: .toolUsed,
        sessionID: "fallback-root",
        timestamp: observedAt,
        role: .root,
        attention: .none,
        toolClassification: .ordinary
    )
    var merger = CodexEventSourceMerger()

    let merged = merger.merge(
        hookEvents: [],
        rolloutEvents: [rolloutEvent],
        observedAt: observedAt
    )

    #expect(merged == [rolloutEvent])
}

@Test("Codex current activity ends on completion abort removal and timeout")
func CodexCurrentActivityTracksLiveSessions() {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let tool = AgentEvent(
        kind: .toolUsed,
        sessionID: "root",
        timestamp: observedAt,
        role: .root,
        attention: .none,
        toolClassification: .ordinary
    )
    var activity = CodexCurrentActivity()

    activity.observe([tool], at: observedAt)
    #expect(activity.isActive(at: observedAt))

    activity.observe([
        AgentEvent(
            kind: .attentionChanged,
            sessionID: "root",
            timestamp: observedAt.addingTimeInterval(1),
            role: .root,
            attention: .required
        )
    ], at: observedAt.addingTimeInterval(1))
    #expect(!activity.isActive(at: observedAt.addingTimeInterval(1)))
    activity.observe([tool], at: observedAt.addingTimeInterval(2))

    for (index, terminalKind) in [
        AgentEvent.Kind.completed,
        .aborted,
        .sessionRemoved
    ].enumerated() {
        let terminalAt = observedAt.addingTimeInterval(TimeInterval(3 + index * 2))
        activity.observe([
            AgentEvent(
                kind: terminalKind,
                sessionID: "root",
                timestamp: terminalAt,
                role: .root,
                attention: .none
            )
        ], at: terminalAt)
        #expect(!activity.isActive(at: terminalAt))
        activity.observe([tool], at: terminalAt.addingTimeInterval(1))
    }

    #expect(!activity.isActive(at: observedAt.addingTimeInterval(5 * 60 + 10)))
}

@Test("one completed session does not hide another active Codex session")
func CodexCurrentActivityAggregatesSessions() {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var activity = CodexCurrentActivity()
    let active = ["root-a", "root-b"].map { sessionID in
        AgentEvent(
            kind: .toolUsed,
            sessionID: sessionID,
            timestamp: observedAt,
            role: .root,
            attention: .none,
            toolClassification: .ordinary
        )
    }
    activity.observe(active, at: observedAt)
    activity.observe([
        AgentEvent(
            kind: .completed,
            sessionID: "root-a",
            timestamp: observedAt.addingTimeInterval(1),
            role: .root,
            attention: .none
        )
    ], at: observedAt.addingTimeInterval(1))

    #expect(activity.isActive(at: observedAt.addingTimeInterval(1)))
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
        isAgentActive: false,
        noAgentFallbackEnabled: true
    )
    let idleFallback = CodexIntegrationPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasObservedEvent: true,
        isAgentActive: false,
        noAgentFallbackEnabled: true
    )
    let activeFallback = CodexIntegrationPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasObservedEvent: true,
        isAgentActive: true,
        noAgentFallbackEnabled: true
    )
    let disabled = CodexIntegrationPresentation(
        health: .fallbackOnly,
        isObservationEnabled: false,
        hasObservedEvent: false,
        isAgentActive: false,
        noAgentFallbackEnabled: true
    )
    let connected = CodexIntegrationPresentation(
        health: .connected,
        isObservationEnabled: true,
        hasObservedEvent: true,
        isAgentActive: false,
        noAgentFallbackEnabled: true
    )
    let unavailable = CodexIntegrationPresentation(
        health: .unavailable,
        isObservationEnabled: false,
        hasObservedEvent: false,
        isAgentActive: false,
        noAgentFallbackEnabled: true
    )

    #expect(waiting.status == "Codex 观察：已就绪")
    #expect(waiting.detail.contains("正在监听本机 Codex"))
    #expect(waiting.detail.contains("普通定时饮水提醒仍会工作"))
    #expect(!waiting.detail.contains("/hooks"))
    #expect(!waiting.detail.contains("允许 Health Token"))
    #expect(!waiting.detail.contains("生命周期"))
    #expect(!waiting.detail.contains("保持 B"))
    #expect(disabled.status == "Codex 观察：未启用")
    #expect(disabled.detail.contains("自动配置本地连接"))
    #expect(!disabled.detail.contains("/hooks"))
    #expect(idleFallback.status == "Codex 观察：已就绪")
    #expect(idleFallback.detail.contains("当前空闲"))
    #expect(activeFallback.status == "Codex 观察：工作中")
    #expect(connected.status == "Codex 观察：已就绪")
    #expect(connected.detail.contains("实时事件已验证"))
    #expect(unavailable.status == "Codex 观察：不可用")
}

@Test("compact Codex status only appears for an actionable observation problem")
func compactCodexStatusOnlyShowsActionableProblems() {
    let waiting = CodexCompactAttentionPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasError: false
    )
    let confirmed = CodexCompactAttentionPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasError: false
    )
    let failed = CodexCompactAttentionPresentation(
        health: .fallbackOnly,
        isObservationEnabled: true,
        hasError: true
    )

    #expect(!waiting.shouldShow)
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

@Test("hydration heatmap periods and bottle-relative intensities stay stable")
func hydrationHeatmapPeriodAndIntensitySemantics() {
    #expect(HydrationHeatmapPeriod.quarter.dayCount == 84)
    #expect(HydrationHeatmapPeriod.year.dayCount == 365)
    #expect(HydrationHeatmapPeriod.quarter.layout == .focusedQuarter)
    #expect(HydrationHeatmapPeriod.year.layout == .yearOverview)
    #expect(HydrationHeatmapIntensity(estimatedMilliliters: 0, bottleCapacity: 1_000, isAvailable: false) == .unavailable)
    #expect(HydrationHeatmapIntensity(estimatedMilliliters: 0, bottleCapacity: 1_000, isAvailable: true) == .zero)
    #expect(HydrationHeatmapIntensity(estimatedMilliliters: 999, bottleCapacity: 1_000, isAvailable: true) == .partialBottle)
    #expect(HydrationHeatmapIntensity(estimatedMilliliters: 1_000, bottleCapacity: 1_000, isAvailable: true) == .oneBottle)
    #expect(HydrationHeatmapIntensity(estimatedMilliliters: 1_999, bottleCapacity: 1_000, isAvailable: true) == .oneBottle)
    #expect(HydrationHeatmapIntensity(estimatedMilliliters: 2_000, bottleCapacity: 1_000, isAvailable: true) == .twoBottles)
    #expect(HydrationHeatmapIntensity(estimatedMilliliters: 2_999, bottleCapacity: 1_000, isAvailable: true) == .twoBottles)
    #expect(HydrationHeatmapIntensity(estimatedMilliliters: 3_000, bottleCapacity: 1_000, isAvailable: true) == .threeOrMoreBottles)
}

@Test("quarter heatmap distinguishes unavailable and zero days with exact accessible values")
func hydrationHeatmapPresentationUsesChronologicalDaysAndTrackingBoundary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    let today = calendar.date(
        from: DateComponents(year: 2027, month: 8, day: 11, hour: 12)
    )!
    let summaries = try (0..<365).map { offset in
        let day = try #require(calendar.date(byAdding: .day, value: -offset, to: today))
        let interval = try #require(calendar.dateInterval(of: .day, for: day))
        let amount = switch offset {
        case 0: 700
        case 1: 1_000
        default: 0
        }
        return DailyHydrationSummary(
            interval: interval,
            estimatedMilliliters: amount,
            recordCount: amount == 0 ? 0 : 1
        )
    }
    let trackingStartedAt = try #require(
        calendar.date(byAdding: .day, value: -2, to: today)
    )

    let presentation = DailyHydrationHeatmapPresentation(
        summaries: summaries,
        trackingStartedAt: trackingStartedAt,
        period: .quarter,
        bottleCapacity: 1_000,
        calendar: calendar,
        locale: Locale(identifier: "zh_CN")
    )

    try #require(presentation.days.count == 84)
    #expect(presentation.days.first?.summary.interval.start == summaries[83].interval.start)
    #expect(presentation.days.last?.summary.interval.start == summaries[0].interval.start)
    #expect(presentation.days.first?.intensity == .unavailable)
    #expect(presentation.days[81].intensity == .zero)
    #expect(presentation.days.last?.intensity == .partialBottle)
    #expect(presentation.todayAmount == "700 mL")
    #expect(presentation.todayBottleEquivalent == "今天 · 约 0.7 瓶")
    #expect(presentation.recentSevenDayTotal == "近 7 日 · 1.7 L")
    #expect(presentation.days.first?.accessibilityLabel.contains("无数据") == true)
    #expect(presentation.days[81].accessibilityLabel.contains("没有饮水记录") == true)
    #expect(presentation.days.last?.accessibilityLabel.contains("记录约 700 毫升") == true)
    #expect(presentation.days.last?.accessibilityLabel.contains("约 0.7 瓶") == true)
}

@Test("hydration heatmap layout respects the calendar week across a month boundary")
func hydrationHeatmapLayoutUsesCalendarWeekGeometry() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    calendar.firstWeekday = 2
    let firstDay = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 12, day: 28, hour: 12))
    )
    let days = try (0..<14).map { offset in
        let date = try #require(calendar.date(byAdding: .day, value: offset, to: firstDay))
        let interval = try #require(calendar.dateInterval(of: .day, for: date))
        return HydrationHeatmapDay(
            summary: DailyHydrationSummary(
                interval: interval,
                estimatedMilliliters: offset * 25,
                recordCount: offset == 0 ? 0 : 1
            ),
            intensity: offset == 0 ? .zero : .partialBottle,
            accessibilityLabel: "day \(offset)"
        )
    }
    let today = try #require(days.last?.summary.interval.start)

    let layout = HydrationHeatmapLayout(
        days: days,
        today: today,
        calendar: calendar,
        locale: Locale(identifier: "zh_CN")
    )

    try #require(layout.points.count == 14)
    #expect(layout.weekCount == 2)
    #expect(layout.points.first?.weekIndex == 0)
    #expect(layout.points.first?.weekdayIndex == 0)
    #expect(layout.points.last?.weekIndex == 1)
    #expect(layout.points.last?.weekdayIndex == 6)
    #expect(layout.points.last?.isToday == true)
    #expect(layout.monthTicks.count == 1)
    #expect(layout.monthTicks.map(\.weekIndex) == [0])
    #expect(layout.weekdayLabels.count == 7)
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

@MainActor
@Test("settings renders the hydration heatmap without trapping")
func settingsRendersHydrationHeatmapWithoutTrapping() throws {
    let engine = try HydrationEngine(
        clock: WindowTestClock(now: Date(timeIntervalSince1970: 1_800_000_000)),
        store: InMemoryHydrationStore()
    )
    let model = HydrationAppModel(engine: engine, integrationHealth: .unavailable)
    let hostingView = NSHostingView(
        rootView: HealthTokenSettingsView(model: model)
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 430, height: 560)

    hostingView.layoutSubtreeIfNeeded()

    #expect(hostingView.fittingSize.width > 0)
    #expect(hostingView.fittingSize.height > 0)
}

@MainActor
@Test("opening the menu refreshes a stale yesterday snapshot")
func temporalRefreshMovesYesterdayIntoHistory() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    let yesterday = calendar.date(
        from: DateComponents(year: 2027, month: 3, day: 7, hour: 23, minute: 59)
    )!
    let clock = WindowTestClock(now: yesterday)
    let engine = try HydrationEngine(
        clock: clock,
        store: InMemoryHydrationStore(),
        calendar: calendar
    )
    _ = try engine.send(.recordProactiveSip)
    let model = HydrationAppModel(engine: engine, integrationHealth: .unavailable)
    let previousCycle = model.snapshot.cycle
    #expect(model.snapshot.todayEstimatedMilliliters == 25)

    clock.now = calendar.date(
        from: DateComponents(year: 2027, month: 3, day: 8, hour: 8)
    )!
    #expect(model.snapshot.todayEstimatedMilliliters == 25)

    model.refreshTemporalState()

    #expect(model.snapshot.todayEstimatedMilliliters == 0)
    #expect(model.snapshot.recentDailySummaries[1].estimatedMilliliters == 25)
    #expect(model.snapshot.cycle == previousCycle)
}

@MainActor
@Test("calendar clock timezone locale and wake notifications share one refresh path")
func temporalCoordinatorObservesEveryTimeBoundary() {
    let center = NotificationCenter()
    let workspaceCenter = NotificationCenter()
    var refreshCount = 0
    let coordinator = TemporalRefreshCoordinator(
        notificationCenter: center,
        workspaceNotificationCenter: workspaceCenter
    ) {
        refreshCount += 1
    }
    coordinator.start()

    center.post(name: .NSCalendarDayChanged, object: nil)
    center.post(name: .NSSystemClockDidChange, object: nil)
    center.post(name: .NSSystemTimeZoneDidChange, object: nil)
    center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

    #expect(refreshCount == 5)
    coordinator.stop()
    center.post(name: .NSCalendarDayChanged, object: nil)
    workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(refreshCount == 5)
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
