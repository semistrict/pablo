import AppKit
import Foundation

struct TargetApplication {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String

    static func resolve(pid: pid_t?, bundleIdentifier: String?, appName: String?) throws -> TargetApplication {
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let application: NSRunningApplication?

        if let pid {
            application = NSRunningApplication(processIdentifier: pid)
        } else if let bundleIdentifier {
            application = running.first { $0.bundleIdentifier == bundleIdentifier }
        } else if let appName {
            application = running.first {
                $0.localizedName?.localizedCaseInsensitiveCompare(appName) == .orderedSame
            }
        } else {
            application = NSWorkspace.shared.frontmostApplication
        }

        guard let application else {
            let selector = bundleIdentifier ?? appName ?? pid.map(String.init) ?? "frontmost application"
            throw RecordingError.targetNotFound("Could not find a running application matching \(selector).")
        }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw RecordingError.targetNotFound("The recorder cannot target itself.")
        }

        return TargetApplication(
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            name: application.localizedName ?? application.bundleIdentifier ?? "PID \(application.processIdentifier)"
        )
    }
}
