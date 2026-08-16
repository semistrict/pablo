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

    let webRecordingType = try #require(declarations.first(where: {
        $0["UTTypeIdentifier"] as? String == "com.ramon.pablo.web-recording"
    }))
    let webConformance = try #require(webRecordingType["UTTypeConformsTo"] as? [String])
    let webTags = try #require(webRecordingType["UTTypeTagSpecification"] as? [String: Any])
    let webExtensions = try #require(webTags["public.filename-extension"] as? [String])
    #expect(webConformance.contains("com.apple.package"))
    #expect(webExtensions == ["pabloweb"])
    #expect(documentTypes.contains(where: {
        ($0["LSItemContentTypes"] as? [String])?.contains("com.ramon.pablo.web-recording") == true &&
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

@Test("The signed app embeds a least-privilege Safari Web Extension")
func safariExtensionIsEmbeddedAndLeastPrivilege() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildScript = try String(
        contentsOf: projectDirectory.appending(path: "scripts/build-app.sh"),
        encoding: .utf8
    )
    let manifestData = try Data(contentsOf: projectDirectory.appending(
        path: "SafariExtension/Resources/manifest.json"
    ))
    let manifest = try #require(
        JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    )
    let permissions = try #require(manifest["permissions"] as? [String])
    let infoData = try Data(contentsOf: projectDirectory.appending(path: "Resources/Pablo-Info.plist"))
    let info = try #require(
        PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
    )

    #expect(buildScript.contains("build-safari-extension.sh"))
    #expect(buildScript.contains("Pablo Safari.appex"))
    #expect(buildScript.range(of: "Pablo Safari.appex")!.lowerBound <
        buildScript.range(of: "--identifier com.ramon.pablo")!.lowerBound)
    #expect(Set(permissions) == Set(["activeTab", "nativeMessaging", "scripting"]))
    #expect(manifest["host_permissions"] == nil)
    #expect(manifest["content_scripts"] == nil)
    #expect(!String(decoding: manifestData, as: UTF8.self).contains("<all_urls>"))
    #expect(manifest["version"] as? String == info["CFBundleShortVersionString"] as? String)

    let recorderSource = try String(
        contentsOf: projectDirectory.appending(path: "SafariExtension/JavaScript/recorder-entry.js"),
        encoding: .utf8
    )
    let playerSource = try String(
        contentsOf: projectDirectory.appending(path: "SafariExtension/JavaScript/player-entry.js"),
        encoding: .utf8
    )
    let extensionBuild = try String(
        contentsOf: projectDirectory.appending(path: "scripts/build-safari-extension.sh"),
        encoding: .utf8
    )
    let replaySource = try String(
        contentsOf: projectDirectory.appending(path: "Sources/PabloApp/RRWebReplayView.swift"),
        encoding: .utf8
    )
    #expect(recorderSource.contains("maskAllInputs: true"))
    #expect(recorderSource.contains("recordCanvas: false"))
    #expect(recorderSource.contains("recordCrossOriginIframes: false"))
    #expect(playerSource.contains(#"import RRWebPlayer from "rrweb-player""#))
    #expect(extensionBuild.contains("SafariExtension/Generated/rrweb-recorder.js"))
    #expect(extensionBuild.contains("$web_extension_source/rrweb-recorder.js"))
    #expect(extensionBuild.contains("Sources/Pablo/RRWebSpoolStore.swift"))
    #expect(extensionBuild.contains(#"INFOPLIST_KEY_CFBundleDisplayName="Pablo Safari""#))
    #expect(extensionBuild.contains(#"PRODUCT_NAME="Pablo Safari""#))
    #expect(extensionBuild.contains("PRODUCT_MODULE_NAME=PabloSafariHost_Extension"))
    #expect(buildScript.contains("build-rrweb-assets.sh"))
    #expect(buildScript.range(of: "build-rrweb-assets.sh")!.lowerBound <
        buildScript.range(of: "build-safari-extension.sh")!.lowerBound)
    #expect(replaySource.contains("websiteDataStore = .nonPersistent()"))
    #expect(replaySource.contains(#""url-filter":"^https?://""#))
    #expect(replaySource.contains("autoPlay: false"))
    #expect(replaySource.contains("showController: true"))
    #expect(replaySource.contains("skipInactive: true"))
    #expect(replaySource.contains("speedOption: [0.5, 1, 2, 4, 8]"))
}

@Test("Safari extension and rrweb JavaScript parse before packaging")
func safariExtensionJavaScriptParses() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sources = [
        "SafariExtension/Resources/background.js",
        "SafariExtension/JavaScript/recorder-entry.js",
        "SafariExtension/JavaScript/player-entry.js",
        "SafariExtension/Generated/rrweb-recorder.js",
        "Sources/PabloApp/Resources/RRWebPlayer/player.js",
    ]

    for source in sources {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--check", projectDirectory.appendingPathComponent(source).path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let detail = try output.fileHandleForReading.readToEnd() ?? Data()
        #expect(
            process.terminationStatus == 0,
            Comment(rawValue: "\(source): \(String(decoding: detail, as: UTF8.self))")
        )
    }
}

@Test("Local app builds never silently fall back to ad-hoc signing")
func localBuildRequiresAnExplicitSigningChoice() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = try String(
        contentsOf: projectDirectory.appending(path: "scripts/build-app.sh"),
        encoding: .utf8
    )

    #expect(script.contains("No Apple Development signing identity was found."))
    #expect(script.contains("exit 1"))
    #expect(!script.contains("signing_identity=-"))
}

@Test("Distribution signing requires App Group-authorized profiles")
func distributionSigningRequiresAppGroupProfiles() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildScript = try String(
        contentsOf: projectDirectory.appending(path: "scripts/build-app.sh"),
        encoding: .utf8
    )
    let distributionScript = try String(
        contentsOf: projectDirectory.appending(path: "scripts/build-distribution.sh"),
        encoding: .utf8
    )
    let appEntitlements = try String(
        contentsOf: projectDirectory.appending(path: "Resources/Pablo.entitlements"),
        encoding: .utf8
    )
    let extensionEntitlements = try String(
        contentsOf: projectDirectory.appending(
            path: "SafariExtension/PabloSafariExtension.entitlements"
        ),
        encoding: .utf8
    )

    #expect(buildScript.contains("validate-distribution-profile.sh"))
    #expect(buildScript.contains("Contents/embedded.provisionprofile"))
    #expect(distributionScript.contains("PABLO_APP_PROVISIONING_PROFILE"))
    #expect(distributionScript.contains("PABLO_SAFARI_EXTENSION_PROVISIONING_PROFILE"))
    #expect(appEntitlements.contains("D9G32AG3E5.com.ramon.pablo"))
    #expect(extensionEntitlements.contains("D9G32AG3E5.com.ramon.pablo.safari.extension"))
    #expect(appEntitlements.contains("com.apple.developer.team-identifier"))
    #expect(extensionEntitlements.contains("com.apple.developer.team-identifier"))
}

@Test("The permission reset script is scoped to Pablo's bundle identifier")
func permissionResetIsScopedToPablo() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = try String(
        contentsOf: projectDirectory.appending(path: "scripts/reset-permissions.sh"),
        encoding: .utf8
    )

    #expect(script.contains("tccutil reset All \"$bundle_identifier\""))
    #expect(script.contains("installed_bundle_identifier != $bundle_identifier"))
    #expect(!script.contains("tccutil reset All\n"))
}

@Test("The generated OpenAPI document matches its source")
func generatedControlOpenAPIMatchesSource() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectDirectory = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let process = Process()
    let output = Pipe()
    process.executableURL = projectDirectory.appending(path: "scripts/generate-control-openapi.rb")
    process.arguments = ["--check"]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let detail = try output.fileHandleForReading.readToEnd() ?? Data()
    #expect(
        process.terminationStatus == 0,
        Comment(rawValue: String(decoding: detail, as: UTF8.self))
    )
}
