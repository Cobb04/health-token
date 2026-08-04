# Health Token

Health Token is a local-first macOS hydration helper. After a 30-minute
hydration cycle, it shows a quiet water drop beneath the built-in notch or at
the top center of the active display. Opening the drop lets you record one
deliberate sip and see today's estimated total.

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

## Verify

```sh
swift test --disable-index-store
swift build --disable-index-store
```
