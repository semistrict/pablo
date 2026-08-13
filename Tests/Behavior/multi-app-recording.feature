Feature: Record a desktop session with first-class application identity

  @automated
  # ReplayRecordingTests.multiApplicationReplayKeepsTreesSeparate
  Scenario: Interleaved accessibility deltas never cross application roots
    Given a display recording contains application `APP-001` and application `APP-002`
    And each application has a namespaced full accessibility tree
    When a delta for `APP-001` is recorded after a full tree for `APP-002`
    Then replay materializes the new `APP-001` state independently
    And replay preserves the prior `APP-002` state
    And the frame at the playback point follows the frontmost application
    And `workspace` exposes stable `WKS-####` snapshots with lifecycle details

  @automated
  # ProtobufStreamTests.protobufStreamRoundTrip
  Scenario: Every input event carries application and window provenance
    Given an input event is directed to a visible application window
    When the event is encoded and decoded through the protobuf stream
    Then its `APP-###` application identity is preserved
    And its application-scoped `WIN-###` window identity is preserved

  @automated
  # ProtobufStreamTests.workspaceStreamRoundTrip
  Scenario: Workspace lifecycle is explicit protobuf evidence
    Given a workspace snapshot contains visible apps and windows
    And it identifies appeared and removed application and window identities
    When the snapshot is encoded and decoded through the protobuf stream
    Then all identities and lifecycle transitions are preserved exactly

  @signed-app @human-approval @manual
  Scenario: A screen recording observes application switches on one timeline
    Given Pablo has Accessibility, Input Monitoring, and Screen Recording permission
    And the user starts `pablo record --screen`
    When the user types in Notes, clicks Safari, drags a Finder window, and opens System Settings
    Then video contains the selected display continuously
    And global input records the receiving application and window for each interaction
    And workspace evidence records frontmost changes and app and window appearance or removal
    And accessibility snapshots for each visible application have independent roots
    And pausing removes the same interval from video, input, workspace, and accessibility evidence

  @automated
  # ApplicationRegistryTests.recycledPIDGetsNewApplicationIdentity
  Scenario: A process identifier is never an application identity
    Given an application disappears during a display recording
    When another application later receives the same operating-system process identifier
    Then Pablo assigns a new `APP-###` identity
    And no accessibility delta or input provenance is joined to the earlier application instance

  @manual
  Scenario: Replay maps accessibility geometry into display coordinates
    Given a display recording contains windows from multiple applications
    When the tester selects an accessibility node from any application
    Then its highlight uses the captured display frame as the coordinate space
    And the highlight remains aligned with the full-screen video
