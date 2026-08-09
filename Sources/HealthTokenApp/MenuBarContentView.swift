import AppKit
import HealthTokenCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: HydrationAppModel

    var body: some View {
        Text(statusPresentation.text)
            .foregroundStyle(
                statusPresentation.usesCountdownAccent ? Color.blue : Color.primary
            )
        Text("今日估算总量：约 \(model.snapshot.todayEstimatedMilliliters) mL")

        Button("我刚喝了一口 · 约 \(sipMilliliters) mL") {
            model.recordProactiveSip()
        }
        .accessibilityLabel(ReminderControlName.drink(sipMilliliters: sipMilliliters))

        Button("喝完一瓶 · \(formattedBottleCapacity)") {
            model.completeBottle()
        }
        .accessibilityLabel("喝完一瓶，校准到下一个 \(formattedBottleCapacity) 节点")

        if let record = model.snapshot.undoableDrinkRecord {
            Button("撤销刚才的记录 · 约 \(record.estimatedMilliliters) mL") {
                model.undoDrink(record.id)
            }
        }

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

        if let persistenceError = model.persistenceError {
            Divider()
            Text(persistenceError)
        }

        Divider()

        Button("退出 Health Token") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var statusPresentation: HydrationMenuStatusPresentation {
        HydrationMenuStatusPresentation(
            status: model.snapshot.status,
            remainingTimeUntilReminder: model.snapshot.remainingTimeUntilReminder
        )
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

    private var sipMilliliters: Int {
        model.snapshot.settings.sipEstimate.milliliters
    }

    private var formattedBottleCapacity: String {
        HydrationVolumeFormatter.bottleCapacity(
            model.snapshot.settings.bottleCapacityMilliliters
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
