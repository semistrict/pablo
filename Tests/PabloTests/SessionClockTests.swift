import XCTest
@testable import PabloCore

final class SessionClockTests: XCTestCase {
    func testDelayedFramesUseCaptureTimeAcrossMultiplePauses() {
        let pauses: [ClosedRange<UInt64>] = [200...300, 500...700]
        XCTAssertEqual(SessionClock.timestamp(hostNanoseconds: 150, origin: 100, pauses: pauses), 50)
        XCTAssertEqual(SessionClock.timestamp(hostNanoseconds: 400, origin: 100, pauses: pauses), 200)
        XCTAssertEqual(SessionClock.timestamp(hostNanoseconds: 800, origin: 100, pauses: pauses), 400)
        XCTAssertEqual(SessionClock.timestamp(hostNanoseconds: 50, origin: 100, pauses: pauses), 0)
    }
    func testPausedTimeIsExcludedFromTimeline() {
        let clock = SessionClock()
        Thread.sleep(forTimeInterval: 0.01)
        clock.pause()
        let beforePause = clock.nowNanoseconds()

        Thread.sleep(forTimeInterval: 0.05)
        let whilePaused = clock.nowNanoseconds()
        XCTAssertLessThan(whilePaused - beforePause, 2_000_000)

        clock.resume()
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertGreaterThan(clock.nowNanoseconds() - whilePaused, 10_000_000)
    }
}
