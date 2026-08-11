# Pablo

Pablo records an interaction with a running macOS application as a synchronized session package. A recording contains:

- H.264 video of the app's largest visible window, including the pointer.
- Global keyboard, mouse, drag, and scroll events while the target app is active.
- An initial accessibility tree followed by structural deltas after input and at a periodic interval.
- A manifest that ties every artifact to one monotonic nanosecond timeline.

Pablo is a native menu-bar app. Choose a running application, then start, pause, resume, or stop from the menu-bar panel. Paused time is removed from the shared timeline and video instead of becoming an empty section of the recording.

## Build the app

Requires macOS 14 or newer and an Xcode toolchain with Swift 6.2 support.

```sh
./scripts/build-app.sh
open dist/Pablo.app
```

The script creates `dist/Pablo.app` and automatically uses the first installed Apple Development signing identity. This stable identity allows macOS privacy approvals to survive rebuilds. Override the selection by setting `PABLO_SIGNING_IDENTITY` to an exact identity name.

The source icon is [Resources/AppIcon/PabloAppIcon.png](Resources/AppIcon/PabloAppIcon.png). The build compiles its macOS size variants from `Resources/Assets.xcassets` into the application bundle.

## Permissions

The first recording requests three macOS privacy permissions for Pablo:

- **Accessibility** to read UI elements and create the event tap.
- **Input Monitoring** to observe keyboard and pointer input.
- **Screen & System Audio Recording** to capture window frames.

After enabling a permission in System Settings, macOS may require Pablo to be restarted. The panel links directly to each required privacy pane. Pablo only writes local files and has no network code.

Typed Unicode text is recorded by default because it is part of an exact interaction trace. This can include sensitive text. Use `--no-text` to retain key codes, key transitions, and modifiers while omitting decoded text. Values exposed by secure accessibility text fields are always replaced with `<redacted>`.

## Record from the menu bar

1. Open Pablo. Its recorder window appears immediately, and the same controls remain available from the circular record icon in the menu bar after the window is closed.
2. Choose a running application.
3. Click **Start Recording**.
4. Use **Pause**, **Resume**, and **Stop** from the same panel.

Recordings are saved under `~/Movies/Pablo Recordings`. **Show Recordings** opens that folder in Finder.

## Command-line interface

The command-line interface remains available for scripting. Build it with `swift build`. The target must already be running and have a visible window:

```sh
.build/debug/pablo record --app Notes -o notes-session.pablo
.build/debug/pablo record --bundle-id com.apple.Notes --duration 30
.build/debug/pablo record --pid 1234 --fps 60 --snapshot-interval 0.5
```

Press Control-C to end a recording without `--duration`. Replay inspection commands default to the latest recording, so common workflows are short:

```sh
pablo recordings
pablo latest
pablo inspect
pablo frames
pablo frame A11Y-012
pablo frame A11Y-012 --changed
pablo events --limit 25
```

Pass a `.pablo` path to `inspect`, `frames`, `frame`, or `events` to choose a different recording. Add `--json` for structured output. Each accessibility snapshot has the same stable `A11Y-###` reference in the replay UI and CLI. The app bundle includes the CLI at `Pablo.app/Contents/MacOS/pablo`.

## Package layout

```text
notes-session.pablo/
├── manifest.json
├── video.mov
├── events.jsonl
└── accessibility.jsonl
```

`events.jsonl` stores one event per line. Each event has a nanosecond `timestampNs`, event type, modifier flags, and the fields relevant to that event. Coordinates use the global macOS display coordinate space.

`accessibility.jsonl` starts with a `kind: "full"` record. Later `kind: "delta"` records contain `upserts` for new or changed nodes and `removed` node IDs. Each node is flat and references its parent and ordered children by ID. This lets a player maintain a materialized tree without rewriting the full tree after every interaction.

See [docs/recording-format.md](docs/recording-format.md) for the replay algorithm and schema notes.

## License

Pablo is available under the [Apache License 2.0](LICENSE).

## Current boundaries

- Video follows the largest visible window present when recording starts. Menus, popovers, and windows created later may not appear in that window stream, although their accessibility elements can still appear in snapshots.
- Accessibility APIs expose less state than a browser DOM. Some apps publish sparse trees, canvas content, or unstable element identities.
- Secure input mode and protected video surfaces can prevent capture at the operating-system level.
- The accessibility walker is bounded to 30 levels and 10,000 nodes per snapshot. A record reports `truncated: true` when either bound is hit.
- This format captures observed state and inputs; it does not yet guarantee deterministic re-execution.
