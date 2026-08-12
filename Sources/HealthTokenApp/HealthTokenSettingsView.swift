import AppKit
import HealthTokenCore
import SwiftUI

struct HealthTokenSettingsView: View {
    @ObservedObject var model: HydrationAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            DailyHydrationHeatmapView(
                summaries: model.snapshot.recentDailySummaries,
                trackingStartedAt: model.snapshot.records.map(\.timestamp).min(),
                bottleCapacity: model.snapshot.settings.bottleCapacityMilliliters
            )
                hydrationSettings
                codexSettings

                if let persistenceError = model.persistenceError {
                    settingsCard("本地记录") {
                    Text(persistenceError)
                        .foregroundStyle(.red)
                    }
                }

                Button("退出 Health Token") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 430, height: 560)
        .onAppear {
            model.refreshTemporalState()
        }
    }

    private var hydrationSettings: some View {
        settingsCard("饮水设置") {
            settingsRow("每口估算") {
                Picker("每口估算", selection: sipEstimate) {
                    ForEach(SipEstimate.allCases, id: \.self) { estimate in
                        Text("约 \(estimate.milliliters) mL").tag(estimate)
                    }
                }
                .labelsHidden()
                .frame(width: 126)
                .accessibilityLabel("每口饮水估算设置")
            }

            Divider()

            settingsRow("水瓶容量") {
                Picker("水瓶容量", selection: bottleCapacityMilliliters) {
                    ForEach(bottleCapacityOptions, id: \.self) { capacity in
                        Text(HydrationVolumeFormatter.bottleCapacity(capacity)).tag(capacity)
                    }
                }
                .labelsHidden()
                .frame(width: 126)
                .accessibilityLabel("水瓶容量设置")
            }

            Divider()

            Button {
                promptForBottleCapacity()
            } label: {
                HStack {
                    Text("自定义水瓶容量…")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            settingsRow("提醒间隔") {
                Picker("提醒间隔", selection: reminderInterval) {
                    ForEach(HydrationSettings.reminderIntervalOptions, id: \.self) { interval in
                        Text("\(Int(interval / 60)) 分钟").tag(interval)
                    }
                }
                .labelsHidden()
                .frame(width: 126)
                .accessibilityLabel("饮水提醒间隔设置")
            }

            Divider()

            settingsRow("无 Agent 时显示低干扰提醒") {
                Toggle("", isOn: noAgentFallbackEnabled)
                    .labelsHidden()
                    .accessibilityLabel("无 Agent 时显示低干扰提醒")
            }
        }
    }

    private var codexSettings: some View {
        settingsCard("Codex") {
            Label(
                integrationPresentation.status,
                systemImage: integrationPresentation.image
            )

            Text(integrationPresentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button(model.isCodexObservationEnabled ? "停用 Codex 观察" : "启用 Codex 观察") {
                if model.isCodexObservationEnabled {
                    model.disableCodexObservation()
                } else {
                    model.enableCodexObservation()
                }
            }

            if let integrationError = model.integrationError {
                Text(integrationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func settingsRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 34)
    }

    private func settingsCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.82),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.58), lineWidth: 1)
            }
        }
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
            isAgentActive: model.isCodexAgentActive,
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
