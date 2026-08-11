import Foundation
import PabloCore

@main
struct PabloCommandLine {
    static func main() async {
        do {
            switch try CLI.parse(Array(CommandLine.arguments.dropFirst())) {
            case .record(let options):
                print(CLI.formatControlResult(try CLI.sendControl(method: .startRecording, options: options)))
            case .status:
                print(CLI.formatControlResult(try CLI.sendControl(method: .status)))
            case .pause:
                print(CLI.formatControlResult(try CLI.sendControl(method: .pauseRecording)))
            case .resume:
                print(CLI.formatControlResult(try CLI.sendControl(method: .resumeRecording)))
            case .stop:
                print(CLI.formatControlResult(try CLI.sendControl(method: .stopRecording)))
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
