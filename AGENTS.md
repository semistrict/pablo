# Pablo development guide

Pablo is a native macOS menu-bar desktop-session recorder, live application inspector, and consent-gated automation bridge. It records either one application window or an entire display, with attributed input, evolving apps and windows, and independently materialized accessibility roots on one monotonic timeline.

## Requirements

- macOS 14 or newer
- Xcode toolchain with Swift 6.2 support
- Buf CLI 1.72 or newer when changing protobuf schemas
- Accessibility, Input Monitoring, and Screen & System Audio Recording permissions for end-to-end recording tests
- An Apple Development certificate for stable local privacy grants
- A Developer ID Application certificate and configured notary profile for distribution

The project uses Swift Package Manager directly; there is no `.xcodeproj`.

## Repository map

- `Sources/Pablo/` — recording engine, models, replay reader, CLI parser, and local control protocol
- `Sources/PabloApp/` — SwiftUI/AppKit menu-bar application, permission flow, approval UI, and replay UI
- `Sources/PabloCLI/` — executable entry point for the `pablo` command
- `proto/pablo/v3/` — protobuf source of truth for recording streams and local RPC
- `Sources/Pablo/Generated/` — Buf-generated Swift; never edit directly
- `Tests/PabloTests/` — XCTest and Swift Testing suites
- `Resources/Pablo-Info.plist` — bundle identity, version, build number, and privacy usage descriptions
- `Resources/Assets.xcassets/` — source app-icon catalog used by `actool`
- `docs/recording-format.md` — session package schema and accessibility replay algorithm
- `scripts/build-app.sh` — local app bundling and signing
- `scripts/build-distribution.sh` — arm64 Developer ID build, notarization, stapling, and ZIP packaging

Do not edit compiled app bundles or generated icon outputs. Change their source files and rebuild.

## Architecture

`PabloCore` owns the recorder and file format. `PabloApp` owns user consent, macOS privacy permission handling, recording lifecycle, and replay presentation. `PabloCLI` is intentionally thin.

A session has five synchronized evidence artifacts plus optional markup:

```text
Recording.pablo/
├── manifest.json
├── video.mov
├── events.pb
├── workspace.pb
├── accessibility.pb
└── annotations.pb
```

The session clock uses monotonic nanoseconds. Paused time is removed from every evidence timeline and video. Workspace snapshots record frontmost state plus explicit app/window appearance and removal. Accessibility trees materialize independently per stable `APP-###` identity. Each accessibility record has a global `A11Y-###` index shared by replay and CLI.

The protobuf source of truth is `proto/pablo/v3/pablo.proto`; `buf.gen.yaml` pins Swift generation. Run `buf format --diff --exit-code`, `buf lint`, and `buf generate` after schema changes. Never edit generated `.pb.swift` files. Streams use unsigned varint length-delimited protobuf records. Only recording schema and control protocol version 3 are supported; there is no compatibility path.

Captured artifacts and the manifest are evidence and remain untouched by markup. `annotations.pb` is an append-only journal of full annotation states with stable `NOTE-###` references. Visual markup is a full-fidelity spatiotemporal freehand trace: normalized x/y samples carry session timestamps, with equal timestamps denoting a shape on one paused video frame. Resolving an annotation appends a new state. Agent annotation mutations go through the approved app bridge; read-only annotation inspection stays offline.

Application scope follows the selected app's largest visible window. Display scope records the selected display without app exclusions, observes global input with receiving app/window provenance, and snapshots accessibility for visible applications. Both scopes use the same v3 structures. Secure accessibility text values are redacted.

Every approved live action requested while a recording is active or paused appends explicit `automationAction` requested and outcome records to `events.pb`, including actions aimed at a different app. They share one UUID and preserve the verified calling application/developer, exact sanitized target parameters, resolved action PID when available, and paused state. Never put typed content in the automation record; store only its character count. Synthesized raw input stays as separate evidence when it is in recording scope.

## App control and trust boundary

Recording lifecycle commands go through the running app over a Unix-domain socket at:

```text
~/Library/Application Support/Pablo/control.sock
```

The parent directory is mode `0700`, the socket is mode `0600`, peer credentials must match the current user, requests are capped at 64 KiB, responses are capped at 16 MiB, and each connection handles one protobuf `PabloControlService.Call` request. Offline inspection commands read recording packages directly and never contact the app. Live inspection and actions use the same bridge and daily approval as recording control. Live accessibility frames and bounded event history remain in memory and disappear when the app exits.

The app resolves the real invoking application by walking the CLI process ancestry. Background/helper processes with a prohibited activation policy and processes without a bundle identifier are skipped. The caller's live code signature is validated, then its static signing information supplies the application identifier, developer name, and team identifier shown in the approval dialog.

Verified applications can be allowed once per application/developer identity per local calendar day. Unsigned or otherwise unverifiable callers require approval every time. Never move this decision into the CLI or trust caller-supplied identity fields.

When changing the bridge, preserve these invariants:

- only the current local user can connect;
- the app remains the sole owner of recording actions and consent;
- approval is bound to a verified application and developer, not a helper executable name;
- denial and malformed requests fail closed;
- inspection commands continue to work without launching the app.
- live inspection never creates or modifies a recording package;
- live accessibility and input reads remain consent-gated and bounded in memory.
- live actions are revalidated in the app before target activation or event posting;
- normalized coordinates remain inside the target's largest accessible window;
- generic accessibility actions can invoke only actions the selected node currently exposes.
- annotation writes preserve verified caller provenance and never modify captured evidence.

## Build and run

Build a signed local app:

```sh
./scripts/build-app.sh
open dist/Pablo.app
```

The script signs with the first available Apple Development identity. Set `PABLO_SIGNING_IDENTITY` to an exact identity name to override it. If no identity exists, it falls back to ad-hoc signing and macOS privacy approvals may reset after every rebuild.

Build and run only the CLI during development:

```sh
swift build --product pablo
.build/debug/pablo --help
```

The built app embeds the CLI at `Pablo.app/Contents/MacOS/pablo`.

Useful commands against a running app:

```sh
pablo record --app Notes
pablo status
pablo pause
pablo resume
pablo stop
```

Useful offline inspection commands:

```sh
pablo recordings
pablo latest
pablo inspect
pablo frames
pablo frame A11Y-012
pablo frame A11Y-012 --changed
pablo events --limit 25
pablo annotations --json
pablo annotate Recording.pablo --kind issue --text "Disabled" --frame A11Y-012
pablo resolve NOTE-001 Recording.pablo
```

Most inspection commands accept a `.pablo` path and `--json`.

Useful live inspection commands:

```sh
pablo inspect --app Notes
pablo frames --app Notes --json
pablo frame A11Y-001 --app Notes --changed --json
pablo events --app Notes --limit 25 --json
pablo annotations --app Notes --json
```

Live targets also accept `--bundle-id` or `--pid`. The first live `events` request starts the in-memory observer; later requests return events observed since then.

Useful live action commands:

```sh
pablo click --app Notes --node ax-save
pablo drag --app Notes --from 0.2,0.5 --to 0.8,0.5 --duration 0.75
pablo scroll --app Notes --direction down --amount 6
pablo type --app Notes --node ax-editor --text "Hello"
pablo key --app Notes --key return --modifiers command,shift
pablo perform --app Notes --node ax-stepper --action increment
```

Live pointer coordinates are normalized within the target's largest accessible window. Node actions should use IDs from a fresh live frame. Action output never echoes typed text. Pablo's daily caller approval is the transport trust boundary; agents must still honor action-time confirmation requirements for consequential UI operations.

## Testing

Run the complete suite before shipping:

```sh
swift test
```

Tests use both XCTest and Swift Testing. Behavioral tests must encode the intended correct behavior. Never leave a reproduction test green because the bug still occurs.

`Tests/Behavior/*.feature` is the Gherkin-style behavioral catalog for AI testers. Keep it synchronized with automated coverage and signed-app behavior. Scenarios must state real preconditions and intended outcomes; blocked permission or signing prerequisites are not passes.

High-risk areas that need focused coverage when changed:

- ScreenCaptureKit start/stop lifecycle and a user ending system screen sharing
- session clock pause/resume accounting
- automation action provenance, requested/outcome pairing, and typed-text redaction
- accessibility full-tree and delta materialization
- secure-value redaction
- app bundle packaging and distinct GUI/CLI executables
- Swift package resource bundles, including dependency privacy manifests
- control-message size, decoding, peer identity, caller resolution, and daily approval expiry
- replay frame indexing and CLI/UI agreement
- live target parsing, snapshot indexing, bounded responses, and in-memory event observation
- live action validation, coordinate mapping, key names, exposed accessibility actions, and target isolation
- annotation journal materialization, immutable evidence, anchor validation, and caller provenance

Some true permission and capture behaviors require a signed app and manual testing because macOS owns the consent UI. Unit-test the state transitions and error classification around those boundaries.

## Versioning and release

Update both values in `Resources/Pablo-Info.plist`:

- `CFBundleShortVersionString` — public version
- `CFBundleVersion` — monotonically increasing build number

Create a distribution build with:

```sh
./scripts/build-distribution.sh
```

That script:

1. selects an installed Developer ID Application identity;
2. builds arm64 executables for Apple silicon Macs;
3. enables hardened runtime and timestamped signing;
4. verifies the signature;
5. submits through the `pablo-notary` keychain profile;
6. staples and validates the notarization ticket;
7. writes `dist/Pablo-<version>-<build>-mac-arm64.zip`;
8. asks Gatekeeper to assess the final app.

Before publishing, extract the exact ZIP into a clean temporary directory and verify the extracted app with `codesign`, `spctl`, and `xcrun stapler validate`. Publish the ZIP on the matching GitHub release so the README's latest-release link remains stable.

Do not commit certificates, private keys, provisioning profiles, recordings, build products, or notarization credentials. The existing `.gitignore` covers the common forms.

## Product boundaries

- ScreenCaptureKit may not include menus, popovers, protected surfaces, or windows created after capture starts.
- Accessibility APIs can expose sparse or unstable trees, especially for canvas-heavy apps.
- Virtualized collections prefer `AXVisibleChildren`; off-screen rows are intentionally absent until they become visible.
- The accessibility walker is bounded to 30 levels and 10,000 nodes per snapshot; truncated records say so.
- The format records observed state and input. It does not promise deterministic re-execution.
- Typed Unicode text is captured by default unless disabled; preserve clear user disclosure around that behavior.

Keep the public README for users. Put contributor and release details here or in focused documents under `docs/`.
