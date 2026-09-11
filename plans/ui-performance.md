# Replay UI performance

## Scope

The user reports stutter across UI transitions and while exploring the recorded accessibility tree. The affected owner is the replay model and its tree presentation in `ReplayView.swift`; native and web renderer observations share the same publishing invariant. Preserve playback synchronization, inspector controls, complete evidence access, and the user's recording.

## Reproduction and diagnosis

- The paused signed app used approximately 97–100% CPU with a 936-node frame open in the tree inspector. Five-second `sample` captures showed sustained main-thread SwiftUI graph updates and layout work. The tree projection also appeared in the sampled stacks.
- The SwiftUI Instruments capture spent several minutes finalizing and was stopped. It is not used as a completed trace or a frame-time measurement. Lightweight samples are the comparison source.
- `swift test --filter 'accessibilityOutline|pausedReplayTicksDoNotPublishUnchangedState'` failed before the fix: 120 unchanged native ticks emitted 120 model notifications, and collapsed descendants incorrectly remained visible as top-level rows.
- `swift test --filter pausedWebReplayDoesNotPublishUnchangedState` failed before the fix: 120 unchanged web observations emitted 240 notifications.

## Change

- Publish renderer time and web playback state only when their values change. Genuine playback and seek updates retain their existing timing and semantics.
- Determine disconnected tree components separately from expansion. Traverse only expanded branches for visible rows; a collapsed descendant remains attached to its parent.
- Keep orphaned components and cyclic evidence reachable without duplicate rows.

## Verification

The four regression tests pass. The complete suite passes with 189 Swift Testing tests and 18 XCTest tests. Structured review reported no actionable P0 findings.

The updated signed app was tested on the same paused source and frame, with the library, timeline, and tree inspector open. The original source, paused position (4.415075917 seconds), pinned node, and annotation count were restored after restart. The tree's initial visible outline now contains 19 rows; expanding a branch adds its child and collapsing removes that child. Scrolling and closing/reopening the Inspector completed, and the review was left paused with the tree visible.

Before the fix, the lightweight sample contained 3,940 main-thread observations, including 2,138 in root geometry/layout; process CPU readings were approximately 97–100%. After the fix, 3,770 of 4,004 main-thread observations were waiting in the run loop, and settled process CPU was 1.8%. The comparison measures CPU and sampled thread activity, not display frame rate. Accessibility inspection that previously took roughly 67 seconds returned in about half a second with the corrected outline.

The signed build was notarized and stapled. The incomplete Instruments trace was removed and its profiler stopped. Lightweight diagnostic samples remain outside the repository; no temporary recordings or cloud resources were created.
