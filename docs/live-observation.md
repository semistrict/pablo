# Live inspection and observation

Live inspection remains approved by the app and never creates a recording package. Each target visit has a UUID `sessionID`. Reusing a PID or bundle identifier after process restart or session eviction does not reuse its observations. Pass the session ID as a precondition when continuing a context-dependent operation.

```sh
pablo inspect --app Notes
pablo frames --app Notes
pablo frame LIVE-SESSION-UUID/A11Y-001 --app Notes --session SESSION-UUID
```

Use the exact qualified `reference` returned in the frame envelope. Ordinary recorded `A11Y-001` references are deliberately insufficient for a live frame. Live node IDs also contain the inspection session UUID, so a node from an evicted session cannot become a node in its replacement. The app retains at most eight target sessions and 128 frames per session. Old or evicted frame references fail explicitly.

```sh
pablo observe start --app Notes --no-text
pablo observe status --app Notes
pablo observe read --app Notes --session SESSION-UUID --after 0 --limit 100
pablo observe stop --app Notes --session SESSION-UUID
```

`observe` calls `inspect.live` with `observationStart`, `observationStatus`, `events`, or `observationStop`. `--no-text` excludes typed text. Otherwise a new observation captures text by default, as disclosed by the app. Existing observations preserve their setting; stop first to change it. Starting requires the human's existing Accessibility and Input Monitoring grants.

Event pages return `sessionID`, `observing`, `capturesText`, `events` with sequence numbers and records, `nextCursor`, `oldestSequence`, `newestSequence`, and `resyncRequired`. Always carry the returned session ID alongside the next cursor. Omitting `after` reads the latest bounded page. Supplying it reads only later events. An empty page retains the cursor; a retention gap reports resynchronization. At most 10,000 events are retained.

The existing `events --app Notes` starts observation when needed and returns the same page contract. Subsequent calls can use `--session UUID --after SEQUENCE`. Cursors cannot silently cross process or session replacement.

The recorder window, menu panel, and `record.status` expose active input observation and whether it includes typed text. The human's **Stop Live Observation** button stops all observers and forgets their inspection sessions. A targeted stop also forgets that session, expiring its frame and node references. Quitting the app clears all live evidence.

## Explicit action targets

`inspect` returns observed `windows` and action capabilities. A frame's nodes
include their observed `actions`: `null` means the query was unavailable; an
empty array means the node exposed no actions. `AXPress` supports a background
single left click. Foreground pointer and keyboard input still requires the
human's explicit foreground unlock.

Use `--session UUID --window WINDOW-ID` to bind an action to an observed window.
Coordinates use that window's current bounds. A closed, minimized, or changed
window causes rejection; Pablo never falls back to another window. Foreground
input checks that the chosen window retains focus. Add `--frame LIVE-…/A11Y-…`
to require that the inspected frame is still current, including after activation
or between input segments. These window/frame options apply to actions and state
observations; inspect the application to discover its windows.

Live action output includes the resolved application/session, selected window,
inspection frame, `actionID`, and dispatch method. The action ID matches recorded
automation evidence when recording is active. `effectStatus: unverified` means
that dispatch succeeded; inspect again to determine the application's response.
Typed text is represented only by its character count.

## State observations and text editing

`pablo observe state --app Notes` samples accessibility state without starting
input observation. Supply `--since-frame LIVE-…/A11Y-…` for changes from your own
retained frame, `--full` for a complete snapshot, or `--screenshot` for a paired
window PNG. Missing or expired baselines return full state with `resyncRequired`.
Structured changes contain complete replacement nodes and explicit removals;
the compact text view is bounded and reports `textTruncated` when shortened.

Add `--observe` to a live action to return its subsequent state in the same call.
`--settle-ms` controls the quiet interval and `--timeout-ms` bounds polling.
`settled` describes sampled tree stability; `timedOut` includes the last sample.
A synchronous macOS accessibility call can exceed the polling deadline. An
`observationFailure` preserves the dispatched action instead of inviting a retry.

`select-text --node NODE-ID --text PHRASE` supports `--prefix`, `--suffix`, and
`--selection-type text|cursorBefore|cursorAfter`. It uses exact matching and
UTF-16 ranges, and rejects ambiguous matches, changed values, and secure fields.
`set-value --node NODE-ID --text VALUE` replaces or clears a supported text control.
Live nodes expose `settableAttributes` and, when available, `selectedTextRange`.
These live-only attributes do not change recorded accessibility evidence.

`paste --node NODE-ID --text CONTENT --unlock-foreground-actions` supports
`--format html --plain-text FALLBACK` as well as plain text. Pablo preserves
materialized clipboard representations and restores them unless another writer
has changed the clipboard. Inspect `clipboardRestoration` and the resulting
field; the temporary paste data remains available for 500 ms after dispatch.

Screenshots require an existing Screen Recording grant. They identify the
observation, frame, selected window, geometry, and capture interval. Pablo checks
accessibility state and window geometry around capture; macOS does not provide
an atomic accessibility-and-image snapshot. Images are limited to 2048 pixels
per side and 6 MiB of PNG data.

The [JavaScript client](../JavaScript/README.md) provides persistent app and Safari
tab handles, automatic native deltas, action observations, receipts, and cancellation.
