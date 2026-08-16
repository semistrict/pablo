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
    When Pablo creates a `.pabloweb` package
    Then its filename contains a safe form of the tab title
    And simultaneous names remain unique
    And its manifest identifies the tab, recording UUID, rrweb version, and start time
    And its manifest states that input values are masked

  @automated
  # RRWebSpoolStoreTests.rrwebSpoolOrdersBatches
  # RRWebSpoolStoreTests.rrwebSpoolRejectsInvalidBatches
  # RRWebSpoolStoreTests.rrwebSpoolBoundsErrors
  # RRWebSpoolStoreTests.rrwebSpoolLifecycle
  # RRWebRecordingTests.rrwebFinalizationPreservesEventOrder
  # RRWebRecordingTests.invalidRRWebBatchDoesNotReplaceEvents
  # RRWebRecordingTests.rrwebDiscoveryIgnoresMalformedPackages
  Scenario: Streamed events finalize without corrupting evidence
    Given the native extension has persisted ordered event batches
    When Pablo stops or interrupts the recording
    Then events are merged in batch and event order
    And the manifest records the final state, end time, count, and error
    And an invalid batch does not replace the previously valid event file
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
    When the tester refreshes Safari tabs in Pablo
    Then that tab appears in both the recorder window and menu-bar controls
    When the tester starts, pauses, resumes, and stops its web recording
    Then the visible state and event count follow each transition
    And Safari never becomes frontmost
    And a completed `.pabloweb` package opens in the review window

  @signed-app @manual
  Scenario: The review UI exposes full rrweb playback controls
    Given a completed `.pabloweb` recording with replayable events
    When it is opened in Pablo
    Then the review window lists saved Safari web recordings
    And it displays the tab title, URL, state, count, and masking disclosure
    And the player supports play, pause, timeline scrubbing, elapsed time, speed selection, inactive-period skipping, and full screen
    And playback starts paused
    And playback does not fetch original remote page assets

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
