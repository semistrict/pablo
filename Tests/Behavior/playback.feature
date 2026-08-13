Feature: Replay is driven by one authoritative media clock
  Video, accessibility evidence, annotations, node highlights, and transport state stay synchronized at every supported speed.

  @automated
  # ReplayRecordingTests.replayLoaderReturnsEveryAccessibilityStep
  Scenario: A video time selects the latest materialized accessibility frame
    Given accessibility frames occur at 0.10, 1.00, and 1.40 seconds of video time
    When replay time is 0.99 seconds
    Then the first frame is selected
    When replay time is exactly 1.00 seconds
    Then the second frame is selected
    When replay time is 1.40 seconds
    Then the third frame is selected

  @automated
  # ReplayRecordingTests.replayLoaderReturnsEveryAccessibilityStep
  Scenario: Exact evidence-marker time survives integer-to-seconds conversion
    Given an accessibility frame has an integer nanosecond timestamp
    When its timestamp is converted to video seconds and mapped back to a frame
    Then the same frame is selected
    And the preceding frame is not selected because of rounding

  @signed-app @manual
  Scenario Outline: Play continuously at a supported speed
    Given a recording is open at an early video time
    And playback is paused
    When the tester chooses <speed>
    And starts playback
    Then the transport displays <speed>
    And video time advances at approximately <multiplier> times wall time
    And playback remains active until paused or the movie ends

    Examples:
      | speed | multiplier |
      | 0.25× | 0.25       |
      | 0.5×  | 0.5        |
      | 0.75× | 0.75       |
      | 1×    | 1          |
      | 1.25× | 1.25       |
      | 1.5×  | 1.5        |
      | 2×    | 2          |
      | 2.5×  | 2.5        |
      | 3×    | 3          |

  @signed-app @manual
  Scenario: Change speed without restarting playback
    Given playback is active at 1×
    When the tester changes speed to 3×
    Then the movie continues from its current point
    And time advances at approximately 3×
    When the tester changes speed to 0.25×
    Then the movie still continues from its current point
    And time advances at approximately 0.25×

  @signed-app @manual
  Scenario: Accessibility evidence follows playing video without feedback seeks
    Given the Evidence panel is visible
    And playback starts before several `A11Y-###` timestamps
    When video crosses each accessibility timestamp
    Then the selected `A11Y-###` frame advances to the latest frame at or before video time
    And the Changes or Tree content updates to that frame
    And an unavailable selected node is cleared
    And playback does not pause, restart, or seek backward

  @signed-app @manual
  Scenario: Time-dependent annotations follow the same clock
    Given a recording contains a paused-frame trace and a moving trace
    When playback crosses their timestamps at any supported speed
    Then the paused trace appears only at its attached frame
    And the moving trace reveals samples in timestamp order
    And its live tip interpolates between stored samples
    And the transport, evidence frame, and annotation overlay describe the same video point

  @signed-app @manual
  Scenario: Explicit evidence and timeline selection seeks and pauses
    Given playback is active
    When the tester selects an evidence marker or another `A11Y-###` frame
    Then playback pauses
    And video seeks to that frame
    And the evidence panel shows that exact frame
    When the tester drags the transport slider
    Then video and all time-dependent UI synchronize to the selected time
