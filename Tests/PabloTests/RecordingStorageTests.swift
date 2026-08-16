import Foundation
import PabloCore
import Testing

@Test("Pablo recordings are user documents rather than movies")
func recordingsUseTheDocumentsDirectory() {
    let expected = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Pablo Recordings", isDirectory: true)

    #expect(PabloRecordingStorage.localRecordingsDirectory == expected)
}

@Test("Default application recording names include a filename-safe application name")
func defaultApplicationRecordingNamesIncludeTheApplication() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/Pablo Recordings", isDirectory: true)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let application = PabloRecordingStorage.defaultRecordingURL(
        applicationName: "Acme/QA: Demo\n",
        at: date,
        timeZone: timeZone,
        directory: directory
    )
    let display = PabloRecordingStorage.defaultRecordingURL(
        applicationName: nil,
        at: date,
        timeZone: timeZone,
        directory: directory
    )

    #expect(application.lastPathComponent == "Acme-QA- Demo Recording 2023-11-14 at 22.13.20.pablo")
    #expect(display.lastPathComponent == "Recording 2023-11-14 at 22.13.20.pablo")

    var explicitOptions = RecordOptions()
    explicitOptions.scope = .display
    explicitOptions.outputURL = directory.appendingPathComponent("Chosen Name.pablo", isDirectory: true)
    let explicitSession = try RecordingSession(options: explicitOptions)
    #expect(explicitSession.packageURL == explicitOptions.outputURL)
}

@Test("Existing movie-folder recordings move once without overwriting documents")
func legacyRecordingsMoveWithoutOverwriting() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("Movies", isDirectory: true)
    let destination = root.appendingPathComponent("Documents", isDirectory: true)
    let moved = source.appendingPathComponent("Moved.pablo", isDirectory: true)
    let collision = source.appendingPathComponent("Existing.pablo", isDirectory: true)
    let existingDestination = destination.appendingPathComponent("Existing.pablo", isDirectory: true)
    let unrelated = source.appendingPathComponent("notes.txt")
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: moved, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: collision, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: existingDestination, withIntermediateDirectories: true)
    #expect(fileManager.createFile(atPath: unrelated.path, contents: Data()))

    try PabloRecordingStorage.migrateRecordings(
        from: source,
        to: destination,
        fileManager: fileManager
    )

    #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("Moved.pablo").path))
    #expect(!fileManager.fileExists(atPath: moved.path))
    #expect(fileManager.fileExists(atPath: collision.path))
    #expect(fileManager.fileExists(atPath: existingDestination.path))
    #expect(fileManager.fileExists(atPath: unrelated.path))
}
