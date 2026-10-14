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
    func testSettingsReaderUsesSharedDefaultsAndPreservesExplicitZero() throws {
        let suite = "PreviewSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PreviewSettings.load(from: defaults), .defaults)
        defaults.set(0.0, forKey: PreviewSettings.Keys.fraction)
        defaults.set(0.0, forKey: PreviewSettings.Keys.minSeconds)
        defaults.set(0.0, forKey: PreviewSettings.Keys.maxSeconds)
        let settings = PreviewSettings.load(from: defaults)
        XCTAssertEqual(settings, PreviewSettings(fraction: 0, minSeconds: 0, maxSeconds: 0))
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(settings.startSeconds(duration: 300), 0)
    }

    func testInvalidPersistedSettingsHaveSafePlaybackAndValidControlDefaults() throws {
        let suite = "PreviewSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(100.0, forKey: PreviewSettings.Keys.minSeconds)
        defaults.set(75.0, forKey: PreviewSettings.Keys.maxSeconds)
        let settings = PreviewSettings.load(from: defaults)
        XCTAssertFalse(settings.isValid)
        XCTAssertEqual(settings.minSeconds, 100)
        XCTAssertEqual(settings.startSeconds(duration: 300), 0)
        XCTAssertEqual(settings.validOrDefault, .defaults)
        XCTAssertEqual(settings.validOrDefault.startSeconds(duration: 300), 60)
    }

    private func start(_ duration: Double) throws -> Double {
        try PreviewPolicy.startSeconds(duration: duration, fraction: 0.2, minSeconds: 20, maxSeconds: 75)
    }
}
