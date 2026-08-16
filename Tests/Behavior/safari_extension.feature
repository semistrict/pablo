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
    And includes roles, accessible names, states, frames, and CSS-selector node IDs
    And password values are redacted
    And the result states when node or depth limits truncate it
    And it never claims to be WebKit's private native accessibility tree
