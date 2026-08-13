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
            case .inspect(let source):
                print(try CLI.inspect(source))
            case .latest:
                print(try CLI.latestRecordingPath())
            case .recordings(let json):
                print(try CLI.recordings(json: json))
            case .frames(let source, let json):
                print(try CLI.frames(source, json: json))
            case .frame(let reference, let source, let changedOnly, let json):
                print(try CLI.frame(
                    reference: reference,
                    source: source,
                    changedOnly: changedOnly,
                    json: json
                ))
            case .events(let source, let limit, let json):
                print(try CLI.events(source, limit: limit, json: json))
            case .annotations(let source, let json):
                print(try CLI.annotations(source, json: json))
            case .liveAction(let action):
                print(try CLI.performLiveAction(action))
            case .annotate(let options):
                print(CLI.formatControlResult(try CLI.addAnnotation(options)))
            case .resolveAnnotation(let reference, let recording):
                print(CLI.formatControlResult(try CLI.resolveAnnotation(
                    reference: reference,
                    requestedURL: recording
                )))
            case .help:
                print(CLI.help)
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            if case RecordingError.usage = error {
                FileHandle.standardError.write(Data("\n\(CLI.help)\n".utf8))
            }
            Foundation.exit(1)
        }
    }
}
