Feature: Efficient computer use through Pablo's approved bridge
  Agents retain observed targets and verify fresh state after actions.

  # LiveAccessibilityObservationTests.liveObservationUsesCallerBaseline
  Scenario: Independent clients receive complete changes since their own observations
    Given two approved clients inspect the same application
    And the first client retains its frame reference
    When the application changes and the second client inspects it
    And the first client observes using its retained baseline
    Then its delta describes all changes from that baseline
    And applying additions, replacements, and removals reconstructs the current tree
    And a reverted transient change is not reported as a current difference

  # LiveAccessibilityObservationTests.liveObservationResynchronizes
  Scenario: Missing baselines cannot silently produce incomplete state
    Given a client's observation baseline has expired or belongs to another session
    When it requests a delta
    Then Pablo returns full state with resyncRequired
    And the client replaces its materialized tree
    And an explicit full request also returns all currently observed nodes

  # LiveObservationSamplingTests.liveObservationWaitsForQuietState, liveObservationReportsTimeout
  Scenario: Settling has an observable bound
    Given an approved application changes after an action
    When the action requests a subsequent observation
    Then an unchanged tree over the quiet interval is reported as settled
    And continuous changes produce timedOut with the last sampled state
    And dispatch and sampled stability remain separate from the intended application effect

  # Signed app required: Accessibility and Screen Recording already granted
  Scenario: A paired image describes the same selected window as its accessibility observation
    Given a signed Pablo app has Accessibility and Screen Recording permission
    And a fixture app has two accessible windows
    When an approved client selects the smaller window and requests a screenshot observation
    Then the PNG contains the selected window
    And its observation ID, frame reference, window ID, dimensions, and geometry agree
    And Pablo does not activate the target or start recording or input monitoring
    And a changed or ambiguous window causes a failed observation instead of a substituted image

  # Signed app required: an action closes its explicitly selected window
  Scenario: Observation failure preserves a dispatched action
    Given an approved action closes its selected window
    When a subsequent image observation cannot find that window
    Then the response retains the action ID and dispatched status
    And it contains observationFailure
    And the client invalidates its cached state without repeating the action

  # LiveTextEditingTests.liveTextSelectionUsesUnicodeAndContext, liveTextSelectionRejectsChangedValues
  Scenario: Precise edits respect Unicode and changing content
    Given a non-secure editable field contains repeated phrases and supplementary Unicode characters
    When an agent selects a phrase with adjacent prefix or suffix context
    Then the range selects only the matching occurrence using UTF-16 units
    And cursorBefore and cursorAfter place a zero-length selection at the requested boundary
    And ambiguous, missing, or concurrently changed text is rejected before range mutation
    And a separate setValue action can replace or clear a supported field

  # LivePasteTests.livePastePreservesNativeClipboardRepresentations, livePasteRestoresAfterCancellationAndFailure, livePasteKeepsNewerClipboardContents
  Scenario: Paste preserves clipboard ownership
    Given the clipboard contains multiple items with text and binary representations
    And the user explicitly accepted foreground input to the intended application
    When an agent pastes multiline text or HTML with a plain-text fallback
    Then the temporary representations are available for the paste shortcut
    And unchanged clipboard ownership allows restoration of every original representation
    And failure or cancellation also attempts restoration
    And a newer clipboard value from the human is preserved
    And restoration failures remain explicit in the result

  # AutomationActionTraceTests.textEditingTraceRedactsAllTextInputs
  Scenario: New action evidence retains metadata without text inputs
    Given a recording is active or paused
    When approved selectText, setValue, or paste actions are requested
    Then requested and outcome records share an action ID and verified caller provenance
    And phrase, prefix, suffix, replacement, HTML, and fallback contents are absent from automation records
    And action kind, selection type, paste format, and applicable character counts are retained

  # JavaScript/tests/client.test.mjs
  Scenario: Persistent handles compose actions without replaying uncertain effects
    Given a JavaScript session retains an app or unlocked Safari tab handle
    When it performs an action and observes the result
    Then native actions use the observed process, session, window, and frame context
    And Safari actions use the observed document generation
    And a lost action response triggers receipt lookup without another execution
    And cancellation targets the same operation ID
    And unavailable receipts remain uncertain until the client inspects current state
