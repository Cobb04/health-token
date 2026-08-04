import AppKit
import HealthTokenCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: HydrationAppModel

    var body: some View {
        Text(statusText)
        Text("今日估算总量：约 \(model.snapshot.todayEstimatedMilliliters) mL")

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

        Text("每口估算：约 \(model.snapshot.settings.sipEstimate.milliliters) mL")
        Text("提醒间隔：\(reminderMinutes) 分钟")

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
        }
    }

    private var reminderMinutes: Int {
        Int(model.snapshot.settings.reminderInterval / 60)
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
            (
                "Codex 观察：仅低干扰兜底",
                "exclamationmark.circle",
                model.isCodexObservationEnabled
                    ? "等待 Codex /hooks 信任确认或首个生命周期事件；饮水到期仍保持 B。"
                    : "Codex 事件未连接；饮水到期仍只显示低干扰提醒。"
            )
        case .unavailable:
            (
                "Codex 观察：不可用",
                "xmark.circle",
                "未发现可用的本地 Codex 会话；可安装 Codex 后再启用。"
            )
        }
    }
}
