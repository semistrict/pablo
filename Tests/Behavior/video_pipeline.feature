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
  Scenario: Capture follows the target window selected at start
    Given a target application has one largest visible window
    When recording starts
    Then video captures that window
    And the movie dimensions match the captured content
    And protected or unavailable surfaces are not misrepresented as captured

  @signed-app @manual
  Scenario: User-ended sharing finalizes a playable movie
    Given recording is active through ScreenCaptureKit
    When the user chooses Stop Sharing in macOS
    Then Pablo finalizes once
    And no already-stopped error is shown as a recording failure
    And the resulting video is readable when frames were captured
