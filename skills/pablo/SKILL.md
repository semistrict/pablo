---
name: pablo
description: Record, inspect, control, and annotate Pablo macOS interactions. Use when asked to inspect or operate a running Mac app, click, drag, scroll, type, press keys, perform accessibility actions, observe live input or accessibility state, record a workflow, examine a `.pablo` recording, compare indexed `A11Y-###` frames, add stable `NOTE-###` markup, or explain what happened during an interaction.
---

# Use Pablo

Use Pablo's CLI to inspect live Mac apps, control the consent-gated menu-bar app, and inspect completed recordings. Prefer structured CLI output and refer to accessibility states by their stable `A11Y-###` indexes.

## Resolve the CLI

Find the executable before running a command:

```sh
command -v pablo
```

If it is not on `PATH`, try these locations in order:

```text
/Applications/Pablo.app/Contents/MacOS/pablo
dist/Pablo.app/Contents/MacOS/pablo
.build/debug/pablo
```

Store the resolved absolute path and use it for every subsequent command. Do not install, rebuild, or replace the app unless the user asks.

## Choose the workflow

- For `record`, `status`, `pause`, `resume`, `stop`, `annotate`, `resolve`, live actions, or inspection commands with a live target, use the CLI to speak to the running Pablo app.
- For `recordings`, `latest`, or inspection commands with a recording path, read completed recordings directly without the app or an approval prompt.
- If the request is only to analyze an existing recording, do not start a new one.

## Record an interaction

Require an explicit user request before starting a recording. Confirm the target is running and has a visible window, then select exactly one target form:

```sh
pablo record --app "Notes"
pablo record --bundle-id com.apple.Notes
pablo record --pid 1234
```

Add options only when they serve the request:

```sh
pablo record --app "Notes" --duration 20
pablo record --app "Notes" --snapshot-interval 0.5 --fps 30
pablo record --app "Notes" --no-text
pablo record --app "Notes" -o "/absolute/path/demo.pablo"
```

Prefer `--no-text` when the user does not need typed Unicode text or the workflow may contain sensitive text. Explain that ordinary recordings can contain typed text and everything visible in the captured app.

Pablo may open and show an approval dialog identifying the calling application and developer. Leave that decision to the user. Never click, automate, bypass, suppress, or imitate the approval dialog, and never connect to the control socket directly.

Use lifecycle controls exactly as requested:

```sh
pablo status
pablo pause
pablo resume
pablo stop
```

If the user ends macOS screen sharing or capture from the system UI, treat that as an intentional stop. Check `status` before issuing another `stop`; do not turn an already-stopped capture into an error.

## Locate a recording

Recordings normally live under `~/Movies/Pablo Recordings`.

```sh
pablo recordings --json
pablo latest
```

Use `latest` only when the user has not named a recording and recency is unambiguous. Otherwise select the requested `.pablo` package from `recordings --json`. A `.pablo` recording is a directory package; preserve it as a unit.

## Inspect a recording

Start with a structured overview:

```sh
pablo inspect "/path/to/Recording.pablo"
pablo frames "/path/to/Recording.pablo" --json
pablo events "/path/to/Recording.pablo" --limit 100 --json
```

Then inspect only the accessibility frames needed to answer the question:

```sh
pablo frame A11Y-012 "/path/to/Recording.pablo" --json
pablo frame A11Y-012 "/path/to/Recording.pablo" --changed --json
```

Use `--changed` to explain what changed at one step. Load the complete frame when the surrounding hierarchy, labels, values, roles, or window context matters. Increase the event limit only when necessary.

When describing a recording:

1. Identify the target app, duration, capture outcome, and available artifacts from `inspect`.
2. Establish the relevant time range from events and frame timestamps.
3. Compare the nearest accessibility frames before and after important input.
4. Refer to every discussed state by its exact `A11Y-###` index.
5. Separate direct evidence from inference. Accessibility state may be sparse and is not equivalent to a browser DOM.
6. Mention truncation, missing video, sparse trees, protected surfaces, or timing gaps when present.

Do not reconstruct or repeat passwords, tokens, payment details, or other secrets from key events. Redact sensitive values in summaries even when the recording contains them.

## Inspect a live app

Use exactly one of the recording target forms with any read-only inspection command:

```sh
pablo inspect --app "Notes"
pablo frames --bundle-id com.apple.Notes --json
pablo frame A11Y-001 --pid 1234 --changed --json
pablo events --app "Notes" --limit 100 --json
pablo annotations --app "Notes" --json
```

Live inspection goes through Pablo's approved app bridge. Leave the approval dialog to the user; never approve it on the user's behalf. Live snapshots and events are bounded, memory-only observations and do not create a recording.

`inspect`, `frames`, and `frame` read accessibility state. Each new observation receives a stable `A11Y-###` reference for the lifetime of the Pablo app. `frame A11Y-001` creates the first observation when needed; use `frames` to create and list later observations before requesting them by reference.

The first `events` request begins observing input directed to the target and normally returns no events. Interact with the target or wait for the user to do so, then call `events` again. Typed text can appear in live event output. Never elicit or expose sensitive input merely to populate the event history.

Live `annotations` is read-only and normally empty. To create durable notes, make a recording and annotate that recording.

## Control a live app

Inspect immediately before acting. Prefer an exact accessibility node from the latest live frame; use normalized coordinates only when the accessibility tree cannot represent the target.

```sh
pablo frames --app "Notes" --json
pablo click --app "Notes" --node ax-save
pablo click --app "Notes" --point 0.50,0.80 --button left --count 2
pablo drag --app "Notes" --from-node ax-item --to 0.80,0.20 --duration 0.75
pablo scroll --app "Notes" --node ax-list --direction down --amount 6
pablo type --app "Notes" --node ax-editor --text "Hello"
pablo key --app "Notes" --key return --modifiers command,shift
pablo perform --app "Notes" --node ax-stepper --action increment
```

Points are normalized within the target's largest accessible window. Drag endpoints may independently use `--from`/`--to` points or `--from-node`/`--to-node` references. `perform` accepts only actions the selected element currently exposes, such as `press`, `show-menu`, `increment`, or `decrement`.

Apply the normal action-time confirmation rules before consequential UI actions. Pablo's once-per-day caller approval does not authorize purchases, permanent deletion, credential changes, permission changes, external communications, or other consequential steps. Never use Pablo to click its own approval dialog or to bypass a confirmation that must remain with the user.

After an action, inspect a new live frame and verify the intended state change before continuing. If a node is stale, refresh frames and resolve a new node instead of falling back blindly to coordinates. Do not echo typed secrets in logs, summaries, or command output.

While Pablo is recording, every CLI action is also explicit evidence in `events.pb`, even when it targets another app: a sanitized `automationAction` request and its success or failure share one action UUID and identify the verified calling application and developer. Synthesized raw input remains separate when it is in recording scope. Type-action provenance stores only character count, never the typed content.

## Mark up findings

Read existing markup before adding duplicate findings:

```sh
pablo annotations "/path/to/Recording.pablo" --json
```

Attach each finding to the strongest available evidence. Prefer a frame and node for accessibility facts, a time range for transient behavior, and a normalized point or timed freehand trace for visible evidence:

```sh
pablo annotate "/path/to/Recording.pablo" \
  --kind issue \
  --text "The submit button remains disabled after valid input." \
  --frame A11Y-012 \
  --node submit-button

pablo annotate "/path/to/Recording.pablo" \
  --kind observation \
  --text "This underline follows the stale result while the video moves." \
  --trace 14.2,0.42,0.40 \
  --trace 14.3,0.53,0.41 \
  --trace 14.4,0.64,0.43 \
  --line-width 0.008
```

`--trace SEC,X,Y` is repeatable and must stay in drawing order. Preserve every available sample rather than reducing a human gesture to a rectangle or geometric primitive. Use `--point X,Y --at SEC` for a single-frame point, or `--point X,Y --from SEC --to SEC` for a stationary point over an interval.

Use `issue`, `observation`, `question`, or `highlight`. State direct evidence as fact and label interpretations as inference. Pablo returns a stable reference such as `NOTE-007`; use that reference in summaries and follow-up work.

Resolve a finding only when the user asks or the evidence clearly shows it is no longer active:

```sh
pablo resolve NOTE-007 "/path/to/Recording.pablo"
```

Annotation mutations require the same verified-app approval as recording control. Leave the approval decision to the user and do not retry a denial. Never edit `annotations.pb` directly.

## Handle failures

- If the CLI is missing, report the paths checked and point to `https://github.com/semistrict/pablo/releases/latest`.
- If Pablo is not running for a control command, allow the CLI's normal app-launch behavior; do not launch an unrelated build.
- If macOS permission is missing, name the permission reported by Pablo and let the user change it in System Settings. Do not repeatedly open privacy panes.
- If approval is denied, stop the requested control action and report the denial without retrying.
- If the target has no visible window, ask the user to expose one or choose another target.
- If no recording exists, report that plainly instead of guessing a path.
- If a frame index is invalid, list frames and select only an index present in that recording.

## Command reference

```text
pablo record (--app NAME | --bundle-id ID | --pid PID) [options]
pablo status
pablo pause
pablo resume
pablo stop
pablo recordings [--json]
pablo latest
pablo inspect [recording.pablo | --app NAME | --bundle-id ID | --pid PID]
pablo frames [recording.pablo | live target] [--json]
pablo frame <A11Y-###> [recording.pablo | live target] [--changed] [--json]
pablo events [recording.pablo | live target] [--limit N] [--json]
pablo annotations [recording.pablo | live target] [--json]
pablo click live-target (--node ID | --point X,Y) [--button BUTTON] [--count N]
pablo drag live-target (--from X,Y | --from-node ID) (--to X,Y | --to-node ID)
pablo scroll live-target --direction DIRECTION [--amount N] [--node ID | --point X,Y]
pablo type live-target --text TEXT [--node ID]
pablo key live-target --key KEY [--modifiers LIST]
pablo perform live-target --node ID --action ACTION
pablo annotate [recording.pablo] --text TEXT [markup options]
pablo resolve <NOTE-###> [recording.pablo]
```
