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
@Test("one real panel moves across displays without passive focus or transparent hits")
func realPanelWindowBehavior() throws {
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
    model.sendForWindowIntegrationTest(.timeAdvanced)
    let panelIdentity = ObjectIdentifier(controller.panel)

    #expect(controller.panel.isVisible)
    #expect(!controller.panel.canBecomeKey)
    #expect(controller.panel.frame.midX == notchedDisplay.frame.midX)

    for _ in 0..<3 {
        model.sendForWindowIntegrationTest(.agentEvent(AgentEvent(
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
    model.sendForWindowIntegrationTest(.agentEvent(AgentEvent(
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
@Test("intentional expansion authorizes the real panel and exposes named controls")
func realPanelAccessibleKeyboardOutput() throws {
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
    model.sendForWindowIntegrationTest(.timeAdvanced)

    #expect(!controller.panel.canBecomeKey)
    controller.userDidIntentionallyInteract()
    model.openReminder()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    #expect(controller.panel.canBecomeKey)
    #expect(model.snapshot.detailsExpanded)

    let names = Set(controller.accessibleControlNames)
    #expect(names.contains("喝了一口，记录约 25 毫升"))
    #expect(names.contains("稍后提醒十五分钟"))
    #expect(names.contains("暂停 Health Token"))
    #expect(names.contains("饮水设置"))
}

@Test("Reduce Motion uses opacity while standard transitions may scale")
func reduceMotionTransition() {
    #expect(ReminderTransitionPolicy(reduceMotion: true).usesScale == false)
    #expect(ReminderTransitionPolicy(reduceMotion: false).usesScale == true)
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
private final class ActiveDisplayState {
    var geometry: ReminderDisplayGeometry
    init(geometry: ReminderDisplayGeometry) { self.geometry = geometry }
}
