# Local control API

Pablo exposes an HTTP/1.1 JSON API on the current user's Unix-domain socket:

```sh
export PABLO_SOCKET="$HOME/Library/Application Support/Pablo/control.sock"
```

Each connection handles one request. JSON request bodies are capped at 64 KiB
and JSON response bodies at 16 MiB. The socket is not a network listener.

Discover the complete OpenAPI 3.1 contract from the running app:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/openapi.json
```

The checked-in JSON served by the app is generated from
`api/control-api.openapi.yaml` with `scripts/generate-control-openapi.rb`.

The control method is the URL path. Any HTTP verb is accepted, so bodyless curl
calls can use the default `GET` while `-d` naturally uses `POST`.
Clients do not send a protocol version, request ID, or method field. Pablo
generates the response ID. Bodies are always decoded as JSON, so a
`Content-Type` header is optional.

## Recording lifecycle

Read status without a request body:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/record.status
```

Start a display recording with the method-specific payload:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" -d '{"scope":"display"}' \
  http://localhost/record.start
```

For application recording, use exactly one target selector:

```json
{"scope":"application","appName":"Notes"}
```

Recording options also accept `pid`, `bundleIdentifier`, `displayID`,
`outputPath`, `duration`, `snapshotInterval`, `captureText`, and
`framesPerSecond`. Defaults are a one-second snapshot interval, text capture
enabled, and 30 frames per second.

The other bodyless lifecycle endpoints are:

```text
/record.pause
/record.resume
/record.stop
```

## Live inspection

Post a `LiveInspectionRequest` directly to `/inspect.live`. Its `kind` is
`inspect`, `frames`, `frame`, `events`, or `annotations`. A target contains
exactly one of `pid`, `bundleIdentifier`, or `appName`.

```json
{"kind":"frames","target":{"appName":"Notes"}}
```

Frame requests accept `reference` and `changedOnly`. Event requests accept
`limit`. Live inspection output is always pretty-printed JSON. The defaults are
`changedOnly: false` and `limit: 100`.

The response places that data directly in `result.output` as a JSON array or
object, not as an escaped JSON string.

## Live actions

Post a `LiveActionRequest` directly to `/action.live`. The app applies the same
target, coordinate, node, key, and accessibility-action validation regardless
of which client created the JSON.

```json
{"kind":"click","target":{"appName":"Notes"},"nodeID":"ax-save"}
```

The action kinds are `click`, `drag`, `scroll`, `type`, `key`, and `perform`.
Optional fields are `point`, `fromNodeID`, `fromPoint`, `toNodeID`, `toPoint`,
`mouseButton`, `clickCount`, `duration`, `scrollDirection`, `scrollAmount`,
`text`, `key`, `modifiers`, and `accessibilityAction`. Defaults are left button,
one click, 0.5-second drag duration, three scroll lines, and no modifiers.

Foreground actions are locked by default. Pablo keeps the current foreground
application unchanged for `perform` and for a single left click on a node that
exposes `AXPress`. If a click needs pointer events, or an action uses drag,
scroll, typing, or keys, Pablo rejects it without activating the target.

The request may set `"unlockForegroundActions":true` (CLI:
`--unlock-foreground-actions`) to allow Pablo to activate the target. This is
**NOT RECOMMENDED**. An agent must leave it false unless the user explicitly
accepts the focus change; general approval to control Pablo is not enough.

## Annotation mutations

Post an `AnnotationRequest` directly to `/annotation.add` or
`/annotation.resolve`. Read-only inspection of completed recording packages
remains offline.

## Safari DOM bridge

Pablo includes a Safari Web Extension for background DOM inspection and bounded
DOM actions. Enable **Pablo Safari** in Safari > Settings > Extensions, visit the
tab, and click Pablo's toolbar button. This grants `activeTab` access only until
that tab navigates; the extension requests no persistent website access.

Dump the tab's DOM-derived accessibility tree:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" \
  -d '{"kind":"dumpAccessibilityTree"}' http://localhost/safari.dom
```

The dump returns a `documentGeneration` UUID and opaque `nodeID` values.
Refresh the tree immediately before an action, then include that generation
and the selected node ID (or a CSS selector):

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" \
  -d '{"kind":"click","selector":"#submit","documentGeneration":"01234567-89ab-cdef-0123-456789abcdef"}' http://localhost/safari.dom
```

Supported kinds are `dumpDOM`, `dumpAccessibilityTree`, `click`, `focus`,
`setValue`, and `scrollIntoView`. Dumps accept `includeHidden`, `maxNodes`, and
`maxDepth`. Actions require exactly one `selector` or `nodeID`; `setValue` also
requires `value`. Navigation, back/forward restoration, disconnected nodes, and
expired node references invalidate prior context. Selectors also require a
matching document generation. A successful action reports `dispatchStatus:
dispatched` and `effectStatus: unverified`; inspect again to establish the page's
resulting state.

Dumps count every visited node, including text, hidden nodes, and generic
containers. Output includes `visitedNodeCount`, emitted `nodeCount`,
`truncated`, and a 1 MiB `byteBudget`. Attributes, labels, and text samples have
individual limits; `byteBudgetReached` identifies exhaustion of the aggregate
limit. Ordinary prose is retained as ordered text leaves. The accessibility result is a semantic projection derived
from standard DOM and ARIA data, not WebKit's private native accessibility tree.

Pablo and its extension exchange serialized protobuf commands using Apple's
native Safari-extension messaging and App Group mechanisms. These commands do
not activate Safari. A disabled extension, a missing toolbar grant, navigation,
or a stale node fails closed.

## Safari rrweb recordings

List the active Safari tabs that currently retain an explicit toolbar grant:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/safari.tabs
```

Start a masked rrweb recording with a returned tab ID. Pablo generates the
recording UUID and package path:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" \
  -d '{"tabID":42}' http://localhost/rrweb.start
```

Lifecycle transitions serialize in both the app and extension. Status exposes
`transition`, `recoveryNeeded`, and `recoveryError`. An unknown start or stop
acknowledgment retains the active package and spool. Status failures never prove
the recorder stopped and never finalize its evidence. Pause/resume and another
start stay blocked during recovery; check status, or use stop to retrieve the
extension's retained stop acknowledgment. The extension retains its eight most
recent stop receipts until the document is replaced. Lost documents or evicted
receipts may need manual recovery; available evidence remains on disk.

Use `/rrweb.pause`, `/rrweb.resume`, `/rrweb.stop`, and `/rrweb.status` without
a body. `/rrweb.recordings` discovers saved `.pablo` packages whose declared
event source is rrweb.
`/rrweb.inspect` accepts exactly one of `recordingPath` or `recordingID`, plus
optional `includeEvents` and `eventLimit` fields. See
[Safari web recordings](rrweb.md) for the complete UI, storage, playback,
recovery, and privacy behavior.

Open any supported evidence source in the same normal review player:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" \
  -d '{"recordingPath":"/absolute/path/Recording.pablo"}' \
  http://localhost/recording.open
```

Only schema-v3 `.pablo` packages are accepted. There is no alternate-extension
or older-manifest compatibility path.

## Responses and errors

A valid call returns HTTP 200 with a server-generated ID:

```json
{"id":"1D267C89-299C-46F2-878A-C18F1B505CA9","result":{"state":"idle","applicationIDs":[],"elapsedNanoseconds":0}}
```

An operation rejected by Pablo also returns HTTP 200 with an `error` field.
Unsupported method URLs, malformed HTTP, and malformed JSON return HTTP 400.

The app obtains caller identity from socket peer credentials and process
ancestry. Requests cannot supply a trusted identity. Approval remains in the
app, and callers must not interact with Pablo's approval dialog.

### Readiness and recoverable operations

`service.info` is available without a prompt and returns runtime version/build, the
service UUID, method inventory, nonprompting privacy checks, and the calling app's
approval readiness. It contains no recording paths, target inventory, or another
caller's identity. Readiness is advisory; the app revalidates consent and permissions
before dispatch. `targets.list` requires daily approval and lists current application
PIDs and display IDs. Use `inspect.live` with a returned PID for session-bound windows
and observed node actions; `safari.tabs` lists only human-unlocked tabs.

For recording lifecycle, annotation writes, native actions, Safari mutations, and
opening a recording, verified callers can use `operation.execute`:

```json
{
  "serviceID": "<UUID from service.info>",
  "operationID": "<new caller-generated UUID>",
  "issuedAt": "<current ISO-8601 date>",
  "method": "record.stop",
  "payload": {}
}
```

The nested payload has exactly the ordinary method's shape and receives the same
human approval. The receipt is bound to the app-verified caller and a digest of the
entire request. Typed input is not retained in the receipt. Native and Safari action
evidence uses the operation UUID; ordinary action calls use their response UUID.
Review commands retain their existing `review.command` receipt contract.

Read or cancel with `operation.status` or `operation.cancel`, supplying `serviceID`
and `operationID`. These endpoints disclose only that verified caller's receipt,
including while approval is pending, and cannot grant access for a new command.
Cancellation stops waiting and further cooperative dispatch; it cannot undo effects
already sent. A completed native/Safari action proves dispatch, while its application
effect remains unverified until inspected.

The app retains at most 64 operation receipts for five minutes, with at most 256 KiB
of response per receipt. An oversized response sets `resultOmitted`; inspect current
state. Running operations remain observable until they settle. A service restart,
expired request, or unavailable receipt never establishes that the operation did not
run. Do not replay it. An exact repeated request within its service/time window can
retrieve the prior result; never create a fresh key merely because a response was lost.

Failures include a `failure.code`, `failure.dispatchStatus`, and, where applicable,
a precise `humanAction`. `notDispatched` guarantees no requested operation started;
`outcomeUnknown` requires inspection. Approval denial, another pending prompt,
missing permission, malformed input, and busy admission are distinct. No endpoint
changes privacy grants or grants daily approval. The human can revoke approvals and
stop live observation from the recorder window.

`rrweb.recover` selects a retained unfinished recording by `recordingID` from
`rrweb.recordings`. Selection alone does not contact Safari, finalize evidence, or
remove any spool. Stop a healthy current recording first. If the current package is
already recovery-needed, another unresolved package can be selected; all others remain
retained. `rrweb.status` and `rrweb.stop` operate on the selected package and require a
matching acknowledgment before finalization. The recorder window exposes the same
recovery selection. If the recorder was destroyed by navigation, tab closure, or a
browser restart, select its package and call `rrweb.recover` with that `recordingID`
and `recoveryAction: "finishInterrupted"`. Close the original tab first: this cannot
stop an unreachable recorder. Pablo saves received events as interrupted, retains
the spool for late delivery, and permits a new recording. Unreadable evidence leaves
recovery active. The recorder and menu expose **Save Received Events as Interrupted**.
Use an operation envelope to recover the result safely if the response is lost.

Safari checks tab access with a read-only probe before submitting a DOM or recorder command. A failed probe reports `permissionRequired` with the toolbar-unlock instructions in `humanAction`. A later dispatch failure remains an unknown outcome; a successful probe is not an action acknowledgment. The caller must obtain the tab grant through the human and then read fresh state.
