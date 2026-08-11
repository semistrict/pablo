# Recording format v1

All JSON files use UTF-8. Timeline values are unsigned nanoseconds from a `mach_continuous_time` origin created immediately before the recording components start. Wall-clock strings in the manifest are informational and are not used for synchronization.

## Manifest

`manifest.json` declares `schemaVersion: 1`, the target process metadata, video dimensions and frame rate, and the relative paths of the other artifacts. `capture.firstFrameTimestampNs` gives the session-timeline time at which the first video sample arrived. `durationNs` is written when shutdown completes.

## Input stream

`events.jsonl` is append-only. Common fields are:

| Field | Meaning |
| --- | --- |
| `timestampNs` | Event time on the session timeline |
| `type` | Mouse, scroll, keyboard, or flags transition |
| `targetPID` | Process target reported by the event system, when available |
| `flags` | Raw `CGEventFlags` bitset |
| `x`, `y` | Global pointer position for pointer and scroll events |
| `deltaX`, `deltaY` | Scroll point deltas |
| `keyCode` | Hardware-independent virtual key code |
| `text` | Decoded Unicode for key-down, unless `--no-text` was used |
| `button`, `clickCount` | Pointer button and click sequence count |

Events are observed, not swallowed or modified. They are retained when the target process is frontmost, when the event system reports the target PID, or when a pointer event falls within the captured window's initial frame.

## Accessibility stream

`accessibility.jsonl` is also append-only. The first successful read is a full record. A player materializes it with:

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

Each flat node contains identity and topology (`id`, `parentID`, `childIDs`), accessibility semantics (`role`, `subrole`, `title`, `label`, `value`, `identifier`, `help`), interaction state (`enabled`, `focused`), and global geometry (`position`, `size`). Unavailable optional attributes are encoded as `null`.

Snapshots are taken at startup, 75 ms after relevant input settles, periodically, and once during shutdown. Multiple inputs inside the 75 ms window are coalesced. A periodic snapshot captures UI changes caused by animation, timers, networking, or other state not directly initiated by input.

Element IDs are derived from the accessibility object's Core Foundation identity. They are intended to be stable within one recording, not portable across processes or sessions. Apps that destroy and recreate elements will naturally produce removals and upserts.

## Video alignment

The movie starts its media session at the first ScreenCaptureKit sample. To map a session timestamp to movie time:

```text
movieTimeNs = max(0, sessionTimestampNs - manifest.capture.firstFrameTimestampNs)
```

Frames before `firstFrameTimestampNs` have no corresponding video image. Consumers should show a blank or poster state for that short startup interval.

## Forward compatibility

Readers should reject unknown major `schemaVersion` values and ignore unknown fields. New optional fields may be added without changing version 1.
