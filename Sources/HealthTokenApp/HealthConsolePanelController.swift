import AppKit
import SwiftUI

@MainActor
enum HealthConsolePanelAppearance {
    static func apply(to panel: NSPanel) {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
    }
}

enum HealthConsolePanelGeometry {
    static func frame(
        anchorFrame: CGRect,
        contentSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        // The status item is only the trigger. The console belongs beneath the
        // notch/menu bar, so keep it centered on the active display regardless
        // of where macOS places the status item.
        let desiredX = visibleFrame.midX - contentSize.width / 2
        let minimumX = visibleFrame.minX
        let maximumX = max(minimumX, visibleFrame.maxX - contentSize.width)
        let x = min(max(desiredX, minimumX), maximumX)
        let desiredY = anchorFrame.minY - contentSize.height
        let minimumY = visibleFrame.minY
        let maximumY = max(minimumY, visibleFrame.maxY - contentSize.height)
        let y = min(max(desiredY, minimumY), maximumY)
        return CGRect(origin: CGPoint(x: x, y: y), size: contentSize)
    }
}

@MainActor
final class HealthConsolePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class HealthConsolePanelController: NSObject {
    private let model: HydrationAppModel
    private let presentSettings: () -> Void
    private let statusItem: NSStatusItem
    private let panel: HealthConsolePanel
    private var hostingView: NSHostingView<MenuBarContentView>!
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(
        model: HydrationAppModel,
        presentSettings: @escaping () -> Void,
        initialSurface: HealthConsolePresentation.Surface = .overview
    ) {
        self.model = model
        self.presentSettings = presentSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = HealthConsolePanel(
            contentRect: CGRect(origin: .zero, size: HealthConsolePresentation.overviewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureStatusItem()
        configurePanel(initialSurface: initialSurface)
    }

    func stop() {
        removeDismissMonitors()
        panel.orderOut(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePanel() {
        panel.isVisible ? hide() : show()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Health Token")
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp])
        button.toolTip = "Health Token"
        button.setAccessibilityLabel("Health Token")
    }

    private func configurePanel(initialSurface: HealthConsolePresentation.Surface) {
        HealthConsolePanelAppearance.apply(to: panel)
        let rootView = MenuBarContentView(
            model: model,
            initialSurface: initialSurface,
            onPreferredSizeChange: { [weak self] size in
                self?.updatePanelSize(size)
            },
            presentSettings: { [weak self] in
                self?.hide()
                self?.presentSettings()
            }
        )
        hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: HealthConsolePresentation.overviewSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
    }

    private func show() {
        model.refreshTemporalState()
        positionPanel(size: panel.frame.size)
        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors()
    }

    private func hide() {
        panel.orderOut(nil)
        removeDismissMonitors()
    }

    private func updatePanelSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = CGRect(origin: .zero, size: size)
        positionPanel(size: size)
    }

    private func positionPanel(size: CGSize) {
        guard let anchorFrame = statusItemScreenFrame else { return }
        let visibleFrame = statusItem.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: size)
        panel.setFrame(
            HealthConsolePanelGeometry.frame(
                anchorFrame: anchorFrame,
                contentSize: size,
                visibleFrame: visibleFrame
            ),
            display: true
        )
    }

    private var statusItemScreenFrame: CGRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            if event.window !== self?.panel {
                self?.hide()
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }
}
