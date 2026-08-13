import Foundation
import Testing

@Test("The app executable name cannot collide with the bundled CLI")
func appExecutableDoesNotCollideWithCLI() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let infoURL = projectDirectory.appending(path: "Resources/Pablo-Info.plist")
    let data = try Data(contentsOf: infoURL)
    let plist = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    let executable = try #require(plist["CFBundleExecutable"] as? String)

    #expect(executable.lowercased() != "pablo")
}

@Test("The review window uses a standard application activation policy")
func reviewWindowUsesStandardApplicationActivation() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let infoURL = projectDirectory.appending(path: "Resources/Pablo-Info.plist")
    let data = try Data(contentsOf: infoURL)
    let plist = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )

    #expect((plist["LSUIElement"] as? Bool) != true)
}

@Test("Swift package resource bundles are copied into the app")
func dependencyResourceBundlesArePackaged() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = try String(
        contentsOf: projectDirectory.appending(path: "scripts/build-app.sh"),
        encoding: .utf8
    )

    #expect(script.contains("*.bundle(N)"))
    #expect(script.contains("ditto \"$resource_bundle\""))
}
