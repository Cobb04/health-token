import AppKit
import HealthTokenCore
import SwiftUI
import Testing
@testable import HealthTokenApp

@Test("health console starts as a compact overview")
func healthConsoleStartsCollapsed() {
    let presentation = HealthConsolePresentation()

    #expect(presentation.surface == .overview)
    #expect(presentation.preferredSize == .init(width: 554, height: 260))
}

@Test("selecting Water extends the console downward")
func selectingWaterExpandsDownward() {
    var presentation = HealthConsolePresentation()

    presentation.send(.selectWater)

    #expect(presentation.surface == .water)
    #expect(presentation.preferredSize == .init(width: 554, height: 543))
    #expect(
        presentation.waterDrawerFrame
            == CGRect(x: 14, y: 238, width: 526, height: 305)
    )
}

@Test("quick sip never opens or closes Water details")
func quickSipPreservesSurface() {
    var collapsed = HealthConsolePresentation()
    collapsed.send(.quickSip)
    #expect(collapsed.surface == .overview)

    var expanded = HealthConsolePresentation(surface: .water)
    expanded.send(.quickSip)
    #expect(expanded.surface == .water)
}

@Test("collapse returns to the exact compact size")
func collapseReturnsToOverview() {
    var presentation = HealthConsolePresentation(surface: .water)

    presentation.send(.collapseWater)

    #expect(presentation.surface == .overview)
    #expect(presentation.preferredSize == .init(width: 554, height: 260))
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
@Test("production console renders its compact and Water sizes")
func productionConsoleRendersBothSurfaces() throws {
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

    let overview = try renderConsole(model: model, surface: .overview)
    let water = try renderConsole(model: model, surface: .water)

    #expect(overview.size == .init(width: 554, height: 260))
    #expect(water.size == .init(width: 554, height: 543))
    #expect(overview.pixelsWide >= Int(overview.size.width))
    #expect(water.pixelsHigh >= Int(water.size.height))
}

@MainActor
@Test("console window is transparent without the gray system shadow")
func consoleWindowHasNoGrayChrome() {
    let panel = NSPanel(
        contentRect: CGRect(x: 0, y: 0, width: 554, height: 260),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )

    HealthConsoleWindowAppearance.apply(to: panel)

    #expect(panel.backgroundColor == .clear)
    #expect(!panel.isOpaque)
    #expect(!panel.hasShadow)
}

@MainActor
@Test("console clears only the system material that wraps its SwiftUI content")
func consoleClearsWrappingSystemMaterial() {
    let panel = NSPanel(
        contentRect: CGRect(x: 0, y: 0, width: 554, height: 543),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let systemMaterial = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
    let marker = NSView(frame: .zero)
    let productMaterial = NSVisualEffectView(frame: .zero)
    systemMaterial.addSubview(marker)
    marker.addSubview(productMaterial)
    panel.contentView = systemMaterial

    HealthConsoleWindowAppearance.apply(to: panel, from: marker)

    #expect(systemMaterial.maskImage != nil)
    #expect(productMaterial.maskImage == nil)
}

@MainActor
private func renderConsole(
    model: HydrationAppModel,
    surface: HealthConsolePresentation.Surface
) throws -> NSBitmapImageRep {
    let size = HealthConsolePresentation(surface: surface).preferredSize
    let hostingView = NSHostingView(
        rootView: MenuBarContentView(model: model, initialSurface: surface)
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
