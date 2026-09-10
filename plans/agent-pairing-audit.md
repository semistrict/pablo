# Pablo: human–agent pairing audit

Date: 2026-09-10. Baseline: de56748 plus the current uncommitted replay redesign, hover inspection, and toolbar fixes. This evaluates the current application, not only the latest diff. Source references are relative to the repository and use the line numbers at audit time.

## Assessment

Pablo exposes useful recording, live inspection, action, and annotation primitives, but it does not yet expose the shared review context needed for a competent pair. An agent can inspect a recording from disk or operate a live application while remaining unaware of the recording, element, timeline event, note, or draft the human is currently discussing.

The most important product gap is a first-class review session with a coherent snapshot, stable identity, shared commands, and observable changes. The most urgent correctness gaps are ambiguous retries, unchecked request bounds, stale pointer geometry, and lifecycle responses that can conceal finalization failure. Adding replay endpoints without addressing those failure modes would create more operations that an agent could misunderstand or repeat.

“Accessible” needs two complementary guarantees:

- The native interface exposes meaningful names, roles, selected values, keyboard actions, and errors to accessibility clients. A human can use the interface without depending on a particular mouse gesture, and an agent can use normal UI automation when needed.
- The approved local API exposes the same semantic state and operations with stable references and completion/error semantics. The agent can say what is selected, act on that selection, and verify the result without inferring it from screenshots or widget coordinates.

The UI and API should call the same state transitions. Merely adding more click targets, or exposing private view properties independently, would leave conflicting notions of selection and completion.

## Scope and evidence limits

Three parallel read-only investigations covered replay/annotations, capture/live/Safari, and the CLI/control contract. The primary review re-read the cited implementation for the findings below and consolidated overlap. Recon included the product vocabulary, ADR, README, build and package configuration, behavioral catalog, CI/release workflows, and generation checks.

This audit did not modify source, run new recordings, exercise dangerous malformed requests, or perform fault injection against the running app. The defects below are static findings unless stated otherwise. The earlier signed-app checks and human confirmation established hover behavior and the repaired tool selection in the specific Finder replay; they do not validate the whole app. The pre-audit suite completed 15 XCTest tests and 102 Swift Testing tests. That baseline is not proof of the missing scenarios identified here.

Not performed: a line-by-line audit of generated/vendor code; external dependency-advisory or latest-version checks; a fresh notarization/release; exhaustive macOS permission/signature permutations; multi-display capture fault injection; load profiling; or VoiceOver testing of every control. Performance and native accessibility concerns below distinguish source evidence from unmeasured runtime impact.

## Human operation versus agent capability

“Partial” means a useful structured primitive exists, but it does not establish shared context or the complete outcome. “Missing” means no corresponding method exists in the current control inventory, not that screen automation could never approximate the action.

| Workflow | Existing structured support | Pairing gap |
|---|---|---|
| Find saved recordings | CLI recordings/latest; rrweb recording listing | Discovery is file-oriented; latest can be a web package that native-only offline readers reject. No open-review listing or explicit source capabilities in ordinary discovery. |
| Open a recording | recording.open supports native and web packages | Returns path and data source before asynchronous window/video readiness; no review ID, ready/failed result, or reuse/new-window policy. |
| Identify what the human is reviewing | Missing | Current recording, active review, selected evidence, tool, crop, and draft are private UI state. Two windows can show the same package with different context. |
| Manage multiple review windows | Human window operations exist | No structured list, activate, close, or explicit pairing to one review. Automatic “latest” selection is insufficient. |
| Play, pause, seek, change speed | Internal playback methods; ordinary UI controls | No replay API. Requested seek time is not a renderer-settled acknowledgment. Web readiness/errors are not shared with callers. |
| Hover/pin recorded elements | Video hit testing and Elements inspector; offline AX frame reads | No recorded-point inspection API or current pin readback. A live AX node is a different identity from recorded evidence. |
| Select a recorded window/crop | Internal focusWindow and window menu | No viewport/focused-window state or command; no shared explanation when a recorded window is unavailable at that time. |
| Inspect AX trees and changes | Offline frames/frame/changed | Useful evidence access, but no command to show that same frame/node in an existing review. Sample time and playhead must stay distinct. |
| Navigate timeline events | Offline native events/workspace; web inspection through app | No common time-range query, cursor, visible selection, or jump-to-evidence operation across both sources. |
| Zoom or expand timeline evidence | Human controls | Context lives in view-local state. Agent queries need a time range and selected item; they do not need an endpoint for every visual pixel. |
| Read, add, resolve notes | Shared journal, approved writes, offline native read | Web CLI parity is broken; no current-selection anchoring, journal revision, edit/reopen, or safe create retry. Human writes do not refresh other open reviews. |
| Draw or compose a comment | Human Pen/Comment tools and quick note | No shared draft identity, captured anchor, ownership, or explicit save/discard/reanchor lifecycle. |
| Inspect the current rendered web page in replay | rrweb event inspection and web renderer | Raw recorded events are not the same as a selected DOM element at the current replay time. No shared rendered-node inspection/selection. |
| Choose a native capture target | App picker; record options accept selectors/display ID | No native app/window/display discovery method or permission preflight. Agent cannot reliably discover the same choices as the human. |
| Start/pause/resume/stop capture | Native and rrweb lifecycle methods | Status lacks complete active configuration, stream health, and durable last-operation outcome. Some stop failures appear only in the UI. |
| Inspect live native apps | AX snapshot/history and input events | No explicit window target, screenshot method, session-generation token, event cursor, or observation stop. Node output omits available actions/editability. |
| Act on native apps | Click/drag/scroll/type/key/exposed AX action | Coordinate paths can use stale geometry; pointer sequences do not stop on focus loss. Output describes dispatch without observing the application-level effect. |
| Inspect and act on Safari | Granted-tab discovery, DOM/derived AX, click/focus/value/scroll | Derived AX drops ordinary text; traversal bounds are incomplete. No document-generation precondition or action-effect verification. |
| Record Safari interaction | rrweb lifecycle, status, listing, event inspection | Stop can outrun pending event delivery; emitted count is not a durable persistence acknowledgment. |
| Recover from permission or operation failure | Human dialogs/settings links; string API errors | No structured readiness, awaiting-user state, result lookup, or safe retry contract. Consent and OS grants must remain human controlled. |
| Stop live observation or review daily grants | Sessions stop on teardown/eviction; daily approvals expire | No explicit observer stop/status contract or human grant-management UI in the audited surface. |

Primary inventory evidence: Sources/Pablo/ControlProtocol.swift:4–23, 50–60, 598–642; Sources/PabloApp/PabloApp.swift:111–139, 912–962, 1403–1429; Sources/PabloApp/ReplayView.swift:43–62, 281–335, 716–724, 1549–1554, 1990–1999; Sources/Pablo/CLI.swift:527–544, 555–695; Sources/Pablo/LiveInspection.swift:82–108, 244–320.

## Verified correctness and reliability findings

Priority reflects impact, exposure, effort, and confidence. P1 items can cause duplicate/wrong interaction, interrupt recording, lose evidence, or prevent recovery. P2 items undermine context, coverage, or completeness. Estimates: S is a contained change, M spans a few boundaries and tests, L needs coordinated design. Risk is the risk of the proposed change. These are estimates, not delivery commitments. All listed code paths were verified in source; no claim is made that every failure was reproduced at runtime.

| ID | Priority | Finding | Category / impact | Effort | Fix risk | Confidence |
|---|---|---|---|---|---|---|
| F01 | P1 | Reject invalid inspection and recording inputs in the app | Validation; approved malformed calls can trap the app during a recording | S–M | Low | High |
| F02 | P1 | Do not automatically resend ambiguously delivered mutations | Recovery; clicks, typing, and note creation can execute again | M | Medium | High |
| F03 | P1 | Refresh target geometry at dispatch | Target isolation; a moved window/control leaves pointer coordinates stale | M | Medium | High |
| F04 | P1 | Interrupt pointer sequences when focus changes | Target isolation; user switches apps while global events continue | M | Medium | High |
| F05 | P1 | Propagate finalization failures to lifecycle callers | Evidence integrity; stop can return success after failure | M | Low–medium | High |
| F06 | P1 | Drain pending rrweb delivery before pause/stop completes | Evidence integrity; final batches can be omitted | M | Medium | High |
| F07 | P1 | Keep control I/O responsive during approval/slow clients | Availability; one request blocks subsequent discovery and control | M–L | Medium | High |
| F08 | P2 | Restore idle state when recording initialization throws | Recovery; failed target resolution leaves the recorder starting | S | Low | High |
| F09 | P2 | Expose incremental live events | Observation; repeated reads keep returning the oldest retained page | S–M | Low | High |
| F10 | P2 | Preserve live-reference identity across eviction | Context integrity; an old frame reference can mean a new observation | M | Medium | High |
| F11 | P2 | Dispatch offline inspection/notes by recording source | Feature parity; a valid web package fails normal CLI workflows | M | Low–medium | High |
| F12 | P2 | Broadcast human annotation mutations to all reviews | Shared state; other open windows show stale notes/status | S | Low | High |
| F13 | P2 | Validate actual annotation evidence anchors | Evidence integrity; valid-looking nonexistent node IDs persist | M | Medium | High |
| F14 | P2 | Clear stale note selection when selecting other events | UI correctness; inspector can stay on an unrelated note | S | Low | High |
| F15 | P2 | Include meaningful page text in Safari derived AX | Observation; prose and heading text can disappear | M | Medium | High |
| F16 | P2 | Bound Safari traversal work and serialization | Reliability; maxNodes does not bound all visited/output nodes | M | Low–medium | High; runtime threshold unmeasured |
| F17 | P2 | Correct advertised rrweb schema version | Contract; strict clients reject valid output | S | Low | High |
| F18 | P2 | Publish recording stream degradation | Observability; input/AX writes can fail behind an active recording | M | Low–medium | High |
| F19 | P2 | Make boundary-test claims match executable coverage | Verification; catalog overstates identity and rejection tests | M | Low | High |

### F01 — App-side input validation

Sources/Pablo/LiveInspection.swift:82–106 forwards a decoded limit to eventsOutput; line 315 calls prefix(limit), which requires a nonnegative bound. Sources/Pablo/ControlProtocol.swift:381–408 also accepts recording numbers and copies them into RecordOptions without semantic validation; Sources/Pablo/VideoRecorder.swift:100 multiplies FPS and line 209 narrows it to CMTimeScale. CLI checks do not protect direct HTTP clients. Caller approval and relevant OS prerequisites still apply; this is not an unauthenticated remote attack.

Reject invalid limits, target-selector combinations, durations, snapshot intervals, and FPS at the app boundary before observation or capture starts. Share validation with the CLI and document actual ranges. Test raw JSON with negative and excessive values, invalid selectors, and the largest decoded integers; expect a bounded error and a still-running server, never a test that passes because the app crashes.

### F02 — Ambiguous delivery retry

Sources/Pablo/CLI.swift:410–417 catches any client send/read/decode failure, launches the app, and resends. Lines 1282–1290 retry up to 80 times without distinguishing connection failure from response loss after execution. Sources/Pablo/ControlProtocol.swift:501–530 supplies a fresh server-side request UUID when decoding each call, with no deduplication. Ordinary application-error responses do not trigger this retry; the risk is ambiguous transport/protocol failure.

Immediately restrict automatic startup retry to failures known to precede delivery. Return outcome-unknown when execution may have happened. A subsequent operation receipt/idempotency design should permit safe lookup or retry within an explicit retention period. A fake transport must apply one mutation, lose the response, and prove the client does not apply it twice.

### F03 — Stale pointer coordinates

Sources/Pablo/LiveInspection.swift:123–126 captures an action snapshot only if none exists. Sources/Pablo/LiveActions.swift:22–48 acquires it before asynchronous activation; lines 371–408 use cached node/window geometry and prefer cached windows over a live fallback. A recent inspection followed by a human moving the window can therefore misdirect a coordinate action.

Resolve the selected live AX element/window and its geometry after activation and immediately before posting. Validate current ownership, visibility, and existence; reject stale references rather than substituting another target. Keep background AXPress support. Test window movement, resize, removed/replaced controls, and a target disappearing during activation with an injectable AX/input adapter.

### F04 — Pointer focus interruption

Sources/Pablo/LiveActions.swift:411–417 has a focus guard for keyboard delivery. The drag loop at 194–220 and repeated clicks at 432–457 post global events across asynchronous sleeps without that guard; scroll at 272–274 also posts without a final target check. Foreground actions are explicitly unlocked first, but unlock does not mean the human gave up control indefinitely.

Revalidate the target before pointer dispatch and between segments/clicks. On interruption, stop further interaction and safely release any held input. Check both application and intended window/geometry where feasible; do not claim macOS can make all global input atomic. Test focus loss during drag and between clicks, including button-release cleanup.

### F05 — Stop falsely implies successful finalization

Sources/PabloApp/PabloApp.swift:817–835 catches native stop errors into UI errorMessage, clears the session, and becomes idle. The API invokes it at 905–909 and returns a normal result at 1096–1099; controlResult at 1403–1429 does not include that error. The rrweb path at 1039–1044 similarly returns status after stopRRWebRecording can catch a finalization error at 591–592.

Use a shared throwing/result-returning lifecycle operation for UI and API. Return package completeness, error, and recoverable path; retain a last-operation result after teardown. Test video/manifest/journal finalization failures and rrweb storage failure. A stop request must not mean the package is complete merely because capture is no longer running.

### F06 — rrweb flush race

SafariExtension/JavaScript/recorder-entry.js:34–39 returns immediately if the current event buffer is empty even when pendingFlush is still sending an earlier batch. Pause and stop await this helper at 105 and 118. Sources/PabloApp/PabloApp.swift:568–595 then reads batches, finalizes, and removes the spool. RRWebSpoolStore.swift:43–47 can recreate its directory for a late batch.

Always await the pending chain, including an empty current buffer. A final acknowledgment should identify the last sequence/count; finalization should confirm receipt before marking complete or removing the spool. Test with a deliberately unresolved send promise, then release it and assert the final batch is present exactly once and no spool is recreated. Delivery failure must yield interrupted/failed completeness rather than silent success.

### F07 — One connection stalls every later connection

Sources/Pablo/ControlProtocol.swift:925–935 handles clients synchronously in the sole accept loop. Lines 984–990 wait for the handler and response write; 993–1009 configure only a receive timeout. Approval can wait on the human, and a sufficiently large response to a client that stops reading can block writes. Even approval-free openapi.json cannot be served until acceptance resumes.

Separate bounded connection I/O from a serialized app mutation coordinator. Add admission limits and write/operation deadlines, preserving the existing same-user and caller-verification boundary. Status/readiness must distinguish queued, awaiting-user, running, and failed. Test a stalled reader and a pending handler while a second discovery request completes. Deadline expiry after execution must report ambiguity, not trigger F02 again.

### F08 — Failed initialization leaves starting state

Sources/PabloApp/PabloApp.swift:842–850 sets starting and constructs RecordingSession before entering its reset catch. RecordingSession.swift:35–41 can throw while resolving a nonexistent app. Human start wrappers reset state, but the API path at PabloApp.swift:886–894 only reaches the outer response-error catch; it does not restore idle. Later starts reject starting, while stop requires an active session.

Include construction in the same cleanup transition as startup, and ensure failure leaves no active session or automatic-stop task. Test an invalid target through app dispatch followed by a valid start attempt; the second call must not be blocked by the first failure.

### F09 — Live event polling returns the old page

Sources/Pablo/LiveInspection.swift:313–316 always takes the oldest retained prefix and drops the internal sequence index. Lines 323–328 retain up to 10,000 events. Once the first limit-sized page fills, repeated polls cannot retrieve newer events until callers increase the limit or retention evicts old ones.

Expose sequences, after/next cursors, an observation-session identity, and oldest/newest retained bounds. Report gaps explicitly. Test incremental and empty reads, exact limit boundaries, and eviction. Returning only the latest page would improve visibility but still cannot guarantee loss detection.

### F10 — Live references silently acquire new meanings

Sources/Pablo/LiveInspection.swift:8 starts frame numbering at zero; 129–140 evicts sessions after eight targets. On a recreated session, 229–238 can capture a new first frame when asked for the old first-frame reference. A retained A11Y reference can then identify different evidence without an app restart.

Qualify references with a session generation, or preserve globally monotonic identity across eviction and return stale-reference errors. Do not confuse bounded retention with permission to reuse identities silently. Test nine targets, revisit the evicted one, and verify the original reference cannot resolve as new evidence. Update the agent-facing reference-lifetime documentation.

### F11 — Native/web offline parity

Sources/Pablo/CLI.swift:527–538 assumes native streams for inspect. Lines 320 and 682 load ReplayRecording for annotation creation preparation and listing. ReplayRecording.swift:189–197 requires accessibility/events/workspace; RRWebRecording.swift:419–440 writes valid web packages with only an rrweb evidence file. The UI already creates web notes through RecordingAnnotationStore at ReplayView.swift:432–449.

Dispatch through the existing manifest dataSource and share source-independent annotation journal loading. Provide offline web summary/event inspection and explicit unsupported-operation errors for native-only frames/traces. Test mixed recording directories, a web latest recording, web note reads, time conversion, and native regressions. This requires current-v3 source dispatch, not legacy compatibility.

### F12 — Human note edits do not refresh other windows

Sources/PabloApp/ReplayView.swift:448, 487, and 506 reload only the originating model after human add/resolve. The same operations through the bridge broadcast pabloAnnotationsDidChange at PabloApp.swift:945–961. ReplayView.swift:778–780 listens for it, and PabloApp.swift:111–117 creates an independent model per window.

Publish one source-qualified journal-change event after every successful mutation regardless of human/agent origin. Refresh all matching views while preserving valid selection. Test two models showing one package, human create/resolve in one, and agent create/resolve through the same mutation service.

### F13 — Annotation anchors can name nonexistent evidence

Sources/Pablo/RecordingAnnotations.swift:358–370 checks frame existence/application ownership, but 373–385 checks only node namespace and application membership. It does not prove that the node exists in the referenced materialized frame. Lines 315–357 also do not enforce completed-recording time bounds. Replay selection clamps playback to actual duration at ReplayView.swift:282, so an out-of-range anchor can be shown at a different time.

Define node-plus-frame anchor semantics and validate actual membership; reject nonexistent or removed nodes. Define completed-recording bounds separately from an active recording's evidence watermark. Keep sampled AX time distinct from video time: a legitimate older observation is not an invalid anchor merely because it precedes the current picture. Tests should include nonexistent nodes within a valid namespace, removal deltas, wrong-app frames, and beyond-end timestamps.

### F14 — Primary selection conflicts after leaving a note

Sources/PabloApp/ReplayView.swift:376–389 sets selectedAnnotationID. Selecting workspace/input/automation/web timeline evidence at 391–402 does not clear it. The inspector's 2122–2123 callback chooses Notes whenever that old ID remains non-nil, even though a different event is selected and the playhead moved.

Centralize mutually exclusive primary selection transitions, preserving deliberate node pinning separately if desired. Test note → input event, note → workspace event, and note → web event. The inspector and shared snapshot must agree about the primary selection.

### F15 — Safari derived AX omits reading content

SafariExtension/Resources/background.js:319–337 derives names for labels and selected controls, not ordinary paragraphs or general heading text. Lines 402–407 visit element children only and discard elements without a role/name/tab stop. Ordinary prose can disappear, and heading roles can remain without their heading text. Raw DOM is available, but it is a poor substitute for the promised concise accessibility view.

Represent meaningful static text in order and compute role-appropriate names without duplicating every descendant label. Test article paragraphs, headings, mixed inline text, labels, hidden text, and password fields. Keep this explicitly a derived view rather than claiming full browser accessibility-tree equivalence.

### F16 — Safari node limits do not bound the work

SafariExtension/Resources/background.js:365–392 does not count text nodes and continues mapping all children after the count is exhausted. Lines 396–407 visit accessibility descendants before incrementing a returned-node count; generic wrappers need not consume it at all. Lines 561–564 push the complete byte array with spread syntax, which also risks engine argument limits on large payloads; the exact failure threshold was not measured.

Bound visited work, depth, returned nodes, and encoded bytes separately. Stop child iteration when exhausted, account for text/attributes, and append bytes in bounded chunks. Return honest truncation metadata. Test text-heavy pages, many wrappers, deep trees, oversized attributes, and large responses with deterministic fixtures.

### F17 — OpenAPI says version 1; runtime emits version 3

api/control-api.openapi.yaml:602 declares RRWebRecordingManifest.schemaVersion constant 1. Sources/Pablo/RRWebRecording.swift:35 and 59 emit 3. Loose generic-output validation may conceal this, while operation-specific clients reject valid results.

Change the YAML source, run scripts/generate-control-openapi.rb, and validate real encoded response fixtures against their operation schema. Tests/PabloTests/AppBundlePackagingTests.swift:310–329 already checks generation freshness; semantic agreement is the missing coverage.

### F18 — Evidence stream failures are not shared health state

Sources/Pablo/RecordingSession.swift:137–141 logs failed input appends to stderr. Sources/Pablo/AccessibilityRecorder.swift:283–287 does the same for AX append failure. The recording status response at PabloApp.swift:1422–1429 contains no per-stream degradation or persistence counters.

Retain first/latest errors, affected streams, and persistence watermarks in session health and show them in both UI and API. Distinguish transient capture gaps from failed durable writes; do not equate running video with complete evidence. Inject writer failures and assert that degradation remains observable before and after stop.

### F19 — Behavioral coverage is overstated

Tests/Behavior/control_and_consent.feature:15–24 labels live signature/team resolution and dialog identity automated. The cited ancestry logic is exercised with dictionaries at Tests/PabloTests/ControlProtocolTests.swift:71–82; adjacent tests cover bundle-path ownership and kernel parent lookup, not the full signing/consent flow. The bounded/private scenario at feature lines 26–40 claims oversize/peer rejection, while the cited round-trip test at ControlProtocolTests.swift:105–149 tests valid calls and file modes. The no-caller-identity round trip at 550–593 does not supply forged identity fields.

Split modeled unit guarantees from real signed-app/manual prerequisites. Add adversarial socket/request fixtures, caller-verification injection, ambiguous-delivery tests, and end-to-end approval-to-dispatch tests at the appropriate boundary. Keep tests expecting correct behavior; neither a crash reproduction nor a skipped permission prerequisite establishes a passing product scenario.

## Performance and UI-accessibility follow-up

These source findings warrant targeted measurements, not an immediate broad rewrite.

| Concern | Evidence | Likely effect | Effort / risk / confidence |
|---|---|---|---|
| Library discovery materializes all native recordings synchronously | ReplayView.swift:191–246; ReplayRecording.swift:195–228 | Opening one review scales with the evidence in every native library package; repeated across windows | M / low–medium / high for work performed, latency unmeasured |
| Repeated full-history temporal scans during playback | ReplayView.swift:672–678, 777 and 71–75; ReplayRecording.swift:282–288 | Main-actor work grows with recording length; inspection caching occurs after another temporal query | M / medium / high for algorithm, user impact unmeasured |
| Custom replay semantics are not fully represented as accessibility actions/state | ReplayView.swift:1155–1168, 1777–1795, 2700–2704 | Canvas gestures, marker identity, and visual row selection need explicit semantic verification; labels alone do not establish operability | M / low–medium / medium pending AX/VoiceOver matrix |

Use manifest metadata for library rows and materialize the chosen recording off the main actor with source-generation cancellation. Consider per-app timestamp indexes and one reusable current-evidence snapshot after profiling long recordings.

For native accessibility, verify every interactive control has a stable name, correct role, selected/current value, keyboard action, and visible error feedback. Verify the selected recorded node and annotation through an inspectable semantic representation; decorative bounds/traces may remain accessibility-hidden when equivalent text/selection exists. Provide a keyboard-accessible alternative for point inspection and drawing-related annotation, while the structured API can accept exact trace samples. Do not require an accessibility tree with thousands of virtual pixel targets.

## Four product directions

### D1 — Shared review sessions and semantic commands

Grounding: per-window ReplayModel creation at PabloApp.swift:111–117; private selection/playback at ReplayView.swift:43–62; view-local tool/draft/inspector state at 716–724 and 1990–1999; only recording.open in ControlProtocol.swift:4–23. This is the central missing pairing feature. Effort L; change risk medium.

An app-owned registry should assign an opaque reviewID to each open review and a source generation when its package changes. A coherent snapshot should contain source identity/path/type, active/key status, revision, renderer readiness/error, playhead, playback state/rate, focused recorded window and coordinate transform, primary selection, separate pinned/hovered evidence where relevant, annotation revision, tool, and draft summary. Native packages do not currently provide a universal recording UUID; define identity without rewriting immutable manifests, for example an app/session source handle plus a verified package descriptor. A path alone does not distinguish replacement at that path.

Commands should address a review explicitly and use the same transitions as UI controls: open/activate, seek, play/pause/rate, focus recorded window, inspect recorded point, select frame/node/event/note, clear selection, and show the relevant inspector context. Accept optional expected source/selection revision for context-sensitive mutations; reject stale commands. Report the resulting snapshot and separate requested time from settled renderer time. A read can default to the active review; a mutation based on “this” should be resolved to a specific handle before execution.

Trade-off: exposing every incidental SwiftUI variable would freeze presentation details into the API. Expose product concepts and stable evidence references; only expose timeline visibility/range or inspector expansion when it materially affects shared context. Use a clear primary-selection model rather than independent nullable fields that can disagree.

### D2 — Operations, recovery, and bounded change watching

Grounding: free-text errors at ControlProtocol.swift:626–642; retry at CLI.swift:410–417; asynchronous open at PabloApp.swift:927–934; native action evidence UUID at 972–989. Effort L; change risk medium, especially around consent and scheduling.

Define operation-specific results and errors: invalid request, target unavailable, stale context, denied, awaiting human, failed before dispatch, interrupted, completed, and outcome unknown. Keep operation status separate from observed application effect. Return the resolved target and automation evidence action ID. A generic click can prove dispatch or an AX API result; it cannot promise the page saved successfully without a separate observable condition.

Support bounded operation receipts and either an explicit client idempotency key or a prepare/execute receipt. Bind deduplication to the verified caller and operation payload; a key is never proof of identity. Do not retain typed content in receipts. Specify receipt expiry and behavior after app restart so “not found” does not silently mean “safe to execute again.”

A bounded event feed should report review activation, source/selection/tool changes, journal changes, lifecycle transitions, readiness/errors, and operation completion. Include cursor, sequence, source/revision, and origin so the agent can see human changes without reacting to its own update repeatedly. Coalesce playhead/hover motion; avoid flooding clients. Report retention gaps and require resynchronization. Long polling can work with the existing one-request-per-connection protocol if connection handling is bounded and does not block other work.

Trade-off: transport concurrency must not permit uncoordinated concurrent mutations. Keep an app-owned serialized mutation path, permit independent bounded reads, and retain human approval as the authority. Cancellation cannot undo a completed side effect; represent the actual phase.

### D3 — Shared evidence and annotation workflows

Grounding: native/web mismatch F11, cross-window refresh F12, anchors F13, and local draft state in ReplayView.swift:1419, 1999, 2127–2138. Effort M–L; change risk medium.

Provide source-aware offline queries for summaries, events, frames where supported, notes, and time ranges. An agent should be able to request the visible recorded frame or crop together with coordinate mapping, playhead, sampled AX frame references/ages, and source generation. For web replay, define rendered DOM/event anchors separately from native AX anchors. Do not silently reinterpret one source's reference as the other.

Make a draft an explicit object bound to its review/source and captured anchor, with owner, body, kind, trace, and save/discard/reanchor operations. Source changes and closing/hiding an inspector need defined draft behavior. A human draft must not be silently published, overwritten, or moved to a new recording by an agent. Agent suggestions can use a separate draft or a deliberate update to a shared draft. Editing/reopening saved notes would be new features on both surfaces; if added, retain append-only full states and expected note revisions.

Trade-off: draft persistence and exposing unfinished text require an intentional user-facing lifecycle. Prioritize reliable current-selection anchoring and shared saved notes before adding collaborative draft editing. Exported visual evidence must retain source/time provenance and remain distinct from original captured artifacts.

### D4 — Discovery, live freshness, and human-controlled recovery

Grounding: application discovery exists in RecorderModel but not the method inventory; target fields are app-only at ControlProtocol.swift:50–60; AX nodes at AccessibilityRecorder.swift:80–95 omit action names; live observers start at LiveInspection.swift:244–264 and stop on teardown at 199–200. Effort L across smaller deliverables; change risk medium.

Expose runtime build/capabilities, approved app/window/display targets, permission prerequisites, and current recording configuration/health. Return current action capabilities and whether they use background AX or require explicitly unlocked foreground input. Give native targets an inspection-session/window identity and Safari targets a navigation/document generation, with stale-target errors. Optional screenshot/frame capture should have explicit scope and return its relationship to the semantic snapshot.

Make live observation explicit: start/status/read/stop, bounded retention, cursor gaps, text-capture disclosure, and visible active observation. Provide a human-owned place to inspect/revoke daily approvals. Readiness can explain which human action is needed, but neither agents nor the API should approve themselves, grant macOS privacy access, or expand Safari activeTab permission.

Trade-off: discovery can reveal application/page metadata, so keep sensitive detail under the appropriate existing consent boundary. A static protocol/build capability response can be separated from a consent-gated target listing. Do not conflate authorization readiness with authorization itself.

## Suggested contract shape

Names below are design proposals, not existing endpoints. Keep the current method-specific URL convention and source-generated OpenAPI process. Existing protocol decisions can change where needed, but compatibility work is not a requirement for this task.

| Family | Proposed responsibility | Essential invariant |
|---|---|---|
| review.list / review.state | Find open reviews and read one coherent snapshot | Identifies window, source generation, and revision; never substitutes latest file for active review |
| review.open / review.activate | Open or bring forward a chosen review | Returns review handle and observable opening/ready/failed state |
| review.seek / playback / focus / select | Mutate the same state as human controls | Explicit review; stale-context preconditions; clear completion semantics |
| review.inspect / evidence queries | Inspect a recorded point, selected evidence, frame/crop, or time range | Source-qualified identity, coordinate transform, playhead and AX observation time |
| review.events | Observe bounded changes | Cursor/gap/origin semantics and coalescing; no blocking of unrelated requests |
| annotation / draft operations | Create/resolve and, if added, edit/reopen or collaborate on drafts | Shared mutation service, append-only saved state, revisions, provenance, explicit publication |
| operation.status / cancel | Recover results and request cancellation | Distinguishes not-started, dispatched, completed, interrupted, and unknown; no duplicate replay |
| capabilities / targets / observation | Discover allowed targets/readiness and manage live observation | Human grants remain authoritative; identities expire explicitly |

Avoid a broad “set arbitrary state” endpoint. A small typed command vocabulary is easier to validate, test, document, and keep aligned with UI behavior.

## Delivery order and dependencies

1. **Correctness foundation.** Fix F01, F02, F05, F06, and F08 with failing regression tests first. F17 and F12 are small independent fixes. Harden pointer targeting F03/F04 before expanding live-action usage.
2. **Read-only shared context.** Introduce the review registry, source identity, coherent snapshot, primary selection, and renderer readiness. Address F14. This immediately allows the agent to understand what the human selected without taking control.
3. **Reliable commands and observation.** Design operation/error/receipt semantics and bounded transport together with F07. Add semantic replay commands and revision preconditions, then change watching. Test concurrent human activity before exposing broad automation.
4. **Evidence and note parity.** Implement source-aware offline reads F11, anchor validation F13, and shared annotation revisions. Add frame/crop export and selection-anchored note creation. Decide draft ownership before any draft-edit API.
5. **Live and Safari completeness.** Add discovery/readiness, explicit observation lifecycle, live cursors F09 and generation identity F10; correct Safari text/budgets F15/F16 and expose dispatch/effect semantics. Publish stream health F18.
6. **Accessibility, scale, and release confidence.** Finish the native accessibility matrix, executable JavaScript fixtures, and honest boundary coverage F19. Profile large recordings before implementing indexing/background loading. Run the full signed-app pairing scenarios and normal release checks.

Dependencies that should not be split accidentally: review commands depend on source/review identity; change watching depends on revisions and transport admission; safe retry depends on receipt semantics; current-selection annotation depends on source-qualified anchors; draft edits depend on ownership; live action preconditions depend on session/document identity. Discovery, state-model work, and contained bug fixes can proceed independently after their contracts are agreed.

## Acceptance scenarios for a competent pair

| Scenario | Observable correct outcome |
|---|---|
| Human clicks an element in paused video | Agent reads the same review, source, playhead, node, frame reference, crop, and AX observation age; no note is created. |
| Human has two reviews of the same recording | Agent targets one review ID; seeking it does not seek the other. Switching the key window is observable. |
| Human changes recording after agent reads selection | A selection-based command using the old source/revision returns stale context and performs no mutation. |
| Agent asks to show a frame or node | The intended review visibly selects it; returned state and renderer acknowledgment agree on source and time. |
| Agent requests a time with no available window/video/AX observation | Response distinguishes unavailable video, absent window, absent AX, and older sampled evidence; it never invents a node. |
| Human switches Notes, Pen, Comment, Inspect | AX state and review snapshot expose the selected tool; playback controls remain operable; tool/draft transitions have defined outcomes. |
| Human adds/resolves a note with two windows open | Both matching reviews and the agent's journal view update to the same revision without losing unrelated valid selections. |
| Human has an unfinished note while agent acts | Draft owner/source/anchor remain intact; agent cannot accidentally publish or reanchor the human draft. |
| Agent creates a note and the response is lost | Exactly one note exists; caller gets the recorded result or outcome unknown, never an automatic duplicate. |
| Agent targets a node after the human moves its live window | Current geometry is used or a stale-target error occurs before posting; old coordinates are not used. |
| Human switches apps during a foreground drag | Remaining input stops, held buttons are released safely, and the operation is interrupted rather than succeeded. |
| Live events exceed one page or retention | Incremental reads expose new events exactly once per cursor progression and explicitly identify any retention gap. |
| A live target is evicted and later revisited | Old frame references fail as stale rather than aliasing new evidence. |
| Recording initialization/finalization fails | UI and API agree about failure, retain a recoverable path where applicable, and permit valid subsequent operations. |
| rrweb stop runs while a batch is in flight | Completion waits for durable receipt or reports interruption; no omitted final batch or recreated orphan spool. |
| Latest recording is a web package | Offline summary/events/notes work, and native-only operations explain their unsupported capability. |
| An API client sends invalid numeric bounds | Structured rejection before work starts; ongoing recording and later requests remain usable. |
| One client waits on approval or stops reading | Other allowed discovery/status work stays bounded and responsive; mutating requests remain coordinated. |
| Safari page is mostly prose or very large | Derived AX contains meaningful ordered text; traversal and bytes stay bounded with honest truncation. |
| A permission or approval is missing | Agent sees a precise human-action requirement; denial has no side effect; no programmatic self-approval. |

## Verification and maintenance

Use the existing XCTest/Swift Testing conventions under Tests/PabloTests and keep Tests/Behavior scenarios synchronized. Extract small injectable boundaries for transport, input dispatch, writer failure, and review state where needed. Behavioral assertions must describe correct results. Do not test that a known bug reproduces and count it as a passing suite guarantee.

Run swift test before shipping. API changes update api/control-api.openapi.yaml, run scripts/generate-control-openapi.rb, and pass its --check mode; validate runtime fixtures against operation-specific output schemas. Protobuf changes update proto/pablo/v3 inputs, then run buf format --diff --exit-code, buf lint, and buf generate. Never edit generated Swift or web bundles directly.

The Safari JavaScript package currently has a build script, not a test script. Introduce an executable fixture harness for recorder delivery and DOM traversal using the existing pnpm workflow, then integrate it into CI. Run scripts/build-rrweb-assets.sh after source changes and preserve the generated-asset freshness checks already present in CI.

Use scripts/build-app.sh for a signed local app and document actual permission prerequisites for integration testing. Test UI/API parity against the same state transitions, plus signed-app scenarios for real identity, consent, focus, and capture. The opt-in application capture smoke test requires existing privacy grants; an unavailable prerequisite is blocked, not passed. Distribution verification remains the existing exact-ZIP signature, Gatekeeper, and stapler workflow; this audit did not perform it.

## Considered and rejected / intentionally preserved

- No legacy recording compatibility work: current v3 data-source dispatch is different from supporting old manifest layouts.
- macOS privacy grants, app-owned daily caller approval, and Safari activeTab grants remain human decisions. Missing diagnostics are a pairing gap; the grants themselves are not a bug.
- Foreground input is locked by default. The fixes above strengthen target isolation after an explicit unlock.
- Captured video/events/workspace/accessibility remain immutable; notes stay an append-only journal with verified provenance.
- Native AX and web DOM/rrweb references remain different evidence types. Rejecting native spatial traces and AX anchors on web notes is intentional.
- AX evidence is sampled, bounded, and sometimes sparse or truncated. A frame-age field must explain that; the product must not claim deterministic re-execution or an always-exact match to video.
- Bounded live retention and offline web resource blocking are intentional. Retention gaps and identity reuse must be handled explicitly.
- The source-generated OpenAPI check, pinned dependencies, generated-asset checks, and packaging gates already exist. This audit does not claim missing checks where the actual problem is incomplete semantic fixtures or overstated behavioral coverage.
- No broad plugin system, backend service, or cloud infrastructure is needed to solve the identified pairing problem. Build on the app-owned local bridge and existing evidence model.
