import AppKit
import HealthTokenCore
import SwiftUI

struct HealthTokenSettingsView: View {
    @ObservedObject var model: HydrationAppModel

    var body: some View {
        Form {
            Section("饮水") {
                LabeledContent("今日估算总量") {
                    Text("约 \(model.snapshot.todayEstimatedMilliliters) mL")
                }

                Picker("每口估算", selection: sipEstimate) {
                    ForEach(SipEstimate.allCases, id: \.self) { estimate in
                        Text("约 \(estimate.milliliters) mL").tag(estimate)
                    }
                }
                .accessibilityLabel("每口饮水估算设置")

                Picker("水瓶容量", selection: bottleCapacityMilliliters) {
                    ForEach(bottleCapacityOptions, id: \.self) { capacity in
                        Text(HydrationVolumeFormatter.bottleCapacity(capacity)).tag(capacity)
                    }
                }
                .accessibilityLabel("水瓶容量设置")

                Button("自定义水瓶容量…") {
                    promptForBottleCapacity()
                }

                Picker("提醒间隔", selection: reminderInterval) {
                    ForEach(HydrationSettings.reminderIntervalOptions, id: \.self) { interval in
                        Text("\(Int(interval / 60)) 分钟").tag(interval)
                    }
                }
                .accessibilityLabel("饮水提醒间隔设置")

                Toggle("无 Agent 时显示低干扰提醒", isOn: noAgentFallbackEnabled)
                    .accessibilityLabel("无 Agent 时显示低干扰提醒")
            }

            Section("Codex") {
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
                        .foregroundStyle(.red)
                }
            }

            if let persistenceError = model.persistenceError {
                Section("本地记录") {
                    Text(persistenceError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("退出 Health Token") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 440)
    }

    private var sipEstimate: Binding<SipEstimate> {
        Binding(
            get: { model.snapshot.settings.sipEstimate },
            set: { model.setSipEstimate($0) }
        )
    }

    private var integrationPresentation: CodexIntegrationPresentation {
        CodexIntegrationPresentation(
            health: model.integrationHealth,
            isObservationEnabled: model.isCodexObservationEnabled,
            hasObservedEvent: model.hasObservedCodexEvent,
            noAgentFallbackEnabled: model.snapshot.settings.noAgentFallbackEnabled
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

    private var bottleCapacityMilliliters: Binding<Int> {
        Binding(
            get: { model.snapshot.settings.bottleCapacityMilliliters },
            set: { model.setBottleCapacityMilliliters($0) }
        )
    }

    private var bottleCapacityOptions: [Int] {
        Array(
            Set(
                HydrationSettings.bottleCapacityOptions
                    + [model.snapshot.settings.bottleCapacityMilliliters]
            )
        ).sorted()
    }

    private func promptForBottleCapacity() {
        let field = NSTextField(string: String(model.snapshot.settings.bottleCapacityMilliliters))
        field.placeholderString = "例如 600"

        let alert = NSAlert()
        alert.messageText = "自定义水瓶容量"
        alert.informativeText = "请输入 100–5000 mL。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let capacity = BottleCapacityInput.parse(field.stringValue) else {
            let error = NSAlert()
            error.messageText = "容量无效"
            error.informativeText = "请输入 100–5000 之间的整数毫升数。"
            error.runModal()
            return
        }
        model.setBottleCapacityMilliliters(capacity)
    }
}
