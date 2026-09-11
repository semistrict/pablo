import Foundation
import PabloCore
import Testing

@Test("Installed apps load package resources without consulting the build directory",
      arguments: ["Pablo_PabloCore", "Pablo_PabloApp"])
func installedPackageResources(name: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let appURL = root.appendingPathComponent("Pablo.app")
    let resources = appURL.appendingPathComponent("Contents/Resources/\(name).bundle")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.semistrict.pablo.fixture.resources",
        "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    try Data("packaged resource".utf8).write(to: resources.appendingPathComponent("fixture.txt"))
    let app = try #require(Bundle(url: appURL))
    var developmentLookups = 0
    func developmentBundle() -> Bundle { developmentLookups += 1; return .main }

    let bundle = try PabloPackageResources.bundle(
        named: name, in: app, developmentBundle: developmentBundle()
    )

    let resource = try #require(bundle.url(forResource: "fixture", withExtension: "txt"))
    #expect(try String(contentsOf: resource, encoding: .utf8) == "packaged resource")
    #expect(developmentLookups == 0)
}

@Test("A missing installed resource produces an error without evaluating SwiftPM's fatal fallback")
func missingInstalledPackageResources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let appURL = root.appendingPathComponent("Pablo.app")
    try FileManager.default.createDirectory(
        at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true
    )
    let info = ["CFBundleIdentifier": "com.semistrict.pablo.fixture.resources", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    let app = try #require(Bundle(url: appURL))
    var developmentLookups = 0
    func developmentBundle() -> Bundle { developmentLookups += 1; return .main }

    #expect(throws: RecordingError.self) {
        try PabloPackageResources.bundle(
            named: "Pablo_PabloCore", in: app, developmentBundle: developmentBundle()
        )
    }
    #expect(developmentLookups == 0)
}
