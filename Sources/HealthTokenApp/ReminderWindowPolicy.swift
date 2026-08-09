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

struct HydrationMenuStatusPresentation {
    let text: String
    let usesCountdownAccent: Bool

    init(status: HydrationStatus, remainingTimeUntilReminder: TimeInterval) {
        switch status {
        case .accumulating:
            let remainingSeconds = Int(ceil(max(0, remainingTimeUntilReminder)))
            text = String(
                format: "下一次提醒 %02d:%02d",
                remainingSeconds / 60,
                remainingSeconds % 60
            )
            usesCountdownAccent = true
        case .dueAmbient:
            text = "该喝水了"
            usesCountdownAccent = false
        case .dueStrong:
            text = "Codex 还在忙，该喝水了"
            usesCountdownAccent = false
        case .snoozed:
            text = "已稍后提醒，饮水仍到期"
            usesCountdownAccent = false
        case .paused:
            text = "Health Token 已暂停"
            usesCountdownAccent = false
        }
    }
}

struct CodexIntegrationPresentation {
    let status: String
    let image: String
    let detail: String

    init(
        health: CodexIntegrationHealth,
        isObservationEnabled: Bool,
        noAgentFallbackEnabled: Bool
    ) {
        switch health {
        case .connected:
            status = "Codex 观察：已连接"
            image = "checkmark.circle.fill"
            detail = "只读取工作状态，不读取提示词、代码或工具参数。"
        case .fallbackOnly:
            image = "exclamationmark.circle"
            if isObservationEnabled {
                status = "Codex 观察：等待连接"
                detail = noAgentFallbackEnabled
                    ? "在 Codex 中输入 /hooks，并允许 Health Token。连接前，普通定时饮水提醒仍会工作。"
                    : "在 Codex 中输入 /hooks，并允许 Health Token。你已关闭无 Agent 提醒，连接前不会显示计时提醒。"
            } else {
                status = "Codex 观察：未启用"
                detail = "启用后，在 Codex 中输入 /hooks 并允许 Health Token。普通定时饮水提醒不受影响。"
            }
        case .unavailable:
            status = "Codex 观察：不可用"
            image = "xmark.circle"
            detail = "没有发现可用的本地 Codex；安装或启动 Codex 后可以再试。"
        }
    }
}

enum HydrationVolumeFormatter {
    static func bottleCapacity(_ milliliters: Int) -> String {
        if milliliters.isMultiple(of: 1_000) {
            return "\(milliliters / 1_000) L"
        }
        return "\(milliliters) mL"
    }
}
