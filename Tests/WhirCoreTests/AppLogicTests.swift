import XCTest
@testable import WhirCore

final class AppLogicTests: XCTestCase {
    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)!
    }

    // Bug: the popover total froze on the launch month. The key must track the date.
    func testCurrentMonthKeyRollsOver() {
        XCTAssertEqual(currentMonthKey(date("2026-06-15")), "2026-06")
        XCTAssertEqual(currentMonthKey(date("2026-07-15")), "2026-07")
        XCTAssertNotEqual(currentMonthKey(date("2026-06-15")), currentMonthKey(date("2026-07-15")))
    }

    // ROI must not divide by a rounded-to-$0 subscription.
    func testRoiMultiplierGatesTinySubscriptions() {
        XCTAssertNil(roiMultiplier(total: 500, subscription: 0))
        XCTAssertNil(roiMultiplier(total: 500, subscription: 0.5))
        XCTAssertEqual(roiMultiplier(total: 500, subscription: 50)!, 10, accuracy: 1e-9)
        XCTAssertEqual(roiMultiplier(total: 40, subscription: 40)!, 1, accuracy: 1e-9)
    }

    // Drilldown selection must not survive a bucket that disappeared.
    func testValidSelection() {
        XCTAssertEqual(validSelection("a", in: ["a", "b"]), "a")
        XCTAssertNil(validSelection("z", in: ["a", "b"]))
        XCTAssertNil(validSelection(nil, in: ["a"]))
        XCTAssertNil(validSelection("a", in: []))
    }

    // Missing/unreadable roots must be distinguishable from "no usage".
    func testRootsStatusDetectsMissingFolders() throws {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "whir-test-" + UUID().uuidString
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        let missing = tmp + "/does-not-exist"

        let mixed = rootsStatus(claudeProjects: tmp, codexSessions: missing)
        XCTAssertTrue(mixed.claudeReadable)
        XCTAssertFalse(mixed.codexReadable)
        XCTAssertTrue(mixed.anyReadable)

        let none = rootsStatus(claudeProjects: missing, codexSessions: missing)
        XCTAssertFalse(none.anyReadable)
    }

    // The price table ships with the app; flag it once it's clearly old.
    func testPricingStaleness() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let asOf = f.date(from: Pricing.asOf)!
        XCTAssertFalse(Pricing.isStale(now: asOf.addingTimeInterval(10 * 24 * 3600)))
        XCTAssertTrue(Pricing.isStale(now: asOf.addingTimeInterval(200 * 24 * 3600)))
    }

    // last-30d headline: a true trailing calendar window, not "last 30 active days".
    func testSumFromCalendarWindow() {
        let buckets = [
            ("2026-05-01", 100.0),   // way before the cutoff — excluded
            ("2026-05-15", 50.0),    // before cutoff — excluded
            ("2026-06-02", 10.0),    // on/after cutoff — included
            ("2026-06-30", 20.0),    // included
            ("unknown", 999.0),      // must be skipped despite sorting after dates
        ]
        XCTAssertEqual(sumFrom(cutoff: "2026-06-01", buckets), 30.0, accuracy: 1e-9)
        XCTAssertEqual(sumFrom(cutoff: "2026-01-01", buckets), 180.0, accuracy: 1e-9)
        XCTAssertEqual(sumFrom(cutoff: "2026-07-01", buckets), 0.0, accuracy: 1e-9)
    }
}
