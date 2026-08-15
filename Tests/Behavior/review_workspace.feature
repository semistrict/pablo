Feature: Review recordings in one synchronized evidence workspace
  Pablo presents video, attributed evidence, accessibility state, and markup on one shared timeline without splitting investigation into separate modes.

  @automated
  # Expected: ReviewTimelineModelTests.timelineBuildsOrderedEvidenceLanesAroundOnePlayhead
  Scenario: One playhead synchronizes every evidence lane
    Given a recording contains app and window transitions, human input, agent actions, accessibility changes, and annotations
    When the review timeline is built at a video time between recorded events
    Then it contains an Apps lane for app and window transitions
    And it contains a Human Input lane for observed pointer, keyboard, and scroll input
    And it contains an Agents lane for requested and completed automation actions with caller provenance
    And it contains an A11Y lane for accessibility snapshots and meaningful changes
    And it contains a Notes lane for annotations
    And human input and agent actions remain distinct even when they share a timestamp and target
    And every lane uses the same recording-time scale and shared playhead
    And video, selected accessibility state, visible markup, and every lane describe that playhead time

  @automated
  # Expected: ReviewTimelineModelTests.denseEventsClusterAndExpandWithZoom
  Scenario: Dense evidence clusters remain legible across zoom levels
    Given many events occupy fewer horizontal pixels than their individual markers require
    When the timeline is viewed at its initial zoom level
    Then nearby events are represented by a cluster with its event count and time span
    And events from Apps, Human Input, Agents, A11Y, and Notes are never merged across lanes
    When the user zooms into that time span
    Then the cluster progressively separates into smaller clusters and individual events
    And event times and the shared playhead do not change because of zooming

  @signed-app @manual
  Scenario: A cluster popover is anchored to the visible timeline marker
    Given a timeline lane contains clusters near its leading edge, center, and trailing edge
    When the tester clicks each visible cluster marker
    Then the popover arrow points to the marker that was clicked rather than the center of the timeline track
    And the popover lists only that cluster's evidence items
    When the tester selects an item from the popover
    Then the item becomes selected
    And the shared playhead seeks to its timestamp

  @signed-app @manual
  Scenario: The user can pan the timeline viewport independently of the playhead
    Given a recording is open with evidence distributed across its duration
    When the tester zooms the timeline in and out
    Then all evidence lanes remain horizontally aligned to one time scale
    And zooming does not seek or change playback state
    When the tester pans the zoomed timeline away from the playhead
    Then every lane pans together
    And the viewport remains at the chosen time range instead of immediately recentering on the playhead
    And playback time, playback state, and selected evidence do not change
    When the tester explicitly seeks in the ruler or selects an event
    Then the shared playhead moves and all time-dependent surfaces synchronize to it

  @automated
  # Expected: ReviewTimelineModelTests.meaningfulChangeNavigationSkipsIncidentalSnapshots
  Scenario: Previous and next navigation visits meaningful changes
    Given the timeline contains accessibility snapshots with and without meaningful changes
    And it contains meaningful events in the Apps, Human Input, Agents, A11Y, and Notes lanes
    When the next meaningful change is requested from the current playhead
    Then the playhead moves to the earliest later meaningful event across all lanes
    And incidental accessibility snapshots are skipped
    When the previous meaningful change is requested
    Then the playhead returns to the latest earlier meaningful event across all lanes
    And navigation pauses playback and synchronizes video, evidence, and markup

  @signed-app @manual
  Scenario Outline: The video stage uses the full review-column width
    Given a recording is open in a <window> review window
    And the contextual inspector is <inspector>
    When the tester observes the video stage and unified timeline
    Then the video stage and timeline share the same leading and trailing edges
    And the aspect-fit video is centered with equal unused space on opposite sides
    And the video is never stretched or cropped
    When the tester resizes the window and toggles the inspector
    Then the stage fills the newly available main-column width
    And an existing trace remains attached to the same recorded pixels
    And clicking or drawing at a video point stores coordinates relative to the video rather than its surrounding stage

    Examples:
      | window  | inspector |
      | wide    | hidden    |
      | wide    | visible   |
      | compact | hidden    |

  @signed-app @manual
  Scenario: Pen is the default direct-drawing tool
    Given a recording has just opened
    Then the explicit `Review`, `Pen`, and `Comment` video tools are visible
    And `Pen` is selected by default
    When the tester presses and drags directly on the video without choosing another tool
    Then a freehand trace begins at mouse-down without requiring a separate Trace button
    And releasing the pointer opens an adjacent comment composer

  @signed-app @manual
  Scenario: A click creates an exact point annotation with an adjacent composer
    Given a recording is open and video is paused on a materialized accessibility frame
    And the tester selects the `Comment` tool
    When the tester clicks a visible point in the video
    Then an exact one-frame point anchor appears at the clicked coordinate and playhead time
    And a compact comment composer appears beside the point without covering it
    And the composer text field receives focus
    When the tester submits a comment
    Then a stable `NOTE-###` annotation is selected
    And its marker appears in the annotation lane at that exact time

  @signed-app @manual
  Scenario: A drag creates a freehand trace with an adjacent composer
    Given a recording is open with the `Pen` tool selected
    When the tester presses, drags, and releases directly over the playing or paused video
    Then Pablo preserves the sampled path as a freehand trace rather than replacing it with a geometric approximation
    And each sample is attached to the shared playhead time observed while drawing
    And a compact comment composer appears beside the trace endpoint without covering the trace
    When the tester cancels the composer
    Then the unfinished trace disappears and no annotation is written
    When the tester draws again and submits a comment
    Then a stable `NOTE-###` annotation is selected and represented in the annotation lane

  @signed-app @manual
  Scenario: Review selects existing traces without creating markup
    Given a recording contains a visible trace at the current playhead time
    And the tester selects the `Review` tool
    When the tester clicks the visible trace
    Then its stable `NOTE-###` annotation is selected in the contextual inspector
    And no draft trace or comment composer appears
    When the tester presses and drags across empty video
    Then no trace or point annotation is created

  @automated
  # Expected: ReviewSelectionModelTests.annotationSelectionProducesUnifiedContext
  Scenario: Annotation selection yields one unified contextual inspection
    Given an annotation is anchored to an exact time, `A11Y-###` frame, application, and accessibility node
    And the accessibility frame describes a meaningful change to that node
    When the annotation is selected from either the video or timeline
    Then one contextual selection exposes its `NOTE-###` reference and comment
    And it exposes the exact `A11Y-###` reference, application identity, node identity, and change summary
    And the same selection drives the video highlight, timeline marker, and inspector content
    And no Markup or Evidence mode switch is required

  @automated
  # Expected: ReviewSelectionModelTests.annotationSelectionUsesItsExactAnchoredEvidence
  Scenario: Annotation context comes from its exact evidence anchor
    Given the playhead's current accessibility frame differs from an annotation's anchored `A11Y-###` frame
    And the annotation identifies one application and one stable accessibility node in its anchored frame
    When the annotation is selected
    Then the contextual inspector shows the annotation's anchored `A11Y-###` reference rather than an unrelated current or latest frame
    And it shows the anchored application's recorded identity and display name
    And it shows the exact stable accessibility node identifier and human-readable node name
    And it summarizes that node's added, removed, or changed properties from the anchored frame
    And selecting the annotation seeks the shared playhead to the anchor before highlighting the node

  @signed-app @manual
  Scenario: The contextual inspector adapts to narrow review windows
    Given a review window shows the unified contextual inspector beside the video
    When the tester narrows the window below the full-inspector layout threshold
    Then the inspector collapses without obscuring the video or timeline
    And a clear control reveals the same selected context on demand
    And collapsing or expanding the inspector preserves playback time and selection

  @automated
  # Expected: ReviewWindowPlacementTests.newRecordingWindowsCascadeWithinVisibleScreen
  Scenario: Several recordings receive distinct cascaded window frames
    Given multiple recording windows will open on one visible screen
    When Pablo calculates each new review window frame
    Then every new window is offset from the previously opened window
    And each title bar remains reachable within the screen's visible frame
    And cascading wraps before a window would be placed off screen

  @signed-app @manual
  Scenario: Opening several recordings cascades them in one application instance
    Given Pablo is running with no review windows open
    And three different `.pablo` recordings exist
    When the tester opens all three recordings
    Then each recording opens in an independent review window in the existing Pablo instance
    And the three windows are visibly cascaded instead of perfectly overlapping
    And each window retains independent playback, timeline zoom, and selection state

  @signed-app @manual
  Scenario: Reopening Pablo from the Dock raises the dedicated recorder
    Given Pablo is running with its recorder and one or more review windows behind another application
    When the tester clicks Pablo in the Dock
    Then Pablo raises the existing `Pablo Recorder` window and makes it key
    And it does not create a duplicate recorder or review window
    And every review window preserves its playback time, timeline zoom, and selection

  @automated
  # Expected: ReviewWindowPlacementTests.sideBySideFramesTileVisibleReviewWindows
  Scenario: Side-by-side arrangement tiles visible recording windows
    Given review windows are distributed across two or more displays
    When Pablo calculates the Arrange Side by Side layout
    Then each display's visible frame is divided only among the review windows already on that display
    And no review window is moved from one display to another
    And windows arranged on the same display do not overlap
    And every window respects its minimum usable size
    And each title bar remains reachable within its display's visible frame

  @signed-app @manual
  Scenario: Arrange Side by Side makes recordings comparable
    Given two or more review windows are visible across one or more displays
    When the tester chooses `Arrange Side by Side` from Pablo's Window menu
    Then the visible review windows tile without overlap within their current displays
    And no review window crosses to another display
    And each recording remains independently playable and inspectable
    And the Window menu identifies every open recording and its key window
