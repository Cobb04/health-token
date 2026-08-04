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

        Divider()

        Picker("每口估算", selection: sipEstimate) {
            ForEach(SipEstimate.allCases, id: \.self) { estimate in
                Text("约 \(estimate.milliliters) mL").tag(estimate)
            }
        }

        Picker("提醒间隔", selection: reminderInterval) {
            ForEach(Self.reminderIntervalOptions, id: \.self) { interval in
                Text("\(Int(interval / 60)) 分钟").tag(interval)
            }
        }

        Toggle("无 Agent 时显示低干扰提醒", isOn: noAgentFallbackEnabled)

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
