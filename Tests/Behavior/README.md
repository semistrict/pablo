# Pablo behavioral test catalog

The `.feature` files in this directory describe intended product behavior in a Gherkin-style language that an AI tester can follow through the app, CLI, or focused fixtures. They complement the Swift suites; they do not replace executable regression tests.

## Tags

- `@automated` — covered by the Swift test named in the scenario comment.
- `@signed-app` — requires a signed Pablo build running on macOS.
- `@permission` — may reach an operating-system permission surface. The tester must hand control to the user before approving or changing privacy access.
- `@human-approval` — the user must make the final allow/deny choice in Pablo.
- `@manual` — requires observation of behavior owned by macOS or another live app.
- `@distribution` — requires a Developer ID build and the release verification workflow.

## AI tester protocol

1. Treat every `Given` as a required precondition. Do not silently substitute a different app, recording, signature type, permission state, or build.
2. Perform `When` steps in order. For a scenario tagged `@human-approval` or `@permission`, pause at the approval surface and ask the user to take the stated action.
3. Verify every `Then` and `And` independently. Capture exact paths, `A11Y-###` or `NOTE-###` references, timestamps, visible labels, and errors.
4. Never include passwords, tokens, payment details, or private typed text in the report. State that sensitive data was redacted.
5. A scenario passes only when all outcomes match. Product crashes, disappearing windows, repeated permission prompts, unexpected seeks, and unexplained dialogs are failures even if a package is eventually produced.
6. Report blocked scenarios separately with the missing prerequisite. Do not mark them passed.

## Automated coverage map

| Swift suite | Behavioral feature |
| --- | --- |
| `AutomationActionTraceTests` | `recording_lifecycle.feature` |
| `SafariDOMProtocolTests`, `AppBundlePackagingTests`, `ControlProtocolTests` | `safari_extension.feature` |
| `RRWebRecordingTests`, `RRWebSpoolStoreTests`, `RRWebReplayModelTests`, `SafariDOMProtocolTests`, `ControlProtocolTests`, `AppBundlePackagingTests` | `rrweb.feature` |
| `AXTreeDifferTests` | `accessibility_replay.feature` |
| `AppBundlePackagingTests` | `packaging.feature` |
| `CLITests` | `cli.feature`, `annotations.feature`, and `live_actions.feature` |
| `ControlProtocolTests` | `control_and_consent.feature` and `live_actions.feature` |
| `LiveActionTests` | `live_actions.feature` |
| `LiveInspectionTests` | `cli.feature` |
| `ProtobufStreamTests` | `protobuf.feature` |
| `RecordingAnnotationTests` | `annotations.feature` |
| `ReplayRecordingTests` | `accessibility_replay.feature`, `playback.feature`, and `protobuf.feature` |
| `SessionClockTests` | `recording_lifecycle.feature` |
| `VideoCaptureLifecycleTests` | `recording_lifecycle.feature` |
| `VideoWriterPipelineTests` | `video_pipeline.feature` |
