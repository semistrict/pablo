import AppKit
import CoreGraphics
import Darwin
import Foundation

struct RecordingProcessIdentity: Equatable, Sendable {
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

final class RecordingApplicationRegistry: @unchecked Sendable {
    private struct Entry {
        var application: RecordingApplication
        let processIdentity: RecordingProcessIdentity?
    }

    private let lock = NSLock()
    private var nextSequence = 1
    private var entriesByPID: [pid_t: Entry] = [:]
    private var catalogByID: [String: RecordingApplication] = [:]
    private var previousVisibleApplicationIDs = Set<String>()
    private var previousWindowIDs = Set<String>()

    func application(for pid: pid_t, timestampNs: UInt64) -> RecordingApplication? {
        application(
            for: pid,
            timestampNs: timestampNs,
            processIdentity: Self.processIdentity(for: pid)
        )
    }

    func application(
        for pid: pid_t,
        timestampNs: UInt64,
        processIdentity: RecordingProcessIdentity?
    ) -> RecordingApplication? {
        guard pid > 0 else { return nil }
        return lock.withLock {
            if let existing = entriesByPID[pid],
               existing.processIdentity == nil || processIdentity == nil ||
               existing.processIdentity == processIdentity {
                return existing.application
            }
            if var existing = entriesByPID[pid]?.application {
                existing.lastSeenTimestampNs = timestampNs
                catalogByID[existing.id] = existing
            }
            let running = NSRunningApplication(processIdentifier: pid)
            let descriptor = RecordingApplication(
                id: String(format: "APP-%03d", nextSequence),
                pid: pid,
                bundleIdentifier: running?.bundleIdentifier,
                name: running?.localizedName ?? "Process \(pid)",
                firstSeenTimestampNs: timestampNs,
                lastSeenTimestampNs: nil
            )
            nextSequence += 1
            entriesByPID[pid] = Entry(application: descriptor, processIdentity: processIdentity)
            catalogByID[descriptor.id] = descriptor
            return descriptor
        }
    }

    func allApplications() -> [RecordingApplication] {
        lock.withLock { catalogByID.values.sorted { $0.id < $1.id } }
    }

    func snapshot(
        timestampNs: UInt64,
        reason: String,
        captureFrame: CGRect?,
        tracksLifecycle: Bool = true
    ) -> WorkspaceSnapshotRecord {
        let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [RecordingWindow] = []
        var visiblePIDs = Set<pid_t>()

        for (zOrder, info) in windowInfo.enumerated() {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let systemID = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            if let captureFrame, !captureFrame.intersects(frame) { continue }
            let pid = pid_t(ownerPID.int32Value)
            guard let application = application(for: pid, timestampNs: timestampNs) else { continue }
            visiblePIDs.insert(pid)
            windows.append(RecordingWindow(
                id: "\(application.id):WIN-\(systemID.uint32Value)",
                applicationID: application.id,
                systemWindowID: systemID.uint32Value,
                title: info[kCGWindowName as String] as? String,
                frame: RecordingRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                zOrder: UInt32(zOrder)
            ))
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostID = frontmostPID.flatMap { application(for: $0, timestampNs: timestampNs)?.id }
        let visible = lock.withLock {
            entriesByPID.values.map(\.application).filter {
                visiblePIDs.contains(pid_t($0.pid)) || $0.id == frontmostID
            }
        }
        let visibleApplicationIDs = Set(visible.map(\.id))
        let windowIDs = Set(windows.map(\.id))
        let lifecycle = lock.withLock { () -> ([String], [String], [String], [String]) in
            guard tracksLifecycle else { return ([], [], [], []) }
            let appearedApps = visibleApplicationIDs.subtracting(previousVisibleApplicationIDs).sorted()
            let removedApps = previousVisibleApplicationIDs.subtracting(visibleApplicationIDs).sorted()
            let appearedWindows = windowIDs.subtracting(previousWindowIDs).sorted()
            let removedWindows = previousWindowIDs.subtracting(windowIDs).sorted()
            previousVisibleApplicationIDs = visibleApplicationIDs
            previousWindowIDs = windowIDs
            return (appearedApps, removedApps, appearedWindows, removedWindows)
        }
        return WorkspaceSnapshotRecord(
            schemaVersion: RecordingManifest.currentSchemaVersion,
            timestampNs: timestampNs,
            reason: reason,
            frontmostApplicationID: frontmostID,
            applications: visible.sorted { $0.id < $1.id },
            windows: windows.sorted { $0.zOrder < $1.zOrder },
            appearedApplicationIDs: lifecycle.0,
            removedApplicationIDs: lifecycle.1,
            appearedWindowIDs: lifecycle.2,
            removedWindowIDs: lifecycle.3
        )
    }

    private static func processIdentity(for pid: pid_t) -> RecordingProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copied = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard copied == expectedSize else { return nil }
        return RecordingProcessIdentity(
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }
}

enum RecordingDisplays {
    static func current() -> [RecordingDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = number.uint32Value
            return RecordingDisplay(
                id: id,
                name: screen.localizedName,
                frame: RecordingRect(
                    x: screen.frame.origin.x,
                    y: screen.frame.origin.y,
                    width: screen.frame.width,
                    height: screen.frame.height
                ),
                scale: screen.backingScaleFactor,
                isPrimary: id == CGMainDisplayID()
            )
        }.sorted { $0.id < $1.id }
    }
}
