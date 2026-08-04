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
    #expect(confirmed.reminderLevel == .confirmation)
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

@Test("changing sip estimate affects future records without rewriting history")
func sipEstimateChangesOnlyFutureRecords() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())

    _ = try engine.send(.setSipEstimate(.large))
    clock.now.addTimeInterval(30 * 60)
    _ = try engine.send(.confirmSip)
    _ = try engine.send(.setSipEstimate(.small))

    #expect(engine.snapshot.settings.sipEstimate == .small)
    #expect(engine.snapshot.records.map(\.estimatedMilliliters) == [35])
}

@Test("changing reminder interval updates the active cycle from its existing start")
func reminderIntervalUpdatesActiveCycle() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let store = InMemoryHydrationStore()
    let engine = try HydrationEngine(clock: clock, store: store)

    clock.now.addTimeInterval(30 * 60)
    let lengthened = try engine.send(.setReminderInterval(45 * 60))
    clock.now.addTimeInterval(15 * 60)
    let due = try engine.send(.timeAdvanced)
    let restarted = try HydrationEngine(clock: clock, store: store)

    #expect(lengthened.status == .accumulating)
    #expect(lengthened.cycle.startedAt == setup)
    #expect(lengthened.cycle.reminderInterval == 45 * 60)
    #expect(due.status == .dueAmbient)
    #expect(restarted.snapshot.settings.reminderInterval == 45 * 60)
    #expect(restarted.snapshot.cycle.reminderInterval == 45 * 60)
}

@Test("snooze keeps hydration due and ambient for a fifteen minute cooldown")
func snoozeSuppressesEscalationWithoutDrinking() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)

    let snoozed = try engine.send(.snooze)
    clock.now.addTimeInterval(15 * 60 - 1)
    let stillSnoozed = try engine.send(.timeAdvanced)
    clock.now.addTimeInterval(1)
    let eligibleAgain = try engine.send(.timeAdvanced)

    #expect(snoozed.status == .snoozed)
    #expect(snoozed.reminderLevel == .ambient)
    #expect(snoozed.snoozedUntil == setup.addingTimeInterval(45 * 60))
    #expect(stillSnoozed.status == .snoozed)
    #expect(eligibleAgain.status == .dueAmbient)
    #expect(eligibleAgain.records.isEmpty)
    #expect(eligibleAgain.cycle.startedAt == setup)
}

@Test("pause survives restart and resume recomputes from the existing cycle")
func pauseAndResumePreserveHydrationContext() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let store = InMemoryHydrationStore()
    let engine = try HydrationEngine(clock: clock, store: store)
    clock.now.addTimeInterval(30 * 60)

    let paused = try engine.send(.setPaused(true))
    let restarted = try HydrationEngine(clock: clock, store: store)
    let restoredPause = restarted.snapshot
    clock.now.addTimeInterval(20 * 60)
    let resumed = try restarted.send(.setPaused(false))

    #expect(paused.status == .paused)
    #expect(paused.reminderLevel == .hidden)
    #expect(paused.records.isEmpty)
    #expect(restoredPause.status == .paused)
    #expect(resumed.status == .dueAmbient)
    #expect(resumed.reminderLevel == .ambient)
    #expect(resumed.cycle.startedAt == setup)
    #expect(resumed.records.isEmpty)
}

@Test("disabling no-Agent fallback hides the clock-only ambient reminder")
func noAgentFallbackCanBeDisabled() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let store = InMemoryHydrationStore()
    let engine = try HydrationEngine(clock: clock, store: store)
    clock.now.addTimeInterval(30 * 60)

    let fallbackDisabled = try engine.send(.setNoAgentFallbackEnabled(false))
    let agentAware = try engine.send(.agentActivity)
    let restarted = try HydrationEngine(clock: clock, store: store)

    #expect(fallbackDisabled.status == .dueAmbient)
    #expect(fallbackDisabled.reminderLevel == .hidden)
    #expect(agentAware.status == .dueAmbient)
    #expect(agentAware.reminderLevel == .ambient)
    #expect(!restarted.snapshot.settings.noAgentFallbackEnabled)
    #expect(restarted.snapshot.status == .dueAmbient)
    #expect(restarted.snapshot.reminderLevel == .hidden)
}

@Test("snooze requires fresh Agent activity after cooldown when fallback is disabled")
func snoozeRequiresFreshAgentActivity() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    _ = try engine.send(.setNoAgentFallbackEnabled(false))
    clock.now.addTimeInterval(30 * 60)
    _ = try engine.send(.agentActivity)
    _ = try engine.send(.snooze)
    _ = try engine.send(.agentActivity)

    clock.now.addTimeInterval(15 * 60)
    let cooldownEnded = try engine.send(.timeAdvanced)
    let nextOpportunity = try engine.send(.agentActivity)

    #expect(cooldownEnded.status == .dueAmbient)
    #expect(cooldownEnded.reminderLevel == .hidden)
    #expect(cooldownEnded.records.isEmpty)
    #expect(nextOpportunity.reminderLevel == .ambient)
}

@Test("undo removes exactly the just-created record and restores its due context")
func undoRestoresPreviousDueContext() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)

    let confirmed = try engine.send(.confirmSip)
    let recordID = try #require(confirmed.records.first?.id)
    let undone = try engine.send(.undoSip(recordID))
    let duplicateUndo = try engine.send(.undoSip(recordID))

    #expect(confirmed.reminderLevel == .confirmation)
    #expect(confirmed.undoableDrinkRecord?.id == recordID)
    #expect(confirmed.todayEstimatedMilliliters == 25)
    #expect(undone.records.isEmpty)
    #expect(undone.todayEstimatedMilliliters == 0)
    #expect(undone.status == .dueAmbient)
    #expect(undone.reminderLevel == .ambient)
    #expect(undone.cycle.startedAt == setup)
    #expect(duplicateUndo.records.isEmpty)
}

@Test("undoing a drink made during snooze restores the snooze deadline")
func undoRestoresSnoozedContext() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    let snoozed = try engine.send(.snooze)

    let confirmed = try engine.send(.confirmSip)
    let recordID = try #require(confirmed.undoableDrinkRecord?.id)
    let undone = try engine.send(.undoSip(recordID))

    #expect(undone.status == .snoozed)
    #expect(undone.snoozedUntil == snoozed.snoozedUntil)
    #expect(undone.reminderLevel == .ambient)
    #expect(undone.records.isEmpty)
}

@Test("undo affordance expires after ten seconds")
func undoAffordanceExpires() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    let confirmed = try engine.send(.confirmSip)
    let recordID = try #require(confirmed.undoableDrinkRecord?.id)

    clock.now.addTimeInterval(9)
    let stillUndoable = try engine.send(.timeAdvanced)
    clock.now.addTimeInterval(1)
    let expired = try engine.send(.timeAdvanced)
    let lateUndo = try engine.send(.undoSip(recordID))

    #expect(stillUndoable.reminderLevel == .confirmation)
    #expect(expired.reminderLevel == .hidden)
    #expect(expired.undoableDrinkRecord == nil)
    #expect(lateUndo.records.count == 1)
}

@Test("undo restores the old cycle start while retaining a newly selected interval")
func undoRetainsIntervalSetting() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    let confirmed = try engine.send(.confirmSip)
    let recordID = try #require(confirmed.undoableDrinkRecord?.id)

    _ = try engine.send(.setReminderInterval(45 * 60))
    let undone = try engine.send(.undoSip(recordID))

    #expect(undone.settings.reminderInterval == 45 * 60)
    #expect(undone.cycle.startedAt == setup)
    #expect(undone.cycle.reminderInterval == 45 * 60)
    #expect(undone.status == .accumulating)
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

private final class TestClock: HydrationClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
