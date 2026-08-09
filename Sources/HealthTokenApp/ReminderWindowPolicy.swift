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
        let width = min(size.width, display.visibleFrame.width)
        let height = min(size.height, display.visibleFrame.height)
        let centeredX = centerX - width / 2
        let x = min(
            max(centeredX, display.visibleFrame.minX),
            display.visibleFrame.maxX - width
        )
        return CGRect(
            x: x,
            y: max(display.visibleFrame.minY, topEdge - height),
            width: width,
            height: height
        )
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

struct ReminderAccessibilityCue {
    let status: HydrationStatus
    let reminderLevel: ReminderLevel
    let integrationHealth: CodexIntegrationHealth

    var nonColorCue: String {
        if status == .paused { return "已暂停" }
        if status == .snoozed { return "已稍后" }
        if integrationHealth == .unavailable { return "Codex 观察不可用" }
        if reminderLevel == .strong { return "Codex 合格信号，强提醒" }
        if reminderLevel == .ambient { return "低干扰提醒" }
        return "正在计时"
    }
}

enum ReminderControlName {
    static func drink(sipMilliliters: Int) -> String {
        "喝了一口，记录约 \(sipMilliliters) 毫升"
    }

    static let snooze = "稍后提醒十五分钟"
    static let pause = "暂停 Health Token"
    static let settings = "饮水设置"
    static let dismissConfirmation = "长按收起确认，不撤销饮水记录"

    static func undo(sipMilliliters: Int) -> String {
        "撤销刚才约 \(sipMilliliters) 毫升的饮水记录"
    }
}

struct ReminderTransitionPolicy {
    let reduceMotion: Bool
    var usesScale: Bool { !reduceMotion }
    var scale: Double { reduceMotion ? 1 : 0.98 }
    var duration: TimeInterval { reduceMotion ? 0.12 : 0.2 }
}

struct ReminderAppearancePolicy {
    let increasedContrast: Bool

    var showsGlow: Bool { !increasedContrast }
    var dropBackgroundOpacity: Double { increasedContrast ? 0.95 : 0.82 }
    var cardBorderOpacity: Double { increasedContrast ? 1 : 0.18 }
    var confirmationBorderOpacity: Double { increasedContrast ? 1 : 0.12 }
}
