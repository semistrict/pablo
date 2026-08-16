---
name: pablo
description: Record, inspect, control, and annotate Pablo macOS interactions. Use when asked to inspect or operate a running Mac app, click, drag, scroll, type, press keys, perform accessibility actions, observe live input or accessibility state, record a workflow, examine a `.pablo` recording, compare indexed `A11Y-###` frames, add stable `NOTE-###` markup, or explain what happened during an interaction.
---

# Use Pablo

Use Pablo's HTTP JSON API over its Unix-domain socket to inspect live Mac apps and control the consent-gated menu-bar app. Use the CLI only to inspect completed recordings offline. Prefer structured JSON and refer to accessibility states by their stable `A11Y-###` indexes.

## Discover the interfaces

The running app serves its OpenAPI 3.1 contract without an approval prompt:

```sh
export PABLO_SOCKET="$HOME/Library/Application Support/Pablo/control.sock"
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/openapi.json
```

Read that contract before making a live request. Put the control method in the
URL and pass only that method's JSON payload. Any HTTP verb works. Curl uses
`GET` without a body and automatically uses `POST` with `-d`. The body is
decoded as JSON without requiring a `Content-Type` header.

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" \
  -d '{"kind":"frames","target":{"appName":"Notes"}}' \
  http://localhost/inspect.live
```

For sensitive payloads such as typed secrets, use `-d @-` and supply JSON on
standard input instead of putting it in the shell command line.

For offline recording inspection, find the executable with `command -v pablo`.
If it is not on `PATH`, try these locations in order:

```text
/Applications/Pablo.app/Contents/MacOS/pablo
dist/Pablo.app/Contents/MacOS/pablo
.build/debug/pablo
```

Store the resolved absolute CLI path and use it only for offline commands. Do not install, rebuild, or replace the app unless the user asks.

## Choose the workflow

- For recording lifecycle, annotation mutations, live actions, or inspection with a live target, use the HTTP JSON API described by the running app.
- For `recordings`, `latest`, or inspection commands with a recording path, read completed recordings directly without the app or an approval prompt.
- If the request is only to analyze an existing recording, do not start a new one.

## Record an interaction

Require an explicit user request before starting a recording. Confirm the target is running and has a visible window, then select exactly one target form:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" -d '{"scope":"application","appName":"Notes"}' http://localhost/record.start
curl -fsS --unix-socket "$PABLO_SOCKET" -d '{"scope":"application","bundleIdentifier":"com.apple.Notes"}' http://localhost/record.start
curl -fsS --unix-socket "$PABLO_SOCKET" -d '{"scope":"application","pid":1234}' http://localhost/record.start
```

Add options only when they serve the request:

```json
{"scope":"application","appName":"Notes","duration":20,"snapshotInterval":0.5,"framesPerSecond":30}
{"scope":"application","appName":"Notes","captureText":false}
{"scope":"application","appName":"Notes","outputPath":"/absolute/path/demo.pablo"}
```

Prefer `"captureText": false` when the user does not need typed Unicode text or the workflow may contain sensitive text. Explain that ordinary recordings can contain typed text and everything visible in the captured app.

Pablo may open and show an approval dialog identifying the calling application and developer. Leave that decision to the user. Never click, automate, bypass, suppress, or imitate the approval dialog.

Use lifecycle controls exactly as requested:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/record.status
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/record.pause
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/record.resume
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/record.stop
```

If the user ends macOS screen sharing or capture from the system UI, treat that as an intentional stop. Check `status` before issuing another `stop`; do not turn an already-stopped capture into an error.

## Locate a recording

Recordings normally live under `~/Documents/Pablo Recordings`.

```sh
pablo recordings --json
pablo latest
```

Use `latest` only when the user has not named a recording and recency is unambiguous. Otherwise select the requested `.pablo` package from `recordings --json`. A `.pablo` recording is a directory package; preserve it as a unit.

## Inspect a recording

Start with a structured overview:

```sh
pablo inspect "/path/to/Recording.pablo"
pablo frames "/path/to/Recording.pablo" --json
pablo events "/path/to/Recording.pablo" --limit 100 --json
```

Then inspect only the accessibility frames needed to answer the question:

```sh
pablo frame A11Y-012 "/path/to/Recording.pablo" --json
pablo frame A11Y-012 "/path/to/Recording.pablo" --changed --json
```

Use `--changed` to explain what changed at one step. Load the complete frame when the surrounding hierarchy, labels, values, roles, or window context matters. Increase the event limit only when necessary.

When describing a recording:

1. Identify the target app, duration, capture outcome, and available artifacts from `inspect`.
2. Establish the relevant time range from events and frame timestamps.
3. Compare the nearest accessibility frames before and after important input.
4. Refer to every discussed state by its exact `A11Y-###` index.
5. Separate direct evidence from inference. Accessibility state may be sparse and is not equivalent to a browser DOM.
6. Mention truncation, missing video, sparse trees, protected surfaces, or timing gaps when present.

Do not reconstruct or repeat passwords, tokens, payment details, or other secrets from key events. Redact sensitive values in summaries even when the recording contains them.

## Inspect a live app

Use exactly one target selector with a read-only `inspect.live` request:

```json
{"kind":"inspect","target":{"appName":"Notes"}}
{"kind":"frames","target":{"bundleIdentifier":"com.apple.Notes"}}
{"kind":"frame","target":{"pid":1234},"reference":"A11Y-001","changedOnly":true}
{"kind":"events","target":{"appName":"Notes"},"limit":100}
{"kind":"annotations","target":{"appName":"Notes"}}
```

Live inspection goes through Pablo's approved app bridge. Leave the approval dialog to the user; never approve it on the user's behalf. Live snapshots and events are bounded, memory-only observations and do not create a recording.

Live inspection output is always pretty-printed JSON; do not add a `json` field
to the request. Read `result.output` directly as a JSON array or object; it is
not an escaped JSON string.

`inspect`, `frames`, and `frame` read accessibility state. Each new observation receives a stable `A11Y-###` reference for the lifetime of the Pablo app. `frame A11Y-001` creates the first observation when needed; use `frames` to create and list later observations before requesting them by reference.

The first `events` request begins observing input directed to the target and normally returns no events. Interact with the target or wait for the user to do so, then call `events` again. Typed text can appear in live event output. Never elicit or expose sensitive input merely to populate the event history.

Live `annotations` is read-only and normally empty. To create durable notes, make a recording and annotate that recording.

## Control a live app

Inspect immediately before acting. Prefer an exact accessibility node from the latest live frame; use normalized coordinates only when the accessibility tree cannot represent the target.

```json
{"kind":"click","target":{"appName":"Notes"},"nodeID":"ax-save"}
{"kind":"click","target":{"appName":"Notes"},"point":{"x":0.5,"y":0.8},"mouseButton":"left","clickCount":2}
{"kind":"drag","target":{"appName":"Notes"},"fromNodeID":"ax-item","toPoint":{"x":0.8,"y":0.2},"duration":0.75}
{"kind":"scroll","target":{"appName":"Notes"},"nodeID":"ax-list","scrollDirection":"down","scrollAmount":6}
{"kind":"type","target":{"appName":"Notes"},"nodeID":"ax-editor","text":"Hello"}
{"kind":"key","target":{"appName":"Notes"},"key":"return","modifiers":["command","shift"]}
{"kind":"perform","target":{"appName":"Notes"},"nodeID":"ax-stepper","accessibilityAction":"increment"}
```

Points are normalized within the target's largest accessible window. Drag endpoints may independently use points or node references. `perform` accepts only actions the selected element currently exposes, such as `press`, `show-menu`, `increment`, or `decrement`.

Apply the normal action-time confirmation rules before consequential UI actions. Pablo's once-per-day caller approval does not authorize purchases, permanent deletion, credential changes, permission changes, external communications, or other consequential steps. Never use Pablo to click its own approval dialog or to bypass a confirmation that must remain with the user.

Foreground actions are locked by default. Prefer `perform` or a single left click on a node exposing `AXPress`, which Pablo can execute without activating the target. The request field `unlockForegroundActions: true` and CLI flag `--unlock-foreground-actions` permit focus-changing pointer, scroll, drag, typing, key, and fallback click input. This option is **NOT RECOMMENDED**. Never use it unless the user explicitly accepts the focus change.

After an action, inspect a new live frame and verify the intended state change before continuing. If a node is stale, refresh frames and resolve a new node instead of falling back blindly to coordinates. Do not echo typed secrets in logs, summaries, or command output.

While Pablo is recording, every local API action is also explicit evidence in `events.pb`, even when it targets another app: a sanitized `automationAction` request and its success or failure share one action UUID and identify the verified calling application and developer. Synthesized raw input remains separate when it is in recording scope. Type-action provenance stores only character count, never the typed content.

## Control an explicitly unlocked Safari tab

Use `safari.dom` when Safari must remain in the background. The user must first enable Pablo Safari and click its toolbar button on the active tab. Do not attempt to grant this permission for the user. The extension has no persistent website access; its `activeTab` grant ends when the tab navigates.

Start with `{"kind":"dumpAccessibilityTree"}`. This returns a bounded, DOM-derived semantic tree whose `nodeID` values are CSS selectors. Use a fresh `nodeID` with `click`, `focus`, `setValue`, or `scrollIntoView`, then dump again to verify the result. `dumpDOM` is available when semantic output is insufficient. Never treat this projection as WebKit's private native accessibility tree.

Do not request arbitrary JavaScript execution or persistent host access. If Pablo reports that the extension is disabled or the tab is not unlocked, ask the user to enable or click it once and stop retrying until they do. Keep typed values out of summaries and logs.

## Record and replay an unlocked Safari tab

Use the rrweb API only when the user explicitly asks to record a Safari tab. It
does not activate Safari. First call `/safari.tabs`; select only a returned tab
whose title and URL match the user's request. If no matching tab is returned,
ask the user to visit it and click Pablo Safari's toolbar button. Never grant
extension access for the user.

Start with `{"tabID":42}` at `/rrweb.start`. The server generates the recording
ID. Use the bodyless `/rrweb.pause`, `/rrweb.resume`, `/rrweb.stop`, and
`/rrweb.status` endpoints for lifecycle control. Always stop a recording when
the requested workflow finishes. Navigation or tab closure interrupts capture;
do not retry until the user unlocks the new page.

Use `/rrweb.recordings` for discovery and `/rrweb.inspect` with exactly one of
`recordingID` or absolute `recordingPath`. Add `includeEvents: true` only when
raw events are needed, and use the smallest useful `eventLimit` from 1 to
10,000. Pablo's review UI provides play/pause, scrubbing, speed, inactive-period
skipping, and full-screen playback.

Input values are always masked, but DOM text, titles, URLs, and rendered page
content can remain sensitive. Canvas pixels, cross-origin iframe contents, and
remote playback assets are absent. Treat a `.pabloweb` package as sensitive and
preserve it as a directory package.

## Mark up findings

Read existing markup before adding duplicate findings:

```sh
pablo annotations "/path/to/Recording.pablo" --json
```

Attach each finding to the strongest available evidence. Prefer a frame and node for accessibility facts, a time range for transient behavior, and a normalized point or timed freehand trace for visible evidence. Send mutations through `annotation.add`:

```json
{"recordingPath":"/path/to/Recording.pablo","draft":{"kind":"issue","text":"The submit button remains disabled after valid input.","applicationIDs":[],"accessibilityReferences":["A11Y-012"],"accessibilityNodeIDs":["submit-button"]}}
{"recordingPath":"/path/to/Recording.pablo","draft":{"kind":"observation","text":"This underline follows the stale result while the video moves.","applicationIDs":[],"accessibilityReferences":[],"accessibilityNodeIDs":[],"trace":{"samples":[{"timestampNs":14200000000,"x":0.42,"y":0.4},{"timestampNs":14300000000,"x":0.53,"y":0.41},{"timestampNs":14400000000,"x":0.64,"y":0.43}],"lineWidth":0.008}}}
```

Trace samples must stay in drawing order. Preserve every available sample rather than reducing a human gesture to a rectangle or geometric primitive.

Use `issue`, `observation`, `question`, or `highlight`. State direct evidence as fact and label interpretations as inference. Pablo returns a stable reference such as `NOTE-007`; use that reference in summaries and follow-up work.

Resolve a finding only when the user asks or the evidence clearly shows it is no longer active:

```json
{"recordingPath":"/path/to/Recording.pablo","reference":"NOTE-007"}
```

Annotation mutations require the same verified-app approval as recording control. Leave the approval decision to the user and do not retry a denial. Never edit `annotations.pb` directly.

## Handle failures

- If the CLI needed for offline inspection is missing, report the paths checked and point to `https://github.com/semistrict/pablo/releases/latest`.
- If the control socket or OpenAPI endpoint is unavailable, report that Pablo is not running and ask the user to open the installed app; do not launch an unrelated build.
- If macOS permission is missing, name the permission reported by Pablo and let the user change it in System Settings. Do not repeatedly open privacy panes.
- If approval is denied, stop the requested control action and report the denial without retrying.
- If the target has no visible window, ask the user to expose one or choose another target.
- If no recording exists, report that plainly instead of guessing a path.
- If a frame index is invalid, list frames and select only an index present in that recording.

## Interface reference

```text
ANY /record.start       ANY /record.pause       ANY /record.resume
ANY /record.stop        ANY /record.status      ANY /annotation.add
ANY /annotation.resolve ANY /inspect.live       ANY /action.live
ANY /safari.dom        ANY /safari.tabs         ANY /rrweb.start
ANY /rrweb.pause       ANY /rrweb.resume        ANY /rrweb.stop
ANY /rrweb.status      ANY /rrweb.recordings    ANY /rrweb.inspect
ANY /openapi.json

pablo recordings [--json]
pablo latest
pablo inspect [recording.pablo]
pablo frames [recording.pablo] [--json]
pablo frame <A11Y-###> [recording.pablo] [--changed] [--json]
pablo events [recording.pablo] [--limit N] [--json]
pablo annotations [recording.pablo] [--json]
```
