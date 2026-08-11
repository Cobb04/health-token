# Daily hydration time-boundary research

Researched 2026-08-11 against Apple documentation and fixed commits from
open-source macOS menu-bar applications.

## Decision

Health Token treats Drink Records as the only persisted source of truth. It
derives today and recent Hydration Days with the current system Calendar and
time zone. It does not persist a mutable daily total or clear records at
midnight.

For each Hydration Day, records are selected with the half-open interval
`[day.start, day.end)`, where the interval comes from
`Calendar.dateInterval(of: .day, for:)`. Recent days are reached with calendar
day arithmetic rather than fixed 86,400-second offsets. This covers daylight
saving days with 23 or 25 hours.

The MVP interprets records using the user's current system time zone. A time-zone
change can therefore move a near-midnight record to a neighboring Hydration Day.
Persisting a record-time time zone remains a future option if user research shows
that historical travel semantics matter.

Daily totals, Hydration Cycles, and Bottle Progress are separate concepts:

- a new day changes summaries only;
- the reminder cycle continues across midnight;
- pause remains paused;
- Bottle Progress can span days and cannot use today's total as its checkpoint.

## Platform evidence

Apple provides distinct invalidation signals for calendar day, system clock,
system time zone, locale, and workspace wake. `Calendar.autoupdatingCurrent`
tracks preference changes, but Apple warns that values derived from a calendar
are not automatically invalidated.

- [Apple Calendar](https://developer.apple.com/documentation/foundation/calendar)
- [Apple Calendar.autoupdatingCurrent](https://developer.apple.com/documentation/foundation/nscalendar/autoupdatingcurrent)
- [Apple NSCalendarDayChanged](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/nscalendardaychanged)
- [Apple NSSystemTimeZoneDidChange](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/nssystemtimezonedidchange)
- [Apple NSWorkspace.didWakeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification)

The shared open-source pattern is event-driven refresh plus a self-healing
fallback:

- [CodexBar at `8d113c6`](https://github.com/steipete/CodexBar/blob/8d113c6425160ebd63d62cabd86508eecdeb3ebf/Sources/CodexBar/StatusItemController%2BCountdownRefresh.swift#L88-L143)
  computes the next local day boundary with Calendar and observes day, clock,
  and time-zone changes.
- [Calendr at `8177942`](https://github.com/pakerwreah/Calendr/blob/817794261798a28d15d29cdeb9899af6f472b765/Calendr/Main/MainViewModel.swift#L130-L142)
  merges day changes and workspace wake into one refresh stream.
- [MeetingBar at `26eef52`](https://github.com/leits/MeetingBar/blob/26eef52e008a98e42f87fd1a560f404cb615bf03/MeetingBar/App/LifecycleObserver.swift#L45-L84)
  explicitly observes wake, clock, time-zone, and calendar-day lifecycle events.
- [NetNewsWire at `63468ce`](https://github.com/Ranchero-Software/NetNewsWire/blob/63468ce88249e6542895ba18af51925fe78a76cd/Shared/SmartFeeds/SmartFeed.swift#L49-L76)
  refreshes on launch, activation, and day change and moves notification work to
  the MainActor.

## Applied design

Health Token uses a single idempotent temporal refresh path for launch, menu
appearance, day change, clock change, time-zone change, locale change, and wake.
The existing presentation poll is retained only as a fallback.

The compact 264-point menu remains unchanged. The Settings window uses a native
Swift Charts heatmap with quarterly and yearly tabs, exact selected-day text,
localized dates, and one complete VoiceOver label per day. This preserves the
primary one-sip action while giving long-term history a dedicated settings
surface.
