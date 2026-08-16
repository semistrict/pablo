# Safari web recordings

Pablo can record the DOM evolution of a Safari tab with rrweb while Safari
remains in the background. This is separate from a `.pablo` video and
accessibility recording. Safari web recordings use `.pabloweb` directory
packages and play in Pablo's dedicated web-recording review window.

## Permission boundary

1. Enable **Pablo Safari** in Safari > Settings > Extensions.
2. Visit the tab to record and click the Pablo Safari toolbar button.
3. Refresh Pablo's Safari tab list.

The extension requests `activeTab`, `nativeMessaging`, and `scripting`. It has
no host patterns and no persistent website access. Pablo lists only the active
tab from each Safari window whose current page is still covered by the user's
toolbar click. The grant ends on navigation; closing or navigating a recorded
tab interrupts that recording. Pablo never activates or foregrounds Safari.

## Capture and storage

The recorder streams ordered rrweb event batches through Safari's standard
extension messaging and the app-extension App Group. Input values are always
masked. Canvas pixels, cross-origin iframe contents, and downloaded fonts are
not captured. Same-origin DOM snapshots, DOM mutations, pointer movement,
scroll state, viewport changes, and other standard rrweb events can be present.

Each package contains:

```text
Example Web Recording 2026-08-15 at 14.30.00.pabloweb/
├── manifest.json
└── events.json
```

The manifest records the server-generated recording UUID, tab and window IDs,
tab title and URL, start and end times, state, event count, masking policy, and
rrweb version. The package name includes a filesystem-safe form of the tab
title. Event chunks are merged in sequence order when capture stops. If Pablo
restarts, it reconnects to a still-running tab recorder when possible; otherwise
it preserves received chunks and finalizes the package as `interrupted`.
Each native event batch is limited to 16 MiB; a page whose individual snapshot
exceeds that bound is reported as interrupted instead of silently truncating it.

Recordings are local under `~/Documents/Pablo Recordings`. Treat them as
sensitive: masking input values does not hide text already rendered elsewhere
in the DOM, page URLs, document titles, or other visible page content.

## Controls

The recorder window and menu-bar panel both provide tab refresh, start, pause,
resume, stop, live status, event count, and input-masking disclosure. The review
window discovers `.pabloweb` packages and uses the official rrweb player for
play/pause, timeline scrubbing, elapsed time, 0.5×–8× playback speed, inactive
period skipping, and full-screen playback.

Playback uses a non-persistent WebKit data store and a restrictive content
security policy. It reads the saved package locally and does not fetch original
page assets. Missing remote images, video, fonts, canvas pixels, protected
content, and cross-origin iframe contents therefore remain missing. Replay is a
DOM reconstruction, not deterministic re-execution of the original website.

## Agent API

Set the socket once and fetch the self-describing contract:

```sh
export PABLO_SOCKET="$HOME/Library/Application Support/Pablo/control.sock"
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/openapi.json
```

List currently unlocked tabs, then start by tab ID:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" http://localhost/safari.tabs
curl -fsS --unix-socket "$PABLO_SOCKET" -d '{"tabID":42}' http://localhost/rrweb.start
```

Lifecycle and discovery endpoints are:

```text
ANY /rrweb.pause
ANY /rrweb.resume
ANY /rrweb.stop
ANY /rrweb.status
ANY /rrweb.recordings
```

Inspect by `recordingID` or absolute `recordingPath`. Events are omitted by
default and bounded to 1–10,000 when requested:

```sh
curl -fsS --unix-socket "$PABLO_SOCKET" \
  -d '{"recordingID":"01234567-89AB-CDEF-0123-456789ABCDEF","includeEvents":true,"eventLimit":100}' \
  http://localhost/rrweb.inspect
```

The app generates all request and recording IDs. Clients do not send a protocol
version. Any HTTP method is accepted, `Content-Type` is optional, and every
response is pretty-printed JSON. The normal verified-caller approval remains in
Pablo; an agent must leave that decision to the user.
