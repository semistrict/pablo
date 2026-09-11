import Foundation

public enum PabloPackageResources {
    public static func bundle(
        named name: String,
        in application: Bundle = .main,
        developmentBundle: @autoclosure () -> Bundle
    ) throws -> Bundle {
        if let url = application.url(forResource: name, withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }

        // SwiftPM's generated accessor searches the app root and its original
        // build directory, not Contents/Resources. Never evaluate that fatal
        // fallback for an installed app, even when its resources are missing.
        guard application.bundleURL.pathExtension != "app" else {
            throw RecordingError.capture("Pablo's \(name) resource bundle is missing.")
        }
        return developmentBundle()
    }
}
