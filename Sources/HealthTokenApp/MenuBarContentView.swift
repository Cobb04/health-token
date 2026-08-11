import AppKit
import HealthTokenCore
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: HydrationAppModel

    var body: some View {
        VStack(spacing: 0) {
            header

            if codexNeedsAttention {
                codexAttentionButton
                    .padding(.top, 10)
            }

            proactiveSipButton
                .padding(.top, 13)

            contextRow
                .padding(.top, 9)

            if let persistenceError = model.persistenceError {
                Text(persistenceError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }

            Divider()
                .padding(.top, 7)

            toolbar
                .padding(.top, 7)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 11)
        .frame(width: 264)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear {
            model.refreshTemporalState()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(statusPresentation.text)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(
                    statusPresentation.usesCountdownAccent ? Color.accentColor : Color.primary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 4)

            Text("今日 \(model.snapshot.todayEstimatedMilliliters) mL")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var proactiveSipButton: some View {
        Button {
            model.recordProactiveSip()
        } label: {
            HStack(spacing: 12) {
                Text("＋ 一口")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("记录 \(sipMilliliters) mL")
                    .font(.system(size: 10.5, weight: .regular))
                    .opacity(0.76)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(CompactPrimaryButtonStyle())
        .accessibilityLabel(ReminderControlName.drink(sipMilliliters: sipMilliliters))
    }

    @ViewBuilder
    private var contextRow: some View {
        HStack(spacing: 8) {
            if let record = model.snapshot.undoableDrinkRecord {
                Text("已记录 ＋\(record.estimatedMilliliters) mL")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Spacer(minLength: 0)

                Button {
                    model.undoDrink(record.id)
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(CompactTextButtonStyle())
                .accessibilityLabel("撤销刚才的饮水记录")
            } else {
                Text("cost your token, not health.")
                    .font(.custom("Iowan Old Style", size: 12))
                    .tracking(-0.14)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    model.completeBottle()
                } label: {
                    Text("🥛")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(CompactIconButtonStyle())
                .help("喝完一瓶 · \(formattedBottleCapacity)")
                .accessibilityLabel("喝完一瓶")
                .accessibilityHint("校准到下一个 \(formattedBottleCapacity) 节点")
            }
        }
        .frame(minHeight: 24)
    }

    private var codexAttentionButton: some View {
        Button(action: presentSettings) {
            codexAttentionLabelView
        }
        .buttonStyle(.plain)
    }

    private var codexAttentionLabelView: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle")
            Text(codexAttentionLabel)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(codexAttentionLabel)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                model.setPaused(model.snapshot.status != .paused)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.snapshot.status == .paused ? "play.fill" : "pause.fill")
                        .frame(width: 14, height: 14)
                    Text(model.snapshot.status == .paused ? "恢复" : "暂停")
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .frame(height: 25)
            }
            .buttonStyle(CompactToolbarButtonStyle())
            .accessibilityLabel(
                model.snapshot.status == .paused ? "恢复 Health Token" : "暂停 Health Token"
            )

            Spacer(minLength: 0)

            settingsButton
        }
    }

    private var settingsButton: some View {
        Button(action: presentSettings) {
            settingsButtonLabel
        }
        .buttonStyle(CompactToolbarButtonStyle())
    }

    private var settingsButtonLabel: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 28, height: 25)
            .contentShape(Rectangle())
            .accessibilityLabel("设置")
    }

    private var statusPresentation: HydrationMenuStatusPresentation {
        HydrationMenuStatusPresentation(
            status: model.snapshot.status,
            remainingTimeUntilReminder: model.snapshot.remainingTimeUntilReminder
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

    private var codexNeedsAttention: Bool {
        CodexCompactAttentionPresentation(
            health: model.integrationHealth,
            isObservationEnabled: model.isCodexObservationEnabled,
            hasObservedEvent: model.hasObservedCodexEvent,
            hasError: model.integrationError != nil
        ).shouldShow
    }

    private var codexAttentionLabel: String {
        if model.integrationHealth == .unavailable {
            return "Codex 观察不可用"
        }
        if !model.isCodexObservationEnabled {
            return "启用 Codex 观察"
        }
        return "Codex 需连接"
    }

    private func presentSettings() {
        let presentation = SettingsWindowPresentation(
            activateApplication: activateApplication,
            openWindow: { openWindow(id: HealthTokenSettingsWindow.id) }
        )
        presentation.present()
    }

    private func activateApplication() {
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

private struct CompactPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.2), radius: 4, y: 2)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

private struct CompactTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct CompactIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.accentColor.opacity(0.18)
                    : Color.accentColor.opacity(0.1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct CompactToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(configuration.isPressed ? Color.secondary.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
