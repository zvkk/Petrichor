import XCTest
@testable import Petrichor

final class PreviewPolicyTests: XCTestCase {
    func testArithmeticAndShortDurations() throws {
        XCTAssertEqual(try start(300), 60)
        XCTAssertEqual(try start(21), 0)
        XCTAssertEqual(try start(.nan), 0)
        XCTAssertEqual(try start(.infinity), 0)
        for duration in [0.0, 5, 20] { XCTAssertEqual(try start(duration), 0) }
        XCTAssertEqual(try start(25), 20)
        XCTAssertEqual(try start(375), 75)
    }
    func testInvalidSettingsRejectedEvenForUnknownDuration() {
        for values in [(2.0,20.0,75.0), (.nan,20,75), (0.2,-1,75), (0.2,76,75), (0.2,20,.infinity)] {
            XCTAssertThrowsError(try PreviewPolicy.startSeconds(duration: .nan, fraction: values.0, minSeconds: values.1, maxSeconds: values.2))
        }
    }
    private func start(_ duration: Double) throws -> Double {
        try PreviewPolicy.startSeconds(duration: duration, fraction: 0.2, minSeconds: 20, maxSeconds: 75)
    }
}
