import AppKit
import HealthTokenCore
import Testing
@testable import HealthTokenApp

@Test("notched displays center B and C on the physical notch")
func notchedDisplayPlacement() {
    let display = ReminderDisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        safeAreaInsets: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0),
        auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 644, height: 38),
        auxiliaryTopRightArea: CGRect(x: 868, y: 944, width: 644, height: 38)
    )

    let b = ReminderPanelLayout.frame(
        for: CGSize(width: 48, height: 48),
        on: display
    )
    let c = ReminderPanelLayout.frame(
        for: CGSize(width: 330, height: 132),
        on: display
    )

    #expect(b.midX == 756)
    #expect(c.midX == 756)
    #expect(b.maxY == display.visibleFrame.maxY)
    #expect(c.maxY == display.visibleFrame.maxY)
}

@Test("displays without a notch use a predictable top-center fallback")
func topCenterFallbackPlacement() {
    let display = ReminderDisplayGeometry(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
        safeAreaInsets: .init(),
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil
    )

    let frame = ReminderPanelLayout.frame(
        for: CGSize(width: 330, height: 132),
        on: display
    )

    #expect(frame.midX == display.frame.midX)
    #expect(frame.maxY == display.visibleFrame.maxY)
}

@Test("changing the active display moves the same panel frame")
func activeDisplayChangeRecomputesPlacement() {
    let builtIn = ReminderDisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        safeAreaInsets: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0),
        auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 644, height: 38),
        auxiliaryTopRightArea: CGRect(x: 868, y: 944, width: 644, height: 38)
    )
    let external = ReminderDisplayGeometry(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
        safeAreaInsets: .init(),
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil
    )

    let initial = ReminderPanelLayout.frame(for: CGSize(width: 48, height: 48), on: builtIn)
    let moved = ReminderPanelLayout.frame(for: CGSize(width: 48, height: 48), on: external)

    #expect(initial.midX == builtIn.frame.midX)
    #expect(moved.midX == external.frame.midX)
    #expect(initial != moved)
}

@MainActor
@Test("appearance and B-C transitions do not authorize keyboard focus")
func passiveTransitionsDoNotAuthorizeFocus() {
    let authorization = ReminderKeyboardFocusAuthorization()

    authorization.reminderDidAppear()
    authorization.reminderLevelDidChange()

    #expect(!authorization.isAuthorized)
    authorization.userDidIntentionallyInteract()
    #expect(authorization.isAuthorized)
    authorization.reminderDidClose()
    #expect(!authorization.isAuthorized)
}

@Test("only visible reminder shapes intercept pointer input")
func visibleHitRegionsOnly() {
    let bounds = CGRect(x: 0, y: 0, width: 48, height: 48)

    #expect(ReminderHitRegion.ambient.contains(CGPoint(x: 24, y: 24), in: bounds))
    #expect(!ReminderHitRegion.ambient.contains(CGPoint(x: 1, y: 1), in: bounds))
    #expect(ReminderHitRegion.card.contains(CGPoint(x: 24, y: 24), in: bounds))
    #expect(!ReminderHitRegion.card.contains(CGPoint(x: 1, y: 1), in: bounds))
}

@Test("accessible controls and non-color cues cover daily-use states")
func accessiblePresentationOutput() {
    let ambient = ReminderAccessibilityPresentation(
        status: .dueAmbient,
        reminderLevel: .ambient,
        integrationHealth: .connected,
        isExpanded: true
    )
    let snoozed = ReminderAccessibilityPresentation(
        status: .snoozed,
        reminderLevel: .ambient,
        integrationHealth: .connected,
        isExpanded: false
    )
    let paused = ReminderAccessibilityPresentation(
        status: .paused,
        reminderLevel: .hidden,
        integrationHealth: .connected,
        isExpanded: false
    )
    let unavailable = ReminderAccessibilityPresentation(
        status: .dueAmbient,
        reminderLevel: .ambient,
        integrationHealth: .unavailable,
        isExpanded: false
    )

    #expect(ambient.controlNames == ["喝了一口，记录约 25 毫升", "稍后提醒十五分钟", "暂停 Health Token", "饮水设置"])
    #expect(snoozed.nonColorCue == "已稍后")
    #expect(paused.nonColorCue == "已暂停")
    #expect(unavailable.nonColorCue == "Codex 观察不可用")
}

@Test("Reduce Motion uses opacity while standard transitions may scale")
func reduceMotionTransition() {
    #expect(ReminderTransitionPolicy(reduceMotion: true).usesScale == false)
    #expect(ReminderTransitionPolicy(reduceMotion: false).usesScale == true)
}
