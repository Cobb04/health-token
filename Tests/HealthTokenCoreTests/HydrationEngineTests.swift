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
    let undone = try engine.send(.undoDrink(recordID))
    let duplicateUndo = try engine.send(.undoDrink(recordID))

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
    let undone = try engine.send(.undoDrink(recordID))

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
    let lateUndo = try engine.send(.undoDrink(recordID))

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
    let undone = try engine.send(.undoDrink(recordID))

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

@Test("recent hydration summaries include today and 364 prior local calendar days")
func recentDailySummariesIncludeEmptyDays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    let today = calendar.date(
        from: DateComponents(year: 2027, month: 3, day: 8, hour: 10)
    )!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
    let settings = HydrationSettings()
    let records = [
        DrinkRecord(
            id: UUID(),
            timestamp: today,
            estimatedMilliliters: 35,
            sourceAction: .proactiveSip
        ),
        DrinkRecord(
            id: UUID(),
            timestamp: yesterday,
            estimatedMilliliters: 500,
            sourceAction: .bottleReconciliation
        ),
        DrinkRecord(
            id: UUID(),
            timestamp: threeDaysAgo,
            estimatedMilliliters: 25,
            sourceAction: .sipConfirmation
        )
    ]
    let engine = try HydrationEngine(
        clock: TestClock(now: today),
        store: InMemoryHydrationStore(
            persistence: HydrationPersistence(
                settings: settings,
                records: records,
                cycle: HydrationCycle(
                    startedAt: today,
                    reminderInterval: settings.reminderInterval
                )
            )
        ),
        calendar: calendar
    )

    let summaries = engine.snapshot.recentDailySummaries

    try #require(summaries.count == 365)
    #expect(Array(summaries.prefix(7).map(\.estimatedMilliliters)) == [35, 500, 0, 25, 0, 0, 0])
    #expect(Array(summaries.prefix(7).map(\.recordCount)) == [1, 1, 0, 1, 0, 0, 0])
    #expect(summaries[0].interval.start == calendar.startOfDay(for: today))
    #expect(summaries[1].interval.start == calendar.startOfDay(for: yesterday))
    #expect(
        summaries[364].interval.start
            == calendar.startOfDay(for: calendar.date(byAdding: .day, value: -364, to: today)!)
    )
}

@Test("a record exactly at local midnight belongs only to the new hydration day")
func midnightRecordBelongsOnlyToTheNewDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    let midnight = calendar.date(
        from: DateComponents(year: 2027, month: 3, day: 8)
    )!
    let settings = HydrationSettings()
    let records = [
        DrinkRecord(
            id: UUID(),
            timestamp: midnight.addingTimeInterval(-1),
            estimatedMilliliters: 25,
            sourceAction: .sipConfirmation
        ),
        DrinkRecord(
            id: UUID(),
            timestamp: midnight,
            estimatedMilliliters: 35,
            sourceAction: .proactiveSip
        )
    ]
    let engine = try HydrationEngine(
        clock: TestClock(now: midnight.addingTimeInterval(60)),
        store: InMemoryHydrationStore(
            persistence: HydrationPersistence(
                settings: settings,
                records: records,
                cycle: HydrationCycle(
                    startedAt: midnight,
                    reminderInterval: settings.reminderInterval
                )
            )
        ),
        calendar: calendar
    )

    let summaries = engine.snapshot.recentDailySummaries

    #expect(summaries[0].estimatedMilliliters == 35)
    #expect(summaries[0].recordCount == 1)
    #expect(summaries[1].estimatedMilliliters == 25)
    #expect(summaries[1].recordCount == 1)
}

@Test("an overnight overdue reminder stays due as B while today's total resets")
func overnightDueReminderKeepsCycleButDropsStaleCodexSignal() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    let evening = calendar.date(
        from: DateComponents(year: 2027, month: 3, day: 7, hour: 23)
    )!
    let clock = TestClock(now: evening)
    let engine = try HydrationEngine(
        clock: clock,
        store: InMemoryHydrationStore(),
        calendar: calendar
    )
    _ = try engine.send(.recordProactiveSip)
    clock.now.addTimeInterval(30 * 60)
    for _ in 0..<3 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "overnight-root",
            at: clock.now,
            tool: .ordinary
        )))
    }
    #expect(engine.snapshot.reminderLevel == .strong)
    let previousCycle = engine.snapshot.cycle

    clock.now = calendar.date(
        from: DateComponents(year: 2027, month: 3, day: 8, hour: 8)
    )!
    let morning = try engine.send(.timeAdvanced)

    #expect(morning.todayEstimatedMilliliters == 0)
    #expect(morning.recentDailySummaries[1].estimatedMilliliters == 25)
    #expect(morning.cycle == previousCycle)
    #expect(morning.status == .dueAmbient)
    #expect(morning.reminderLevel == .ambient)
}

@Test("cold launch on the next day preserves yesterday and pause without migration")
func coldLaunchRebuildsDailySummariesFromDrinkRecords() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    let yesterday = calendar.date(
        from: DateComponents(year: 2027, month: 3, day: 7, hour: 23, minute: 59)
    )!
    let clock = TestClock(now: yesterday)
    let store = InMemoryHydrationStore()
    let firstEngine = try HydrationEngine(
        clock: clock,
        store: store,
        calendar: calendar
    )
    _ = try firstEngine.send(.recordProactiveSip)
    _ = try firstEngine.send(.setPaused(true))

    clock.now = calendar.date(
        from: DateComponents(year: 2027, month: 3, day: 8, hour: 8)
    )!
    let restarted = try HydrationEngine(
        clock: clock,
        store: store,
        calendar: calendar
    ).snapshot

    #expect(restarted.todayEstimatedMilliliters == 0)
    #expect(restarted.recentDailySummaries[1].estimatedMilliliters == 25)
    #expect(restarted.records.count == 1)
    #expect(restarted.status == .paused)
}

@Test("daily summaries use the current local timezone to interpret absolute records")
func dailySummariesRebucketAcrossTimeZones() throws {
    let recordTimestamp = Date(timeIntervalSince1970: 1_804_464_600)
    let evaluatedAt = Date(timeIntervalSince1970: 1_804_506_000)
    let settings = HydrationSettings()
    let record = DrinkRecord(
        id: UUID(),
        timestamp: recordTimestamp,
        sipEstimate: .regular,
        sourceAction: .proactiveSip
    )
    let persistence = HydrationPersistence(
        settings: settings,
        records: [record],
        cycle: HydrationCycle(
            startedAt: recordTimestamp,
            reminderInterval: settings.reminderInterval
        )
    )
    var eastCalendar = Calendar(identifier: .gregorian)
    eastCalendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    var westCalendar = Calendar(identifier: .gregorian)
    westCalendar.timeZone = TimeZone(secondsFromGMT: -8 * 60 * 60)!

    let east = try HydrationEngine(
        clock: TestClock(now: evaluatedAt),
        store: InMemoryHydrationStore(persistence: persistence),
        calendar: eastCalendar
    ).snapshot
    let west = try HydrationEngine(
        clock: TestClock(now: evaluatedAt),
        store: InMemoryHydrationStore(persistence: persistence),
        calendar: westCalendar
    ).snapshot

    #expect(east.todayEstimatedMilliliters == 25)
    #expect(west.todayEstimatedMilliliters == 0)
    #expect(west.recentDailySummaries[1].estimatedMilliliters == 25)
}

@Test("calendar day intervals retain every record on DST transition days")
func dailySummariesRespectDSTDayLengths() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let settings = HydrationSettings()
    let localDates = [
        (components: DateComponents(year: 2027, month: 3, day: 14, hour: 12), hours: 23),
        (components: DateComponents(year: 2027, month: 11, day: 7, hour: 12), hours: 25)
    ]

    for localDate in localDates {
        let evaluatedAt = calendar.date(from: localDate.components)!
        let interval = try #require(calendar.dateInterval(of: .day, for: evaluatedAt))
        let records = [
            DrinkRecord(
                id: UUID(),
                timestamp: interval.start,
                sipEstimate: .small,
                sourceAction: .proactiveSip
            ),
            DrinkRecord(
                id: UUID(),
                timestamp: interval.end.addingTimeInterval(-1),
                sipEstimate: .large,
                sourceAction: .proactiveSip
            )
        ]
        let snapshot = try HydrationEngine(
            clock: TestClock(now: evaluatedAt),
            store: InMemoryHydrationStore(
                persistence: HydrationPersistence(
                    settings: settings,
                    records: records,
                    cycle: HydrationCycle(
                        startedAt: interval.start,
                        reminderInterval: settings.reminderInterval
                    )
                )
            ),
            calendar: calendar
        ).snapshot

        #expect(interval.duration == TimeInterval(localDate.hours * 60 * 60))
        #expect(snapshot.todayEstimatedMilliliters == 50)
        #expect(snapshot.recentDailySummaries[0].recordCount == 2)
    }
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

@Test("Codex activity supplies the Agent-aware reminder when fallback is disabled")
func codexActivityEnablesAgentAwareReminder() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(
        clock: clock,
        store: InMemoryHydrationStore()
    )
    _ = try engine.send(.setNoAgentFallbackEnabled(false))
    clock.now.addTimeInterval(30 * 60)

    let clockOnly = try engine.send(.timeAdvanced)
    let agentAware = try engine.send(
        .agentEvent(
            AgentEvent(
                kind: .toolUsed,
                sessionID: "synthetic-session",
                timestamp: clock.now,
                role: .root,
                attention: .none,
                toolClassification: .ordinary
            )
        )
    )

    #expect(clockOnly.status == .dueAmbient)
    #expect(clockOnly.reminderLevel == .hidden)
    #expect(agentAware.status == .dueAmbient)
    #expect(agentAware.reminderLevel == .ambient)
    #expect(agentAware.records.isEmpty)
}

@Test("a due reminder escalates only on the third qualifying tool in one turn")
func qualifyingToolStreakEscalatesOnThirdTool() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(
        clock: clock,
        store: InMemoryHydrationStore()
    )
    clock.now.addTimeInterval(30 * 60)

    let plan = try engine.send(.agentEvent(agentEvent(
        .planUpdated,
        sessionID: "turn-a",
        at: clock.now,
        tool: .plan
    )))
    let first = try engine.send(.agentEvent(agentEvent(
        .toolUsed,
        sessionID: "turn-a",
        at: clock.now,
        tool: .ordinary
    )))
    let second = try engine.send(.agentEvent(agentEvent(
        .toolUsed,
        sessionID: "turn-a",
        at: clock.now,
        tool: .ordinary
    )))
    let third = try engine.send(.agentEvent(agentEvent(
        .toolUsed,
        sessionID: "turn-a",
        at: clock.now,
        tool: .ordinary
    )))

    #expect(plan.reminderLevel == .ambient)
    #expect(first.reminderLevel == .ambient)
    #expect(second.reminderLevel == .ambient)
    #expect(third.status.rawValue == "dueStrong")
    #expect(third.reminderLevel.rawValue == "strong")
}

@Test("a verified active Subagent upgrades an already-due reminder")
func verifiedSubagentEscalatesDueReminder() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)

    let escalated = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "child-session",
        at: clock.now,
        role: .subagent,
        parentSessionID: "parent-session"
    )))

    #expect(escalated.status == .dueStrong)
    #expect(escalated.reminderLevel == .strong)
    #expect(escalated.records.isEmpty)
}

@Test("observation loss immediately returns a strong reminder to ordinary local fallback")
func observationLossFailsBackToAmbient() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    let strong = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "child-session",
        at: clock.now,
        role: .subagent,
        parentSessionID: "parent-session"
    )))

    let fallback = try engine.send(.agentObservationUnavailable)
    let repeated = try engine.send(.agentObservationUnavailable)

    #expect(strong.status == .dueStrong)
    #expect(fallback.status == .dueAmbient)
    #expect(fallback.reminderLevel == .ambient)
    #expect(fallback.records.isEmpty)
    #expect(fallback.cycle == strong.cycle)
    #expect(repeated == fallback)
}

@Test("a Subagent that starts before hydration is due does not create or carry a reminder")
func preDueSubagentDoesNotCreateReminder() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())

    let started = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "child-session",
        at: clock.now,
        role: .subagent,
        parentSessionID: "parent-session"
    )))
    clock.now.addTimeInterval(30 * 60)
    let due = try engine.send(.timeAdvanced)

    #expect(started.status == .accumulating)
    #expect(started.reminderLevel == .hidden)
    #expect(due.status == .dueAmbient)
    #expect(due.reminderLevel == .ambient)
    #expect(due.records.isEmpty)
}

@Test("Subagent completion and removal downgrade a strong reminder without clearing hydration due")
func terminalSubagentEventsDowngradeStrongReminder() throws {
    for terminalKind in [AgentEvent.Kind.completed, .sessionRemoved] {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
        clock.now.addTimeInterval(30 * 60)
        _ = try engine.send(.agentEvent(agentEvent(
            .sessionStarted,
            sessionID: "child-session",
            at: clock.now,
            role: .subagent,
            parentSessionID: "parent-session"
        )))

        let downgraded = try engine.send(.agentEvent(agentEvent(
            terminalKind,
            sessionID: "child-session",
            at: clock.now,
            role: .subagent,
            parentSessionID: "parent-session"
        )))

        #expect(downgraded.status == .dueAmbient)
        #expect(downgraded.reminderLevel == .ambient)
        #expect(downgraded.records.isEmpty)
        #expect(downgraded.cycle.startedAt == clock.now.addingTimeInterval(-30 * 60))
    }
}

@Test("root and Subagent sessions remain isolated by stable session identifiers")
func rootAndSubagentSessionsAreIsolated() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    _ = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "child-a",
        at: clock.now,
        role: .subagent,
        parentSessionID: "root-a"
    )))
    _ = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "root-b",
        at: clock.now
    )))

    let rootCompleted = try engine.send(.agentEvent(agentEvent(
        .completed,
        sessionID: "root-b",
        at: clock.now
    )))
    let childCompleted = try engine.send(.agentEvent(agentEvent(
        .completed,
        sessionID: "child-a",
        at: clock.now,
        role: .subagent,
        parentSessionID: "root-a"
    )))

    #expect(rootCompleted.reminderLevel == .strong)
    #expect(childCompleted.reminderLevel == .ambient)
}

@Test("confirming from a Subagent-triggered strong reminder uses the existing drink completion path")
func subagentStrongReminderUsesExistingDrinkRecordPath() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    _ = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "child-session",
        at: clock.now,
        role: .subagent,
        parentSessionID: "parent-session"
    )))

    let confirmed = try engine.send(.confirmSip)
    let duplicate = try engine.send(.confirmSip)

    #expect(confirmed.records.count == 1)
    #expect(confirmed.records.first?.sourceAction == .sipConfirmation)
    #expect(confirmed.todayEstimatedMilliliters == 25)
    #expect(confirmed.cycle.startedAt == clock.now)
    #expect(confirmed.status == .accumulating)
    #expect(duplicate.records.count == 1)
}

@Test("tool streaks are isolated by active Codex session")
func toolStreaksAreSessionScoped() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)

    for sessionID in ["turn-a", "turn-b", "turn-a", "turn-b"] {
        let snapshot = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: sessionID,
            at: clock.now,
            tool: .ordinary
        )))
        #expect(snapshot.reminderLevel == .ambient)
    }

    let thirdForA = try engine.send(.agentEvent(agentEvent(
        .toolUsed,
        sessionID: "turn-a",
        at: clock.now,
        tool: .ordinary
    )))
    #expect(thirdForA.reminderLevel.rawValue == "strong")
}

@Test("user input resets the qualifying tool streak for its turn")
func userInputResetsToolStreak() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)

    for _ in 0..<2 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "turn-a",
            at: clock.now,
            tool: .ordinary
        )))
    }
    _ = try engine.send(.agentEvent(agentEvent(
        .promptSubmitted,
        sessionID: "turn-a",
        at: clock.now
    )))
    for _ in 0..<2 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "turn-a",
            at: clock.now,
            tool: .ordinary
        )))
    }

    #expect(engine.snapshot.reminderLevel == .ambient)
}

@Test("completion and abort remove the autonomous signal without clearing due")
func terminalEventsDowngradeStrongReminder() throws {
    let terminalKinds: [AgentEvent.Kind] = [.completed, .aborted]

    for terminalKind in terminalKinds {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
        clock.now.addTimeInterval(30 * 60)
        for _ in 0..<3 {
            _ = try engine.send(.agentEvent(agentEvent(
                .toolUsed,
                sessionID: "turn-a",
                at: clock.now,
                tool: .ordinary
            )))
        }

        let downgraded = try engine.send(.agentEvent(agentEvent(
            terminalKind,
            sessionID: "turn-a",
            at: clock.now
        )))

        #expect(downgraded.status == .dueAmbient)
        #expect(downgraded.reminderLevel == .ambient)
        #expect(downgraded.records.isEmpty)
    }
}

@Test("session removal resets only the removed session streak")
func sessionRemovalResetsStreak() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    let removed = try #require(AgentEvent.Kind(rawValue: "sessionRemoved"))
    clock.now.addTimeInterval(30 * 60)
    for _ in 0..<2 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "turn-a",
            at: clock.now,
            tool: .ordinary
        )))
    }

    _ = try engine.send(.agentEvent(agentEvent(
        removed,
        sessionID: "turn-a",
        at: clock.now
    )))
    let nextTool = try engine.send(.agentEvent(agentEvent(
        .toolUsed,
        sessionID: "turn-a",
        at: clock.now,
        tool: .ordinary
    )))

    #expect(nextTool.reminderLevel == .ambient)
}

@Test("a stale session expires its strong signal and tool streak")
func staleSessionExpiresAutonomousSignal() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    for _ in 0..<3 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "turn-a",
            at: clock.now,
            tool: .ordinary
        )))
    }
    #expect(engine.snapshot.reminderLevel.rawValue == "strong")

    clock.now.addTimeInterval(5 * 60)
    let expired = try engine.send(.timeAdvanced)
    let nextTool = try engine.send(.agentEvent(agentEvent(
        .toolUsed,
        sessionID: "turn-a",
        at: clock.now,
        tool: .ordinary
    )))

    #expect(expired.status == .dueAmbient)
    #expect(expired.reminderLevel == .ambient)
    #expect(nextTool.reminderLevel == .ambient)
}

@Test("tool streaks never create a reminder before hydration is due")
func toolStreakCannotMakeHydrationDue() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())

    for _ in 0..<3 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "turn-a",
            at: clock.now,
            tool: .ordinary
        )))
    }

    #expect(engine.snapshot.status == .accumulating)
    #expect(engine.snapshot.reminderLevel == .hidden)
    #expect(engine.snapshot.records.isEmpty)
    #expect(engine.snapshot.cycle.startedAt == setup)
}

@Test("a pre-due tool streak cannot upgrade the reminder when the cycle becomes due")
func preDueToolStreakDoesNotCarryIntoDueState() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup.addingTimeInterval(30 * 60 - 1))
    let settings = HydrationSettings()
    let engine = try HydrationEngine(
        clock: clock,
        store: InMemoryHydrationStore(
            persistence: HydrationPersistence(
                settings: settings,
                records: [],
                cycle: HydrationCycle(
                    startedAt: setup,
                    reminderInterval: settings.reminderInterval
                )
            )
        )
    )
    for _ in 0..<3 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "turn-a",
            at: clock.now,
            tool: .ordinary
        )))
    }

    clock.now.addTimeInterval(1)
    let due = try engine.send(.timeAdvanced)

    #expect(due.status == .dueAmbient)
    #expect(due.reminderLevel == .ambient)
}

@Test("confirming from strong records one sip and starts one new cycle")
func strongReminderUsesExistingDrinkRecordPath() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    for _ in 0..<3 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "turn-a",
            at: clock.now,
            tool: .ordinary
        )))
    }

    let confirmed = try engine.send(.confirmSip)
    let duplicate = try engine.send(.confirmSip)

    #expect(confirmed.records.count == 1)
    #expect(confirmed.todayEstimatedMilliliters == 25)
    #expect(confirmed.cycle.startedAt == clock.now)
    #expect(confirmed.status == .accumulating)
    #expect(duplicate.records.count == 1)
}

@Test("root attention immediately collapses strong while preserving hydration context")
func rootAttentionCollapsesStrongAndPreservesHydration() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let existingRecord = DrinkRecord(
        id: UUID(),
        timestamp: setup,
        sipEstimate: .large,
        sourceAction: .sipConfirmation
    )
    let settings = HydrationSettings()
    let store = InMemoryHydrationStore(
        persistence: HydrationPersistence(
            settings: settings,
            records: [existingRecord],
            cycle: HydrationCycle(
                startedAt: setup,
                reminderInterval: settings.reminderInterval
            )
        )
    )
    let clock = TestClock(now: setup.addingTimeInterval(30 * 60))
    let engine = try HydrationEngine(clock: clock, store: store)
    _ = try engine.send(.setNoAgentFallbackEnabled(false))
    for _ in 0..<3 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "autonomous-root",
            at: clock.now,
            tool: .ordinary
        )))
    }
    #expect(engine.snapshot.reminderLevel == .strong)

    let collapsed = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "interactive-root",
        at: clock.now,
        attention: .required,
        tool: .userInput
    )))

    #expect(collapsed.status == .dueAmbient)
    #expect(collapsed.reminderLevel == .ambient)
    #expect(collapsed.cycle.startedAt == setup)
    #expect(collapsed.records == [existingRecord])
    #expect(collapsed.todayEstimatedMilliliters == 35)
    #expect(store.persistence?.records == [existingRecord])
}

@Test("attention leaves an active snooze and its stored hydration data unchanged")
func rootAttentionPreservesSnooze() throws {
    let setup = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: setup)
    let store = InMemoryHydrationStore()
    let engine = try HydrationEngine(clock: clock, store: store)
    clock.now.addTimeInterval(30 * 60)
    let snoozed = try engine.send(.snooze)
    let savedBeforeAttention = store.persistence

    let attention = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "interactive-root",
        at: clock.now,
        attention: .required,
        tool: .userInput
    )))

    #expect(attention.status == .snoozed)
    #expect(attention.reminderLevel == .ambient)
    #expect(attention.snoozedUntil == snoozed.snoozedUntil)
    #expect(attention.records.isEmpty)
    #expect(store.persistence == savedBeforeAttention)
}

@Test("one interactive root suppresses autonomous work in every session without replay")
func attentionSuppressesAllSessionsAndRequiresFreshToolStreak() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    _ = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "child",
        at: clock.now,
        role: .subagent,
        parentSessionID: "autonomous-root"
    )))
    #expect(engine.snapshot.reminderLevel == .strong)

    let collapsed = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "interactive-root",
        at: clock.now,
        attention: .required,
        tool: .userInput
    )))
    #expect(collapsed.reminderLevel == .ambient)

    for _ in 0..<3 {
        let suppressed = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "other-root",
            at: clock.now,
            tool: .ordinary
        )))
        #expect(suppressed.reminderLevel == .ambient)
    }

    let resolved = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "interactive-root",
        at: clock.now,
        attention: .none,
        tool: .userInput
    )))
    #expect(resolved.reminderLevel == .ambient)

    for expectedLevel in [ReminderLevel.ambient, .ambient, .strong] {
        let fresh = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "other-root",
            at: clock.now,
            tool: .ordinary
        )))
        #expect(fresh.reminderLevel == expectedLevel)
    }
}

@Test("two roots keep global suppression until both requests resolve")
func attentionResolutionIsAggregatedAcrossRoots() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)

    for sessionID in ["root-a", "root-b"] {
        _ = try engine.send(.agentEvent(agentEvent(
            .attentionChanged,
            sessionID: sessionID,
            at: clock.now,
            attention: .required,
            tool: .userInput
        )))
    }
    let oneResolved = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "root-a",
        at: clock.now,
        attention: .none,
        tool: .userInput
    )))
    _ = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "child",
        at: clock.now,
        role: .subagent,
        parentSessionID: "root-c"
    )))
    let bothResolved = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "root-b",
        at: clock.now,
        attention: .none,
        tool: .userInput
    )))

    #expect(oneResolved.reminderLevel == .ambient)
    #expect(bothResolved.reminderLevel == .ambient)

    let newSubagent = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "new-child",
        at: clock.now,
        role: .subagent,
        parentSessionID: "root-c"
    )))
    #expect(newSubagent.reminderLevel == .strong)
}

@Test("completion abort removal and stale cleanup cannot leave ghost attention")
func terminalAndStaleEventsClearAttention() throws {
    for terminalKind in [
        AgentEvent.Kind.completed,
        .aborted,
        .sessionRemoved
    ] {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
        clock.now.addTimeInterval(30 * 60)
        _ = try engine.send(.agentEvent(agentEvent(
            .attentionChanged,
            sessionID: "interactive-root",
            at: clock.now,
            attention: .required,
            tool: .userInput
        )))
        _ = try engine.send(.agentEvent(agentEvent(
            terminalKind,
            sessionID: "interactive-root",
            at: clock.now
        )))
        let fresh = try engine.send(.agentEvent(agentEvent(
            .sessionStarted,
            sessionID: "fresh-child",
            at: clock.now,
            role: .subagent,
            parentSessionID: "other-root"
        )))

        #expect(fresh.reminderLevel == .strong)
    }

    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    _ = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "stale-root",
        at: clock.now,
        attention: .required,
        tool: .userInput
    )))
    clock.now.addTimeInterval(5 * 60)
    let staleRemoved = try engine.send(.timeAdvanced)
    let fresh = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "fresh-child",
        at: clock.now,
        role: .subagent,
        parentSessionID: "other-root"
    )))

    #expect(staleRemoved.reminderLevel == .ambient)
    #expect(fresh.reminderLevel == .strong)
}

@Test("non-actionable background metadata does not suppress strong")
func backgroundMetadataDoesNotSuppressStrongReminder() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    _ = try engine.send(.agentEvent(agentEvent(
        .sessionStarted,
        sessionID: "child",
        at: clock.now,
        role: .subagent,
        parentSessionID: "root-a"
    )))

    let metadata = try engine.send(.agentEvent(agentEvent(
        .planUpdated,
        sessionID: "background-root",
        at: clock.now,
        tool: .plan
    )))

    #expect(metadata.status == .dueStrong)
    #expect(metadata.reminderLevel == .strong)
}

@Test("same-session plan and tool activity cannot resolve attention")
func sameSessionActivityDoesNotResolveAttention() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    for _ in 0..<3 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "interactive-root",
            at: clock.now,
            tool: .ordinary
        )))
    }
    _ = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "interactive-root",
        at: clock.now,
        attention: .required,
        tool: .userInput
    )))

    let plan = try engine.send(.agentEvent(agentEvent(
        .planUpdated,
        sessionID: "interactive-root",
        at: clock.now,
        tool: .plan
    )))
    var tool = plan
    for _ in 0..<3 {
        tool = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "interactive-root",
            at: clock.now,
            tool: .ordinary
        )))
    }

    #expect(plan.reminderLevel == .ambient)
    #expect(tool.reminderLevel == .ambient)

    let resolved = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "interactive-root",
        at: clock.now,
        attention: .none,
        tool: .userInput
    )))
    #expect(resolved.reminderLevel == .ambient)
}

@Test("a completed question hook cannot clear another pending request")
func mixedHookAttentionWaitsForCorrelatedResolution() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    let hookPayloads = [
        #"{"hook_event_name":"PermissionRequest","session_id":"interactive-root","tool_name":"Bash","tool_input":{"command":"synthetic private command"}}"#,
        #"{"hook_event_name":"PreToolUse","session_id":"interactive-root","tool_name":"request_user_input","tool_input":{"questions":["synthetic private question"]}}"#,
        #"{"hook_event_name":"PostToolUse","session_id":"interactive-root","tool_name":"request_user_input","tool_response":{"answers":["synthetic private answer"]}}"#
    ]
    for payload in hookPayloads {
        let event = try #require(AgentEventAdapter.normalizeHook(
            Data(payload.utf8),
            observedAt: clock.now
        ))
        _ = try engine.send(.agentEvent(event))
    }

    var whilePermissionPending = engine.snapshot
    for _ in 0..<3 {
        whilePermissionPending = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "other-root",
            at: clock.now,
            tool: .ordinary
        )))
    }

    #expect(whilePermissionPending.reminderLevel == .ambient)

    _ = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "interactive-root",
        at: clock.now,
        attention: .none,
        tool: .userInput
    )))
    for expectedLevel in [ReminderLevel.ambient, .ambient, .strong] {
        let fresh = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "other-root",
            at: clock.now,
            tool: .ordinary
        )))
        #expect(fresh.reminderLevel == expectedLevel)
    }
}

@Test("daily acceptance flow returns to a new cycle after an approximate sip")
func dailyAcceptanceFlowStartsNewCycle() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: start)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())

    clock.now.addTimeInterval(30 * 60)
    let dueB = try engine.send(.timeAdvanced)
    for _ in 0..<3 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "acceptance-root",
            at: clock.now,
            tool: .ordinary
        )))
    }
    let qualifyingC = engine.snapshot
    let needsUserB = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "acceptance-root",
        at: clock.now,
        attention: .required,
        tool: .userInput
    )))
    _ = try engine.send(.agentEvent(agentEvent(
        .attentionChanged,
        sessionID: "acceptance-root",
        at: clock.now,
        attention: .none,
        tool: .userInput
    )))
    for _ in 0..<3 {
        _ = try engine.send(.agentEvent(agentEvent(
            .toolUsed,
            sessionID: "acceptance-root",
            at: clock.now,
            tool: .ordinary
        )))
    }
    let freshC = engine.snapshot
    let confirmed = try engine.send(.confirmSip)

    #expect(dueB.reminderLevel == .ambient)
    #expect(qualifyingC.reminderLevel == .strong)
    #expect(needsUserB.reminderLevel == .ambient)
    #expect(freshC.reminderLevel == .strong)
    #expect(confirmed.todayEstimatedMilliliters == 25)
    #expect(confirmed.records.last?.estimatedMilliliters == 25)
    #expect(confirmed.cycle.startedAt == clock.now)
    #expect(confirmed.status == .accumulating)
}

@Test("a proactive sip records while accumulating and can be dismissed without undoing")
func proactiveSipIsIndependentFromReminderVisibility() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: start)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(4 * 60)

    let recorded = try engine.send(.recordProactiveSip)
    let recordID = try #require(recorded.undoableDrinkRecord?.id)
    let dismissed = try engine.send(.dismissConfirmation)
    let undone = try engine.send(.undoDrink(recordID))

    #expect(recorded.records.count == 1)
    #expect(recorded.records[0].sourceAction == .proactiveSip)
    #expect(recorded.records[0].estimatedMilliliters == 25)
    #expect(recorded.todayEstimatedMilliliters == 25)
    #expect(recorded.cycle.startedAt == clock.now)
    #expect(recorded.reminderLevel == .confirmation)
    #expect(dismissed.reminderLevel == .hidden)
    #expect(dismissed.undoableDrinkRecord?.id == recordID)
    #expect(dismissed.todayEstimatedMilliliters == 25)
    #expect(undone.records.isEmpty)
    #expect(undone.cycle.startedAt == start)
}

@Test("a proactive sip clears snooze and preserves pause through record and undo")
func proactiveSipPreservesPauseAndRestoresPreviousContext() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: start)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(30 * 60)
    let snoozed = try engine.send(.snooze)
    _ = try engine.send(.setPaused(true))

    clock.now.addTimeInterval(2 * 60)
    let recorded = try engine.send(.recordProactiveSip)
    let recordID = try #require(recorded.undoableDrinkRecord?.id)
    let undone = try engine.send(.undoDrink(recordID))

    #expect(recorded.status == .paused)
    #expect(recorded.reminderLevel == .confirmation)
    #expect(recorded.snoozedUntil == nil)
    #expect(recorded.cycle.startedAt == clock.now)
    #expect(undone.status == .paused)
    #expect(undone.snoozedUntil == snoozed.snoozedUntil)
    #expect(undone.cycle.startedAt == start)
}

@Test("a bottle completion reconciles to the next strict capacity checkpoint")
func bottleCompletionAddsOnlyTheCheckpointDifference() throws {
    let cases = [
        (capacity: 1_000, existing: 700, expectedAdjustment: 300, expectedTotal: 1_000),
        (capacity: 1_000, existing: 1_200, expectedAdjustment: 800, expectedTotal: 2_000),
        (capacity: 1_000, existing: 1_000, expectedAdjustment: 1_000, expectedTotal: 2_000),
        (capacity: 500, existing: 1_200, expectedAdjustment: 300, expectedTotal: 1_500)
    ]

    for testCase in cases {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(now: start)
        let settings = HydrationSettings(
            bottleCapacityMilliliters: testCase.capacity
        )
        let records = (0..<(testCase.existing / SipEstimate.regular.milliliters)).map { _ in
            DrinkRecord(
                id: UUID(),
                timestamp: start,
                sipEstimate: .regular,
                sourceAction: .proactiveSip
            )
        }
        let store = InMemoryHydrationStore(
            persistence: HydrationPersistence(
                settings: settings,
                records: records,
                cycle: HydrationCycle(
                    startedAt: start,
                    reminderInterval: settings.reminderInterval
                )
            )
        )
        let engine = try HydrationEngine(clock: clock, store: store)
        clock.now.addTimeInterval(5 * 60)

        let reconciled = try engine.send(.completeBottle)

        #expect(reconciled.records.dropLast() == records[...])
        #expect(reconciled.records.last?.sourceAction == .bottleReconciliation)
        #expect(reconciled.records.last?.estimatedMilliliters == testCase.expectedAdjustment)
        #expect(reconciled.todayEstimatedMilliliters == testCase.expectedTotal)
        #expect(reconciled.cycle.startedAt == clock.now)
    }
}

@Test("bottle capacity affects future checkpoints without changing sip estimate")
func bottleCapacityIsIndependentFromSipEstimate() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: start)
    let store = InMemoryHydrationStore()
    let engine = try HydrationEngine(clock: clock, store: store)

    let configured = try engine.send(.setBottleCapacityMilliliters(500))
    let reconciled = try engine.send(.completeBottle)
    let restarted = try HydrationEngine(clock: clock, store: store)

    #expect(configured.settings.bottleCapacityMilliliters == 500)
    #expect(reconciled.todayEstimatedMilliliters == 500)
    #expect(reconciled.settings.sipEstimate == .regular)
    #expect(restarted.snapshot.settings.bottleCapacityMilliliters == 500)
}

@Test("deliberate menu drink actions never retain a strong Codex presentation")
func deliberateDrinkActionsEndStrongPresentation() throws {
    for action in [HydrationEngine.Action.recordProactiveSip, .completeBottle] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(now: start)
        let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
        clock.now.addTimeInterval(30 * 60)
        for _ in 0..<3 {
            _ = try engine.send(.agentEvent(agentEvent(
                .toolUsed,
                sessionID: "manual-drink-root",
                at: clock.now,
                tool: .ordinary
            )))
        }
        #expect(engine.snapshot.reminderLevel == .strong)

        let recorded = try engine.send(action)
        let dismissed = try engine.send(.dismissConfirmation)

        #expect(recorded.status == .accumulating)
        #expect(recorded.reminderLevel == .confirmation)
        #expect(dismissed.reminderLevel == .hidden)
    }
}

@Test("a bottle checkpoint reconciles the current bottle across midnight")
func bottleCheckpointIsIndependentFromLocalDayTotal() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    let yesterday = calendar.date(
        from: DateComponents(year: 2027, month: 1, day: 4, hour: 23, minute: 50)
    )!
    let today = calendar.date(
        from: DateComponents(year: 2027, month: 1, day: 5, hour: 0, minute: 10)
    )!
    let yesterdaySips = (0..<20).map { _ in
        DrinkRecord(
            id: UUID(),
            timestamp: yesterday,
            sipEstimate: .large,
            sourceAction: .proactiveSip
        )
    }
    let todaySips = (0..<5).map { _ in
        DrinkRecord(
            id: UUID(),
            timestamp: today,
            sipEstimate: .large,
            sourceAction: .proactiveSip
        )
    } + [
        DrinkRecord(
            id: UUID(),
            timestamp: today,
            sipEstimate: .regular,
            sourceAction: .proactiveSip
        )
    ]
    let records = yesterdaySips + todaySips
    let settings = HydrationSettings()
    let store = InMemoryHydrationStore(
        persistence: HydrationPersistence(
            settings: settings,
            records: records,
            cycle: HydrationCycle(
                startedAt: today,
                reminderInterval: settings.reminderInterval
            )
        )
    )
    let engine = try HydrationEngine(
        clock: TestClock(now: today),
        store: store,
        calendar: calendar
    )

    let reconciled = try engine.send(.completeBottle)

    #expect(reconciled.records.last?.estimatedMilliliters == 100)
    #expect(reconciled.todayEstimatedMilliliters == 300)
}

@Test("undoing a bottle completion removes only its adjustment and restores a paused cycle")
func bottleCompletionUndoRestoresContext() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: start)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    _ = try engine.send(.recordProactiveSip)
    clock.now.addTimeInterval(60)
    _ = try engine.send(.setPaused(true))
    let previousCycle = engine.snapshot.cycle

    let reconciled = try engine.send(.completeBottle)
    let adjustmentID = try #require(reconciled.undoableDrinkRecord?.id)
    let undone = try engine.send(.undoDrink(adjustmentID))

    #expect(reconciled.status == .paused)
    #expect(reconciled.todayEstimatedMilliliters == 1_000)
    #expect(undone.status == .paused)
    #expect(undone.records.count == 1)
    #expect(undone.todayEstimatedMilliliters == 25)
    #expect(undone.cycle == previousCycle)
}

@Test("failed proactive and bottle saves leave hydration state unchanged")
func deliberateDrinkActionsAreAtomicOnPersistenceFailure() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let settings = HydrationSettings()
    let initial = HydrationPersistence(
        settings: settings,
        records: [],
        cycle: HydrationCycle(
            startedAt: start,
            reminderInterval: settings.reminderInterval
        )
    )
    let store = FailingHydrationStore(persistence: initial)
    let engine = try HydrationEngine(clock: TestClock(now: start), store: store)
    let before = engine.snapshot
    store.shouldFailSave = true

    #expect(throws: FailingHydrationStore.SaveError.self) {
        try engine.send(.recordProactiveSip)
    }
    #expect(engine.snapshot == before)
    #expect(throws: FailingHydrationStore.SaveError.self) {
        try engine.send(.completeBottle)
    }
    #expect(engine.snapshot == before)
}

@Test("the snapshot derives countdown time from the existing hydration cycle")
func snapshotProvidesExistingCycleCountdown() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(now: start)
    let engine = try HydrationEngine(clock: clock, store: InMemoryHydrationStore())
    clock.now.addTimeInterval(17 * 60 + 26)

    let snapshot = try engine.send(.timeAdvanced)
    #expect(snapshot.remainingTimeUntilReminder == TimeInterval(12 * 60 + 34))
}

private func agentEvent(
    _ kind: AgentEvent.Kind,
    sessionID: String,
    at timestamp: Date,
    role: AgentRole = .root,
    parentSessionID: String? = nil,
    attention: AgentAttention = .none,
    tool: AgentToolClassification? = nil
) -> AgentEvent {
    AgentEvent(
        kind: kind,
        sessionID: sessionID,
        parentSessionID: parentSessionID,
        timestamp: timestamp,
        role: role,
        attention: attention,
        toolClassification: tool
    )
}

private final class TestClock: HydrationClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class FailingHydrationStore: HydrationStore {
    enum SaveError: Error { case failed }

    var persistence: HydrationPersistence?
    var shouldFailSave = false

    init(persistence: HydrationPersistence?) {
        self.persistence = persistence
    }

    func load() throws -> HydrationPersistence? { persistence }

    func save(_ persistence: HydrationPersistence) throws {
        if shouldFailSave { throw SaveError.failed }
        self.persistence = persistence
    }
}
