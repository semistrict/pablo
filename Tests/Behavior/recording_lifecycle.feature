Feature: Record one Mac application on a single monotonic timeline
  Pablo records video, target-scoped input, and accessibility state while respecting pause and user-controlled capture termination.

  @automated
  # SessionClockTests.testPausedTimeIsExcludedFromTimeline
  Scenario: Paused time is excluded from the recording timeline
    Given a session clock starts at monotonic time 1 second
    When the clock pauses at 3 seconds
    And resumes at 8 seconds
    And is read at 10 seconds
    Then its elapsed recording time is 4 seconds
    And no timestamp includes the 5 paused seconds

  @automated
  # AutomationActionTraceTests.automationActionsAreExplicitAndRedactedInTheEventTrace
  Scenario: Agent actions are explicit evidence in the event trace
    Given an approved calling application controls any live app through the Pablo CLI while a recording is active or paused
    When it requests click, drag, scroll, type, key, or accessibility actions
    Then `events.pb` contains an `automationAction` record before each action is attempted
    And the record identifies the action, target, verified calling application, developer, and one stable action UUID
    And a later record with the same UUID says whether the action succeeded or failed
    And synthesized mouse and keyboard events remain separate event records
    And typed content is omitted from the automation record while its character count is retained
    And actions attempted while recording is paused remain explicit with `recordingWasPaused` set
    And actions targeting a different application remain explicit even when their raw input is outside recording scope

  @automated
  # VideoCaptureLifecycleTests.activeCaptureRequestsExactlyOneStop
  Scenario: Stopping active capture requests one stream stop
    Given ScreenCaptureKit capture is active
    When Pablo stops the recording
    Then it requests exactly one stream stop
    And the lifecycle reaches stopped

  @automated
  # VideoCaptureLifecycleTests.userStoppedCaptureDoesNotRequestASecondStop
  Scenario: The macOS Stop Sharing control is respected
    Given ScreenCaptureKit reports that the user ended sharing
    When Pablo finalizes the recording
    Then it does not request another stream stop
    And it treats the user action as a normal stop

  @automated
  # VideoCaptureLifecycleTests.alreadyStoppedErrorIsSafeToIgnore
  Scenario: An already-stopped stream error does not fail finalization
    Given the capture stream is already stopped or absent
    When finalization receives the corresponding ScreenCaptureKit stop error
    Then the error is classified as safe to ignore
    And finalization can complete

  @signed-app @permission @human-approval @manual
  Scenario: Record a visible target application end to end
    Given Pablo is signed with a stable local development identity
    And the target application has a visible window
    And Pablo is running
    When an approved calling application requests recording of the target
    And the user grants any missing Accessibility, Input Monitoring, and Screen Recording permissions
    And the user interacts with the target application
    And the user stops recording in Pablo
    Then Pablo returns to Ready without disappearing
    And one `.pablo` package is finalized in the selected output directory
    And the package contains `manifest.json`, `video.mov`, `events.pb`, and `accessibility.pb`
    And the video is playable
    And all artifact timestamps share the recording timeline

  @signed-app @manual
  Scenario: Global input is captured only while the target is active
    Given recording of a target application is active
    When the user types and clicks in the target application
    And then types and clicks in a different application
    And stops recording
    Then target-active input is present in `events.pb`
    And other-application input is absent

  @signed-app @manual
  Scenario: Pause and resume apply to video, input, and accessibility together
    Given a recording is active
    When the user pauses recording
    And interacts for several seconds
    And resumes recording
    And later stops recording
    Then paused interactions are absent from the captured timeline
    And video duration excludes paused wall time
    And input and accessibility timestamps remain aligned with video
