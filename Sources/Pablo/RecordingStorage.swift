import Foundation

public enum PabloRecordingStorage {
    public static var localRecordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pablo Recordings", isDirectory: true)
    }

    public static func defaultRecordingURL(
        applicationName: String?,
        at date: Date = Date(),
        timeZone: TimeZone = .current,
        directory: URL = localRecordingsDirectory
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"

        let prefix = applicationName.flatMap(safeFilenameComponent).map { "\($0) Recording" }
            ?? "Recording"
        return directory.appendingPathComponent(
            "\(prefix) \(formatter.string(from: date)).pablo",
            isDirectory: true
        )
    }

    private static func safeFilenameComponent(_ value: String) -> String? {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        let replacedScalars = value.unicodeScalars.map { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return forbidden.contains(scalar) ? "-" : String(scalar)
        }.joined()
        let collapsedWhitespace = replacedScalars
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsedWhitespace.isEmpty else { return nil }
        return String(collapsedWhitespace.prefix(80))
    }

    public static func migrateLegacyRecordings(fileManager: FileManager = .default) throws {
        let legacyDirectory = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pablo Recordings", isDirectory: true)
        try migrateRecordings(
            from: legacyDirectory,
            to: localRecordingsDirectory,
            fileManager: fileManager
        )
    }

    public static func migrateRecordings(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: sourceDirectory.path) else { return }
        let recordings = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.pathExtension.caseInsensitiveCompare("pablo") == .orderedSame &&
                ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
        guard !recordings.isEmpty else { return }

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        for recording in recordings {
            let destination = destinationDirectory.appendingPathComponent(
                recording.lastPathComponent,
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.moveItem(at: recording, to: destination)
        }
    }
}
