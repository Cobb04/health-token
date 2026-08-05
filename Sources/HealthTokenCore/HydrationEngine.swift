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
        case agentEvent(AgentEvent)
        case setSipEstimate(SipEstimate)
        case setReminderInterval(TimeInterval)
        case snooze
        case setPaused(Bool)
        case setNoAgentFallbackEnabled(Bool)
        case agentActivity
        case undoSip(UUID)
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
    private var agentSessions: [String: AgentSessionActivity] = [:]

    private struct AgentSessionActivity {
        var role: AgentRole
        var attention: AgentAttention
        var qualifyingToolCount: Int
        var hasActiveSubagentSignal: Bool
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
        return HydrationSnapshot(
            status: status,
            reminderLevel: reminderLevel,
            detailsExpanded: detailsExpanded,
            settings: persistence.settings,
            records: persistence.records,
            cycle: persistence.cycle,
            todayEstimatedMilliliters: persistence.records
                .filter { calendar.isDate($0.timestamp, inSameDayAs: evaluatedAt) }
                .reduce(0) { $0 + $1.estimatedMilliliters },
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

            let previousCycle = persistence.cycle
            let previousSnoozedUntil = persistence.snoozedUntil
            let previousAgentAwarePresentation = agentAwarePresentation
            let record = DrinkRecord(
                id: UUID(),
                timestamp: evaluatedAt,
                sipEstimate: persistence.settings.sipEstimate,
                sourceAction: .sipConfirmation
            )
            try persist { nextPersistence in
                nextPersistence.records.append(record)
                nextPersistence.cycle = HydrationCycle(
                    startedAt: evaluatedAt,
                    reminderInterval: nextPersistence.settings.reminderInterval
                )
                nextPersistence.snoozedUntil = nil
            }
            status = .accumulating
            detailsExpanded = false
            agentAwarePresentation = false
            undoContext = UndoContext(
                recordID: record.id,
                previousCycle: previousCycle,
                previousSnoozedUntil: previousSnoozedUntil,
                previousAgentAwarePresentation: previousAgentAwarePresentation,
                expiresAt: evaluatedAt.addingTimeInterval(10)
            )
        case let .setSipEstimate(estimate):
            try persist { nextPersistence in
                nextPersistence.settings.sipEstimate = estimate
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
        case let .undoSip(recordID):
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
        if activeUndoContext != nil, status != .paused {
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
            $0.hasActiveSubagentSignal || $0.qualifyingToolCount >= 3
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
            agentSessions[event.sessionID] = AgentSessionActivity(
                role: event.role,
                attention: .none,
                qualifyingToolCount: 0,
                hasActiveSubagentSignal: event.role == .subagent
                    && status.isHydrationDue
                    && !hasAttentionRequiredRootSession,
                lastActivityAt: event.timestamp
            )
        case .promptSubmitted:
            updateAgentSession(event) { activity in
                activity.attention = .none
                activity.qualifyingToolCount = 0
            }
        case .attentionChanged:
            updateAgentSession(event) { activity in
                activity.attention = event.attention
                activity.qualifyingToolCount = 0
            }
            if event.role == .root && event.attention == .required {
                invalidateAutonomousSignals()
            }
        case .planUpdated:
            updateAgentSession(event) { activity in
                activity.attention = .none
            }
        case .toolUsed:
            updateAgentSession(event) { activity in
                activity.attention = .none
            }
            let canRecordAutonomousWork = !hasAttentionRequiredRootSession
            updateAgentSession(event) { activity in
                if event.toolClassification == .ordinary,
                   canRecordAutonomousWork {
                    activity.qualifyingToolCount = status.isHydrationDue
                        ? activity.qualifyingToolCount + 1
                        : 0
                } else if event.toolClassification == .userInput {
                    activity.qualifyingToolCount = 0
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
            qualifyingToolCount: 0,
            hasActiveSubagentSignal: false,
            lastActivityAt: event.timestamp
        )
        activity.role = event.role
        activity.lastActivityAt = event.timestamp
        mutation(&activity)
        agentSessions[event.sessionID] = activity
    }

    private func invalidateAutonomousSignals() {
        for sessionID in agentSessions.keys {
            agentSessions[sessionID]?.qualifyingToolCount = 0
            agentSessions[sessionID]?.hasActiveSubagentSignal = false
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
