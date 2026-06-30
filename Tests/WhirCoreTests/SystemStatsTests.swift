import XCTest
@testable import WhirCore

final class SystemStatsTests: XCTestCase {
    func testSampleWithinBounds() {
        let s = SystemSampler()
        _ = s.cpu()                          // prime the delta
        Thread.sleep(forTimeInterval: 0.2)
        let snap = s.sample()
        XCTAssert(snap.cpu >= 0 && snap.cpu <= 1, "cpu fraction in 0...1")
        XCTAssertGreaterThan(snap.ramTotal, 0)
        XCTAssertLessThanOrEqual(snap.ramUsed, snap.ramTotal)
        XCTAssertGreaterThan(snap.diskTotal, 0)
        XCTAssertLessThanOrEqual(snap.diskUsed, snap.diskTotal)
        XCTAssert(snap.ramFraction >= 0 && snap.ramFraction <= 1)
        XCTAssert(snap.diskFraction >= 0 && snap.diskFraction <= 1)
    }
}
