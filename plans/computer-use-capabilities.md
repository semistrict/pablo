# Computer-use capabilities

## Goal

Make Pablo's existing approved control bridge efficient for sustained agent work: compact incremental observations, actions followed by fresh observations, precise text editing, paired accessibility and image observations, clipboard-preserving paste, and a reusable JavaScript client.

## Contract decisions

- Keep live inspection and action requests on the existing consent-gated endpoints. Add an `observe` inspection and optional observation options on live actions.
- Clients supply their own last observation reference. Diffs compare with that retained baseline, even when another caller has inspected the same application in between. Missing or expired baselines return a full snapshot with an explicit resynchronization indication. A client can request a full snapshot at any time.
- Return stable node IDs in structured changes and a compact text view. Text escaping must keep application content distinguishable from structural output.
- A post-action observation reports whether the sampled state settled within a bounded interval. It never turns successful dispatch into a claim that the user's intended effect occurred. Observation failure must preserve the action receipt and prevent blind retries.
- Pair window screenshots with accessibility state and collection timestamps. Validate process, selected window, and geometry around capture; reject ambiguous window matching. Do not claim macOS exposes an atomic accessibility-and-image snapshot.
- Text selection uses UTF-16 ranges, exact matching, and optional surrounding context. Reject ambiguity, unsupported attributes, stale targets, and secure-field reads. Field replacement is a separate accessibility operation from keyboard typing.
- Paste supports plain text and HTML with a plain-text fallback. Preserve all materialized clipboard representations, restore on failure/cancellation, and do not overwrite a clipboard changed by the human during the operation. Report restoration conflicts explicitly.
- The JavaScript client uses the local HTTP socket, operation receipts, caller approval, cancellation, and reusable app/tab handles. It stores references in the client and has no privileged execution endpoint. Existing Safari document grants and foreground-action restrictions remain in force.

## Implementation and verification

1. Add incremental observation models and baseline/retention tests.
2. Add bounded settling, live screenshots, and action observation integration.
3. Add precise text operations and paste with tests at the native side-effect boundaries.
4. Add the JavaScript client, integration tests, and documented examples.
5. Update OpenAPI source and generate its bundled output; synchronize behavioral scenarios and agent instructions.
6. Run the complete automated suite and appropriate signed-app workflows, review the changes, and clean up temporary test state.

## Progress

- Implemented all six capabilities across the native bridge, CLI, OpenAPI, recording metadata, and persistent JavaScript client. Source generators produced the bundled API and protobuf code.
- Automated verification: 185 Swift Testing tests and 18 XCTest tests; eight JavaScript socket/client tests; Buf formatting/lint, OpenAPI freshness, and whitespace checks.
- Signed-app verification: caller-relative deltas despite another reader, action plus observation, field replacement and clearing, Unicode selection and both cursor boundaries, secure-field rejection/redaction, primary and explicitly selected smaller-window screenshots, and preserved dispatch after closing the observed window. PNGs were visually inspected. The signed embedded CLI replaced the fixture field, and a persistent console retained an app handle and its baseline across separate commands.
- Structured review of the final code and documentation found no actionable P0 findings. No commit or publication was requested for this goal.
- Final signing submission `8c9f7ded-96b7-443e-b701-2b215ff5aaf3` was accepted. Stapling the existing build location failed with error 73; stapling an exact copy succeeded. The resulting ZIP was extracted into a clean directory and passed signature, Gatekeeper, and staple validation; that extraction was removed.
- Signed paste acceptance completed after the user brought the fixture to the foreground. HTML inserted a visibly bold heading and both following lines; a second paste inserted multiline text and an emoji. Both operations reported clipboard restoration, and fresh accessibility observations confirmed the resulting content. Clipboard preservation, cancellation, failure, and newer-writer behavior also passed at the native pasteboard boundary. macOS can reject activation from a background app; the operation fails before touching the clipboard in that case.
- Cleanup completed: the fixture was quit, its absence was verified through target discovery, and its temporary bundle was removed. Temporary packaging and extraction directories were removed. The recorder remained idle with no input observers. No cloud resources or recordings were created by these checks.
