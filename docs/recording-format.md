# Recording format v2

`manifest.json` remains UTF-8 JSON. The event, accessibility, and annotation journals are binary protobuf streams defined by `proto/pablo/v2/pablo.proto` and generated with Buf. Each record is encoded as an unsigned protobuf varint byte length followed immediately by one serialized message. A stream is therefore appendable and can be decoded without loading or rewriting preceding records. Frames larger than 64 MiB, truncated prefixes, truncated payloads, and invalid messages fail closed.

Timeline values are unsigned nanoseconds from a `mach_continuous_time` origin created immediately before the recording components start. Wall-clock strings in the manifest are informational and are not used for synchronization.

## Manifest

`manifest.json` declares `schemaVersion: 2`, the target process metadata, video dimensions and frame rate, and the relative paths of the other artifacts. `capture.firstFrameTimestampNs` gives the session-timeline time at which the first video sample arrived. `durationNs` is written when shutdown completes.

## Input stream

`events.pb` is an append-only stream of `pablo.v2.InputEventRecord`. Common fields are:

| Field | Meaning |
| --- | --- |
| `timestampNs` | Event time on the session timeline |
| `type` | Mouse, scroll, keyboard, flags transition, or `automationAction` |
| `targetPID` | Process target reported by the event system, when available |
| `flags` | Raw `CGEventFlags` bitset |
| `x`, `y` | Global pointer position for pointer and scroll events |
| `deltaX`, `deltaY` | Scroll point deltas |
| `keyCode` | Hardware-independent virtual key code |
| `text` | Decoded Unicode for key-down, unless `--no-text` was used |
| `button`, `clickCount` | Pointer button and click sequence count |
| `automationAction` | Provenance and sanitized intent for an action requested through the Pablo CLI |

Events are observed, not swallowed or modified. They are retained when the target process is frontmost, when the event system reports the target PID, or when a pointer event falls within the captured window's initial frame.

Any approved `click`, `drag`, `scroll`, `type`, `key`, or `perform` request made while a recording is active or paused appends an explicit `type: "automationAction"` record before Pablo attempts it, even if the requested action targets a different application. A second record with the same `automationAction.actionID` records `succeeded` or `failed`. The nested record contains the action kind and targeting parameters, the verified calling application and developer identity, `transport: "pabloCLI"`, and whether the recording was paused. The event's `targetPID` is the resolved action target when available. It does not replace the resulting mouse or keyboard events; those remain separate evidence on the same timeline when they fall within the recording's input scope.

Typed content is never copied into `automationAction`. Type actions retain only `textLength`, while the ordinary key-down event follows the recording's `--no-text` policy. Recording the `requested` phase before input is posted ensures a crash or delivery failure cannot turn an attempted agent action into unattributed input. Automation actions attempted while paused remain in the event trace at the paused session timestamp with `recordingWasPaused: true`, even though ordinary input and video remain paused.

## Accessibility stream

`accessibility.pb` is an append-only stream of `pablo.v2.AccessibilitySnapshotRecord`. The first successful read is a full record. A player materializes it with:

```text
nodes = map(full.upserts, by: id)
root = full.rootID
```

For each later delta in timestamp order:

```text
for id in delta.removed: nodes.remove(id)
for node in delta.upserts: nodes[node.id] = node
root = delta.rootID
```

Each flat node contains identity and topology (`id`, `parentID`, `childIDs`), accessibility semantics (`role`, `subrole`, `title`, `label`, `value`, `identifier`, `help`), interaction state (`enabled`, `focused`), and global geometry (`position`, `size`). Unavailable optional attributes are absent on the protobuf wire.

When an accessibility container exposes `AXVisibleChildren`, capture follows that bounded visible collection instead of expanding all off-screen rows. Containers that do not expose it fall back to `AXChildren`. Closed zero-sized menus retain their own node but omit their hidden descendants; a visible menu is traversed normally. This keeps the evidence aligned with the recorded screen and avoids treating an entire virtualized data collection as visible UI state.

Snapshots are taken at startup, 75 ms after relevant input settles, periodically, and once during shutdown. Multiple inputs inside the 75 ms window are coalesced. A periodic snapshot captures UI changes caused by animation, timers, networking, or other state not directly initiated by input.

Element IDs are derived from the accessibility object's Core Foundation identity. They are intended to be stable within one recording, not portable across processes or sessions. Apps that destroy and recreate elements will naturally produce removals and upserts.

## Video alignment

The movie starts its media session at the first ScreenCaptureKit sample. To map a session timestamp to movie time:

```text
movieTimeNs = max(0, sessionTimestampNs - manifest.capture.firstFrameTimestampNs)
```

Frames before `firstFrameTimestampNs` have no corresponding video image. Consumers should show a blank or poster state for that short startup interval.

## Annotation journal

`annotations.pb` is an optional append-only stream of `pablo.v2.RecordingAnnotation`. Its absence means the recording has no annotations. It is not declared in the manifest so adding markup never modifies captured evidence.

Each record contains a complete annotation state with a UUID identity and stable sequence reference such as `NOTE-007`. Readers materialize the latest record for each UUID, then sort annotations by sequence. Resolving an annotation appends a new state with `status: "resolved"`; it does not rewrite an earlier record.

Annotation anchors may include session-timeline start and end nanoseconds, one or more `A11Y-###` frame references, accessibility node IDs, and an optional freehand trace. A trace is an ordered series of normalized `(x, y)` video coordinates carrying session timestamps plus a normalized line width. It is a spatiotemporal curve: circles, underlines, arrows, and arbitrary shapes use the same representation. Samples preserve the drawing gesture at full fidelity. When every sample has the same timestamp, the shape was drawn while playback was paused and belongs to that video frame. When time advances across samples, replay reveals the curve in timestamp order and interpolates only its live tip between captured samples; it never replaces the stored points. Author fields distinguish local human markup from markup created by a verified calling application and retain that application's identifier, developer, and team when available.

Writers must serialize mutations, validate anchors, and atomically replace the sidecar with the prior journal plus one complete framed record. They must never modify `manifest.json`, `video.mov`, `events.pb`, or `accessibility.pb` while adding or resolving markup.

## Local control RPC

The CLI and app share the same protobuf schema. A control connection carries exactly one framed `pablo.v2.CallRequest` and one framed `pablo.v2.CallResponse`, corresponding to `PabloControlService.Call`. Pablo retains its Unix-domain socket, same-user peer checks, 64 KiB request limit, 16 MiB response limit, and one-request-per-connection lifecycle. Caller identity and approval are still derived and enforced by the app; protobuf fields never supply trusted caller identity.

## Forward compatibility

Protobuf readers retain wire compatibility by ignoring unknown fields and preserving field numbers. Never reuse or renumber a published field; reserve deleted field numbers and names. Run `buf lint` and `buf breaking --against <reference>` before publishing schema changes.

Pablo accepts only recording schema version 2. Other manifest versions fail with an unsupported-format error before any journal is read or changed.
