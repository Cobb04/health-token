import HealthTokenCore
import SwiftUI

struct AmbientReminderView: View {
    @ObservedObject var model: HydrationAppModel
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

                Button(action: model.confirmSip) {
                    Label("喝了一口", systemImage: "cup.and.saucer.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .accessibilityLabel("喝了一口，记录约 \(sipMilliliters) 毫升")
            }
        }
        .modifier(ReminderCardStyle(increasedContrast: contrast == .increased))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("强饮水提醒")
    }

    private var dropButton: some View {
        Button(action: model.openReminder) {
            Image(systemName: "drop.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(contrast == .increased ? Color.white : Color.cyan)
                .shadow(
                    color: contrast == .increased ? .clear : .cyan.opacity(0.7),
                    radius: reduceMotion ? 2 : 7
                )
                .frame(width: 42, height: 42)
                .background(.black.opacity(contrast == .increased ? 0.95 : 0.82), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("饮水提醒，点击展开")
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("喝一口水", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Spacer()
                Button(action: model.closeReminder) {
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

            Button(action: model.confirmSip) {
                Text("喝了一口 · 约 \(sipMilliliters) mL")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .accessibilityLabel("喝了一口，记录约 \(sipMilliliters) 毫升")

            Button(action: model.snooze) {
                Text("稍后 · 15 分钟")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("稍后提醒，强提醒暂停十五分钟")
        }
        .modifier(ReminderCardStyle(increasedContrast: contrast == .increased))
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
                    model.undoSip(record.id)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("撤销刚才约 \(confirmedMilliliters) 毫升的饮水记录")
            }
        }
        .modifier(ReminderCardStyle(increasedContrast: contrast == .increased))
    }

    private var sipMilliliters: Int {
        model.snapshot.settings.sipEstimate.milliliters
    }

    private var confirmedMilliliters: Int {
        model.snapshot.undoableDrinkRecord?.estimatedMilliliters ?? 0
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
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(increasedContrast ? .white : .white.opacity(0.18))
            )
            .padding(4)
    }
}
