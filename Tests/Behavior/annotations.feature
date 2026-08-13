Feature: Attach durable human and application markup to exact replay evidence
  Markup is journaled without modifying captured evidence and visual traces preserve x, y, and time.

  @automated
  # RecordingAnnotationTests.annotationsPreserveEvidence
  Scenario: Annotation creation and resolution preserve immutable evidence
    Given a valid recording package and unchanged captured artifacts
    When an application adds an issue attached to a frame, node, and trace
    And a human resolves that issue
    Then the annotation keeps one UUID and stable `NOTE-###` reference
    And the journal contains creation and resolution states
    And readers materialize only the latest state
    And `manifest.json`, video, events, and accessibility evidence are byte-for-byte unchanged
    And application and developer provenance is retained

  @automated
  # RecordingAnnotationTests.annotationAnchorsAreValidated
  Scenario: Invalid annotation anchors fail closed
    Given a valid recording package
    When an annotation references a nonexistent `A11Y-###` frame
    Then annotation creation fails
    When a trace coordinate lies outside normalized video bounds
    Then annotation creation fails
    When trace timestamps run backward
    Then annotation creation fails

  @automated
  # RecordingAnnotationTests.traceTemporalSlicing
  Scenario: Paused and moving freehand traces have distinct temporal behavior
    Given one freehand trace has equal timestamps for all samples
    And another has increasing timestamps
    When visible samples are requested at replay times
    Then the equal-time trace appears as a complete one-frame shape
    And it disappears outside frame tolerance
    And the moving trace reveals stored samples in order
    And its live tip is interpolated without altering stored samples

  @automated
  # CLITests.testParsesAnnotationCommands
  Scenario: CLI parses timed traces and exact points
    Given valid annotation text
    When repeated `--trace SEC,X,Y` options are supplied in time order
    Then every sample and line width are preserved
    When `--point X,Y --at SEC` is supplied
    Then a one-frame point is parsed
    When trace time runs backward or coordinates exceed normalized bounds
    Then parsing fails with usage guidance

  @signed-app @manual
  Scenario: Mouse-down on video immediately starts freehand markup
    Given a recording is open
    And no trace-mode button has been pressed
    When the tester presses and drags directly on the video
    Then a fresh trace starts at mouse-down
    And every observed gesture point is sampled with current replay time
    And the drawn shape may be a circle, underline, arrow, or arbitrary path

  @signed-app @manual
  Scenario: Mouse-up opens an adjacent comment composer
    Given the tester is drawing a trace on video
    When the tester releases the pointer
    Then a compact comment composer appears beside the trace endpoint
    And the text field receives focus
    And kind, Cancel, and Add controls are present
    When the tester cancels
    Then the unfinished trace is removed
    And no annotation is written
    When the tester instead enters text and adds it
    Then a stable `NOTE-###` annotation is written and selected

  @signed-app @human-approval @manual
  Scenario: Application annotation writes retain verified provenance
    Given a signed application invokes the bundled CLI to add markup
    When the user approves that calling application if required
    Then Pablo writes the annotation as an application author
    And stores the verified application identifier, developer name, and team identifier
    And ignores caller-supplied identity claims
