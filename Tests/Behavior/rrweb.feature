Feature: Record and replay an explicitly unlocked Safari tab
  Pablo streams masked rrweb events from an activeTab-only Safari extension into a local package without foregrounding Safari.

  @automated
  # SafariDOMProtocolTests.safariRRWebCommandsUseSerializedProtobuf
  Scenario: Tab discovery and lifecycle commands cross the protobuf bridge
    Given Pablo creates a Safari tab or rrweb command
    When it crosses the native Safari extension bridge
    Then its tab ID and server-generated recording ID are preserved
    And start, pause, resume, and stop require both identifiers
    And all tab IDs are positive
    And tab discovery accepts no caller-supplied recording identifier

  @automated
  # ControlProtocolTests.rrwebControlRoundTrip
  # ControlProtocolTests.rrwebJSONDefaults
  Scenario: The JSON API exposes compact rrweb lifecycle calls
    Given a same-user client lists unlocked tabs with `/safari.tabs`
    When it starts with only a returned tab ID at `/rrweb.start`
    Then Pablo generates the request and recording identifiers
    And pause, resume, stop, status, and recording discovery require no body
    And inspection can select a package by path or recording ID
    And event inspection is omitted by default and bounded when enabled

  @automated
  # RRWebRecordingTests.rrwebPackageManifestAndFilename
  # RRWebRecordingTests.rrwebPackageNamesRemainUnique
  Scenario: Web recording packages identify their tab and privacy policy
    Given an unlocked Safari tab has a title and URL
    When Pablo creates a `.pablo` package with an rrweb event source
    Then its filename uses Safari as the captured application name and includes a timestamp
    And simultaneous names remain unique
    And its manifest identifies the tab, recording UUID, rrweb version, and start time
    And its manifest states that input values are masked

  @automated
  # RRWebRecordingTests.legacyWebFormatsAreRejected
  Scenario: Pablo has one recording format and no compatibility decoder
    Given a package uses an alternate extension or standalone legacy web manifest
    When Pablo attempts to load it
    Then loading fails closed
    And only a schema-v3 `.pablo` manifest with an explicit data source is accepted

  @automated
  # RRWebSpoolStoreTests.rrwebSpoolOrdersBatches
  # RRWebSpoolStoreTests.rrwebSpoolRejectsInvalidBatches
  # RRWebSpoolStoreTests.rrwebSpoolBoundsErrors
  # RRWebSpoolStoreTests.rrwebSpoolLifecycle
  # RRWebRecordingTests.rrwebFinalizationPreservesEventOrder
  # RRWebRecordingTests.invalidRRWebBatchDoesNotReplaceEvents
  # RRWebRecordingTests.invalidRRWebTimestampsPreserveEvidence
  # RRWebRecordingTests.rrwebDiscoveryIgnoresMalformedPackages
  Scenario: Streamed events finalize without corrupting evidence
    Given the native extension has persisted ordered event batches
    When Pablo stops or interrupts the recording
    Then events are merged in batch and event order
    And the manifest records the final state, end time, count, and error
    And an invalid batch does not replace the previously valid event file
    And out-of-range event timestamps fail without crashing or replacing saved evidence
    And discovery ignores malformed packages

  @automated
  # AppBundlePackagingTests.safariExtensionIsEmbeddedAndLeastPrivilege
  Scenario: Distribution includes the recorder and official player
    Given the checked-in rrweb sources and pinned dependencies
    When Pablo builds its application bundle
    Then the generated masked recorder is embedded in Pablo Safari
    And the official rrweb player JavaScript and stylesheet are application resources
    And the extension still requests no persistent host access

  @signed-app @human-approval @manual
  Scenario: Main and menu-bar UIs control a background recording
    Given Pablo Safari is enabled
    And Safari is running but not frontmost
    And the user has clicked Pablo Safari in the active tab
    When the tester opens the recorder in Pablo
    Then that tab appears in both the recorder window and menu-bar controls
    When the tester starts, pauses, resumes, and stops its web recording
    Then the visible state and event count follow each transition
    And Safari never becomes frontmost
    And the completed `.pablo` package opens in the normal review window

  @signed-app @manual
  Scenario: The review UI exposes full rrweb playback controls
    Given a completed `.pablo` recording with an rrweb event source and replayable events
    When it is opened in Pablo
    Then the normal recording browser lists native and Safari recordings together
    And it displays the tab title, URL, state, count, and masking disclosure
    And the shared player supports play, pause, timeline scrubbing, elapsed time, speed selection, event selection, inspection, and annotations
    And playback starts paused
    And playback does not fetch original remote page assets

  @automated
  # RRWebPlaybackRendererTests.testPlayerReportsTimeAndStateThroughItsRealEventEnvelope
  Scenario: The embedded renderer reports playback time and state
    Given the official rrweb player is loaded with a local recording
    When the player seeks, plays, and pauses
    Then the shared transport receives numeric elapsed time and the matching playback state

  @automated
  # UnifiedReplayModelTests.unifiedRecordingBrowserSwitchesDataSources
  # UnifiedReplayModelTests.sharedTransportDrivesRRWebRenderer
  # UnifiedReplayModelTests.webRecordingsUseSharedAnnotations
  # ControlProtocolTests.recordingOpenControlRoundTrip
  Scenario: Native and rrweb evidence use one review model
    Given native and rrweb `.pablo` packages exist
    When either source is selected in the recording browser or opened through `/recording.open`
    Then the same review model owns transport, time, speed, timeline selection, inspection, and annotations
    And only the central evidence renderer changes with the manifest data source

  @signed-app @manual
  Scenario: Navigation interrupts capture without persistent access
    Given a Safari tab is recording while Safari remains in the background
    When the tab navigates or closes
    Then its activeTab grant ends
    And the extension reports the interruption
    And Pablo preserves received events in an interrupted package
    And the new page does not appear until the user clicks the toolbar button again

  @signed-app @manual
  Scenario: Pablo recovers or finalizes a recording after restart
    Given event chunks exist for a recording whose manifest is recording or paused
    When Pablo restarts
    Then it reconnects if the same tab recorder and recording ID are still active
    Otherwise it preserves the chunks and marks the recording interrupted

  Scenario: Select one of several unfinished Safari recordings for recovery
    Given multiple retained Safari packages are unresolved
    And there is no healthy current Safari recording
    When the human or approved agent selects one recording ID for recovery
    Then that package becomes the shared recovery target
    And every other package and spool remains intact
    And no package is finalized until its matching stop acknowledgment is validated

  Scenario: The recorder follows Safari access without a refresh button
    Given the recorder is visible and Pablo Safari is enabled
    When a Safari tab is unlocked from its toolbar button
    Then the tab appears automatically in the recorder
    When the tab navigates to another page on the same origin
    Then the tab disappears automatically
    And DOM reads, actions, and recording start require another toolbar unlock
    And Safari retaining activeTab permission does not extend Pablo access
    And a background tab discovery failure does not replace a recording failure

  Scenario: Native discovery remains available after Safari becomes idle
    Given Pablo Safari is enabled and its native connection is established
    When Safari remains idle for more than two minutes
    Then tab discovery continues responding without another toolbar click
    And an explicitly unlocked document remains available until navigation
    And navigation still expires access even when Safari retains its activeTab permission

  @automated
  # RecorderLifecycleTests.webRecoveryCanFinishWithoutDestroyedRecorder
  # ControlProtocolTests.rrwebInterruptedRecoveryContract
  Scenario: Explicit recovery can finish after the recorder document is destroyed
    Given an unfinished Safari recording needs recovery after its tab closes or navigates
    When received evidence is explicitly saved with recoveryAction finishInterrupted
    Then the package is marked interrupted with its received events
    And its spool remains available for late delivery
    And a new Safari recording can start
    And an unreadable spool leaves recovery active
    And a healthy recording or mismatched recording ID is rejected
