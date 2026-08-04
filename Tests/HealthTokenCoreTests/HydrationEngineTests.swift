import Foundation
import Testing
@testable import HealthTokenCore

@Test("first launch starts an accumulating cycle")
func firstLaunchStartsAccumulating() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: now)
    let store = InMemoryHydrationStore()

    let engine = try HydrationEngine(clock: clock, store: store)

    #expect(engine.snapshot.status == .accumulating)
    #expect(engine.snapshot.reminderLevel == .hidden)
    #expect(engine.snapshot.records.isEmpty)
    #expect(engine.snapshot.cycle.startedAt == now)
}

@Test("crossing the interval produces one persistent ambient due state")
func intervalExpiryIsPersistent() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: now)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())

    clock.now.addTimeInterval(30 * 60)
    #expect(engine.snapshot.status == .accumulating)
    let firstDue = try engine.send(.timeAdvanced)
    clock.now.addTimeInterval(90 * 60)
    let stillDue = try engine.send(.timeAdvanced)

    #expect(firstDue.status == .dueAmbient)
    #expect(firstDue.reminderLevel == .ambient)
    #expect(stillDue.status == .dueAmbient)
    #expect(stillDue.reminderLevel == .ambient)
    #expect(stillDue.records.isEmpty)
    #expect(stillDue.cycle.startedAt == now)
}

@Test("opening a due reminder reveals approximate sip and today's total")
func openingReminderRevealsDetails() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: now)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)

    let opened = try engine.send(.openReminder)

    #expect(opened.status == .dueAmbient)
    #expect(opened.detailsExpanded)
    #expect(opened.settings.sipEstimate == .regular)
    #expect(opened.settings.sipEstimate.milliliters == 25)
    #expect(opened.todayEstimatedMilliliters == 0)
}

@Test("confirming a sip records once, updates the total, and starts a new cycle")
func confirmingSipCompletesCycleExactlyOnce() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let store = InMemoryHydrationStore()
    let engine = try HydrationEngine(clock: clock, store: store)
    clock.now.addTimeInterval(30 * 60)
    _ = try engine.send(.openReminder)

    let confirmed = try engine.send(.confirmSip)
    let duplicateAttempt = try engine.send(.confirmSip)

    #expect(confirmed.records.count == 1)
    #expect(confirmed.records[0].timestamp == clock.now)
    #expect(confirmed.records[0].estimatedMilliliters == 25)
    #expect(confirmed.records[0].sourceAction == .sipConfirmation)
    #expect(confirmed.todayEstimatedMilliliters == 25)
    #expect(confirmed.status == .accumulating)
    #expect(confirmed.reminderLevel == .hidden)
    #expect(!confirmed.detailsExpanded)
    #expect(confirmed.cycle.startedAt == clock.now)
    #expect(confirmed.cycle.reminderInterval == 30 * 60)
    #expect(duplicateAttempt.records.count == 1)

    clock.now.addTimeInterval(30 * 60 - 1)
    let almostDue = try engine.send(.timeAdvanced)
    clock.now.addTimeInterval(1)
    let nextDue = try engine.send(.timeAdvanced)

    #expect(almostDue.status == .accumulating)
    #expect(nextDue.status == .dueAmbient)
}

@Test("showing, hiding, and restarting never records a drink")
func passiveLifecycleNeverRecordsDrink() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let store = InMemoryHydrationStore()
    let engine = try HydrationEngine(clock: clock, store: store)
    clock.now.addTimeInterval(30 * 60)

    _ = try engine.send(.timeAdvanced)
    _ = try engine.send(.openReminder)
    _ = try engine.send(.closeReminder)
    let restartedEngine = try HydrationEngine(clock: clock, store: store)

    #expect(restartedEngine.snapshot.records.isEmpty)
    #expect(restartedEngine.snapshot.status == .dueAmbient)
}

@Test("the engine restores persisted settings")
func engineRestoresPersistedSettings() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: now)
    let settings = HydrationSettings(reminderInterval: 45 * 60, sipEstimate: .large)
    let store = InMemoryHydrationStore(
        persistence: HydrationPersistence(
            settings: settings,
            records: [],
            cycle: HydrationCycle(startedAt: now, reminderInterval: 45 * 60)
        )
    )
    let restartedEngine = try HydrationEngine(clock: clock, store: store)

    #expect(restartedEngine.snapshot.settings.sipEstimate == .large)
    #expect(restartedEngine.snapshot.settings.reminderInterval == 45 * 60)
}

@Test("drink records retain their selected estimate across restart")
func recordsSurviveRestart() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let settings = HydrationSettings(sipEstimate: .small)
    let store = InMemoryHydrationStore(
        persistence: HydrationPersistence(
            settings: settings,
            records: [],
            cycle: HydrationCycle(
                startedAt: setup,
                reminderInterval: settings.reminderInterval
            )
        )
    )
    let engine = try HydrationEngine(clock: clock, store: store)
    clock.now.addTimeInterval(30 * 60)

    _ = try engine.send(.confirmSip)
    let restartedEngine = try HydrationEngine(clock: clock, store: store)

    #expect(restartedEngine.snapshot.records.count == 1)
    #expect(restartedEngine.snapshot.records[0].estimatedMilliliters == 15)
    #expect(restartedEngine.snapshot.todayEstimatedMilliliters == 15)
    #expect(restartedEngine.snapshot.settings.sipEstimate == .small)
}

@Test("today's estimated total follows the injected local calendar day")
func totalUsesLocalCalendarDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    let firstDrink = calendar.date(
        from: DateComponents(year: 2027, month: 1, day: 4, hour: 23, minute: 59)
    )!
    let clock = TestClock(now: firstDrink.addingTimeInterval(-30 * 60))
    let engine = try HydrationEngine(
        clock: clock,
        store: InMemoryHydrationStore(),
        calendar: calendar
    )

    clock.now = firstDrink
    _ = try engine.send(.confirmSip)
    clock.now.addTimeInterval(31 * 60)
    let nextDay = try engine.send(.confirmSip)

    #expect(nextDay.records.count == 2)
    #expect(nextDay.todayEstimatedMilliliters == 25)
}

@Test("ordinary Codex activity cannot create or clear a hydration reminder")
func ordinaryCodexActivityIsReadOnly() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(
        clock: clock,
        store: InMemoryHydrationStore()
    )
    let event = AgentEvent(
        kind: .toolUsed,
        sessionID: "synthetic-session",
        timestamp: setup,
        role: .root,
        attention: .none,
        toolClassification: .ordinary
    )

    let beforeDue = try engine.send(.agentEvent(event))
    clock.now.addTimeInterval(30 * 60)
    let due = try engine.send(.agentEvent(event))
    let dueEvents: [(AgentEvent.Kind, AgentToolClassification?)] = [
        (.promptSubmitted, nil),
        (.planUpdated, .plan),
        (.toolUsed, .ordinary),
        (.completed, nil),
        (.aborted, nil)
    ]
    var afterActivity = due
    for (kind, toolClassification) in dueEvents {
        afterActivity = try engine.send(
            .agentEvent(
                AgentEvent(
                    kind: kind,
                    sessionID: "synthetic-session",
                    timestamp: clock.now,
                    role: .root,
                    attention: .none,
                    toolClassification: toolClassification
                )
            )
        )
    }

    #expect(beforeDue.status == .accumulating)
    #expect(beforeDue.reminderLevel == .hidden)
    #expect(due.status == .dueAmbient)
    #expect(due.reminderLevel == .ambient)
    #expect(afterActivity.status == .dueAmbient)
    #expect(afterActivity.reminderLevel == .ambient)
    #expect(afterActivity.records.isEmpty)
    #expect(afterActivity.cycle.startedAt == setup)
}

private final class TestClock: HydrationClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
