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

@Test("The app owns Pablo recording packages for Finder open requests")
func appOwnsPabloRecordingPackages() throws {
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
    let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let recordingType = try #require(declarations.first(where: {
        $0["UTTypeIdentifier"] as? String == "com.ramon.pablo.recording"
    }))
    let conformsTo = try #require(recordingType["UTTypeConformsTo"] as? [String])
    let tags = try #require(recordingType["UTTypeTagSpecification"] as? [String: Any])
    let extensions = try #require(tags["public.filename-extension"] as? [String])
    let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])

    #expect(conformsTo.contains("com.apple.package"))
    #expect(extensions == ["pablo"])
    #expect(documentTypes.contains(where: {
        ($0["LSItemContentTypes"] as? [String])?.contains("com.ramon.pablo.recording") == true &&
            $0["CFBundleTypeRole"] as? String == "Viewer" &&
            $0["LSHandlerRank"] as? String == "Owner"
    }))
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
