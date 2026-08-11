import Foundation
import PabloCore

@main
struct PabloCommandLine {
    static func main() async {
        do {
            switch try CLI.parse(Array(CommandLine.arguments.dropFirst())) {
            case .record(let options):
                try await RecordingSession(options: options).run()
            case .inspect(let url):
                print(try CLI.inspect(url))
            case .latest:
                print(try CLI.latestRecordingPath())
            case .recordings(let json):
                print(try CLI.recordings(json: json))
            case .frames(let url, let json):
                print(try CLI.frames(url, json: json))
            case .frame(let reference, let recording, let changedOnly, let json):
                print(try CLI.frame(
                    reference: reference,
                    requestedURL: recording,
                    changedOnly: changedOnly,
                    json: json
                ))
            case .events(let url, let limit, let json):
                print(try CLI.events(url, limit: limit, json: json))
            case .help:
                print(CLI.help)
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            FileHandle.standardError.write(Data("\n\(CLI.help)\n".utf8))
            Foundation.exit(1)
        }
    }
}
