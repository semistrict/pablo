Feature: Control a live Mac application through the approved Pablo bridge
  Actions target one running application and use normalized window coordinates or nodes from live accessibility frames.

  @automated
  # CLITests.testParsesEveryLiveActionCommand
  Scenario: Parse every supported live action command
    When `click` is parsed with a target, node, mouse button, and click count
    Then a click request preserves those values
    When `drag` is parsed with normalized endpoints and a duration
    Then a drag request preserves those values
    When `scroll`, `type`, `key`, and `perform` are parsed with their required options
    Then each corresponding live action is selected

  @automated
  # CLITests.testLiveActionsRejectInvalidOrIncompleteArguments
  Scenario: Invalid or ambiguous action arguments fail before reaching the app
    When an action has no live target
    Then parsing fails
    When click has both a node and point
    Then parsing fails
    When normalized coordinates, click counts, durations, scroll amounts, or modifiers are invalid
    Then parsing fails
    When type has empty text or perform lacks an action
    Then parsing fails

  @automated
  # LiveActionTests.liveActionCoordinatesUseTargetWindow
  Scenario: Normalized points map into the target window
    Given the target window begins at screen point `200,100` and measures `1000x800`
    When normalized point `0.5,0.25` is resolved
    Then its screen point is `700,300`
    And normalized corners map to the target window corners

  @automated
  # LiveActionTests.liveActionNamesArePredictable
  Scenario: Key names and accessibility action aliases are deterministic
    When common named keys, letters, and arrows are resolved
    Then they map to their macOS virtual key codes
    When `press`, `show-menu`, or an `AX`-prefixed action is matched
    Then it selects the corresponding action exposed by the node
    And unknown keys and unavailable actions fail

  @automated
  # LiveActionTests.liveActionValidationFailsClosedAtTheAppBoundary
  Scenario: The app revalidates action payloads received over the socket
    Given a caller bypasses the bundled CLI and constructs a control request directly
    When the request has coordinates outside zero through one
    Or has multiple target selectors
    Or has an out-of-range drag duration
    Then Pablo rejects it before activating the target or posting input

  @automated
  # LiveActionTests.liveActionSnapshotRequirementsAreMinimal
  Scenario: Coordinate actions avoid unnecessary full accessibility walks
    Given a caller supplies normalized points instead of accessibility nodes
    When click, drag, or scroll resolves its target window
    Then Pablo reads the target window bounds directly
    And does not walk the full accessibility tree
    Given an action supplies a node reference
    Then Pablo requires a current accessibility snapshot and exact node element

  @automated
  # LiveActionTests.accessibilityTraversalSkipsClosedMenus
  Scenario: Closed application menus do not dominate accessibility capture time
    Given a menu has no visible size
    When Pablo walks the application accessibility tree
    Then it records the menu node without traversing its closed descendants
    And visible menus and ordinary zero-sized containers still traverse their children
    And containers exposing visible children omit their off-screen collection rows
    And containers without that attribute fall back to their complete children

  @automated
  # ControlProtocolTests.liveActionControlRoundTrip
  Scenario: Live actions cross the private control socket
    Given a same-user client sends a typed-text action for one target and node
    When Pablo decodes the request
    Then the method, target, node, and action payload are preserved
    And caller identity still comes from peer credentials and process ancestry
    And the action result returns over the same connection

  @signed-app @human-approval @manual
  Scenario: The user remains the authority for live control
    Given a verified calling application is not approved today
    When it requests a live action
    Then Pablo shows an approval dialog naming the calling application and developer
    And describes the action category and target application
    When the user denies
    Then no input is posted and the request fails closed
    When the user approves
    Then approval may be reused only for that verified application and local calendar day

  @signed-app @manual
  Scenario: Click an accessibility node or normalized point
    Given the target has a current live accessibility frame
    When `click --node <id>` targets a node exposing `AXPress`
    Then Pablo performs `AXPress` on that exact node
    When the node does not expose `AXPress` or `--point X,Y` is used
    Then Pablo posts the requested mouse button and click count at the resolved point
    And the point remains inside the target window

  @signed-app @manual
  Scenario: Drag between points or accessibility nodes
    Given both drag endpoints resolve inside the target application
    When `drag` runs with a duration
    Then Pablo posts mouse-down, interpolated drag, and mouse-up events in order
    And the requested mouse button remains held through the gesture
    And the final pointer point matches the resolved destination

  @signed-app @manual
  Scenario: Scroll at a node, point, or window center
    Given the target application has an accessible visible window
    When `scroll` supplies a direction and line amount
    Then Pablo posts vertical or horizontal scrolling in that direction
    And uses the selected node or point when present
    And otherwise uses the center of the target window

  @signed-app @manual
  Scenario: Type into the focused or selected control without echoing content
    Given the target application is approved for live control
    When `type --text <text>` includes a node
    Then Pablo focuses that exact accessibility element before posting Unicode keyboard events
    When no node is supplied
    Then Pablo types into the target's current focused control
    And the CLI result reports only the character count, not the text
    And the synthetic key events pass through the HID event tap
    And recording and live-event observation can see those key events

  @signed-app @manual
  Scenario: Send a named key with modifiers
    Given the target application is active
    When `key --key return --modifiers command,shift` runs
    Then Pablo posts key-down and key-up to the target process
    And both events carry command and shift flags
    And an unknown key produces no input

  @signed-app @manual
  Scenario: Perform only an action actually exposed by a node
    Given a current node exposes `AXPress` and `AXShowMenu`
    When `perform --node <id> --action show-menu` runs
    Then Pablo performs `AXShowMenu` on that exact node
    When a requested action is not exposed
    Then Pablo lists the available actions and performs nothing

  @signed-app @manual
  Scenario: Stale nodes and missing windows fail closed
    Given a node reference no longer exists or has no usable bounds
    When a live action tries to use it
    Then Pablo asks the caller to refresh live frames
    And posts no pointer or keyboard input
    Given the target has no accessible visible window
    When a coordinate action runs
    Then the command fails without targeting another application or display
