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
or between input segments. These window/frame options apply to actions; inspect
the application to discover its windows.

Live action output includes the resolved application/session, selected window,
inspection frame, `actionID`, and dispatch method. The action ID matches recorded
automation evidence when recording is active. `effectStatus: unverified` means
that dispatch succeeded; inspect again to determine the application's response.
Typed text is represented only by its character count.
