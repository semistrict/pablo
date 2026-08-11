---
name: pablo
description: Record, control, locate, and inspect Pablo macOS interaction recordings. Use when asked to record a workflow in a Mac app, pause/resume/stop a recording, examine a `.pablo` recording, analyze input events or accessibility snapshots, compare indexed `A11Y-###` frames, or explain what happened during a captured interaction.
---

# Use Pablo

Use Pablo's CLI to control the consent-gated menu-bar app and inspect completed recordings. Prefer structured CLI output and refer to accessibility states by their stable `A11Y-###` indexes.

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

- For `record`, `status`, `pause`, `resume`, or `stop`, use the CLI to speak to the running Pablo app.
- For `recordings`, `latest`, `inspect`, `frames`, `frame`, or `events`, inspect completed recordings directly. These commands do not need the app or an approval prompt.
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
pablo inspect [recording.pablo]
pablo frames [recording.pablo] [--json]
pablo frame <A11Y-###> [recording.pablo] [--changed] [--json]
pablo events [recording.pablo] [--limit N] [--json]
```
