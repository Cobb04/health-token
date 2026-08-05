import HealthTokenCore
import SwiftUI

struct AmbientReminderView: View {
    @ObservedObject var model: HydrationAppModel
    let onIntentionalInteraction: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if model.snapshot.reminderLevel == .confirmation {
                confirmationCard
            } else if model.snapshot.reminderLevel == .strong {
                strongReminder
            } else if model.snapshot.detailsExpanded {
                detailsCard
            } else {
                dropButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(transitionIdentity)
        .transition(reminderTransition)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28),
            value: transitionIdentity
        )
    }

    private var strongReminder: some View {
        HStack(spacing: 14) {
            HealthTokenPixelCharacter()
                .frame(width: 82, height: 82)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Codex 还在忙，喝一口吧")
                    .font(.headline)
                Text("本次记录约 \(sipMilliliters) mL")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: { intentionally(model.confirmSip) }) {
                    Label("喝了一口", systemImage: "cup.and.saucer.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .accessibilityLabel(ReminderControlName.drink(sipMilliliters: sipMilliliters))
                .keyboardShortcut(.defaultAction)
            }
        }
        .modifier(ReminderCardStyle(appearance: appearance))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityPresentation.nonColorCue)
    }

    private var dropButton: some View {
        Button(action: { intentionally(model.openReminder) }) {
            ZStack {
                Image(systemName: "drop.fill")
                if model.snapshot.status == .snoozed {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .offset(x: 12, y: 11)
                } else if model.integrationHealth == .unavailable {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 10, weight: .black))
                }
            }
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(contrast == .increased ? Color.white : Color.cyan)
                .shadow(
                    color: appearance.showsGlow ? .cyan.opacity(0.7) : .clear,
                    radius: reduceMotion ? 2 : 7
                )
                .frame(width: 42, height: 42)
                .background(.black.opacity(appearance.dropBackgroundOpacity), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(accessibilityPresentation.nonColorCue)，点击展开")
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("喝一口水", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Spacer()
                Button(action: { intentionally(model.closeReminder) }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起饮水提醒")
            }

            Text("本次将记录约 \(sipMilliliters) mL")
                .font(.subheadline)
            Text("今日估算总量：约 \(model.snapshot.todayEstimatedMilliliters) mL")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: { intentionally(model.confirmSip) }) {
                Text("喝了一口 · 约 \(sipMilliliters) mL")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .accessibilityLabel(ReminderControlName.drink(sipMilliliters: sipMilliliters))
            .keyboardShortcut(.defaultAction)

            Button(action: { intentionally(model.snooze) }) {
                Text("稍后 · 15 分钟")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(ReminderControlName.snooze)
            .keyboardShortcut("s", modifiers: [])

            HStack {
                Button("暂停") {
                    intentionally { model.setPaused(true) }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(ReminderControlName.pause)
                .keyboardShortcut("p", modifiers: [])

                Spacer()

                settingsMenu
            }
        }
        .modifier(ReminderCardStyle(appearance: appearance))
    }

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("已记录约 \(confirmedMilliliters) mL", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.cyan)
            Text("今日估算总量：约 \(model.snapshot.todayEstimatedMilliliters) mL")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let record = model.snapshot.undoableDrinkRecord {
                Button("撤销刚才的记录") {
                    intentionally { model.undoSip(record.id) }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(
                    ReminderControlName.undo(sipMilliliters: confirmedMilliliters)
                )
                .keyboardShortcut("z", modifiers: [])
            }
        }
        .modifier(ReminderCardStyle(appearance: appearance))
    }

    private var sipMilliliters: Int {
        model.snapshot.settings.sipEstimate.milliliters
    }

    private var confirmedMilliliters: Int {
        model.snapshot.undoableDrinkRecord?.estimatedMilliliters ?? 0
    }

    private var appearance: ReminderAppearancePolicy {
        ReminderAppearancePolicy(increasedContrast: contrast == .increased)
    }

    private var settingsMenu: some View {
        Menu("设置") {
            Picker("每口估算", selection: sipEstimate) {
                ForEach(SipEstimate.allCases, id: \.self) { estimate in
                    Text("约 \(estimate.milliliters) mL").tag(estimate)
                }
            }
            Picker("提醒间隔", selection: reminderInterval) {
                ForEach(HydrationSettings.reminderIntervalOptions, id: \.self) { interval in
                    Text("\(Int(interval / 60)) 分钟").tag(interval)
                }
            }
        }
        .accessibilityLabel(ReminderControlName.settings)
        .keyboardShortcut(",", modifiers: [.command])
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

    private var accessibilityPresentation: ReminderAccessibilityCue {
        ReminderAccessibilityCue(
            status: model.snapshot.status,
            reminderLevel: model.snapshot.reminderLevel,
            integrationHealth: model.integrationHealth
        )
    }

    private var transitionIdentity: String {
        "\(model.snapshot.reminderLevel.rawValue)-\(model.snapshot.detailsExpanded)"
    }

    private var reminderTransition: AnyTransition {
        let policy = ReminderTransitionPolicy(reduceMotion: reduceMotion)
        return policy.usesScale
            ? .scale(scale: 0.96, anchor: .top).combined(with: .opacity)
            : .opacity
    }

    private func intentionally(_ action: () -> Void) {
        onIntentionalInteraction()
        action()
    }

}

private struct HealthTokenPixelCharacter: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(red: 0.08, green: 0.78, blue: 0.88))
                .frame(width: 48, height: 44)
                .offset(x: -8, y: 7)
            Rectangle()
                .fill(Color(red: 0.18, green: 0.9, blue: 0.98))
                .frame(width: 36, height: 10)
                .offset(x: -8, y: -20)
            Rectangle()
                .fill(.black)
                .frame(width: 6, height: 6)
                .offset(x: -19, y: -3)
            Rectangle()
                .fill(.black)
                .frame(width: 6, height: 6)
                .offset(x: -1, y: -3)
            Rectangle()
                .fill(.white)
                .frame(width: 18, height: 5)
                .offset(x: -10, y: 12)
            Rectangle()
                .fill(Color(red: 0.08, green: 0.78, blue: 0.88))
                .frame(width: 14, height: 9)
                .offset(x: 23, y: 13)
            Rectangle()
                .fill(.white)
                .frame(width: 22, height: 27)
                .offset(x: 27, y: 24)
            Rectangle()
                .fill(Color.cyan.opacity(0.75))
                .frame(width: 16, height: 10)
                .offset(x: 27, y: 29)
            Rectangle()
                .stroke(.white, lineWidth: 4)
                .frame(width: 10, height: 15)
                .offset(x: 42, y: 22)
        }
        .accessibilityLabel("Health Token 像素角色举着水杯")
    }
}

private struct ReminderCardStyle: ViewModifier {
    let appearance: ReminderAppearancePolicy

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(appearance.cardBorderOpacity))
            )
            .padding(4)
    }
}
