import Foundation

public protocol HydrationClock: AnyObject {
    var now: Date { get }
}

public final class SystemHydrationClock: HydrationClock {
    public init() {}

    public var now: Date { Date() }
}

public final class HydrationEngine {
    public enum Action: Equatable, Sendable {
        case timeAdvanced
        case openReminder
        case closeReminder
        case confirmSip
    }

    private let clock: any HydrationClock
    private let store: any HydrationStore
    private let calendar: Calendar
    private var persistence: HydrationPersistence
    private var detailsExpanded = false
    private var evaluatedAt: Date
    private var status: HydrationStatus

    public init(
        clock: any HydrationClock,
        store: any HydrationStore,
        calendar: Calendar = .autoupdatingCurrent
    ) throws {
        self.clock = clock
        self.store = store
        self.calendar = calendar
        evaluatedAt = clock.now

        if let saved = try store.load() {
            persistence = saved
        } else {
            let settings = HydrationSettings()
            persistence = HydrationPersistence(
                settings: settings,
                records: [],
                cycle: HydrationCycle(
                    startedAt: clock.now,
                    reminderInterval: settings.reminderInterval
                )
            )
            try store.save(persistence)
        }

        status = persistence.cycle.status(at: evaluatedAt)
    }

    public var snapshot: HydrationSnapshot {
        return HydrationSnapshot(
            status: status,
            reminderLevel: status == .dueAmbient ? .ambient : .hidden,
            detailsExpanded: detailsExpanded,
            settings: persistence.settings,
            records: persistence.records,
            cycle: persistence.cycle,
            todayEstimatedMilliliters: persistence.records
                .filter { calendar.isDate($0.timestamp, inSameDayAs: evaluatedAt) }
                .reduce(0) { $0 + $1.estimatedMilliliters }
        )
    }

    @discardableResult
    public func send(_ action: Action) throws -> HydrationSnapshot {
        evaluatedAt = clock.now
        status = persistence.cycle.status(at: evaluatedAt)

        switch action {
        case .timeAdvanced:
            break
        case .openReminder:
            if snapshot.status == .dueAmbient {
                detailsExpanded = true
            }
        case .closeReminder:
            detailsExpanded = false
        case .confirmSip:
            guard snapshot.status == .dueAmbient else { break }

            let record = DrinkRecord(
                id: UUID(),
                timestamp: evaluatedAt,
                estimatedMilliliters: persistence.settings.sipEstimate.milliliters,
                sourceAction: .sipConfirmation
            )
            try persist { nextPersistence in
                nextPersistence.records.append(record)
                nextPersistence.cycle = HydrationCycle(
                    startedAt: evaluatedAt,
                    reminderInterval: nextPersistence.settings.reminderInterval
                )
            }
            status = .accumulating
            detailsExpanded = false
        }

        return snapshot
    }

    private func persist(
        _ mutation: (inout HydrationPersistence) -> Void
    ) throws {
        var nextPersistence = persistence
        mutation(&nextPersistence)
        try store.save(nextPersistence)
        persistence = nextPersistence
    }
}
