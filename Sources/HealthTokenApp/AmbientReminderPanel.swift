import AppKit
import Combine
import HealthTokenCore
import SwiftUI

@MainActor
final class AmbientReminderPanelController {
    private let panel: AmbientReminderPanel
    private var snapshotObservation: AnyCancellable?

    init(model: HydrationAppModel) {
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
        panel.contentView = InteractiveHostingView(
            rootView: AmbientReminderView(model: model)
        )

        snapshotObservation = model.$snapshot
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
    }

    private func render(_ snapshot: HydrationSnapshot) {
        guard snapshot.reminderLevel != .hidden else {
            panel.orderOut(nil)
            return
        }

        let size: NSSize
        if snapshot.reminderLevel == .strong {
            size = NSSize(width: 330, height: 132)
        } else if snapshot.reminderLevel == .confirmation {
            size = NSSize(width: 292, height: 142)
        } else if snapshot.detailsExpanded {
            size = NSSize(width: 292, height: 224)
        } else {
            size = NSSize(width: 48, height: 48)
        }
        positionPanel(size: size)

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func positionPanel(size: NSSize) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        guard let screen else { return }

        let topInset = max(
            screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY
        )
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - topInset - size.height + 6
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}

private final class AmbientReminderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
