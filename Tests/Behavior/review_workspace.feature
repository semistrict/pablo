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
  Scenario: Inspect is the default video interaction
    Given a native recording has just opened
    Then Inspect is selected above the video
    And playback controls occupy a dedicated bar outside the video
    When the tester hovers over a recorded element
    Then its bounds and a compact accessibility summary appear
    And the summary identifies the application and age of the observation
    When the tester clicks the element
    Then playback pauses at the current time and its details are pinned in the inspector
    And no annotation or comment composer is created
    When the tester uses Play, Pause, or the playback scrubber with any video tool selected
    Then the requested playback operation occurs without creating markup

  @signed-app @manual
  Scenario: Tool buttons respond across their entire visible area
    Given a recording is open with a recorded window focused
    When the tester clicks the padding or text of the Notes, Pen, or Comment segment
    Then the clicked tool becomes selected and its guidance appears
    And the focused video does not intercept the toolbar click

  @automated
  # Expected: videoInspectionPicksSmallestElementAndMapsFocusedNegativeOrigin
  # Expected: videoInspectionRespectsOcclusionAndMissingGeometry, videoInspectionDisambiguatesIdenticalWindowBounds
  # Expected: videoInspectionRejectsCoveredWindowsWithinSameAppAndBreaksTiesByDepth
  # Expected: videoInspectionUsesLastObservedStateAndActiveVideoOnly
  Scenario: Video inspection identifies only recorded elements at the playhead
    Given overlapping windows and independently sampled application accessibility trees
    When a video point is inspected
    Then the smallest enclosing element from the front recorded window is returned
    And windows with identical bounds are distinguished by their recorded titles or left uninspected when ambiguous
    And hidden windows, invalid bounds, unavailable video tracks, and future snapshots yield no element
    And focus cropping and negative display origins preserve the same target

  @signed-app @manual
  Scenario: Drawing requires choosing the Pen tool
    Given a recording is open with Inspect selected
    When the tester selects Pen and drags over the video
    Then a freehand trace begins at mouse-down
    And releasing the pointer opens an adjacent comment composer
    When the tester presses Escape
    Then the draft and composer disappear without writing an annotation

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
  Scenario: Notes selects existing traces without creating markup
    Given a recording contains a visible trace at the current playhead time
    And the tester selects the `Notes` tool
    When the tester clicks the visible trace
    Then its stable `NOTE-###` annotation is selected in the contextual inspector
    And no draft trace or comment composer appears
    When the tester presses and drags across empty video
    Then no trace or point annotation is created

  @signed-app @manual
  # This checks visible agreement across the video, timeline, and inspector.
  Scenario: Annotation selection yields one unified contextual inspection
    Given an annotation is anchored to an exact time, `A11Y-###` frame, application, and accessibility node
    And the accessibility frame describes a meaningful change to that node
    When the annotation is selected from either the video or timeline
    Then one contextual selection exposes its `NOTE-###` reference and comment
    And it exposes the exact `A11Y-###` reference, application identity, node identity, and change summary
    And the same selection drives the video highlight, timeline marker, and inspector content
    And no Markup or Evidence mode switch is required

  @signed-app @manual
  # This checks the inspector's visible evidence provenance.
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
  Scenario: Inspector and library panels never cover playback controls
    Given a recording is open
    When the tester toggles the inspector or recording library
    Then the panels occupy their own columns and the video resizes to fit
    And the video and playback controls remain unobstructed
    And playback time and selection are preserved
    And Elements, Activity, and Notes have separate inspector sections

  @signed-app @manual
  # Cascading is owned by AppKit window placement and requires a visible-screen check.
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

  @signed-app @manual
  # Per-display grouping is an AppKit integration check; pure tiling is covered separately.
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

  @automated
  # ReviewSessionTests.reviewSessionIdentityAndCoherentState
  Scenario: A review snapshot identifies one model and one loaded source generation
    Given two review models loaded the same package
    When their states are read through the registry
    Then the review IDs differ and source IDs agree
    And tool, inspector visibility, playhead, and renderer readiness come from each model
    When one model reloads the same path
    Then its source generation changes and its review ID remains stable
    When the review is removed
    Then that review ID can no longer be read

  @automated
  # ReviewSessionTests.reviewSelectionAndRevision
  Scenario: A web event replaces an earlier primary note selection
    Given a web recording has a selected note and a recorded click event
    When the click event is selected
    Then the note is deselected and the click becomes the primary selection
    When normal playback advances
    Then the logical context revision remains stable
    When an explicit seek occurs
    Then the old event selection is cleared and the revision advances

  @automated
  # ReviewSessionTests.reviewCommandsRespectContextAndReceipts
  Scenario: Review commands preserve stale context and human draft boundaries
    Given a caller has read an explicit review source generation and revision
    When it submits a tool change with a fresh operation ID
    Then the tool changes and a caller-bound receipt is retained
    When it repeats the identical request within its retention window
    Then the original receipt returns without another mutation
    When it submits a new request using the old revision
    Then the request reports stale context
    When the human has unsaved draft text
    Then an agent seek reports a draft conflict without changing the draft

  @automated
  # ReviewSessionTests.reviewSeekWaitsForRenderedTime
  # ReplayVideoCompositionTests.initialNativeNoteSelectionSettlesAtRequestedTime
  Scenario: A seek receipt waits for observed renderer completion
    Given a renderer boundary fixture delays reaching the requested time
    When a review seek is submitted
    Then its operation remains running while observed time differs
    When the renderer reports the requested time
    Then the operation completes with the observed time in its state
    But if the human changes the review while it is pending
    Then the operation is interrupted and preserves the human change

  @signed-app @human-approval @manual
  Scenario: The API and visible review remain synchronized
    Given the signed app has an open native or web review and the calling app is approved
    When the caller reads review.list and review.state
    Then the active review, source, tool, primary selection, crop, and draft match the visible UI
    When the caller applies a seek using that source generation and revision
    Then completion identifies the settled renderer time and the visible playhead agrees
    When the human selects a different tool or source before a context-dependent command arrives
    Then the old command reports stale context without changing the visible selection

  @automated
  # ReplayVideoCompositionTests.reviewImageExportMatchesCrop
  Scenario: A composed recorded frame exports with its current crop
    Given fixture videos show different colors on two recorded displays
    When the review settles at a time containing both tracks and focuses the second window
    Then exported PNG pixels show the second window's color and dimensions
    And the response identifies its source, viewport, and rendered time
    And the manifest and annotation journal are unchanged

  @automated
  # ReplayVideoCompositionTests.nativeReplaySeeksBeyondCapturedVideo
  Scenario: The review timeline continues after captured video ends
    Given the recording has evidence timestamps after its final video track ends
    When the agent seeks to one of those later timestamps
    Then the visible playhead and renderer settle at the requested time
    And video availability remains unavailable
    And the empty composition is black without a stale captured image
    And absent accessibility observations remain unavailable

  @automated
  # ReviewSessionTests.reviewEvidenceRangeAndSourcePreconditions
  Scenario: A timeline query belongs to one source and revision
    Given a web timeline contains events inside and outside a requested range
    Then paged queries contain the matching events in order
    And the next cursor advances without repeating the prior page
    When the human changes the review context
    Then the old query precondition is rejected

  @automated
  # ReviewSessionTests.reviewSourceReplacementPreservesDraft
  Scenario: Failed loads and source changes preserve unfinished text
    Given a review has a loaded source
    When another package fails to load
    Then the original source remains available
    When the human has an unfinished note and selects another source
    Then the source change is rejected and its captured draft remains intact

  @automated
  # ReviewSessionTests.reviewSeekWaitsForRenderedTime
  # ControlProtocolTests.controlPendingHandlerDoesNotBlockReads
  Scenario: A caller can interrupt its pending review command
    Given a renderer fixture has not yet reached the requested time
    When the same caller cancels its pending operation
    Then cancellation is admitted while a mutation is waiting
    And the receipt becomes interrupted without claiming to undo an issued seek
    And another caller cannot cancel that receipt


  @signed-app @manual
  Scenario: Recorded point workflows are keyboard and accessibility operable
    Given a native recording is paused and the video renderer is ready
    When the tester expands Recorded point controls and enters coordinates between 0 and 1
    And activates Inspect point with Inspect selected
    Then the same recorded element as a canvas click is selected with its frame and observation age
    And no annotation draft is created
    When the tester selects Pen and adds two trace points using the coordinate fields
    Then the draft retains both points in the recording canvas coordinate frame
    When the tester activates Finish trace
    Then the comment composer is available through native accessibility
    And Escape cancels the draft without publishing it
    And invalid coordinates or an unsettled renderer disable point actions

  @signed-app @manual
  Scenario: Native accessibility names identify temporal controls and selection
    Given the recording event timeline and inspector are visible
    Then event navigation identifies Previous meaningful event and Next meaningful event
    And frame navigation identifies Previous accessibility frame and Next accessibility frame
    And event markers expose their event descriptions and whether they are selected
    And the video tool picker exposes the selected tool and playback position exposes its value


  @automated
  # ReviewSessionTests.reviewActivationRequiresObservedWindow
  Scenario: Window activation requires an observed result
    Given a review activation callback is awaiting its window observation
    Then its operation receipt remains running
    When the observation confirms activation
    Then the receipt completes and identifies the active review
    But a rejected activation fails and a cancelled activation is interrupted
    And neither rejection nor cancellation marks an inactive review active


  @automated
  # ReviewWindowLayoutTests.twoReviewWindowsArrangeSideBySide
  # ReviewWindowLayoutTests.denseReviewWorkspacesUseBalancedGrid
  # ReviewWindowLayoutTests.reviewWindowLayoutPreservesDisplayCoordinates
  Scenario: A calculated grid stays within one display's supplied visible frame
    Given a supplied visible frame including a negative desktop origin
    When the layout helper places two or more review windows
    Then its grid keeps every frame within those bounds without overlapping adjacent windows

  @automated
  # ReviewSessionTests.quickNoteKeepsCapturedAnchorAndFailedDraft
  Scenario: Quick-note submission retains the captured anchor and failed draft
    Given a human starts a quick note and then seeks to another time
    When the human submits the quick note
    Then the saved note retains its original timestamp
    And a failed journal write retains the text and captured anchor

  @automated
  # ReplayVideoInspectionTests.pinningVideoElementKeepsPlayheadAndDoesNotCreateMarkup
  Scenario: Clearing a recorded selection does not clear observed evidence
    Given a native recorded node or accessibility frame is selected
    When the agent clears the review selection
    Then the primary selection and pinned evidence are empty
    And the playhead and sampled accessibility observations are unchanged
