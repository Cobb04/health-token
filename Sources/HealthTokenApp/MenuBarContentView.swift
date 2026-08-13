import AppKit
import HealthTokenCore
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: HydrationAppModel
    @State private var console: HealthConsolePresentation
    private let onPreferredSizeChange: (CGSize) -> Void
    private let presentSettingsOverride: (() -> Void)?

    init(
        model: HydrationAppModel,
        initialSurface: HealthConsolePresentation.Surface = .overview,
        onPreferredSizeChange: @escaping (CGSize) -> Void = { _ in },
        presentSettings: (() -> Void)? = nil
    ) {
        self.model = model
        self.onPreferredSizeChange = onPreferredSizeChange
        self.presentSettingsOverride = presentSettings
        _console = State(
            initialValue: HealthConsolePresentation(surface: initialSurface)
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            if console.surface == .water {
                WaterConsoleView(
                    model: model,
                    presentSettings: presentSettings,
                    collapse: { console.send(.collapseWater) }
                )
                .frame(
                    width: console.waterDrawerFrame.width,
                    height: console.waterDrawerFrame.height
                )
                .offset(y: console.waterDrawerFrame.minY)
                .zIndex(1)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .offset(y: -console.waterDrawerFrame.height)
                            .combined(with: .opacity)
                )
            }

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
                .zIndex(2)
        }
        .frame(
            width: console.preferredSize.width,
            height: console.preferredSize.height,
            alignment: .top
        )
        .background(Color.clear)
        .animation(
            reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86),
            value: console.surface
        )
        .onAppear {
            model.refreshTemporalState()
            onPreferredSizeChange(console.preferredSize)
        }
        .onChange(of: console.preferredSize) { newSize in
            onPreferredSizeChange(newSize)
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            HStack(spacing: 15) {
                AgentStateBadge(state: wellbeingState)

                Text(wellbeingState.title)
                    .font(.system(size: 25, weight: wellbeingState == .thriving ? .black : .bold))
                    .tracking(-0.8)
                    .foregroundStyle(wellbeingState.color)

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
                    quickSip: {
                        console.send(.quickSip)
                        model.recordProactiveSip()
                    },
                    selectWater: { console.send(.selectWater) }
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
    let quickSip: () -> Void
    let selectWater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: selectWater) {
                    Label("WATER", systemImage: "drop")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(Color.white.opacity(0.54))
                        .symbolRenderingMode(.monochrome)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: quickSip) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("直接记录一口")
            }

            Button(action: selectWater) {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

private struct WaterConsoleView: View {
    @ObservedObject var model: HydrationAppModel
    let presentSettings: () -> Void
    let collapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(countdownText)
                    .font(.system(size: 33, weight: .semibold))
                    .tracking(-1.2)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)

                Spacer()

                Text("今日 \(model.snapshot.todayEstimatedMilliliters) mL")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
            }

            Button(action: model.recordProactiveSip) {
                Text("＋ 一口")
                    .font(.system(size: 20, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 66)
            }
            .buttonStyle(WaterPrimaryButtonStyle())
            .padding(.top, 20)

            HStack {
                if let record = model.snapshot.undoableDrinkRecord {
                    Text("已记录约 \(record.estimatedMilliliters) mL")
                        .font(.custom("Iowan Old Style", size: 17))
                        .foregroundStyle(Color(nsColor: .labelColor))

                    Spacer()

                    Button("撤销") { model.undoDrink(record.id) }
                        .buttonStyle(WaterTextButtonStyle())
                } else {
                    Text("cost your token, not health.")
                        .font(.custom("Iowan Old Style", size: 17))
                        .tracking(-0.2)
                        .foregroundStyle(Color(nsColor: .labelColor))

                    Spacer()

                    Button(action: model.completeBottle) {
                        Text("🥛")
                            .font(.system(size: 24))
                            .frame(width: 39, height: 39)
                    }
                    .buttonStyle(WaterBottleButtonStyle())
                    .help("喝完一瓶 · \(bottleCapacity)")
                    .accessibilityLabel("喝完一瓶")
                }
            }
            .frame(height: 58)
            .padding(.top, 6)

            Divider()

            HStack(spacing: 5) {
                Button {
                    model.setPaused(model.snapshot.status != .paused)
                } label: {
                    Label(
                        model.snapshot.status == .paused ? "恢复" : "暂停",
                        systemImage: model.snapshot.status == .paused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(WaterTextButtonStyle())

                Button(action: presentSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(WaterTextButtonStyle())
                .accessibilityLabel("饮水设置")

                Spacer()

                Button(action: collapse) {
                    Label("收起", systemImage: "chevron.up")
                }
                .buttonStyle(WaterTextButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(height: 54)
        }
        .padding(.horizontal, 24)
        .padding(.top, 38)
        .padding(.bottom, 20)
        .frame(height: 305)
        .background(
            .regularMaterial,
            in: UnevenRoundedRectangle(
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 24,
                style: .continuous
            )
        )
        .overlay {
            UnevenRoundedRectangle(
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 24,
                style: .continuous
            )
            .stroke(Color.white.opacity(0.68), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.26), radius: 22, y: 12)
        .environment(\.colorScheme, .light)
    }

    private var countdownText: String {
        HydrationMenuStatusPresentation(
            status: model.snapshot.status,
            remainingTimeUntilReminder: model.snapshot.remainingTimeUntilReminder
        ).text
    }

    private var bottleCapacity: String {
        HydrationVolumeFormatter.bottleCapacity(
            model.snapshot.settings.bottleCapacityMilliliters
        )
    }
}

private struct WaterPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.84 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.2), radius: 12, y: 7)
            .scaleEffect(configuration.isPressed ? 0.987 : 1)
    }
}

private struct WaterTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, 9)
            .frame(height: 36)
            .background(
                configuration.isPressed
                    ? Color(nsColor: .labelColor).opacity(0.08)
                    : .clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct WaterBottleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.14 : 0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
