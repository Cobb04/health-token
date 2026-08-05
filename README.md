# Health Token

Health Token is a local-first macOS hydration helper. After a 30-minute
hydration cycle, it shows a quiet water drop beneath the built-in notch or at
the top center of the active display. Opening the drop lets you record one
deliberate sip, snooze for 15 minutes, undo a just-created record, and see
today's estimated total. The menu bar provides pause/resume, 15/25/35 mL sip
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

## Codex observation

Use **启用 Codex 观察** in the menu bar to add Health Token's read-only
handlers to `~/.codex/hooks.json`. Existing hook groups and handlers are
preserved. Codex requires newly configured local hooks to be reviewed; after
enabling, open `/hooks` in Codex and trust the Health Token command. Disabling
observation removes only handlers whose command exactly matches Health Token's
bundled helper.

The menu bar reports:

- **Connected** while the complete Health Token hook set is configured and a
  handler has delivered a recent lifecycle event. It falls back if delivery
  stops.
- **Fallback only** when local Codex sessions are present but lifecycle events
  are not connected. Hydration due state still uses ambient B behavior.
- **Unavailable** when no supported local Codex installation is detected.

The adapter follows the public [Codex hooks
contract](https://developers.openai.com/codex/hooks). A bounded incremental
tail of recent local rollout files supplies verified Subagent metadata and
terminal lifecycle evidence used for recovery and fallback. Startup restores
only recently modified verified Subagents whose bounded tail has no completion
or abort, then begins at each file tail so completed history is not replayed.
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
