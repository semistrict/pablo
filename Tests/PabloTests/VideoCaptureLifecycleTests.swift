import Foundation
import ScreenCaptureKit
import Testing
@testable import PabloCore

@Test func userStoppedCaptureDoesNotRequestASecondStop() {
    var lifecycle = VideoCaptureLifecycle()
    lifecycle.beginStart()
    lifecycle.completeStart()

    let error = NSError(
        domain: SCStreamErrorDomain,
        code: SCStreamError.Code.userStopped.rawValue
    )

    let reportedError = lifecycle.streamStopped(with: error)
    #expect(reportedError == nil)
    #expect(lifecycle.phase == .stopped)
    let shouldStopAgain = lifecycle.beginStop()
    #expect(shouldStopAgain == false)
}

@Test func activeCaptureRequestsExactlyOneStop() {
    var lifecycle = VideoCaptureLifecycle()
    lifecycle.beginStart()
    lifecycle.completeStart()

    let shouldStop = lifecycle.beginStop()
    let shouldStopAgain = lifecycle.beginStop()
    #expect(shouldStop)
    #expect(shouldStopAgain == false)
    lifecycle.completeStop()
    let shouldStopAfterCompletion = lifecycle.beginStop()
    #expect(shouldStopAfterCompletion == false)
}

@Test func alreadyStoppedErrorIsSafeToIgnore() {
    let error = NSError(
        domain: SCStreamErrorDomain,
        code: SCStreamError.Code.attemptToStopStreamState.rawValue
    )

    #expect(VideoCaptureLifecycle.isAlreadyStopped(error))
}
