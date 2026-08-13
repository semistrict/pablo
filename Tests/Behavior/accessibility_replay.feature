Feature: Materialize and inspect accessibility evidence
  Pablo reconstructs each observed accessibility state and presents semantic changes without losing the complete hierarchy.

  @automated
  # AXTreeDifferTests.testDiffReportsChangedAddedAndRemovedNodes
  Scenario: Tree diff reports updated, added, and removed nodes
    Given a previous tree contains a root and a child named Old
    And the next tree changes the root and replaces Old with New
    When the trees are diffed
    Then the changed root and New are upserts
    And Old is a removal

  @automated
  # AXTreeDifferTests.testDiffOmitsUnchangedNodes
  Scenario: Tree diff omits unchanged nodes
    Given the previous and current node are equal
    When the trees are diffed
    Then there are no upserts
    And there are no removals

  @automated
  # ReplayRecordingTests.replayLoaderReturnsEveryAccessibilityStep
  Scenario: Replay materializes every full and delta record
    Given a recording begins with a full accessibility tree
    And later records update and removal deltas
    When the recording is loaded for replay
    Then every record has a stable sequential `A11Y-###` reference
    And each frame contains the fully materialized tree at that time
    And changed properties distinguish title, focus, geometry, and removal
    And node geometry is retained for video highlighting

  @signed-app @manual
  Scenario: The first accessibility frame is presented as a baseline
    Given the first frame contains hundreds of nodes
    When the tester opens its Changes view
    Then the UI says it is the initial baseline
    And it summarizes windows and initial focus
    And it does not claim every initial node is an independent user-facing change

  @signed-app @manual
  Scenario: Meaningful changes are separated from technical churn
    Given a later frame contains focus, value, layout, and hierarchy changes
    When the tester opens its Changes view
    Then focus, value, label, title, enabled state, and named appearance or removal are shown first
    And property changes use before-to-after descriptions where values exist
    And layout and hierarchy churn is collapsed by default
    And the tester can expand the technical changes without losing them

  @signed-app @manual
  Scenario: Tree view preserves hierarchy and technical identity
    Given an accessibility frame is selected
    When the tester opens Tree
    Then application, window, group, and control nesting is expandable
    And each row leads with accessible name and uses role as secondary text
    And changed and focused state are compact indicators
    And raw `ax-…` identity is hidden until Technical details is expanded

  @signed-app @manual
  Scenario: Selecting a node highlights its captured bounds
    Given a selected node and ancestor window have valid accessibility frames
    When the tester selects the node in Changes or Tree
    Then its bounds are normalized relative to the captured window
    And a labeled highlight appears over the corresponding video region
    When the node lacks usable geometry
    Then no misleading video highlight is shown

  @signed-app @manual
  Scenario: Sparse or truncated accessibility state is disclosed
    Given a snapshot reached the walker depth or node bound
    When the tester views that frame
    Then the frame is visibly labeled Truncated
    And Pablo does not imply that omitted nodes are absent from the real application

  @signed-app @manual
  Scenario: Secure accessibility text remains redacted
    Given the target contains a secure text field
    When the secure field is captured and replayed
    Then its secret value is not present in accessibility evidence
    And the UI does not reconstruct the secret from input events
