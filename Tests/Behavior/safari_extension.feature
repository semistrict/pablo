Feature: Control one explicitly unlocked Safari tab without foreground activation
  Pablo uses a bundled Safari Web Extension to expose bounded DOM inspection and actions while Safari remains in the background.

  @automated
  # SafariDOMProtocolTests.safariDOMCommandsFailClosed
  Scenario: DOM commands validate their targets and bounds
    Given a Safari DOM command arrives at the app boundary
    When it is a dump command
    Then it accepts no target or value
    When it is an action command
    Then it requires exactly one selector or fresh node ID
    And it requires the document generation returned by an inspection
    And setValue requires a bounded value
    And node and depth limits remain within documented bounds

  @automated
  # SafariDOMProtocolTests.safariDOMBridgeUsesSerializedProtobuf
  Scenario: App and extension messages use binary protobuf
    Given Pablo creates a Safari DOM command with a stable request ID
    When the command crosses the native Safari extension bridge
    Then its kind, target, bounded options, and value are preserved in protobuf
    And the protobuf response carries the same request ID and structured JSON payload

  @automated
  # AppBundlePackagingTests.safariExtensionIsEmbeddedAndLeastPrivilege
  Scenario: Distribution embeds a least-privilege extension
    Given Pablo builds its signed application bundle
    Then the Safari Web Extension is embedded before the outer app is signed
    And it requests activeTab, nativeMessaging, and script injection capabilities
    And it requests no persistent website host patterns or content-script matches

  @automated
  # ControlProtocolTests.safariDOMControlRoundTrip
  Scenario: Safari DOM commands cross the local JSON API
    Given a same-user client sends a dumpAccessibilityTree request to `/safari.dom`
    When Pablo decodes the request
    Then bounded defaults are applied
    And the structured result returns over the same connection

  @signed-app @human-approval @manual
  Scenario: The user explicitly unlocks one active tab
    Given Pablo Safari is enabled in Safari settings
    And Safari is open but not frontmost
    When the user clicks Pablo's toolbar button on the active tab
    Then Safari grants activeTab access to that tab
    And Pablo can dump and manipulate its DOM without activating Safari
    When that tab navigates
    Then the grant ends and later commands fail closed until another toolbar click

  @signed-app @manual
  Scenario: DOM-derived accessibility output is honest and bounded
    Given the unlocked page contains DOM and ARIA semantics
    When Pablo dumps its accessibility tree
    Then the result identifies itself as `dom-derived`
    And includes roles, accessible names, states, frames, and opaque document-bound node IDs
    And password values are redacted
    And the result states when node, depth, text, attribute, or byte limits truncate it
    And it never claims to be WebKit's private native accessibility tree


  @automated
  # SafariExtension/JavaScript/tests/dom.test.mjs and tests/access.test.mjs
  Scenario: DOM-derived evidence retains prose within actual traversal and output bounds
    Given the page contains headings, ordinary paragraphs, and many text or hidden siblings
    When a bounded dump is requested
    Then text remains in reading order
    And traversal stops at the visited-node budget
    And the encoded response stays within 1 MiB with bounded attributes and redacted passwords
    And a near-limit response survives protobuf and base64 delivery without a stack overflow or lost bytes

  @automated
  # SafariDOMProtocolTests.safariDOMMutationsRequireFreshDocument, safariStaleFailureReachesControlAPI and JavaScript DOM fixtures
  Scenario: A stale Safari target cannot act on a replacement page or node
    Given a prior inspection returned a document generation and node reference
    When the node is disconnected or the document is replaced
    Then the old action is rejected before dispatch
    And the control API reports staleContext with notDispatched
    And a successful current action reports its effect as unverified


  @automated
  # RecorderLifecycleTests.webUnknownStopRetainsRecoveryContext, webStartReservesRecoveryContextBeforeAwait
  Scenario: An unknown web lifecycle outcome preserves recovery evidence
    Given a Safari start or stop request loses its acknowledgment
    Then the active recording package and spool remain available
    And repeated status failures do not finalize or discard them
    And a pending start prevents another start from dispatching

  @automated
  # SafariExtension/JavaScript/tests/recorder.test.mjs
  Scenario: Safari transitions wait for delivery and retain stopped receipts
    Given a pause is waiting for native event delivery
    When a resume arrives
    Then it waits until pause finishes
    When the recording later stops
    Then status and another stop for that recording can retrieve the retained receipt


  @automated
  # Safari JavaScript tests/access.test.mjs; SafariDOMProtocolTests.safariAccessFailureCarriesHumanAction
  Scenario: A locked tab reports its human prerequisite before a DOM action
    Given Safari rejects the extension's read-only access probe
    When an inspection or action targets that tab
    Then no DOM command is submitted
    And the response identifies the tab unlock and Safari prompt as human actions
    But a failure after an action was submitted retains an unknown outcome
