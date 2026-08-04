# Health Token

Health Token is a local-first macOS hydration helper. After a 30-minute
hydration cycle, it shows a quiet water drop beneath the built-in notch or at
the top center of the active display. Opening the drop lets you record one
deliberate sip, snooze for 15 minutes, undo a just-created record, and see
today's estimated total. The menu bar provides pause/resume, 15/25/35 mL sip
presets, 15/30/45/60-minute reminder intervals, and a no-Agent fallback toggle.

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
tail of recent local rollout files supplies turn-abort events that hooks do not
currently expose; startup begins at the file tail so completed history is not
replayed. Inputs normalize to `AgentEvent` values with these kinds:
`sessionStarted`, `promptSubmitted`, `planUpdated`, `toolUsed`,
`attentionChanged`, `completed`, and `aborted`. Every event contains only
session identity, receipt timestamp, root/Subagent role, attention state, and
an optional `ordinary`, `plan`, or `userInput` tool classification.

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
