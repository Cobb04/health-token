import AppKit
import HealthTokenCore
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: HydrationAppModel
    private let onPreferredSizeChange: (CGSize) -> Void
    private let presentSettingsOverride: (() -> Void)?

    init(
        model: HydrationAppModel,
        onPreferredSizeChange: @escaping (CGSize) -> Void = { _ in },
        presentSettings: (() -> Void)? = nil
    ) {
        self.model = model
        self.onPreferredSizeChange = onPreferredSizeChange
        self.presentSettingsOverride = presentSettings
    }

    var body: some View {
        overview
        .frame(
            width: HealthConsolePresentation.overviewSize.width,
            height: HealthConsolePresentation.overviewSize.height
        )
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: 23,
                bottomTrailingRadius: 23,
                style: .continuous
            )
        )
        .background(Color.clear)
        .onAppear {
            model.refreshTemporalState()
            onPreferredSizeChange(HealthConsolePresentation.overviewSize)
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            HStack(spacing: 15) {
                AgentStateBadge(state: wellbeingState)

                VStack(alignment: .leading, spacing: 7) {
                    Text(wellbeingState.title)
                        .font(.system(size: 25, weight: wellbeingState == .thriving ? .black : .bold))
                        .tracking(-0.8)
                        .foregroundStyle(wellbeingState.color)

                    Text("cost your token, not health.")
                        .font(.custom("Iowan Old Style", size: 14.5))
                        .tracking(-0.15)
                        .foregroundStyle(Color.white.opacity(0.48))
                }

                Spacer(minLength: 8)

                Button(action: presentSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.68))
                        .frame(width: 49, height: 49)
                        .background(Color.white.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
            }
            .frame(height: 84)
            .padding(.horizontal, 20)

            Divider()
                .overlay(Color.white.opacity(0.13))
                .padding(.horizontal, 20)
                .padding(.top, 18)

            HStack(spacing: 16) {
                WaterOverviewMetric(
                    todayMilliliters: model.snapshot.todayEstimatedMilliliters,
                    goalMilliliters: waterGoalMilliliters,
                    countdownText: countdownText,
                    isPaused: model.snapshot.status == .paused,
                    quickSip: {
                        model.recordProactiveSip()
                    },
                    togglePause: {
                        model.setPaused(model.snapshot.status != .paused)
                    },
                    completeBottle: model.completeBottle
                )

                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 1, height: 66)

                MovementOverviewMetric()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(Color.black)
    }

    private var wellbeingState: HealthConsoleWellbeingState {
        HealthConsoleWellbeingState.resolve(
            waterProgress: Double(model.snapshot.todayEstimatedMilliliters)
                / Double(waterGoalMilliliters),
            movementProgress: nil
        )
    }

    private var waterGoalMilliliters: Int { 2_000 }

    private var countdownText: String {
        HydrationMenuStatusPresentation(
            status: model.snapshot.status,
            remainingTimeUntilReminder: model.snapshot.remainingTimeUntilReminder
        ).text
    }

    private func presentSettings() {
        if let presentSettingsOverride {
            presentSettingsOverride()
            return
        }
        SettingsWindowPresentation(
            activateApplication: activateApplication,
            openWindow: { openWindow(id: HealthTokenSettingsWindow.id) }
        ).present()
    }

    private func activateApplication() {
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

private struct AgentStateBadge: View {
    let state: HealthConsoleWellbeingState

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(cardColor)
                .frame(width: 84, height: 84)

            if let image = bundledImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(imagePadding)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            }

            Text(modelLabel)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(labelColor.opacity(0.91), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                .padding(.bottom, 6)

            if state == .depleted {
                Text("💧")
                    .font(.system(size: 29))
                    .offset(x: 38, y: -64)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 84, height: 84)
        .shadow(color: shadowColor, radius: 12, y: 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.agentName)，\(modelLabel)")
    }

    private var resourceName: String {
        switch state {
        case .depleted: "gemini-spark"
        case .steady: "deepseek"
        case .thriving: "codex-dark"
        }
    }

    private var bundledImage: NSImage? {
        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: "png"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var modelLabel: String {
        switch state {
        case .depleted: "3.6 Flash"
        case .steady: "V4 Pro 0813"
        case .thriving: "⚡ 5.6 Sol Ultra"
        }
    }

    private var cardColor: Color {
        state == .thriving ? Color(red: 0.07, green: 0.07, blue: 0.075) : .white
    }

    private var labelColor: Color {
        switch state {
        case .depleted: Color(red: 0.10, green: 0.11, blue: 0.14)
        case .steady: Color(red: 0.10, green: 0.18, blue: 0.48)
        case .thriving: .black
        }
    }

    private var shadowColor: Color {
        switch state {
        case .depleted: .black.opacity(0.24)
        case .steady: Color(red: 0.12, green: 0.28, blue: 0.75).opacity(0.35)
        case .thriving: .black.opacity(0.3)
        }
    }

    private var imagePadding: CGFloat {
        switch state {
        case .depleted: 11
        case .steady: 0
        case .thriving: -8
        }
    }
}

private struct WaterOverviewMetric: View {
    let todayMilliliters: Int
    let goalMilliliters: Int
    let countdownText: String
    let isPaused: Bool
    let quickSip: () -> Void
    let togglePause: () -> Void
    let completeBottle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Label("WATER", systemImage: "drop")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.monochrome)

                Text(countdownText)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.25)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)

                Spacer()

                Button(action: togglePause) {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(WaterOverviewControlStyle())
                .help(isPaused ? "恢复饮水提醒" : "暂停饮水提醒")
                .accessibilityLabel(isPaused ? "恢复饮水提醒" : "暂停饮水提醒")

                Button(action: completeBottle) {
                    Text("🥛")
                        .font(.system(size: 16))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(WaterOverviewControlStyle(accented: true))
                .help("喝完一瓶")
                .accessibilityLabel("喝完一瓶")

                Button(action: quickSip) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(WaterOverviewControlStyle())
                .accessibilityLabel("直接记录一口")
            }

            VStack(alignment: .leading, spacing: 18) {
                Text(volumeLabel)
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color(red: 0.37, green: 0.84, blue: 0.97))
                                .frame(width: proxy.size.width * progress)
                        }
                }
                .frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var progress: CGFloat {
        min(1, CGFloat(todayMilliliters) / CGFloat(goalMilliliters))
    }

    private var volumeLabel: String {
        String(format: "%.2g/2L", Double(todayMilliliters) / 1_000)
            .replacingOccurrences(of: "e+00", with: "")
    }
}

private struct MovementOverviewMetric: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("MOVEMENT", systemImage: "figure.stand")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Color.white.opacity(0.54))
                .symbolRenderingMode(.multicolor)

            Text("0/8")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 12)

            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(height: 6)
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Movement 尚未接入")
    }
}

private struct WaterOverviewControlStyle: ButtonStyle {
    var accented = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.72 : 0.92))
            .background(
                accented
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.25 : 0.14)
                    : Color.white.opacity(configuration.isPressed ? 0.18 : 0.1)
            )
            .overlay {
                if accented {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.42), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private extension HealthConsoleWellbeingState {
    var title: String {
        switch self {
        case .depleted: "拉完了！"
        case .steady: "还行吧..."
        case .thriving: "夯！"
        }
    }

    var agentName: String {
        switch self {
        case .depleted: "Gemini"
        case .steady: "DeepSeek"
        case .thriving: "Codex"
        }
    }

    var color: Color {
        switch self {
        case .depleted: Color(red: 0.64, green: 0.24, blue: 0.27)
        case .steady: Color(red: 0.30, green: 0.42, blue: 1)
        case .thriving: Color(red: 0.91, green: 0.73, blue: 0.25)
        }
    }
}
