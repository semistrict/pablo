Feature: Produce a readable video and handle capture lifecycle safely

  @automated
  # VideoWriterPipelineTests.writerSetupDoesNotAbort
  Scenario: Writer setup returns an error instead of aborting the process
    Given video-writer setup receives a supported synthetic format
    When setup is attempted
    Then the process remains alive
    And setup returns success or a recoverable error

  @automated
  # VideoWriterPipelineTests.syntheticFramesProduceReadableMovie
  Scenario: Synthetic frames produce a readable movie
    Given a sequence of timestamped synthetic pixel buffers
    When they are written and finalized
    Then the movie can be opened by AVFoundation
    And it contains readable video frames
    And its duration reflects the synthetic timeline

  @signed-app @manual
  Scenario: Capture follows all eligible windows of the selected application
    Given a target application has multiple visible windows
    When recording starts
    Then video captures those windows across connected displays
    And newly opened windows are included
    And each video track's dimensions match its display content
    And protected or unavailable surfaces are not misrepresented as captured

  @automated
  # MultiWindowCaptureTests.applicationCaptureTracksDisplayTopology
  # MultiWindowCaptureTests.displayCaptureRemainsScoped
  # MultiWindowCaptureTests.applicationCaptureHonorsSystemStop
  # MultiWindowCaptureTests.partialApplicationCaptureIsCancelled
  Scenario: Video tracks follow display lifetimes without broadening a display recording
    Given application capture covers two displays on one session clock
    When displays are added, moved, or disconnected
    Then track lifetimes describe each change
    And a track added while paused starts paused
    And an explicit system stop never restarts a stream
    And a partial startup failure cancels every started stream
    And display-scoped recording remains restricted to its selected display

  @permission
  # ApplicationWindowCaptureTests.applicationVideoCapturesNewWindows
  # Run with PABLO_CAPTURE_SMOKE_TEST=1 and an existing Screen Recording grant.
  Scenario: Actual capture includes existing and newly created application windows
    Given the capture test already has Screen Recording permission
    And the test application creates two colored windows
    When capture starts and a third window opens
    Then the recorded pixels include both original windows and the new window
    When one window closes
    Then that window's pixels disappear from subsequent video frames

  @signed-app @manual
  Scenario: User-ended sharing finalizes a playable movie
    Given recording is active through ScreenCaptureKit
    When the user chooses Stop Sharing in macOS
    Then Pablo finalizes once
    And no already-stopped error is shown as a recording failure
    And the resulting video is readable when frames were captured
