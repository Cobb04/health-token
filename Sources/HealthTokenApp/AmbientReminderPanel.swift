import AppKit
import Combine
import HealthTokenCore
import SwiftUI

@MainActor
final class AmbientReminderPanelController {
    let panel: AmbientReminderPanel
    private let hostingView: InteractiveHostingView<AmbientReminderView>
    private let activeDisplay: @MainActor () -> ReminderDisplayGeometry?
    private var snapshotObservation: AnyCancellable?
    private var screenObservation: NSObjectProtocol?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var currentSnapshot: HydrationSnapshot

    convenience init(model: HydrationAppModel) {
        self.init(model: model, activeDisplay: Self.currentActiveDisplay)
    }

    init(
        model: HydrationAppModel,
        activeDisplay: @MainActor @escaping () -> ReminderDisplayGeometry?
    ) {
        currentSnapshot = model.snapshot
        self.activeDisplay = activeDisplay
        panel = AmbientReminderPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hostingView = InteractiveHostingView(
            rootView: AmbientReminderView(
                model: model,
                onIntentionalInteraction: {}
            )
        )
        panel.contentView = hostingView
        hostingView.rootView = AmbientReminderView(
            model: model,
            onIntentionalInteraction: { [weak self] in
                self?.userDidIntentionallyInteract()
            }
        )

        snapshotObservation = model.$snapshot
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
        screenObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.render(self.currentSnapshot)
            }
        }
        let pointerEvents: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) {
            [weak self] _ in
            Task { @MainActor in self?.handlePointerMovement() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) {
            [weak self] event in
            self?.handlePointerMovement()
            return event
        }
    }

    func stop() {
        if let screenObservation {
            NotificationCenter.default.removeObserver(screenObservation)
            self.screenObservation = nil
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
    }

    private func render(_ snapshot: HydrationSnapshot) {
        currentSnapshot = snapshot
        guard snapshot.reminderLevel != .hidden else {
            panel.allowsKeyboardFocus = false
            panel.orderOut(nil)
            return
        }

        let size = panelSize(for: snapshot)
        hostingView.hitRegion = snapshot.reminderLevel == .ambient && !snapshot.detailsExpanded
            ? .ambient
            : .card
        positionPanel(size: size)
        updatePointerInterception()

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func positionPanel(size: NSSize) {
        guard let activeDisplay = activeDisplay() else { return }

        let frame = ReminderPanelLayout.frame(
            for: size,
            on: activeDisplay
        )
        panel.setFrame(frame, display: true)
    }

    func userDidIntentionallyInteract() {
        panel.allowsKeyboardFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    private func handlePointerMovement() {
        guard panel.isVisible else { return }
        positionPanel(size: panelSize(for: currentSnapshot))
        updatePointerInterception()
    }

    private func updatePointerInterception() {
        updatePointerInterception(at: NSEvent.mouseLocation)
    }

    func updatePointerInterception(at screenPoint: CGPoint) {
        let localPoint = CGPoint(
            x: screenPoint.x - panel.frame.minX,
            y: screenPoint.y - panel.frame.minY
        )
        panel.ignoresMouseEvents = !hostingView.hitRegion.contains(
            localPoint,
            in: hostingView.bounds
        )
    }

    func activeDisplayDidChange() {
        render(currentSnapshot)
    }

    var accessibleControlNames: [String] {
        let sipMilliliters = currentSnapshot.settings.sipEstimate.milliliters
        if currentSnapshot.reminderLevel == .confirmation,
           let record = currentSnapshot.undoableDrinkRecord {
            return [ReminderControlName.undo(
                sipMilliliters: record.estimatedMilliliters
            )]
        }
        if currentSnapshot.reminderLevel == .strong {
            return [ReminderControlName.drink(sipMilliliters: sipMilliliters)]
        }
        if currentSnapshot.detailsExpanded {
            return [
                ReminderControlName.drink(sipMilliliters: sipMilliliters),
                ReminderControlName.snooze,
                ReminderControlName.pause,
                ReminderControlName.settings
            ]
        }
        return []
    }

    private func panelSize(for snapshot: HydrationSnapshot) -> NSSize {
        if snapshot.reminderLevel == .strong {
            return NSSize(width: 330, height: 132)
        }
        if snapshot.reminderLevel == .confirmation {
            return NSSize(width: 292, height: 142)
        }
        if snapshot.detailsExpanded {
            return NSSize(width: 292, height: 294)
        }
        return NSSize(width: 48, height: 48)
    }

    private static func currentActiveDisplay() -> ReminderDisplayGeometry? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        return screen.map(ReminderDisplayGeometry.init(screen:))
    }
}

final class AmbientReminderPanel: NSPanel {
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

private final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    var hitRegion: ReminderHitRegion = .ambient

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitRegion.contains(point, in: bounds) else { return nil }
        return super.hitTest(point)
    }
}
