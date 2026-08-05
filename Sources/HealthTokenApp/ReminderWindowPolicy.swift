import AppKit
import HealthTokenCore

struct ReminderDisplayGeometry {
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaInsets: NSEdgeInsets
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?

    init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaInsets: screen.safeAreaInsets,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaInsets: NSEdgeInsets,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaInsets = safeAreaInsets
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    var notchCenterX: CGFloat? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea,
              left.maxX < right.minX else {
            return nil
        }
        return (left.maxX + right.minX) / 2
    }
}

enum ReminderPanelLayout {
    static func frame(for size: CGSize, on display: ReminderDisplayGeometry) -> CGRect {
        let centerX = display.notchCenterX ?? display.frame.midX
        let topEdge = display.visibleFrame.maxY
        return CGRect(
            x: centerX - size.width / 2,
            y: topEdge - size.height,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class ReminderKeyboardFocusAuthorization {
    private(set) var isAuthorized = false

    func reminderDidAppear() {}
    func reminderLevelDidChange() {}

    func userDidIntentionallyInteract() {
        isAuthorized = true
    }

    func reminderDidClose() {
        isAuthorized = false
    }
}

enum ReminderHitRegion {
    case ambient
    case card

    func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
        switch self {
        case .ambient:
            return NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).contains(point)
        case .card:
            return NSBezierPath(
                roundedRect: bounds.insetBy(dx: 4, dy: 4),
                xRadius: 18,
                yRadius: 18
            ).contains(point)
        }
    }
}

struct ReminderAccessibilityPresentation {
    let status: HydrationStatus
    let reminderLevel: ReminderLevel
    let integrationHealth: CodexIntegrationHealth
    let isExpanded: Bool
    let sipMilliliters: Int

    init(
        status: HydrationStatus,
        reminderLevel: ReminderLevel,
        integrationHealth: CodexIntegrationHealth,
        isExpanded: Bool,
        sipMilliliters: Int = SipEstimate.regular.milliliters
    ) {
        self.status = status
        self.reminderLevel = reminderLevel
        self.integrationHealth = integrationHealth
        self.isExpanded = isExpanded
        self.sipMilliliters = sipMilliliters
    }

    var controlNames: [String] {
        if reminderLevel == .confirmation {
            return ["撤销刚才的饮水记录"]
        }
        if reminderLevel == .strong {
            return ["喝了一口，记录约 \(sipMilliliters) 毫升"]
        }
        if isExpanded {
            return [
                "喝了一口，记录约 \(sipMilliliters) 毫升",
                "稍后提醒十五分钟",
                "暂停 Health Token",
                "饮水设置"
            ]
        }
        return reminderLevel == .ambient ? ["饮水提醒，点击展开"] : []
    }

    var nonColorCue: String {
        if status == .paused { return "已暂停" }
        if status == .snoozed { return "已稍后" }
        if integrationHealth == .unavailable { return "Codex 观察不可用" }
        if reminderLevel == .strong { return "Codex 合格信号，强提醒" }
        if reminderLevel == .ambient { return "低干扰提醒" }
        return "正在计时"
    }
}

struct ReminderTransitionPolicy {
    let reduceMotion: Bool
    var usesScale: Bool { !reduceMotion }
}
