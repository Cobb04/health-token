import AppKit
import HealthTokenCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: HydrationAppModel

    var body: some View {
        Text(statusText)
        Text("今日估算总量：约 \(model.snapshot.todayEstimatedMilliliters) mL")

        Divider()

        Button(model.snapshot.status == .paused ? "恢复 Health Token" : "暂停 Health Token") {
            model.setPaused(model.snapshot.status != .paused)
        }
        .accessibilityLabel(
            model.snapshot.status == .paused ? "恢复 Health Token" : "暂停 Health Token"
        )

        Divider()

        Label(
            integrationPresentation.status,
            systemImage: integrationPresentation.image
        )
        Text(integrationPresentation.detail)
            .font(.caption)
            .foregroundStyle(.secondary)

        if model.isCodexObservationEnabled {
            Button("停用 Codex 观察") {
                model.disableCodexObservation()
            }
        } else {
            Button("启用 Codex 观察") {
                model.enableCodexObservation()
            }
        }

        if let integrationError = model.integrationError {
            Text(integrationError)
                .font(.caption)
        }

        Divider()

        Picker("每口估算", selection: sipEstimate) {
            ForEach(SipEstimate.allCases, id: \.self) { estimate in
                Text("约 \(estimate.milliliters) mL").tag(estimate)
            }
        }
        .accessibilityLabel("每口饮水估算设置")

        Picker("提醒间隔", selection: reminderInterval) {
            ForEach(Self.reminderIntervalOptions, id: \.self) { interval in
                Text("\(Int(interval / 60)) 分钟").tag(interval)
            }
        }
        .accessibilityLabel("饮水提醒间隔设置")

        Toggle("无 Agent 时显示低干扰提醒", isOn: noAgentFallbackEnabled)
            .accessibilityLabel("无 Agent 时显示低干扰提醒")

        if let persistenceError = model.persistenceError {
            Divider()
            Text(persistenceError)
        }

        Divider()

        Button("退出 Health Token") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var statusText: String {
        switch model.snapshot.status {
        case .accumulating:
            "下一次低干扰提醒正在计时"
        case .dueAmbient:
            "低干扰饮水提醒已显示"
        case .dueStrong:
            "Codex 持续工作，饮水强提醒已显示"
        case .snoozed:
            "强提醒已稍后，饮水仍到期"
        case .paused:
            "Health Token 已暂停"
        }
    }

    private var sipEstimate: Binding<SipEstimate> {
        Binding(
            get: { model.snapshot.settings.sipEstimate },
            set: { model.setSipEstimate($0) }
        )
    }

    private var integrationPresentation: (
        status: String,
        image: String,
        detail: String
    ) {
        switch model.integrationHealth {
        case .connected:
            (
                "Codex 观察：已连接",
                "checkmark.circle.fill",
                "仅接收会话、角色、注意力和工具分类元数据。"
            )
        case .fallbackOnly:
            if model.snapshot.settings.noAgentFallbackEnabled {
                (
                    "Codex 观察：仅低干扰兜底",
                    "exclamationmark.circle",
                    model.isCodexObservationEnabled
                        ? "等待 Codex /hooks 信任确认或首个生命周期事件；饮水到期仍保持 B。"
                        : "Codex 事件未连接；饮水到期仍只显示低干扰提醒。"
                )
            } else {
                (
                    "Codex 观察：等待事件",
                    "exclamationmark.circle",
                    model.isCodexObservationEnabled
                        ? "等待 Codex 生命周期事件；收到活动后只显示低干扰提醒。"
                        : "Codex 事件未连接，且无 Agent 兜底已关闭。"
                )
            }
        case .unavailable:
            (
                "Codex 观察：不可用",
                "xmark.circle",
                "未发现可用的本地 Codex 会话；可安装 Codex 后再启用。"
            )
        }
    }

    private var reminderInterval: Binding<TimeInterval> {
        Binding(
            get: { model.snapshot.settings.reminderInterval },
            set: { model.setReminderInterval($0) }
        )
    }

    private var noAgentFallbackEnabled: Binding<Bool> {
        Binding(
            get: { model.snapshot.settings.noAgentFallbackEnabled },
            set: { model.setNoAgentFallbackEnabled($0) }
        )
    }

    private static let reminderIntervalOptions: [TimeInterval] = [
        15 * 60,
        30 * 60,
        45 * 60,
        60 * 60
    ]
}
