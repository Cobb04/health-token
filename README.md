# Health Token

Health Token is a local-first macOS hydration helper. After a 30-minute
hydration cycle, it shows a quiet water drop beneath the built-in notch or at
the top center of the active display. Opening the drop lets you record one
deliberate sip, snooze for 15 minutes, undo a just-created record, and see
today's estimated total. The menu bar shows the current cycle as a blue numeric
countdown and always lets you record a proactive sip. You can also select a
usual bottle capacity and use **喝完一瓶** to add only the difference needed to
complete the current bottle, avoiding double-counting earlier sips even when a
bottle spans midnight.
Both actions restart the hydration cycle, remain available while paused, and
share a ten-second undo. The lightweight confirmation can be dismissed with a
long press without undoing its Drink Record. The menu bar also provides
pause/resume, 15/25/35 mL sip presets, 500/750/1000/1500/2000 mL bottle
presets, 15/30/45/60-minute reminder intervals, and a no-Agent fallback toggle.
When hydration is already due, either a verified Codex Subagent session or
three qualifying tool calls in one active Codex turn temporarily upgrades the
water drop to an original pixel character holding a cup. Subagents are
classified only from explicit upstream signals: `SubagentStart` hooks or
`source.subagent.thread_spawn` rollout metadata. They are never inferred from
working directory, timing, process count, nickname, or activity volume. The
character records through the same deliberate sip action as the ambient
reminder. If any interactive root session requests permission or calls
`request_user_input`, the character immediately collapses to the non-activating
water drop across all sessions. The due cycle, snooze, estimated total, and
Drink Records remain unchanged. Resolving the request does not replay an older
tool streak or Subagent start; a new qualifying autonomous-work signal is
required before the character can return.

Every displayed volume is an approximation. Health Token does not show a
medical hydration target or claim to measure actual intake.

## Run locally

The project requires Swift 6 and macOS 13 or later.

```sh
swift run HealthToken
```

To build a native application bundle:

```sh
./scripts/build-app.sh
open .build/release/HealthToken.app
```

Settings, the current hydration-cycle anchor, and drink records are stored at
`~/Library/Application Support/HealthToken/hydration.json`.

## Daily hydration totals

Drink Records remain the only persisted source of truth. Health Token derives
today and the previous 364 natural days from the current system Calendar and
time zone; it never clears records or persists a separate mutable daily total.
The Settings window presents the same history as a native daily heatmap with
**季度** (the latest 84 days) and **年度** (the latest 365 days) tabs. Hovering
the plot shows the exact local date, estimated volume, and bottle equivalent.

Heatmap intensity uses stable multiples of the user's bottle capacity: no
record, less than one bottle, one bottle, two bottles, and three or more. It
does not normalize against the largest day in the visible period and does not
claim that any level is a medical hydration target. Dates before the earliest
surviving Drink Record are shown as unavailable rather than as zero intake.

Daily summaries refresh on app launch, menu presentation, calendar-day change,
system clock or time-zone change, locale change, and wake from sleep. The
one-second presentation poll remains a self-healing fallback. Crossing midnight
does not restart the hydration cycle, resume a paused app, or delete history.
An overdue reminder from the previous evening remains due after wake, but stale
Codex activity expires so it returns as the low-interruption reminder until new
qualifying activity arrives.

## Codex observation

Use **启用 Codex 观察** in the menu bar to add Health Token's read-only
handlers to `~/.codex/hooks.json`. Existing hook groups and handlers are
preserved. No slash command is required: after enabling observation, start a
Codex task and Health Token confirms the connection from the first trusted hook
or bounded local rollout event. Disabling observation removes only handlers
whose command exactly matches Health Token's bundled helper.

The menu bar also supports proactive one-sip records and bottle checkpoint
reconciliation. Choose a common bottle preset or enter any whole-milliliter
capacity from 100–5000 mL. Completing a bottle adjusts the current bottle to its
capacity instead of adding a second full bottle on top of sips already recorded.
Bottle progress is independent of calendar-day totals.

The menu bar reports:

- **Disabled** when Health Token's hook entries are not configured.
- **Waiting for first event** after observation is enabled but before a trusted
  hook or rollout event is received.
- **Connected** while the complete Health Token hook set is configured and a
  handler has delivered a recent lifecycle event. It falls back if delivery
  stops.
- **Fallback only** after an event has been observed but fresh trusted hook
  delivery is unavailable. Ordinary timed reminders continue when fallback is
  enabled.
- **Unavailable** when no supported local Codex installation is detected.

The adapter normalizes local Codex hook events. Rollout discovery visits at
most 512 directory entries (to depth six), considers at most eight rollout
files modified during the previous ten minutes, and never scans the complete
Codex history. Every poll may read at most 64 KiB from one file and 256 KiB in
total, including a 32 KiB-per-file session-metadata prefix. One JSONL record
and each retained partial record are capped at 32 KiB. Parser state is limited
to the eight active files and 32 opaque attention request IDs per file; opaque
IDs are capped at 128 UTF-8 bytes.

At startup, the bounded prefix/tail inspection emits no prompt, tool, or
Subagent lifecycle event. It may restore one root attention-required state
only when complete, monotonically timestamped records prove that a
`request_user_input` or approval created during the previous two minutes has
no matching output/execution start and no later completion or abort. Only the
opaque request ID remains in memory so a subsequent resolution can clear the
state; question text, options, commands, output, and unknown fields are never
retained in normalized events or persistence. Malformed, partial, oversized,
unknown, stale, future-dated, or out-of-order evidence cannot create a strong
reminder. After startup, per-file cursors read only appended bytes; unchanged
files are not reparsed, partial-record memory stays bounded, and files leaving
the active candidate set lose their Agent signal.
Inputs normalize to `AgentEvent` values with these kinds:
`sessionStarted`, `promptSubmitted`, `planUpdated`, `toolUsed`,
`attentionChanged`, `completed`, `aborted`, and `sessionRemoved`. Every event
contains only session identity, optional verified parent-session identity,
receipt timestamp, root/Subagent role, attention state, and an optional
`ordinary`, `plan`, or `userInput` tool classification.

Qualifying tool streaks and verified Subagent signals are isolated per session.
They reset on completion, abort, session removal, or five minutes without
session activity; user input also resets a qualifying tool streak.
Plan updates and metadata, telemetry, or Health Token integration operations do
not contribute to a streak. Completion or expiry collapses the pixel reminder
back to the persistent water drop without recording a drink or clearing the
hydration cycle. Attention-required state is aggregated across root sessions,
expires with the same lifecycle cleanup, and always outranks every tool-streak
or Subagent signal.

The app polls the bounded observer once per second, keeping a qualifying append
within the two-second presentation budget under the representative synthetic
load in the test suite. If Codex is missing, observation is disabled, rollout
reading fails, or the configured hooks stop delivering events, the existing
menu-bar status reports fallback-only or unavailable. The clock-driven local
hydration loop continues and does not post repeated failure notifications.

Prompt bodies, source code, tool arguments, assistant output, transcript paths,
working directories, model names, and unknown upstream fields are discarded
before an event enters the local inbox. The hook helper returns an empty JSON
decision and never approves, denies, rewrites, continues, or answers Codex.
Consumed inbox files are removed, and Agent events are not added to
`hydration.json`. Codex activity cannot record a drink or reset a hydration
cycle. Disabling Codex observation stops both lifecycle hooks and local rollout
tailing.

## Verify

```sh
swift test --disable-index-store
swift build --disable-index-store
```
