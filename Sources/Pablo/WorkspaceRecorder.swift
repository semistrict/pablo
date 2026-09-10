import AppKit
import CoreGraphics
import Darwin
import Foundation

struct RecordingProcessIdentity: Equatable, Sendable {
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct RecordingWindowObservation {
    let pid: pid_t
    let systemID: UInt32
    let title: String?
    let frame: CGRect
    let layer: Int
    let isOnScreen: Bool
    let zOrder: UInt32

    static func current(includeOffscreen: Bool) -> [Self] {
        let options: CGWindowListOption = includeOffscreen ? .optionAll : .optionOnScreenOnly
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return info.enumerated().compactMap { order, info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let systemID = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 0, frame.height > 0 else { return nil }
            return Self(
                pid: pid_t(ownerPID.int32Value), systemID: systemID.uint32Value,
                title: info[kCGWindowName as String] as? String, frame: frame,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                zOrder: UInt32(order)
            )
        }
    }
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
        tracksLifecycle: Bool = true,
        applicationPID: pid_t? = nil,
        observations: [RecordingWindowObservation]? = nil,
        frontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) -> WorkspaceSnapshotRecord {
        let observed = observations ?? RecordingWindowObservation.current(includeOffscreen: applicationPID != nil)
        var windows: [RecordingWindow] = []
        var visiblePIDs = Set<pid_t>()

        for window in observed {
            let frame = window.frame
            let pid = window.pid
            if let applicationPID, pid != applicationPID { continue }
            if let captureFrame, !captureFrame.intersects(frame) { continue }
            guard let application = application(for: pid, timestampNs: timestampNs) else { continue }
            visiblePIDs.insert(pid)
            windows.append(RecordingWindow(
                id: "\(application.id):WIN-\(window.systemID)",
                applicationID: application.id,
                systemWindowID: window.systemID,
                title: window.title,
                frame: RecordingRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                layer: window.layer,
                isOnScreen: window.isOnScreen,
                zOrder: window.zOrder
            ))
        }

        if let applicationPID {
            _ = application(for: applicationPID, timestampNs: timestampNs)
            visiblePIDs.insert(applicationPID)
        }
        let includedFrontmostPID = applicationPID == nil || frontmostPID == applicationPID ? frontmostPID : nil
        let frontmostID = includedFrontmostPID.flatMap { application(for: $0, timestampNs: timestampNs)?.id }
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
                frame: RecordingRect(CGDisplayBounds(id)),
                scale: screen.backingScaleFactor,
                isPrimary: id == CGMainDisplayID()
            )
        }.sorted { $0.id < $1.id }
    }
}
