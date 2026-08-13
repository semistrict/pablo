# Recording format v3

Version 3 is a multi-application desktop-session format. There is no v2 decoder or compatibility representation. Application-scoped and display-scoped recordings use exactly the same manifest, streams, identities, and replay algorithms.

`manifest.json` is UTF-8 JSON. Evidence and annotation journals are length-delimited protobuf streams defined by `proto/pablo/v3/pablo.proto` and generated with Buf. Each record is an unsigned protobuf varint length followed by one serialized message. Oversized, truncated, or invalid records fail closed.

All evidence uses unsigned monotonic nanoseconds from one session clock. Paused time is removed from video and every observed evidence stream. Wall-clock strings are informational.

## Session identity model

Every observed process instance receives a recording-local stable reference such as `APP-004`. A PID is metadata, never identity. Every accessibility node ID is namespaced by its application identity, and every window identity combines an application identity with its observed system window number. Identities are meaningful only inside one recording.

The manifest declares schema version 3, the application or display recording scope, display and application catalogs, global capture geometry, encoded video properties, the first video timestamp, and evidence file paths. The application catalog is finalized at shutdown. Streaming records repeat descriptors needed to interpret evidence before shutdown or after partial recovery.

## Workspace stream

`workspace.pb` contains `pablo.v3.WorkspaceSnapshotRecord` messages. Each record is a complete view of applications and windows intersecting the capture scope at that timestamp. It names the frontmost application and explicitly lists appeared and removed application and window identities.

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

Application scope records the selected application's largest visible window. Display scope records the selected display with no application exclusions. Both store the global captured rectangle in `manifest.capture.frame`.

To map evidence to movie time:

```text
movieTimeNs = max(0, evidenceTimestampNs - firstFrameTimestampNs)
```

For display scope, accessibility rectangles normalize against `manifest.capture.frame`. For application scope, they normalize against the captured window.

## Annotation journal

`annotations.pb` is an optional append-only stream of `pablo.v3.RecordingAnnotation`. It is markup, not captured evidence, and remains absent from the manifest evidence file map.

Each complete state has stable `NOTE-###` sequence identity. Anchors can name application identities, accessibility frames, namespaced nodes, a time interval, and a normalized spatiotemporal freehand trace. Resolving appends a state; it never rewrites evidence or an earlier state.

## Local control RPC

The app and CLI exchange exactly one framed `pablo.v3.CallRequest` and `pablo.v3.CallResponse` per Unix-domain socket connection. Protocol version 3 is accepted; older messages are rejected. Same-user peer checks, size limits, verified caller resolution, and human approval remain app-owned. Protobuf fields never supply trusted caller identity.

## Compatibility policy

Pablo accepts only recording schema version 3 and control protocol version 3. There is no migration, fallback decoder, legacy target field, or dual-write path. Do not reuse or renumber v3 protobuf fields. Change the source proto, run Buf, and update all producers, consumers, and behavior tests together.
