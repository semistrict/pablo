import XCTest
@testable import PabloCore

final class SessionClockTests: XCTestCase {
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
