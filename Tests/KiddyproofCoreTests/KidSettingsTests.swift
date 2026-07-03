import XCTest
@testable import KiddyproofCore

final class KidSettingsTests: XCTestCase {
    func testDefaultsAreAlreadyClamped() {
        XCTAssertEqual(KidSettings.default, KidSettings.default.clamped())
    }

    func testDefaultSceneIsBlackHole() {
        XCTAssertEqual(KidSettings.default.defaultScene, "Black Hole")
    }

    func testEnergeticScenesAreOptIn() {
        XCTAssertFalse(KidSettings.default.energeticEnabled)
    }

    func testClampingBounds() {
        var s = KidSettings.default
        s.shuffleInterval = 0.5
        s.audioVolume = 7
        s.maxSessionSeconds = 999_999
        let c = s.clamped()
        XCTAssertEqual(c.shuffleInterval, 10)
        XCTAssertEqual(c.audioVolume, 1)
        XCTAssertEqual(c.maxSessionSeconds, 1800)

        s.shuffleInterval = 10_000
        s.audioVolume = -3
        s.maxSessionSeconds = 1
        let c2 = s.clamped()
        XCTAssertEqual(c2.shuffleInterval, 600)
        XCTAssertEqual(c2.audioVolume, 0)
        XCTAssertEqual(c2.maxSessionSeconds, 15)
    }

    func testClampingPreservesInRangeValues() {
        var s = KidSettings.default
        s.shuffleInterval = 45
        s.audioVolume = 0.6
        s.maxSessionSeconds = 300
        XCTAssertEqual(s, s.clamped())
    }

    func testCodableRoundTrip() throws {
        var s = KidSettings.default
        s.defaultScene = "Ripples"
        s.intensityCeiling = .wild
        s.audioVolume = 0.25
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(KidSettings.self, from: data)
        XCTAssertEqual(s, back)
    }

    // UserDefaults data survives version changes and is user-writable — decoding a
    // hostile/corrupt payload must fail cleanly (callers then fall back to .default).
    func testCorruptPayloadFailsCleanly() {
        let corrupt = Data("{\"defaultScene\": 42}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KidSettings.self, from: corrupt))
    }
}
