import CoreGraphics
import Testing
@testable import PabloCore

@Test("Normalized live points map into the target window")
func liveActionCoordinatesUseTargetWindow() {
    let window = CGRect(x: 200, y: 100, width: 1_000, height: 800)

    #expect(
        LiveActionGeometry.absolute(PabloLivePoint(x: 0, y: 0), in: window) ==
            CGPoint(x: 200, y: 100)
    )
    #expect(
        LiveActionGeometry.absolute(PabloLivePoint(x: 0.5, y: 0.25), in: window) ==
            CGPoint(x: 700, y: 300)
    )
    #expect(
        LiveActionGeometry.absolute(PabloLivePoint(x: 1, y: 1), in: window) ==
            CGPoint(x: 1_200, y: 900)
    )
}

@Test("Named keys and accessibility action aliases normalize predictably")
func liveActionNamesArePredictable() {
    #expect(PabloLiveKeyMap.keyCode(for: "Return") == 36)
    #expect(PabloLiveKeyMap.keyCode(for: "a") == 0)
    #expect(PabloLiveKeyMap.keyCode(for: "LEFT") == 123)
    #expect(PabloLiveKeyMap.keyCode(for: "not-a-key") == nil)

    let available = ["AXPress", "AXShowMenu", "AXIncrement"]
    #expect(LiveAccessibilityActions.match("press", in: available) == "AXPress")
    #expect(LiveAccessibilityActions.match("show-menu", in: available) == "AXShowMenu")
    #expect(LiveAccessibilityActions.match("AXIncrement", in: available) == "AXIncrement")
    #expect(LiveAccessibilityActions.match("delete", in: available) == nil)
}

@Test("The app validates live actions independently of the CLI")
func liveActionValidationFailsClosedAtTheAppBoundary() throws {
    let target = PabloLiveApplicationTarget(appName: "Notes")
    try PabloLiveActionValidator.validate(PabloLiveActionRequest(
        kind: .click,
        target: target,
        point: PabloLivePoint(x: 0.5, y: 0.5)
    ))

    #expect(throws: RecordingError.self) {
        try PabloLiveActionValidator.validate(PabloLiveActionRequest(
            kind: .click,
            target: target,
            point: PabloLivePoint(x: 1.5, y: 0.5)
        ))
    }
    #expect(throws: RecordingError.self) {
        try PabloLiveActionValidator.validate(PabloLiveActionRequest(
            kind: .key,
            target: PabloLiveApplicationTarget(
                pid: 42,
                bundleIdentifier: "com.example.Notes"
            ),
            key: "return"
        ))
    }
    #expect(throws: RecordingError.self) {
        try PabloLiveActionValidator.validate(PabloLiveActionRequest(
            kind: .drag,
            target: target,
            fromPoint: PabloLivePoint(x: 0.1, y: 0.1),
            toPoint: PabloLivePoint(x: 0.9, y: 0.9),
            duration: 30
        ))
    }
}

@Test("Coordinate actions avoid a full accessibility walk while node actions require one")
func liveActionSnapshotRequirementsAreMinimal() {
    let target = PabloLiveApplicationTarget(appName: "Notes")
    let coordinateClick = LiveActionSnapshotPolicy.requiresSnapshot(for: .init(
        kind: .click,
        target: target,
        point: .init(x: 0.5, y: 0.5)
    ))
    let nodeClick = LiveActionSnapshotPolicy.requiresSnapshot(for: .init(
        kind: .click,
        target: target,
        nodeID: "ax-button"
    ))
    let coordinateDrag = LiveActionSnapshotPolicy.requiresSnapshot(for: .init(
        kind: .drag,
        target: target,
        fromPoint: .init(x: 0.1, y: 0.1),
        toPoint: .init(x: 0.9, y: 0.9)
    ))
    let nodeAction = LiveActionSnapshotPolicy.requiresSnapshot(for: .init(
        kind: .perform,
        target: target,
        nodeID: "ax-button",
        accessibilityAction: "press"
    ))
    let focusedType = LiveActionSnapshotPolicy.requiresSnapshot(for: .init(
        kind: .typeText,
        target: target,
        text: "safe demo text"
    ))

    #expect(coordinateClick == false)
    #expect(nodeClick)
    #expect(coordinateDrag == false)
    #expect(nodeAction)
    #expect(focusedType == false)
}

@Test("Closed menu descendants are skipped but visible menus and ordinary containers remain")
func accessibilityTraversalSkipsClosedMenus() {
    let closedMenu = AccessibilityTraversalPolicy.shouldTraverseChildren(
        role: "AXMenu",
        size: .init(width: 0, height: 0)
    )
    let unsizedMenu = AccessibilityTraversalPolicy.shouldTraverseChildren(role: "AXMenu", size: nil)
    let visibleMenu = AccessibilityTraversalPolicy.shouldTraverseChildren(
        role: "AXMenu",
        size: .init(width: 240, height: 320)
    )
    let ordinaryContainer = AccessibilityTraversalPolicy.shouldTraverseChildren(
        role: "AXGroup",
        size: .init(width: 0, height: 0)
    )

    #expect(closedMenu == false)
    #expect(unsizedMenu == false)
    #expect(visibleMenu)
    #expect(ordinaryContainer)

    var loadedAllChildren = false
    let visible = AccessibilityTraversalPolicy.preferredChildren(
        visible: [1, 2],
        all: {
            loadedAllChildren = true
            return [1, 2, 3, 4]
        }
    )
    let emptyVisible = AccessibilityTraversalPolicy.preferredChildren(
        visible: [Int](),
        all: { [1, 2, 3, 4] }
    )
    let fallback = AccessibilityTraversalPolicy.preferredChildren(
        visible: Optional<[Int]>.none,
        all: { [1, 2, 3, 4] }
    )
    #expect(visible == [1, 2])
    #expect(loadedAllChildren == false)
    #expect(emptyVisible.isEmpty)
    #expect(fallback == [1, 2, 3, 4])
}
