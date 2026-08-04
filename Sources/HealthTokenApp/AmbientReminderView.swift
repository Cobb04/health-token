import HealthTokenCore
import SwiftUI

struct AmbientReminderView: View {
    @ObservedObject var model: HydrationAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if model.snapshot.detailsExpanded {
                detailsCard
            } else {
                dropButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(contrast == .increased ? .white : .white.opacity(0.18))
        )
        .padding(4)
    }

    private var sipMilliliters: Int {
        model.snapshot.settings.sipEstimate.milliliters
    }
}
