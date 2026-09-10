import AppKit

/// A standalone consent window which suspends its request without blocking the main actor.
@MainActor
final class ControlApprovalPrompt: NSObject, NSWindowDelegate {
    private let alert: NSAlert
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    init(alert: NSAlert) { self.alert = alert }

    func decision() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !finished else {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                alert.buttons[0].target = self
                alert.buttons[0].action = #selector(allow)
                alert.buttons[1].target = self
                alert.buttons[1].action = #selector(deny)
                alert.buttons[1].keyEquivalent = "\u{1b}"
                alert.window.delegate = self
                alert.window.level = .floating
                alert.layout()
                alert.window.center()
                NSApplication.shared.activate(ignoringOtherApps: true)
                alert.window.makeKeyAndOrderFront(nil)
            }
        } onCancel: {
            Task { @MainActor in self.finish(false) }
        }
    }

    @objc private func allow() { finish(true) }
    @objc private func deny() { finish(false) }
    func windowWillClose(_ notification: Notification) { finish(false) }

    private func finish(_ allowed: Bool) {
        guard !finished else { return }
        finished = true
        alert.window.delegate = nil
        alert.window.orderOut(nil)
        alert.window.close()
        let pending = continuation
        continuation = nil
        pending?.resume(returning: allowed)
    }
}
