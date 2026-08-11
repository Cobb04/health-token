import Foundation
import HealthTokenCore

enum HydrationHeatmapPeriod: String, CaseIterable, Identifiable {
    case quarter
    case year

    var id: Self { self }

    var title: String {
        switch self {
        case .quarter: "季度"
        case .year: "年度"
        }
    }

    var dayCount: Int {
        switch self {
        case .quarter: 84
        case .year: 365
        }
    }

    var layout: HydrationHeatmapLayoutStyle {
        switch self {
        case .quarter: .focusedQuarter
        case .year: .yearOverview
        }
    }
}

enum HydrationHeatmapLayoutStyle: Equatable {
    case focusedQuarter
    case yearOverview
}

enum HydrationHeatmapIntensity: Int, Equatable, Sendable {
    case unavailable = -1
    case zero = 0
    case partialBottle = 1
    case oneBottle = 2
    case twoBottles = 3
    case threeOrMoreBottles = 4

    init(
        estimatedMilliliters: Int,
        bottleCapacity: Int,
        isAvailable: Bool
    ) {
        guard isAvailable else {
            self = .unavailable
            return
        }
        guard estimatedMilliliters > 0 else {
            self = .zero
            return
        }

        let capacity = max(1, bottleCapacity)
        switch estimatedMilliliters {
        case ..<capacity:
            self = .partialBottle
        case ..<(capacity * 2):
            self = .oneBottle
        case ..<(capacity * 3):
            self = .twoBottles
        default:
            self = .threeOrMoreBottles
        }
    }

    var level: Int {
        max(0, rawValue)
    }
}

struct HydrationHeatmapDay: Identifiable, Equatable {
    let summary: DailyHydrationSummary
    let intensity: HydrationHeatmapIntensity
    let accessibilityLabel: String

    var id: Date { summary.interval.start }
}

struct HydrationHeatmapPoint: Identifiable, Equatable {
    let day: HydrationHeatmapDay
    let weekIndex: Int
    let weekdayIndex: Int
    let isToday: Bool

    var id: Date { day.id }
}

struct HydrationHeatmapMonthTick: Identifiable, Equatable {
    let weekIndex: Int
    let label: String

    var id: String { "\(weekIndex)-\(label)" }
}

struct HydrationHeatmapLayout {
    let points: [HydrationHeatmapPoint]
    let monthTicks: [HydrationHeatmapMonthTick]
    let weekdayLabels: [String]
    let weekCount: Int

    init(
        days: [HydrationHeatmapDay],
        today: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) {
        var displayCalendar = calendar
        displayCalendar.locale = locale
        guard let firstDay = days.first?.summary.interval.start,
              let firstWeek = displayCalendar.dateInterval(
                of: .weekOfYear,
                for: firstDay
              ) else {
            points = []
            monthTicks = []
            weekdayLabels = Self.weekdayLabels(calendar: displayCalendar)
            weekCount = 0
            return
        }

        points = days.map { day in
            let dayStart = day.summary.interval.start
            let dayDistance = displayCalendar.dateComponents(
                [.day],
                from: firstWeek.start,
                to: dayStart
            ).day ?? 0
            let weekday = displayCalendar.component(.weekday, from: dayStart)
            return HydrationHeatmapPoint(
                day: day,
                weekIndex: max(0, dayDistance / 7),
                weekdayIndex: (
                    weekday - displayCalendar.firstWeekday + 7
                ) % 7,
                isToday: displayCalendar.isDate(dayStart, inSameDayAs: today)
            )
        }
        weekCount = (points.map(\.weekIndex).max() ?? -1) + 1
        weekdayLabels = Self.weekdayLabels(calendar: displayCalendar)

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = displayCalendar
        monthFormatter.timeZone = displayCalendar.timeZone
        monthFormatter.locale = locale
        monthFormatter.setLocalizedDateFormatFromTemplate("MMM")
        var ticks: [HydrationHeatmapMonthTick] = []
        var previousMonth: DateComponents?
        for point in points {
            let components = displayCalendar.dateComponents(
                [.year, .month],
                from: point.day.summary.interval.start
            )
            guard components != previousMonth else { continue }
            let tick = HydrationHeatmapMonthTick(
                weekIndex: point.weekIndex,
                label: monthFormatter.string(from: point.day.summary.interval.start)
            )
            if ticks.last?.weekIndex == tick.weekIndex {
                ticks[ticks.count - 1] = tick
            } else {
                ticks.append(tick)
            }
            previousMonth = components
        }
        monthTicks = ticks
    }

    private static func weekdayLabels(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let start = max(0, min(6, calendar.firstWeekday - 1))
        return Array(symbols[start...] + symbols[..<start])
    }
}

struct DailyHydrationHeatmapPresentation {
    let days: [HydrationHeatmapDay]
    let todayAmount: String
    let todayBottleEquivalent: String
    let recentSevenDayTotal: String
    let chartAccessibilityLabel: String

    init(
        summaries: [DailyHydrationSummary],
        trackingStartedAt: Date?,
        period: HydrationHeatmapPeriod,
        bottleCapacity: Int,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) {
        let selectedSummaries = summaries
            .prefix(period.dayCount)
            .reversed()
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.locale = locale
        dateFormatter.setLocalizedDateFormatFromTemplate("MMMEd")

        days = selectedSummaries.map { summary in
            let isAvailable = trackingStartedAt.map {
                summary.interval.end > $0
            } ?? false
            let intensity = HydrationHeatmapIntensity(
                estimatedMilliliters: summary.estimatedMilliliters,
                bottleCapacity: bottleCapacity,
                isAvailable: isAvailable
            )
            let date = dateFormatter.string(from: summary.interval.start)
            let accessibilityLabel: String
            switch intensity {
            case .unavailable:
                accessibilityLabel = "\(date)，无数据"
            case .zero:
                accessibilityLabel = "\(date)，没有饮水记录"
            case .partialBottle, .oneBottle, .twoBottles, .threeOrMoreBottles:
                accessibilityLabel = "\(date)，记录约 \(summary.estimatedMilliliters) 毫升，约 \(Self.bottleText(summary.estimatedMilliliters, capacity: bottleCapacity)) 瓶"
            }
            return HydrationHeatmapDay(
                summary: summary,
                intensity: intensity,
                accessibilityLabel: accessibilityLabel
            )
        }

        let todayMilliliters = summaries.first?.estimatedMilliliters ?? 0
        todayAmount = "\(todayMilliliters) mL"
        todayBottleEquivalent = "今天 · 约 \(Self.bottleText(todayMilliliters, capacity: bottleCapacity)) 瓶"
        let recentTotal = summaries.prefix(7).reduce(0) {
            $0 + $1.estimatedMilliliters
        }
        recentSevenDayTotal = "近 7 日 · \(Self.volumeText(recentTotal))"
        let periodTotal = days.reduce(0) {
            $0 + $1.summary.estimatedMilliliters
        }
        chartAccessibilityLabel = "过去\(period.title)饮水记录，共记录约 \(periodTotal) 毫升"
    }

    private static func volumeText(_ milliliters: Int) -> String {
        guard milliliters >= 1_000 else { return "\(milliliters) mL" }
        if milliliters.isMultiple(of: 1_000) {
            return "\(milliliters / 1_000) L"
        }
        return String(format: "%.1f L", Double(milliliters) / 1_000)
    }

    private static func bottleText(_ milliliters: Int, capacity: Int) -> String {
        let bottles = Double(milliliters) / Double(max(1, capacity))
        if bottles.rounded() == bottles {
            return "\(Int(bottles))"
        }
        return String(format: "%.1f", bottles)
    }
}
