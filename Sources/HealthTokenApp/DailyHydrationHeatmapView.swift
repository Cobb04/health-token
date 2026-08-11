import Charts
import HealthTokenCore
import SwiftUI

struct DailyHydrationHeatmapView: View {
    let summaries: [DailyHydrationSummary]
    let trackingStartedAt: Date?
    let bottleCapacity: Int

    @State private var period: HydrationHeatmapPeriod = .quarter
    @State private var hoveredDayID: Date?
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        let presentation = makePresentation()
        let layout = makeLayout(for: presentation)
        let selectedDay = selectedDay(in: presentation)

        VStack(alignment: .leading, spacing: 0) {
            Text("DAILY HYDRATION")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.15)
                .foregroundStyle(Color.accentColor)

            HStack(spacing: 16) {
                Text("饮水记录")
                    .font(.system(size: 21, weight: .bold))
                    .tracking(-0.7)
                Spacer(minLength: 8)
                Picker("统计时间范围", selection: $period) {
                    ForEach(HydrationHeatmapPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 112)
                .accessibilityLabel("饮水统计时间范围")
            }
            .padding(.top, 6)

            if period.layout == .focusedQuarter {
                focusedQuarterHeader(presentation)
                    .padding(.top, 18)
            }

            heatmapCard(
                presentation: presentation,
                layout: layout,
                selectedDay: selectedDay
            )
            .padding(.top, 16)

            HStack(spacing: 12) {
                Text("每日记录根据当前所在地重新分日")
                Spacer(minLength: 8)
                Text(period == .quarter ? "84 天" : "365 天")
                    .monospacedDigit()
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.top, 13)
        }
        .padding(.vertical, 6)
    }

    private func makePresentation() -> DailyHydrationHeatmapPresentation {
        DailyHydrationHeatmapPresentation(
            summaries: summaries,
            trackingStartedAt: trackingStartedAt,
            period: period,
            bottleCapacity: bottleCapacity,
            calendar: calendar,
            locale: locale
        )
    }

    private func makeLayout(
        for presentation: DailyHydrationHeatmapPresentation
    ) -> HydrationHeatmapLayout {
        var displayCalendar = calendar
        displayCalendar.firstWeekday = 2
        return HydrationHeatmapLayout(
            days: presentation.days,
            today: summaries.first?.interval.start ?? .now,
            calendar: displayCalendar,
            locale: locale
        )
    }

    private func selectedDay(
        in presentation: DailyHydrationHeatmapPresentation
    ) -> HydrationHeatmapDay? {
        if let hoveredDayID,
           let hovered = presentation.days.first(where: { $0.id == hoveredDayID }) {
            return hovered
        }
        return presentation.days.last
    }

    private func focusedQuarterHeader(
        _ presentation: DailyHydrationHeatmapPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.todayAmount)
                .font(.custom("Avenir Next", size: 37).weight(.semibold))
                .tracking(-1.8)
                .foregroundStyle(Color.accentColor)
                .monospacedDigit()
            Text(presentation.todayBottleEquivalent)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func yearSummaryHeader(
        _ presentation: DailyHydrationHeatmapPresentation
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            (
                Text("今天 ").foregroundColor(.primary)
                    + Text(presentation.todayAmount).foregroundColor(Color.accentColor)
            )
                .font(.custom("Avenir Next", size: 25).weight(.semibold))
                .tracking(-1)
                .monospacedDigit()
            Spacer(minLength: 8)
            Text(presentation.recentSevenDayTotal)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func heatmapCard(
        presentation: DailyHydrationHeatmapPresentation,
        layout: HydrationHeatmapLayout,
        selectedDay: HydrationHeatmapDay?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if period.layout == .focusedQuarter {
                Text("饮水节奏")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.25)

                heatmap(presentation: presentation, layout: layout)
                    .padding(.top, 11)

                selectedDayDetail(selectedDay)
                    .padding(.top, 11)
            } else {
                yearSummaryHeader(presentation)
                selectedDayDetail(selectedDay)
                    .padding(.top, 13)
                heatmap(presentation: presentation, layout: layout)
                    .padding(.top, 12)
            }

            legend
                .padding(.top, 9)
        }
        .padding(16)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.82),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.58), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.025), radius: 1, y: 1)
    }

    @ViewBuilder
    private func selectedDayDetail(_ day: HydrationHeatmapDay?) -> some View {
        if let day {
            HStack(spacing: 10) {
                Text(dayTitle(day))
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text(dayDetail(day))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(day.accessibilityLabel)
        }
    }

    private func heatmap(
        presentation: DailyHydrationHeatmapPresentation,
        layout: HydrationHeatmapLayout
    ) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    chart(presentation: presentation, layout: layout)
                        .frame(width: chartWidth(for: layout), height: chartHeight)
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id("latest-hydration-day")
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToLatest(using: scrollProxy)
            }
            .onChange(of: period) { _ in
                hoveredDayID = nil
                scrollToLatest(using: scrollProxy)
            }
        }
        .frame(height: chartHeight)
    }

    private func chart(
        presentation: DailyHydrationHeatmapPresentation,
        layout: HydrationHeatmapLayout
    ) -> some View {
        Chart(layout.points) { point in
            RectangleMark(
                xStart: .value("周", Double(point.weekIndex) + 0.10),
                xEnd: .value("周", Double(point.weekIndex) + 0.90),
                yStart: .value(
                    "星期",
                    Double(plotWeekdayIndex(for: point.weekdayIndex)) + 0.10
                ),
                yEnd: .value(
                    "星期",
                    Double(plotWeekdayIndex(for: point.weekdayIndex)) + 0.90
                )
            )
            .cornerRadius(cellCornerRadius)
            .foregroundStyle(color(for: point.day.intensity))
            .accessibilityLabel(point.day.accessibilityLabel)
            .annotation(position: .overlay) {
                HydrationHeatmapCellOverlay(
                    intensity: point.day.intensity,
                    isToday: point.isToday,
                    size: cellSize,
                    usesWaterLevel: differentiateWithoutColor,
                    usesIncreasedContrast: colorSchemeContrast == .increased
                )
            }
        }
        .chartXScale(domain: 0...Double(max(1, layout.weekCount)))
        .chartYScale(domain: 0...7)
        .chartXAxis {
            AxisMarks(
                position: .top,
                values: layout.monthTicks.map { Double($0.weekIndex) + 0.5 }
            ) { value in
                AxisValueLabel {
                    if let position = value.as(Double.self),
                       let tick = monthTick(at: position, layout: layout) {
                        Text(tick.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [2.5, 4.5, 6.5]) { value in
                AxisValueLabel {
                    if let position = value.as(Double.self) {
                        Text(weekdayLabel(
                            at: weekdayIndex(forPlotValue: position),
                            layout: layout
                        ))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHoveredDay(
                                at: location,
                                proxy: proxy,
                                geometry: geometry,
                                layout: layout
                            )
                        case .ended:
                            hoveredDayID = nil
                        }
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.chartAccessibilityLabel)
    }

    private var legend: some View {
        HStack(spacing: 5) {
            HydrationHeatmapLegendCell(
                color: color(for: .unavailable),
                isHollow: true
            )
            Text("无数据")
            Spacer(minLength: 8)
            Text("0")
            ForEach(0...4, id: \.self) { level in
                HydrationHeatmapLegendCell(
                    color: color(for: intensity(for: level)),
                    isHollow: false
                )
            }
            Text("3+ 瓶")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("图例：无数据、零记录、未满一瓶、一瓶、两瓶、三瓶以上")
    }

    private func chartWidth(for layout: HydrationHeatmapLayout) -> CGFloat {
        let step: CGFloat = period == .quarter ? 24 : 13
        let minimum: CGFloat = period == .quarter ? 315 : 680
        return max(minimum, CGFloat(layout.weekCount) * step)
    }

    private var chartHeight: CGFloat {
        period == .quarter ? 190 : 138
    }

    private var cellSize: CGFloat {
        period == .quarter ? 18 : 9
    }

    private var cellCornerRadius: CGFloat {
        period == .quarter ? 4 : 2.5
    }

    private func color(for intensity: HydrationHeatmapIntensity) -> Color {
        switch intensity {
        case .unavailable:
            return Color(nsColor: .controlBackgroundColor).opacity(0.35)
        case .zero:
            return Color(nsColor: .separatorColor).opacity(
                colorSchemeContrast == .increased ? 0.48 : 0.25
            )
        case .partialBottle:
            return Color.accentColor.opacity(0.25)
        case .oneBottle:
            return Color.accentColor.opacity(0.48)
        case .twoBottles:
            return Color.accentColor.opacity(0.72)
        case .threeOrMoreBottles:
            return Color.accentColor
        }
    }

    private func intensity(for level: Int) -> HydrationHeatmapIntensity {
        switch level {
        case 0: .zero
        case 1: .partialBottle
        case 2: .oneBottle
        case 3: .twoBottles
        default: .threeOrMoreBottles
        }
    }

    private func monthTick(
        at position: Double,
        layout: HydrationHeatmapLayout
    ) -> HydrationHeatmapMonthTick? {
        layout.monthTicks.first {
            abs((Double($0.weekIndex) + 0.5) - position) < 0.01
        }
    }

    private func weekdayLabel(
        at index: Int,
        layout: HydrationHeatmapLayout
    ) -> String {
        guard layout.weekdayLabels.indices.contains(index) else { return "" }
        return layout.weekdayLabels[index]
    }

    private func plotWeekdayIndex(for weekdayIndex: Int) -> Int {
        6 - weekdayIndex
    }

    private func weekdayIndex(forPlotValue value: Double) -> Int {
        6 - Int(floor(value))
    }

    private func updateHoveredDay(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        layout: HydrationHeatmapLayout
    ) {
        let plotFrame = geometry[proxy.plotAreaFrame]
        let x = location.x - plotFrame.origin.x
        let y = location.y - plotFrame.origin.y
        guard x >= 0, y >= 0, x <= plotFrame.width, y <= plotFrame.height,
              let week: Double = proxy.value(atX: x),
              let weekday: Double = proxy.value(atY: y) else {
            return
        }
        let weekIndex = Int(floor(week))
        let weekdayIndex = weekdayIndex(forPlotValue: weekday)
        hoveredDayID = layout.points.first {
            $0.weekIndex == weekIndex && $0.weekdayIndex == weekdayIndex
        }?.id
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("latest-hydration-day", anchor: .trailing)
        }
    }

    private func dayTitle(_ day: HydrationHeatmapDay) -> String {
        if let today = summaries.first?.interval.start,
           calendar.isDate(day.summary.interval.start, inSameDayAs: today) {
            return "今天"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMEd")
        return formatter.string(from: day.summary.interval.start)
    }

    private func dayDetail(_ day: HydrationHeatmapDay) -> String {
        switch day.intensity {
        case .unavailable:
            return "无数据"
        case .zero:
            return "没有饮水记录"
        case .partialBottle, .oneBottle, .twoBottles, .threeOrMoreBottles:
            let bottles = Double(day.summary.estimatedMilliliters)
                / Double(max(1, bottleCapacity))
            let bottleText = bottles.rounded() == bottles
                ? String(Int(bottles))
                : String(format: "%.1f", bottles)
            return "约 \(day.summary.estimatedMilliliters) mL · 约 \(bottleText) 瓶"
        }
    }
}

private struct HydrationHeatmapCellOverlay: View {
    let intensity: HydrationHeatmapIntensity
    let isToday: Bool
    let size: CGFloat
    let usesWaterLevel: Bool
    let usesIncreasedContrast: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if intensity == .unavailable {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(.secondary.opacity(0.55), lineWidth: 1)
            }
            if usesWaterLevel, intensity != .unavailable {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.primary.opacity(0.20))
                    .frame(height: max(1, size * CGFloat(intensity.level) / 4))
            }
            if isToday {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.accentColor, lineWidth: usesIncreasedContrast ? 2.5 : 2)
            } else if usesIncreasedContrast {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(.primary.opacity(0.22), lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var cornerRadius: CGFloat { max(2, size * 0.22) }
}

private struct HydrationHeatmapLegendCell: View {
    let color: Color
    let isHollow: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(isHollow ? Color.clear : color)
            .overlay {
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(.secondary.opacity(isHollow ? 0.55 : 0.12), lineWidth: 1)
            }
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}
