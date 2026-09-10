Feature: Caller-bound operation recovery
  # Automated boundaries: OperationRegistryTests, ControlProtocolTests,
  # RecorderLifecycleTests.serviceReadinessBeforeApproval.
  # Real signed caller identity, modal approval, and cooperative UI/input
  # cancellation require signed-app acceptance; these fixtures do not prove them.

  Scenario: Recover a response without duplicating an effect
    Given a verified caller has current daily approval
    When it executes a mutation with a service UUID and fresh operation UUID
    And its response is lost
    Then operation.status returns that caller's retained receipt
    And the same complete execute request returns the same result
    And the mutation is performed only once

  Scenario: A key does not authorize another caller
    Given a receipt belongs to one verified application and developer
    When another caller requests or cancels that operation
    Then no receipt content is returned and the operation is unchanged

  Scenario: Expiry does not authorize replay
    Given an operation's request window expired or the app restarted
    When the caller attempts to replay the old request
    Then it is rejected before dispatch
    And an unavailable receipt is described as an unknown prior outcome

  Scenario: Cancel before dispatch
    Given an operation is waiting for human approval
    When its verified caller requests cancellation
    Then its receipt exposes cancellation requested
    And a later human approval does not dispatch the cancelled command

  Scenario: Cancellation follows an effect
    Given an input operation already dispatched part of its action
    When the caller cancels it
    Then later input stops at the next cooperative boundary
    And held input is released safely
    And the result does not claim that prior effects were undone

  Scenario: Discovery stays responsive during real application consent
    Given a verified caller has no daily approval
    When its request opens Pablo's approval window
    Then service.info promptly reports awaitingHuman
    And a second unapproved read fails before dispatch without opening another prompt
    When the approval is denied
    Then the original request reports denied and notDispatched
    And no daily approval is stored

  Scenario: Cancelling a pending operation dismisses its consent window
    Given a caller-bound operation is awaiting approval in Pablo
    When that caller cancels the operation
    Then the approval window closes without granting access
    And the command is never dispatched
    And a later request can open a new approval window
