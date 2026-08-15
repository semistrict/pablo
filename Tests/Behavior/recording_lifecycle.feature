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
    And the package contains `manifest.json`, `video.mov`, `events.pb`, `workspace.pb`, and `accessibility.pb`
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

  @signed-app @manual
  Scenario: A human starts recording from the menu bar
    Given Pablo is idle in the menu bar
    When the user opens Pablo's menu-bar panel
    Then `Record Entire Screen` is available
    And `Record an Application` lists the currently running regular applications
    And typed-text capture can be disclosed and toggled before recording
    When the user chooses either recording action
    Then Pablo starts the selected recording without requiring the CLI
    And the same panel replaces the start actions with pause and stop controls

  @signed-app @manual
  Scenario: A dedicated recorder window remains a complete control surface
    Given Pablo's menu-bar icon is hidden because the menu bar has no remaining space
    When the user launches Pablo or reopens it from the Dock
    Then one dedicated `Pablo Recorder` window becomes key
    And it is separate from every recording review window
    When the user views the recorder window
    Then `Record Entire Screen` is available
    And `Record an Application` lists the same running applications as the menu-bar panel
    And typed-text capture can be toggled before recording
    And `Open Review`, `Open Recordings…`, `Show Recordings`, and `Quit Pablo` are available
    When Pablo reports a permission error
    Then the same privacy-settings choices as the menu-bar panel are available
    When recording starts from the recorder window, menu-bar panel, or an approved app
    Then the recorder window and menu-bar panel show the same recording state, scope, and elapsed time
    And both replace their start actions with pause and stop controls
    And review windows remain focused on replay and markup rather than recording controls
    When the user pauses, resumes, or stops from the recorder window or menu-bar panel
    Then both control surfaces update to the same state

  @signed-app @manual
  Scenario: Show Recordings opens the recording directory
    Given Pablo is idle or recording
    When the user chooses `Show Recordings` in the menu-bar panel
    Then Pablo creates `~/Movies/Pablo Recordings` if necessary
    And Finder opens that directory
    And any failure is shown in Pablo instead of being discarded

  @signed-app @manual
  Scenario: Open Review raises the review window
    Given Pablo's review window is closed or behind another application
    When the user chooses `Open Review` in the menu-bar panel
    Then Pablo directly asks its review-window controller to show the latest recording
    And the review window becomes key and moves to the front

  @automated
  # AppBundlePackagingTests.appOwnsPabloRecordingPackages
  Scenario: Finder recognizes Pablo recordings as packages owned by Pablo
    Given Pablo exports `com.ramon.pablo.recording` as a package type
    Then its filename extension is `.pablo`
    And Pablo is registered as the owning viewer

  @signed-app @manual
  Scenario: Double-clicking a recording opens that exact package
    Given a `.pablo` recording exists in Finder
    When the user double-clicks the recording while Pablo is closed or already running
    Then Finder sends the package to Pablo
    And Pablo loads that exact package in the review window
    And the review window becomes key and moves to the front

  @signed-app @manual
  Scenario: Each opened recording has an independent review window
    Given two different `.pablo` recordings exist in Finder
    And Pablo is already running
    When the user opens both recordings
    Then both packages open in the existing Pablo application instance
    And each package has its own review window and playback state
    And closing one review window leaves the other review window open

  @signed-app @manual
  Scenario: The review picker opens multiple recordings without replacing a window
    Given a Pablo review window is already open
    When the user chooses `Open Recordings…` and selects two `.pablo` packages
    Then Pablo opens two additional review windows
    And the original review window keeps its current recording and playback state

  @signed-app @manual
  Scenario: Double-clicking a review window header toggles its zoomed size
    Given a Pablo review window is open at its normal size
    When the user double-clicks a non-interactive part of the window header
    Then the review window zooms to its standard maximum frame
    When the user double-clicks the same header area again
    Then the review window returns to its previous frame
