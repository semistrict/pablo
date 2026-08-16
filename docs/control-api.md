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

The dump returns CSS-selector `nodeID` values. Refresh the tree immediately
before an action, then target one of those IDs:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" \
  -d '{"kind":"click","nodeID":"#submit"}' http://localhost/safari.dom
```

Supported kinds are `dumpDOM`, `dumpAccessibilityTree`, `click`, `focus`,
`setValue`, and `scrollIntoView`. Dumps accept `includeHidden`, `maxNodes`, and
`maxDepth`. Actions require exactly one `selector` or `nodeID`; `setValue` also
requires `value`. The accessibility result is a semantic projection derived
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

Use `/rrweb.pause`, `/rrweb.resume`, `/rrweb.stop`, and `/rrweb.status` without
a body. `/rrweb.recordings` discovers saved `.pabloweb` packages.
`/rrweb.inspect` accepts exactly one of `recordingPath` or `recordingID`, plus
optional `includeEvents` and `eventLimit` fields. See
[Safari web recordings](rrweb.md) for the complete UI, storage, playback,
recovery, and privacy behavior.

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
