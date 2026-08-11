# Pablo development guide

Pablo is a native macOS menu-bar recorder. It captures a target application's video, global input while that application is active, and accessibility state on one monotonic timeline. Completed recordings can be replayed in the app or inspected with the bundled CLI.

## Requirements

- macOS 14 or newer
- Xcode toolchain with Swift 6.2 support
- Accessibility, Input Monitoring, and Screen & System Audio Recording permissions for end-to-end recording tests
- An Apple Development certificate for stable local privacy grants
- A Developer ID Application certificate and configured notary profile for distribution

The project uses Swift Package Manager directly; there is no `.xcodeproj`.

## Repository map

- `Sources/Pablo/` — recording engine, models, replay reader, CLI parser, and local control protocol
- `Sources/PabloApp/` — SwiftUI/AppKit menu-bar application, permission flow, approval UI, and replay UI
- `Sources/PabloCLI/` — executable entry point for the `pablo` command
- `Tests/PabloTests/` — XCTest and Swift Testing suites
- `Resources/Pablo-Info.plist` — bundle identity, version, build number, and privacy usage descriptions
- `Resources/Assets.xcassets/` — source app-icon catalog used by `actool`
- `docs/recording-format.md` — session package schema and accessibility replay algorithm
- `scripts/build-app.sh` — local app bundling and signing
- `scripts/build-distribution.sh` — universal Developer ID build, notarization, stapling, and ZIP packaging

Do not edit compiled app bundles or generated icon outputs. Change their source files and rebuild.

## Architecture

`PabloCore` owns the recorder and file format. `PabloApp` owns user consent, macOS privacy permission handling, recording lifecycle, and replay presentation. `PabloCLI` is intentionally thin.

A session has four synchronized artifacts:

```text
Recording.pablo/
├── manifest.json
├── video.mov
├── events.jsonl
└── accessibility.jsonl
```

The session clock uses monotonic nanoseconds. Paused time is removed from both the event timeline and video. Accessibility data begins with a full flat tree and then stores deltas containing changed nodes and removals. Each materialized UI state has a stable `A11Y-###` index shared by the replay UI and CLI.

The video recorder follows the target's largest visible window at recording start. The input recorder observes keyboard, pointer, drag, and scroll events only while the target app is active. Secure accessibility text values are redacted. See `docs/recording-format.md` before changing schemas or timeline behavior.

## App control and trust boundary

Recording lifecycle commands go through the running app over a Unix-domain socket at:

```text
~/Library/Application Support/Pablo/control.sock
```

The parent directory is mode `0700`, the socket is mode `0600`, peer credentials must match the current user, requests are capped at 64 KiB, and each connection handles one request. Offline inspection commands read recording packages directly and never contact the app.

The app resolves the real invoking application by walking the CLI process ancestry. Background/helper processes with a prohibited activation policy and processes without a bundle identifier are skipped. The caller's live code signature is validated, then its static signing information supplies the application identifier, developer name, and team identifier shown in the approval dialog.

Verified applications can be allowed once per application/developer identity per local calendar day. Unsigned or otherwise unverifiable callers require approval every time. Never move this decision into the CLI or trust caller-supplied identity fields.

When changing the bridge, preserve these invariants:

- only the current local user can connect;
- the app remains the sole owner of recording actions and consent;
- approval is bound to a verified application and developer, not a helper executable name;
- denial and malformed requests fail closed;
- inspection commands continue to work without launching the app.

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
```

Most inspection commands accept a `.pablo` path and `--json`.

## Testing

Run the complete suite before shipping:

```sh
swift test
```

Tests use both XCTest and Swift Testing. Behavioral tests must encode the intended correct behavior. Never leave a reproduction test green because the bug still occurs.

High-risk areas that need focused coverage when changed:

- ScreenCaptureKit start/stop lifecycle and a user ending system screen sharing
- session clock pause/resume accounting
- accessibility full-tree and delta materialization
- secure-value redaction
- app bundle packaging and distinct GUI/CLI executables
- control-message size, decoding, peer identity, caller resolution, and daily approval expiry
- replay frame indexing and CLI/UI agreement

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
2. builds `arm64` and `x86_64` executables;
3. enables hardened runtime and timestamped signing;
4. verifies the signature;
5. submits through the `pablo-notary` keychain profile;
6. staples and validates the notarization ticket;
7. writes `dist/Pablo-<version>-<build>-mac.zip`;
8. asks Gatekeeper to assess the final app.

Before publishing, extract the exact ZIP into a clean temporary directory and verify the extracted app with `codesign`, `spctl`, and `xcrun stapler validate`. Publish the ZIP on the matching GitHub release so the README's latest-release link remains stable.

Do not commit certificates, private keys, provisioning profiles, recordings, build products, or notarization credentials. The existing `.gitignore` covers the common forms.

## Product boundaries

- ScreenCaptureKit may not include menus, popovers, protected surfaces, or windows created after capture starts.
- Accessibility APIs can expose sparse or unstable trees, especially for canvas-heavy apps.
- The accessibility walker is bounded to 30 levels and 10,000 nodes per snapshot; truncated records say so.
- The format records observed state and input. It does not promise deterministic re-execution.
- Typed Unicode text is captured by default unless disabled; preserve clear user disclosure around that behavior.

Keep the public README for users. Put contributor and release details here or in focused documents under `docs/`.
