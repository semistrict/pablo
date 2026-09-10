import Foundation

enum InputRecordingPolicy {
    static func receivingPID(
        eventPID: pid_t,
        frontmostPID: pid_t?,
        hitTestPID: pid_t?,
        isPointer: Bool
    ) -> pid_t? {
        if eventPID > 0 { return eventPID }
        return isPointer ? hitTestPID : frontmostPID
    }

    static func accepts(scope: RecordingScopeKind, selectedPID: pid_t?, receivingPID: pid_t?) -> Bool {
        if scope == .display { return true }
        guard let selectedPID, let receivingPID else { return false }
        return selectedPID == receivingPID
    }
}
