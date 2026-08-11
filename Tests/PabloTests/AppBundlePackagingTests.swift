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
