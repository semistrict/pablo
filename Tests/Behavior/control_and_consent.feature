Feature: Keep recording control and consent inside the Pablo app
  Local callers can request actions, but Pablo verifies the real calling application and the user remains the authority.

  @automated
  # ControlProtocolTests.approvalLastsForOneCallingApplicationAndOneCalendarDay
  Scenario: Verified approval lasts for one application identity for one local day
    Given a verified application and developer identity is approved today
    When the same identity requests another action today
    Then Pablo may reuse that approval
    When the local calendar day changes
    Then Pablo asks again
    When the application or developer identity changes
    Then Pablo asks again

  @automated
  # ControlProtocolTests.callerIdentityComesFromNearestInvokingApplication
  Scenario: Caller identity comes from the invoking application rather than the HTTP helper
    Given curl was launched by a signed foreground application
    When Pablo walks the process ancestry
    Then a signed app-bundled helper may resolve to its running owning application when their live signing teams match
    And it skips other prohibited helpers and processes without bundle identifiers
    And a root-owned terminal login process does not hide its terminal application parent
    And resolves the nearest eligible invoking application
    And the approval dialog names that application and its verified developer

  @automated
  # ControlProtocolTests.localControlSocketHandlesOneRequestPerConnectionAndIsPrivate
  Scenario: Local control socket is private and bounded
    Given the control service is running
    Then its parent directory mode is `0700`
    And its socket mode is `0600`
    When a same-user client connects
    Then one connection handles one HTTP JSON request
    And the JSON body is accepted without a `Content-Type` header
    And the method comes from the URL rather than a JSON field
    And clients do not send protocol versions or request IDs
    And the HTTP verb does not affect routing
    And live inspection output is pretty-printed structured JSON rather than an escaped string
    And JSON request bodies larger than 64 KiB fail closed
    And peer credentials must match the current user

  @automated
  # ControlProtocolTests.controlSocketServesOpenAPI
  Scenario: Local control is self-describing
    Given the control service is running
    When a same-user client gets `/openapi.json`
    Then Pablo returns an OpenAPI 3.1 document without showing approval
    And the document describes its discovery and control endpoints
    And the document identifies the Unix-domain socket transport

  @automated
  # ControlProtocolTests.liveInspectionControlRoundTrip
  Scenario: Large live inspection output crosses the bounded control protocol
    Given a same-user caller sends a live frame request
    When the app returns accessibility output larger than 64 KiB
    Then the request remains capped at 64 KiB
    And the bounded response is delivered without truncation

  @signed-app @human-approval @manual
  Scenario: Approval dialog is shown once per verified application per day
    Given a verified application has not been approved today
    When it requests recording control, annotation mutation, live inspection, or a live action
    Then Pablo shows one approval dialog naming the application and developer
    When the user approves
    And the same application makes another request today
    Then no duplicate dialog appears

  @signed-app @human-approval @manual
  Scenario: Denial fails closed
    Given an application requests control
    When the user denies the request
    Then no recording, annotation mutation, or synthetic input occurs
    And the caller receives a denial error
    And Pablo does not retry the request automatically

  @signed-app @human-approval @manual
  Scenario: Unverifiable callers require approval every time
    Given a caller has no verifiable signing identity
    When it requests an action twice
    Then Pablo shows approval for each request
    And never grants daily persistent trust to that caller

  @manual
  Scenario: Offline inspection does not contact or launch the app
    Given Pablo is not running
    And a recording package exists
    When the tester runs `inspect`, `frames`, `frame`, `events`, or `annotations`
    Then the command reads the package directly
    And Pablo does not launch
    And no approval dialog appears
