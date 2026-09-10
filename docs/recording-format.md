# Recording format v3

This document describes every `.pablo` recording package. A manifest declares
either native video/accessibility evidence or Safari rrweb events as its data
source. Both sources use the same package extension, recording browser, review
window, transport, timeline, inspector, and annotation journal.

Version 3 is a multi-application desktop-session format. There is no v2 decoder or compatibility representation. Application-scoped and display-scoped recordings use exactly the same manifest, streams, identities, and replay algorithms.

`manifest.json` is UTF-8 JSON. Evidence and annotation journals are length-delimited protobuf streams defined by `proto/pablo/v3/pablo.proto` and generated with Buf. Each record is an unsigned protobuf varint length followed by one serialized message. Oversized, truncated, or invalid records fail closed.

All evidence uses unsigned monotonic nanoseconds from one session clock. Paused time is removed from video and every observed evidence stream. Wall-clock strings are informational.

## Session identity model

Every observed process instance receives a recording-local stable reference such as `APP-004`. A PID is metadata, never identity. Every accessibility node ID is namespaced by its application identity, and every window identity combines an application identity with its observed system window number. Identities are meaningful only inside one recording.

The manifest declares schema version 3 and a `dataSource` of `native` or
`rrweb`. Native recordings declare application/display scope, capture geometry,
video tracks, and protobuf evidence paths. rrweb recordings declare tab,
privacy, lifecycle, and rrweb-version metadata plus the `events.json` path.
The field is required; there is no fallback decoder for manifests that omit it.

## Workspace stream

`workspace.pb` contains `pablo.v3.WorkspaceSnapshotRecord` messages. Each record is a complete view of the capture scope at that timestamp, with appeared and removed identities. Application scope includes all observed windows belonging to the selected process across displays. An off-screen or minimized window retains its identity and has `isOnScreen: false`; a closed window is removed. The frontmost application is named only when it belongs to the scope. Display scope includes visible windows intersecting that display.

A consumer selects the last workspace record at or before a playback point. No process lookup is required during replay.

## Input stream

`events.pb` contains `pablo.v3.InputEventRecord` messages. Alongside event type, coordinates, scrolling, keyboard data, flags, button, and click count, every record can carry stable `applicationID` and application-scoped `windowID` provenance. `targetPID` is diagnostic metadata only.

Display scope observes global input and attributes each event to its receiving or frontmost application. Application scope filters input to the selected application but emits the same multi-app-aware message shape.

Approved `click`, `drag`, `scroll`, `type`, `key`, and `perform` requests append `requested` evidence before delivery and `succeeded` or `failed` evidence afterward. The outer event carries the resolved recording application identity. The nested action retains verified calling-application and developer provenance. Typed action text is represented only by length; ordinary key-down text follows the recording's text-capture setting.

## Accessibility stream

`accessibility.pb` contains `pablo.v3.AccessibilitySnapshotRecord` messages. Every record embeds its application descriptor. Materialization is independent per application:

```text
trees = map<applicationID, map<nodeID, node>>()

for record in timestamp order:
    tree = trees[record.application.id]
    if record.kind == "full": tree.removeAll()
    for id in record.removed: tree.remove(id)
    for node in record.upserts: tree[node.id] = node
```

Interleaved deltas for different applications must never share a node map. Global frame indices such as `A11Y-012` identify records in stream order; each indexed frame also identifies its application.

Snapshots occur initially, after relevant input settles, periodically, and at shutdown. A display snapshot normally reads all visible applications. An input-triggered snapshot may update only the receiving application while `workspace.pb` still records desktop state at that timestamp.

Nodes include topology, accessibility semantics, interaction state, and global screen geometry. Secure text is redacted. Visible-child traversal and depth/node limits remain bounded as documented by `truncated`.

## Video and geometry

Application scope uses an application filter for every connected display. Existing and newly opened eligible windows are included without choosing a single window. Display scope records only the selected display with no application exclusions.

Native capture retains sticky `streamIssues` in its finalized manifest when input,
workspace, accessibility, video, or manifest writing fails. Each issue identifies the
stream, failure count, first and last session timestamps, and a bounded error message.
Later successful writes do not erase an earlier gap. Live control status exposes these
issues during capture; stop reports interrupted or failed completeness and keeps the
package for inspection. A manifest write failure can only be reported by the live app
and its retained completion when that same file cannot be updated. Healthy finalized
captures carry an empty issue list; older current-v3 manifests can omit the optional
health diagnostic. This is not a decoder for older recording schema versions.

`manifest.capture.videoTracks` is the native video catalog. Each track identifies a `VIDEO-###` reference, relative `file` path (normally `video/VIDEO-###.mov`), display ID, desktop frame, pixel dimensions, scale, frame rate, start time, optional first-frame time, optional end time, and end reason. Frames use the shared host clock with pause intervals removed. A display disconnect ends its track; reconnecting or changing geometry creates a new track. An explicit system stop ends capture without restarting streams. A track that received no frames has no movie and a null first-frame timestamp.

`manifest.capture.frame` is the union of every track's desktop rectangle over the session, in Quartz logical points (top-left origin, including negative coordinates). Pixel dimensions describe the replay canvas at the maximum track scale. Playback composes tracks at their recorded positions and times through one media clock; ended or not-yet-started tracks contribute no image. The original movies remain separate evidence files.

To map evidence to movie time:

```text
movieTimeNs = max(0, evidenceTimestampNs - firstFrameTimestampNs)
```

The global first-frame timestamp is the earliest captured frame across tracks. Each track's first frame is inserted at its own offset from that origin. Accessibility rectangles normalize against the recording canvas for both scopes.

Replay's All windows view shows the recorded desktop arrangement. Window focus crops to the selected window's current recorded bounds while keeping the same time and player. When its window or display has no recorded view at that time, replay shows an unavailable state. Cropping cannot reveal pixels hidden behind overlapping windows.

## Annotation journal

`annotations.pb` is an optional append-only stream of `pablo.v3.RecordingAnnotation`. It is markup, not captured evidence, and remains absent from the manifest evidence file map.

Each complete state has stable `NOTE-###` sequence identity. Anchors can name application identities, accessibility frames, namespaced nodes, a time interval, and a normalized spatiotemporal freehand trace. Each stored trace retains its desktop `coordinateFrame`; normalized samples and line width refer to that frame. A draft may omit the frame to use the recording canvas at append time. Replay maps the retained frame into its current view, so adding a display or focusing a window never changes where existing markup belongs. Resolving appends a state; it never rewrites evidence or an earlier state.

Safari rrweb packages use the same journal. Their notes are time-anchored and
may reference selected web events; spatial video traces and accessibility-frame
anchors apply only to native sources.

## Local control API

The app accepts one HTTP/1.1 request and response per Unix-domain socket connection. Control methods use distinct `POST` URLs, and each JSON body contains only that method's payload. Clients do not send protocol versions, request IDs, methods, or trusted caller identity in JSON. Same-user peer checks, size limits, verified caller resolution, and human approval remain app-owned. See [control-api.md](control-api.md) for the wire contract and curl examples.

## Compatibility policy

Pablo accepts only recording schema version 3. The HTTP/JSON control API has unversioned URLs and no compatibility fallback. There is no migration, fallback decoder, legacy target field, or dual-write path. Do not reuse or renumber v3 recording protobuf fields. Change the source proto, run Buf, and update all evidence producers, consumers, and behavior tests together. Change the JSON control models, client, server, API documentation, and behavior tests together when the control contract changes.

Safari automation traces additionally preserve `safariTarget`: the requested tab ID,
document generation, opaque DOM node ID and/or selector. These fields are distinct
from a native live session/window target. Set-value traces retain only character count,
never the supplied value. Requested/outcome records share the UUID returned by the
control call or recoverable operation receipt.
