import Foundation
import HealthTokenCore

struct HydrationMenuStatusPresentation {
    let text: String
    let usesCountdownAccent: Bool

    init(status: HydrationStatus, remainingTimeUntilReminder: TimeInterval) {
        switch status {
        case .accumulating:
            let remainingSeconds = Int(ceil(max(0, remainingTimeUntilReminder)))
            text = String(
                format: "%02d:%02d",
                remainingSeconds / 60,
                remainingSeconds % 60
            )
            usesCountdownAccent = true
        case .dueAmbient:
            text = "该喝水了"
            usesCountdownAccent = false
        case .dueStrong:
            text = "Codex 忙碌中"
            usesCountdownAccent = false
        case .snoozed:
            text = "已稍后"
            usesCountdownAccent = false
        case .paused:
            text = "已暂停"
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
        hasObservedEvent: Bool,
        isAgentActive: Bool,
        noAgentFallbackEnabled: Bool
    ) {
        if health == .unavailable {
            status = "Codex 观察：不可用"
            image = "xmark.circle"
            detail = "没有发现可用的本地 Codex；安装或启动 Codex 后可以再试。"
            return
        }

        guard isObservationEnabled else {
            status = "Codex 观察：未启用"
            image = "circle"
            detail = noAgentFallbackEnabled
                ? "启用后，Health Token 会自动配置本地连接。普通定时饮水提醒仍会工作。"
                : "启用后，Health Token 会自动配置本地连接。你已关闭无 Agent 提醒。"
            return
        }

        if isAgentActive {
            status = "Codex 观察：工作中"
            image = health == .connected
                ? "checkmark.circle.fill"
                : "checkmark.circle"
            detail = noAgentFallbackEnabled
                ? "检测到 Codex 正在工作；普通定时饮水提醒仍会工作。"
                : "检测到 Codex 正在工作；你已关闭无 Agent 提醒。"
            return
        }

        switch health {
        case .connected:
            status = "Codex 观察：已就绪"
            image = "checkmark.circle.fill"
            detail = "实时事件已验证；当前空闲。只读取工作状态，不读取提示词、代码或工具参数。"
        case .fallbackOnly where hasObservedEvent:
            status = "Codex 观察：已就绪"
            image = "checkmark.circle"
            detail = noAgentFallbackEnabled
                ? "本机 session 监听正常；当前空闲。普通定时饮水提醒仍会工作。"
                : "本机 session 监听正常；当前空闲。你已关闭无 Agent 提醒。"
        case .fallbackOnly:
            status = "Codex 观察：已就绪"
            image = "checkmark.circle"
            detail = noAgentFallbackEnabled
                ? "正在监听本机 Codex；识别到活动后会自动增强提醒。普通定时饮水提醒仍会工作。"
                : "正在监听本机 Codex；识别到活动后会自动增强提醒。你已关闭无 Agent 提醒。"
        case .unavailable:
            assertionFailure("Unavailable integrations return before enabled-state handling")
            status = "Codex 观察：不可用"
            image = "xmark.circle"
            detail = "没有发现可用的本地 Codex；安装或启动 Codex 后可以再试。"
        }
    }
}

struct CodexCompactAttentionPresentation {
    let health: CodexIntegrationHealth
    let isObservationEnabled: Bool
    let hasError: Bool

    var shouldShow: Bool {
        if !isObservationEnabled || health == .unavailable || hasError {
            return true
        }
        return false
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

enum BottleCapacityInput {
    static func parse(_ text: String) -> Int? {
        guard let milliliters = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (100...5_000).contains(milliliters) else {
            return nil
        }
        return milliliters
    }
}
