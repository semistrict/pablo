# Shared recording review

Review calls use the same app-owned model as the visible review window and the usual caller approval. They target recorded evidence, not a live application.

```sh
pablo review list
pablo review open /path/to/Recording.pablo
pablo review state REVIEW-UUID
```

Opening returns a `ReviewState` as soon as the window has a loaded source. Check `renderer`: opening a window does not mean video preparation has finished. `playheadSeconds` is the requested position; `renderedSeconds` is the last renderer-observed position. Native video time and `sessionTimestampNs` can differ because capture begins after the session clock starts.

Each window has its own `reviewID`. A source has a manifest-derived `sourceID` and a fresh `generation` on every load, including reloads at the same path. Commands also verify the loaded evidence files' descriptor before dispatch. `serviceID` identifies this app process and changes on restart. `revision` advances for logical review changes, including explicit seeks, selections, tools, drafts, and journal changes. Ordinary playback ticks do not advance it.

The state includes the primary selection, focused recorded window and viewport, tool, inspector visibility and section, renderer readiness/error, and a bounded human draft summary with its stable draft ID, source generation, and captured time/evidence anchor. Draft text is capped at 4,096 characters with its full character count and truncation flag. `isActive` identifies the key review window; no review is active while the recorder or another window is key. Reads do not activate a window.

## Commands and receipts

Send `/review.command`, or save its JSON request in a file and run:

```sh
pablo review command request.json
```

The request contains:

- `reviewID` and `serviceID` from the state being discussed;
- a new UUID `operationID` and current ISO-8601 `issuedAt`;
- `expectedSourceGeneration` from `source.generation` and `expectedRevision` from that snapshot;
- `command`, for example `{"kind":"seek","seconds":1.25}`.

Supported kinds are `seek`, `play`, `pause`, `rate`, `focusWindow`, `selectFrame`, `selectNode`, `selectEvent`, `selectAnnotation`, `clearSelection`, `tool`, `showInspector`, `activate`, `close`, `annotate`, and `inspectPoint`. The self-describing `/openapi.json` lists their fields. Frame and node commands require a recorded frame reference; nodes must belong to that materialized frame. Timeline selections use their source's timeline item ID. `focusWindow` without `windowID` restores the full recording canvas.

The `annotate` command takes explicit `text` and session `timestampNs`, with optional native frame `reference`, `nodeID`, and `annotationKind`. It appends a caller-attributed note without seeking the human’s playhead, and returns the saved annotation and `annotationReference`. Its receipt prevents an identical retried request from appending another note.

Context-dependent commands reject stale source generations or revisions. An unsaved human draft blocks context changes; pause and inspector visibility remain available. Renderer operations wait for observed completion. Window activation waits for macOS to make the requested window key in the active application; if activation is refused, the receipt reports failure instead of claiming success. A human change during that wait interrupts the operation. Failed or interrupted operations may have moved the playhead before failing: inspect the returned state.

The output is a `ReviewOperation` containing its status, resulting state, and expiry. Within five minutes of `issuedAt`, repeating the **identical request** returns the existing receipt without another mutation. Its ID is bound to the caller identity and full payload. The store retains up to 128 unexpired receipts; it rejects new work instead of evicting a usable receipt. Unverified callers' receipts are restricted to the same process.

```sh
pablo review operation SERVICE-UUID OPERATION-UUID
```

This reads an operation while it is running or after completion. An expired or unavailable receipt does **not** establish that the operation was never executed. Old service IDs and expired command requests fail before dispatch. Read the current state before deciding whether a new operation is appropriate.

## Change watching

```sh
pablo review watch
pablo review watch SERVICE-UUID CURSOR
```

The first command reads currently retained changes. The second waits up to 25 seconds for a later change. `/changes.watch` also accepts `limit` (1–100) and `waitMs` (0–25,000). Advance using `nextCursor` and retain the returned `serviceID`.

The feed retains 256 events, including review activation/closure, logical model changes, renderer changes, operation outcomes, and recording lifecycle changes. Events identify the review/source generation and revision when applicable. `origin` separates human, application, renderer, system, and mixed changes; application commands carry their operation ID. Model changes in one turn are coalesced; ordinary playback ticks are omitted. The feed is a notification stream, not captured evidence or a record of every intermediate UI value.

`resyncRequired` means a retention gap or an app-process change: reread current state before acting. An empty page preserves its cursor. At most four concurrent watchers are admitted, leaving capacity for other reads. Human draft text and typed input are not copied into change events.

## Transport bounds

The socket admits up to 32 concurrent connections, 12 read handlers, and 8 queued/running mutation handlers. Mutations execute serially; discovery and reads can continue independently. Request I/O has a 10-second deadline, app handlers have a 60-second connection deadline, and response writes have a 10-second budget per header/body write. A timed-out app operation is cancelled where possible and reports an unknown outcome. The client never automatically resends a possibly delivered request.

Review commands use the receipts described here. Other mutating methods can use caller-bound `operation.execute/status/cancel` receipts described in [the control API](control-api.md); direct calls retain their existing result shapes and the no-ambiguous-retry transport rule.

## Recorded evidence queries

`pablo review evidence request.json` sends `/review.evidence`. Supply `reviewID`, `serviceID`, `expectedSourceGeneration`, `expectedRevision`, and `kind` (`point`, `timeline`, or `image`). Reads verify the source before and after asynchronous rendering. They do not seek or select anything.

A native `point` query uses `x` and `y` normalized in the current `state.viewport`; it returns the observed node, normalized bounds, frame reference, sample timestamp, age, and truncation. `inspectPoint` is the matching selection command, requiring a paused, settled renderer. Native AX point queries explicitly reject web sources. State separately reports `videoAvailability` (native track coverage), `accessibilityAvailability`, renderer readiness/errors, pinned evidence, hovered evidence, and each application's latest sampled observation. Older AX is identified by its age; it is not claimed to be contemporaneous video evidence.

A `timeline` query accepts `fromSeconds`, `toSeconds`, `after` (default 0), and `limit` (1–200). Pass `nextCursor` into the same query while `hasMore` is true. The cursor belongs to that exact range and context revision. Source types retain their own event references.

An `image` query requires paused, settled playback and an available recorded viewport. It returns PNG `base64`, dimensions, actual rendered time, and the state carrying source/time/crop provenance. `maxPixelDimension` is 64–2,048, default 1,600; encoded PNG bytes are capped at 8 MiB. Native exports use the composed video and current crop. Web exports snapshot the rendered recorded iframe. They create no files and never modify the recording package.

`pablo review cancel SERVICE-UUID OPERATION-UUID` requests cancellation without waiting behind the pending mutation. The initial receipt can say `cancellationRequested`; lookup reaches `interrupted` once the command stops. Cancellation cannot undo an already issued seek or saved note. A terminal receipt is returned unchanged, and callers cannot cancel another caller's receipt.

Loading a failed package preserves the existing review. A human must save or discard an unfinished note before switching its source. Hiding the inspector leaves the model-owned draft intact.

The native review also offers **Recorded point controls** with labeled horizontal and vertical coordinates. In Inspect, **Inspect point** shares the API's paused, settled selection behavior. In Pen, **Add trace point** and **Finish trace** provide a keyboard alternative to drawing. Comment offers **Place comment**. Coordinates are relative to the current visible video; saved traces use the recording canvas. Drafts remain unpublished until the human submits the composer.

The library reads package metadata during discovery and validates full evidence when a package is opened. A package with valid metadata but damaged evidence remains listed; attempting to open it reports the failure and preserves the existing review.
