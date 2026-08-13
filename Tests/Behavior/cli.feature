Feature: Parse and run the Pablo command-line interface predictably

  @automated
  # CLITests.testParsesRecordOptions
  Scenario: Parse valid recording options
    When `record --bundle-id com.example.App --duration 2.5 --no-text` is parsed
    Then the bundle identifier is `com.example.App`
    And duration is 2.5 seconds
    And typed Unicode capture is disabled

  @automated
  # CLITests.testRequiresOneRecordingScope
  Scenario: Recording requires one scope selector
    When record is parsed without `--screen`, `--app`, `--bundle-id`, or `--pid`
    Then parsing fails
    When more than one application selector is supplied
    Then parsing fails
    When `--screen` and an application selector are supplied together
    Then parsing fails

  @automated
  # CLITests.testParsesDisplayRecordingWithoutAnApplicationSelector
  Scenario: Parse a display recording without an application target
    When `record --screen --display-id 7 --fps 24` is parsed
    Then the recording scope is display 7
    And no application selector is present
    And the frame rate is 24 frames per second

  @automated
  # CLITests.testParsesReplayCommands
  Scenario: Parse offline replay commands
    When `frames --json` is parsed
    Then JSON frame output is selected
    When `frame A11Y-012 --changed` is parsed
    Then frame `A11Y-012` and changed-only output are selected
    When `events --limit 25` is parsed
    Then the event limit is 25
    When `annotations --json` is parsed
    Then JSON annotation output is selected
    When `workspace --json` is parsed
    Then JSON workspace output is selected

  @automated
  # CLITests.testParsesEveryLiveInspectionCommand
  Scenario: Every inspection command accepts a live application target
    Given `Notes` is a running application
    When the tester parses `inspect`, `frames`, `frame`, `events`, and `annotations` with `--app Notes`
    Then every command selects the same live application source
    And recording output flags such as `--json`, `--changed`, and `--limit` retain their meaning

  @automated
  # CLITests.testLiveInspectionRejectsAmbiguousSources
  Scenario: An inspection command has exactly one data source
    When a recording path and a live target are supplied together
    Then parsing fails
    When more than one live target selector is supplied
    Then parsing fails
    When a live process identifier is invalid
    Then parsing fails

  @automated
  # CLITests.testParsesAppControlCommandsWithoutArguments
  Scenario Outline: Control commands reject extra arguments
    When `<command>` is parsed without arguments
    Then the corresponding control action is selected
    When `<command> extra` is parsed
    Then parsing fails

    Examples:
      | command |
      | status  |
      | pause   |
      | resume  |
      | stop    |

  @manual
  Scenario: Inspection output uses stable references
    Given a recording contains input, accessibility frames, and annotations
    When the tester runs `frames`, `frame`, `events`, and `annotations`
    Then accessibility frames use `A11Y-###`
    And input events use `EVT-####`
    And annotations use `NOTE-###`
    And JSON output is machine-readable when requested

  @signed-app @human-approval @manual
  Scenario: Live accessibility inspection matches recording inspection output
    Given a running target application and an approved calling application
    When the tester runs `inspect --app <name>`
    Then the output identifies the live target and the in-memory observation counts
    When the tester runs `frames --app <name>` repeatedly
    Then each observation receives a stable `A11Y-###` reference
    When the tester runs `frame A11Y-001 --app <name>`
    Then the accessibility tree uses the same text shape as a recorded frame
    And `--changed` and `--json` behave as they do for a recording

  @automated
  # LiveInspectionTests.liveAccessibilityHistoryIsStableAndBounded
  Scenario: Live accessibility references remain stable when history is bounded
    Given live accessibility history retains two frames
    When three snapshots are materialized
    Then their references are `A11Y-001`, `A11Y-002`, and `A11Y-003`
    And only `A11Y-002` and `A11Y-003` remain in memory
    And the second frame reports changed and removed nodes relative to the first
    And an evicted reference is never reassigned

  @signed-app @human-approval @manual
  Scenario: Live event inspection begins a bounded observation history
    Given a running target application and an approved calling application
    When the tester first runs `events --app <name>`
    Then Pablo reports that no input has been observed yet
    And begins observing input directed to that target
    When the user interacts with the target and the tester runs the command again
    Then the output uses stable `EVT-####` references
    And `--limit` and `--json` behave as they do for recorded events
    And the history remains only in memory

  @signed-app @human-approval @manual
  Scenario: Live annotation inspection is explicitly read-only
    Given a live inspection session exists
    When the tester runs `annotations --app <name>`
    Then Pablo returns an empty annotation collection
    And explains in text output that live inspection is read-only
    And does not modify or create a recording

  @manual
  Scenario: Missing or invalid recordings produce usage errors
    Given no default recording exists or the supplied path is not a `.pablo` package
    When an inspection command runs
    Then it returns a clear error
    And it does not fabricate output or create a recording
