import AppKit
import HealthTokenCore
import SwiftUI
import Testing
@testable import HealthTokenApp

@Test("health console starts as a compact overview")
func healthConsoleStartsCollapsed() {
    let presentation = HealthConsolePresentation()

    #expect(presentation.preferredSize == .init(width: 554, height: 260))
}

@Test("integrated Water console has no expandable drawer state")
func integratedWaterConsoleHasOneSize() {
    #expect(HealthConsolePresentation.overviewSize == .init(width: 554, height: 260))
}

@Test("Water drives wellbeing until Movement has a real signal")
func WaterDrivesWellbeingWithoutMovementSignal() {
    #expect(
        HealthConsoleWellbeingState.resolve(
            waterProgress: 0.2,
            movementProgress: nil
        ) == .depleted
    )
    #expect(
        HealthConsoleWellbeingState.resolve(
            waterProgress: 0.5,
            movementProgress: nil
        ) == .steady
    )
    #expect(
        HealthConsoleWellbeingState.resolve(
            waterProgress: 0.9,
            movementProgress: nil
        ) == .thriving
    )
}

@Test("the weaker real metric determines overall wellbeing")
func weakerMetricDeterminesWellbeing() {
    #expect(
        HealthConsoleWellbeingState.resolve(
            waterProgress: 0.9,
            movementProgress: 0.2
        ) == .depleted
    )
    #expect(
        HealthConsoleWellbeingState.resolve(
            waterProgress: 0.9,
            movementProgress: 0.6
        ) == .steady
    )
    #expect(
        HealthConsoleWellbeingState.resolve(
            waterProgress: 0.9,
            movementProgress: 0.9
        ) == .thriving
    )
}

@MainActor
@Test("production console renders one integrated surface")
func productionConsoleRendersIntegratedSurface() throws {
    let clock = HealthConsoleTestClock(
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let engine = try HydrationEngine(
        clock: clock,
        store: InMemoryHydrationStore()
    )
    let model = HydrationAppModel(
        engine: engine,
        integrationHealth: .unavailable
    )

    let overview = try renderConsole(model: model)

    #expect(overview.size == .init(width: 554, height: 260))
    #expect(overview.pixelsWide >= Int(overview.size.width))
    #expect(overview.pixelsHigh >= Int(overview.size.height))
}

@MainActor
@Test("custom menu panel is transparent without system chrome")
func customMenuPanelHasNoSystemChrome() {
    let panel = NSPanel(
        contentRect: CGRect(x: 0, y: 0, width: 554, height: 260),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )

    HealthConsolePanelAppearance.apply(to: panel)

    #expect(panel.backgroundColor == .clear)
    #expect(!panel.isOpaque)
    #expect(!panel.hasShadow)
    #expect(panel.styleMask.contains(.borderless))
}

@Test("menu panel stays centered on the status item's screen")
func menuPanelStaysCenteredOnScreen() {
    let frame = HealthConsolePanelGeometry.frame(
        anchorFrame: CGRect(x: 480, y: 876, width: 28, height: 24),
        contentSize: CGSize(width: 554, height: 260),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 900)
    )

    #expect(frame == CGRect(x: 223, y: 616, width: 554, height: 260))

    let secondaryDisplayFrame = HealthConsolePanelGeometry.frame(
        anchorFrame: CGRect(x: 1_780, y: 876, width: 28, height: 24),
        contentSize: CGSize(width: 554, height: 260),
        visibleFrame: CGRect(x: 1_000, y: 0, width: 1_600, height: 900)
    )

    #expect(secondaryDisplayFrame.minX == 1_523)
    #expect(secondaryDisplayFrame.midX == 1_800)
}

@MainActor
private func renderConsole(
    model: HydrationAppModel
) throws -> NSBitmapImageRep {
    let size = HealthConsolePresentation().preferredSize
    let hostingView = NSHostingView(
        rootView: MenuBarContentView(model: model)
    )
    hostingView.frame = CGRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    let bitmap = try #require(
        hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    )
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    return bitmap
}

private final class HealthConsoleTestClock: HydrationClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
