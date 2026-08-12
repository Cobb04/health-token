import Foundation

public protocol HydrationClock: AnyObject {
    var now: Date { get }
}

public final class SystemHydrationClock: HydrationClock {
    public init() {}

    public var now: Date { Date() }
}

public final class HydrationEngine {
    private static let agentSessionStaleInterval: TimeInterval = 5 * 60

    public enum Action: Equatable, Sendable {
        case timeAdvanced
        case openReminder
        case closeReminder
        case confirmSip
        case recordProactiveSip
        case completeBottle
        case dismissConfirmation
        case agentEvent(AgentEvent)
        case agentObservationUnavailable
        case setSipEstimate(SipEstimate)
        case setBottleCapacityMilliliters(Int)
        case setReminderInterval(TimeInterval)
        case snooze
        case setPaused(Bool)
        case setNoAgentFallbackEnabled(Bool)
        case agentActivity
        case undoDrink(UUID)
    }

    private let clock: any HydrationClock
    private let store: any HydrationStore
    private let calendar: Calendar
    private var persistence: HydrationPersistence
    private var detailsExpanded = false
    private var evaluatedAt: Date
    private var status: HydrationStatus
    private var agentAwarePresentation = false
    private var undoContext: UndoContext?
    private var confirmationVisible = false
    private var agentSessions: [String: AgentSessionActivity] = [:]

    private struct AgentSessionActivity {
        var role: AgentRole
        var attention: AgentAttention
        var hasActiveAgentSignal: Bool
        var lastActivityAt: Date
    }

    private struct UndoContext {
        let recordID: UUID
        let previousCycle: HydrationCycle
        let previousSnoozedUntil: Date?
        let previousAgentAwarePresentation: Bool
        let expiresAt: Date
    }

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

        status = .accumulating
        undoContext = nil
        status = evaluatedStatus()
    }

    public var snapshot: HydrationSnapshot {
        let dailySummaries = recentDailySummaries
        return HydrationSnapshot(
            status: status,
            reminderLevel: reminderLevel,
            detailsExpanded: detailsExpanded,
            settings: persistence.settings,
            records: persistence.records,
            cycle: persistence.cycle,
            todayEstimatedMilliliters: dailySummaries.first?.estimatedMilliliters ?? 0,
            recentDailySummaries: dailySummaries,
            remainingTimeUntilReminder: persistence.cycle.remainingTime(at: evaluatedAt),
            snoozedUntil: persistence.snoozedUntil,
            undoableDrinkRecord: undoableDrinkRecord
        )
    }

    @discardableResult
    public func send(_ action: Action) throws -> HydrationSnapshot {
        evaluatedAt = clock.now
        expireStaleAgentSessions()
        if undoContext?.expiresAt ?? .distantPast <= evaluatedAt {
            undoContext = nil
            confirmationVisible = false
        }
        status = evaluatedStatus()

        switch action {
        case .timeAdvanced:
            break
        case .openReminder:
            if snapshot.status.isHydrationDue {
                detailsExpanded = true
            }
        case .closeReminder:
            detailsExpanded = false
        case .confirmSip:
            guard snapshot.status.isHydrationDue else {
                break
            }
            try recordDrink(
                estimatedMilliliters: persistence.settings.sipEstimate.milliliters,
                sourceAction: .sipConfirmation
            )
        case .recordProactiveSip:
            try recordDrink(
                estimatedMilliliters: persistence.settings.sipEstimate.milliliters,
                sourceAction: .proactiveSip
            )
        case .completeBottle:
            let capacity = persistence.settings.bottleCapacityMilliliters
            let remainder = currentBottleEstimatedMilliliters % capacity
            let adjustment = remainder == 0 ? capacity : capacity - remainder
            try recordDrink(
                estimatedMilliliters: adjustment,
                sourceAction: .bottleReconciliation
            )
        case .dismissConfirmation:
            confirmationVisible = false
        case let .setSipEstimate(estimate):
            try persist { nextPersistence in
                nextPersistence.settings.sipEstimate = estimate
            }
        case let .setBottleCapacityMilliliters(milliliters):
            try persist { nextPersistence in
                nextPersistence.settings.bottleCapacityMilliliters =
                    HydrationSettings.normalizedBottleCapacity(milliliters)
            }
        case let .setReminderInterval(interval):
            let normalizedInterval = HydrationSettings.normalizedReminderInterval(interval)
            try persist { nextPersistence in
                nextPersistence.settings.reminderInterval = normalizedInterval
                nextPersistence.cycle = HydrationCycle(
                    startedAt: nextPersistence.cycle.startedAt,
                    reminderInterval: normalizedInterval
                )
            }
            status = evaluatedStatus()
            if status == .accumulating {
                agentAwarePresentation = false
            }
        case .snooze:
            guard status.isHydrationDue else { break }
            try persist { nextPersistence in
                nextPersistence.snoozedUntil = evaluatedAt.addingTimeInterval(15 * 60)
            }
            status = evaluatedStatus()
            detailsExpanded = false
            agentAwarePresentation = false
        case let .setPaused(isPaused):
            try persist { nextPersistence in
                nextPersistence.isPaused = isPaused
            }
            status = evaluatedStatus()
            if isPaused {
                detailsExpanded = false
            }
        case let .setNoAgentFallbackEnabled(isEnabled):
            try persist { nextPersistence in
                nextPersistence.settings.noAgentFallbackEnabled = isEnabled
            }
        case .agentActivity:
            if status == .dueAmbient {
                agentAwarePresentation = true
            }
        case let .agentEvent(event):
            processAgentEvent(event)
            status = evaluatedStatus()
        case .agentObservationUnavailable:
            agentSessions.removeAll(keepingCapacity: false)
            agentAwarePresentation = false
            status = evaluatedStatus()
        case let .undoDrink(recordID):
            guard let context = activeUndoContext,
                  context.recordID == recordID,
                  persistence.records.contains(where: { $0.id == recordID }) else {
                break
            }
            try persist { nextPersistence in
                if let recordIndex = nextPersistence.records.lastIndex(
                    where: { $0.id == recordID }
                ) {
                    nextPersistence.records.remove(at: recordIndex)
                }
                nextPersistence.cycle = HydrationCycle(
                    startedAt: context.previousCycle.startedAt,
                    reminderInterval: nextPersistence.settings.reminderInterval
                )
                nextPersistence.snoozedUntil = context.previousSnoozedUntil
            }
            undoContext = nil
            confirmationVisible = false
            agentAwarePresentation = context.previousAgentAwarePresentation
            status = evaluatedStatus()
            detailsExpanded = status.isHydrationDue
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

    private func recordDrink(
        estimatedMilliliters: Int,
        sourceAction: DrinkRecord.SourceAction
    ) throws {
        let previousCycle = persistence.cycle
        let previousSnoozedUntil = persistence.snoozedUntil
        let previousAgentAwarePresentation = agentAwarePresentation
        let record = DrinkRecord(
            id: UUID(),
            timestamp: evaluatedAt,
            estimatedMilliliters: estimatedMilliliters,
            sourceAction: sourceAction
        )
        try persist { nextPersistence in
            nextPersistence.records.append(record)
            nextPersistence.cycle = HydrationCycle(
                startedAt: evaluatedAt,
                reminderInterval: nextPersistence.settings.reminderInterval
            )
            nextPersistence.snoozedUntil = nil
        }
        status = evaluatedStatus()
        detailsExpanded = false
        agentAwarePresentation = false
        confirmationVisible = true
        undoContext = UndoContext(
            recordID: record.id,
            previousCycle: previousCycle,
            previousSnoozedUntil: previousSnoozedUntil,
            previousAgentAwarePresentation: previousAgentAwarePresentation,
            expiresAt: evaluatedAt.addingTimeInterval(10)
        )
    }

    private var recentDailySummaries: [DailyHydrationSummary] {
        guard let today = calendar.dateInterval(of: .day, for: evaluatedAt) else {
            return []
        }

        let intervals = (0..<365).compactMap { offset -> DateInterval? in
            guard let dayAnchor = calendar.date(
                byAdding: .day,
                value: -offset,
                to: today.start
            ) else {
                return nil
            }
            return calendar.dateInterval(of: .day, for: dayAnchor)
        }
        guard let oldestInterval = intervals.last else { return [] }

        var buckets: [Date: (milliliters: Int, count: Int)] = [:]
        for record in persistence.records
        where record.timestamp >= oldestInterval.start && record.timestamp < today.end {
            guard let interval = calendar.dateInterval(of: .day, for: record.timestamp) else {
                continue
            }
            var bucket = buckets[interval.start] ?? (0, 0)
            bucket.milliliters += record.estimatedMilliliters
            bucket.count += 1
            buckets[interval.start] = bucket
        }

        return intervals.map { interval in
            let bucket = buckets[interval.start] ?? (0, 0)
            return DailyHydrationSummary(
                interval: interval,
                estimatedMilliliters: bucket.milliliters,
                recordCount: bucket.count
            )
        }
    }

    private var currentBottleEstimatedMilliliters: Int {
        var total = 0
        for record in persistence.records.reversed() {
            if record.sourceAction == .bottleReconciliation {
                break
            }
            total += record.estimatedMilliliters
        }
        return total
    }

    private func evaluatedStatus() -> HydrationStatus {
        if persistence.isPaused {
            return .paused
        }

        guard persistence.cycle.status(at: evaluatedAt) == .dueAmbient else {
            return .accumulating
        }

        if let snoozedUntil = persistence.snoozedUntil,
           evaluatedAt < snoozedUntil {
            return .snoozed
        }

        return hasAttentionRequiredRootSession || !hasAutonomousAgentSignal
            ? .dueAmbient
            : .dueStrong
    }

    private var reminderLevel: ReminderLevel {
        if activeUndoContext != nil, confirmationVisible {
            return .confirmation
        }

        switch status {
        case .accumulating, .paused:
            return .hidden
        case .snoozed:
            return .ambient
        case .dueAmbient:
            return persistence.settings.noAgentFallbackEnabled || agentAwarePresentation
                ? .ambient
                : .hidden
        case .dueStrong:
            return .strong
        }
    }

    private var hasAutonomousAgentSignal: Bool {
        agentSessions.values.contains {
            $0.hasActiveAgentSignal
        }
    }

    private var hasAttentionRequiredRootSession: Bool {
        agentSessions.values.contains {
            $0.role == .root && $0.attention == .required
        }
    }

    private func processAgentEvent(_ event: AgentEvent) {
        switch event.kind {
        case .completed, .aborted, .sessionRemoved:
            agentSessions.removeValue(forKey: event.sessionID)
            return
        case .sessionStarted:
            let canRecordAutonomousWork = !hasAttentionRequiredRootSession
            agentSessions[event.sessionID] = AgentSessionActivity(
                role: event.role,
                attention: .none,
                hasActiveAgentSignal: event.role == .subagent
                    && canRecordAutonomousWork,
                lastActivityAt: event.timestamp
            )
        case .promptSubmitted:
            let canRecordAutonomousWork = !hasAttentionRequiredRootSession
            updateAgentSession(event) { activity in
                activity.attention = .none
                activity.hasActiveAgentSignal = canRecordAutonomousWork
            }
        case .attentionChanged:
            updateAgentSession(event) { activity in
                activity.attention = event.attention
                if event.attention == .required {
                    activity.hasActiveAgentSignal = false
                }
            }
            if event.role == .root && event.attention == .required {
                invalidateAutonomousSignals()
            }
        case .planUpdated:
            let canRecordAutonomousWork = !hasAttentionRequiredRootSession
            updateAgentSession(event) { activity in
                activity.hasActiveAgentSignal = canRecordAutonomousWork
            }
        case .toolUsed:
            let canRecordAutonomousWork = !hasAttentionRequiredRootSession
            updateAgentSession(event) { activity in
                if event.toolClassification == .ordinary,
                   canRecordAutonomousWork {
                    activity.hasActiveAgentSignal = true
                } else if event.toolClassification == .userInput {
                    activity.hasActiveAgentSignal = false
                }
            }
        }

        if status.isHydrationDue {
            agentAwarePresentation = true
        }
    }

    private func updateAgentSession(
        _ event: AgentEvent,
        mutation: (inout AgentSessionActivity) -> Void
    ) {
        var activity = agentSessions[event.sessionID] ?? AgentSessionActivity(
            role: event.role,
            attention: .none,
            hasActiveAgentSignal: false,
            lastActivityAt: event.timestamp
        )
        activity.role = event.role
        activity.lastActivityAt = event.timestamp
        mutation(&activity)
        agentSessions[event.sessionID] = activity
    }

    private func invalidateAutonomousSignals() {
        for sessionID in agentSessions.keys {
            agentSessions[sessionID]?.hasActiveAgentSignal = false
        }
    }

    private func expireStaleAgentSessions() {
        agentSessions = agentSessions.filter { _, activity in
            evaluatedAt.timeIntervalSince(activity.lastActivityAt)
                < Self.agentSessionStaleInterval
        }
    }

    private var activeUndoContext: UndoContext? {
        guard let undoContext, evaluatedAt < undoContext.expiresAt else {
            return nil
        }
        return undoContext
    }

    private var undoableDrinkRecord: DrinkRecord? {
        guard let recordID = activeUndoContext?.recordID else { return nil }
        return persistence.records.last { $0.id == recordID }
    }
}
