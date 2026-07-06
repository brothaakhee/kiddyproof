import XCTest
@testable import KiddyproofCore

final class KidSettingsTests: XCTestCase {
    func testDefaultsAreAlreadyClamped() {
        XCTAssertEqual(KidSettings.default, KidSettings.default.clamped())
    }

    func testDefaultSceneIsBlackHole() {
        XCTAssertEqual(KidSettings.default.defaultScene, "Black Hole")
    }

    func testAllScenesEnabledByDefault() {
        XCTAssertTrue(KidSettings.default.disabledScenes.isEmpty)
    }

    func testNoLimitSentinelSurvivesClamping() {
        var s = KidSettings.default
        s.maxSessionSeconds = 0
        XCTAssertEqual(s.clamped().maxSessionSeconds, 0)
    }

    func testDefaultSessionLimitIsTenMinutes() {
        XCTAssertEqual(KidSettings.default.maxSessionSeconds, 600)
    }

    func testClampingBounds() {
        var s = KidSettings.default
        s.shuffleInterval = 0.5
        s.audioVolume = 7
        s.maxSessionSeconds = 999_999
        let c = s.clamped()
        XCTAssertEqual(c.shuffleInterval, 10)
        XCTAssertEqual(c.audioVolume, 1)
        XCTAssertEqual(c.maxSessionSeconds, 3600)

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

    // A payload saved by an OLDER app version (missing newer keys) must decode with
    // defaults for the missing fields — never reset the parent's saved settings.
    func testLegacyPayloadDecodesWithDefaults() throws {
        let legacy = Data("""
        {"defaultScene":"Ripples","kidSwitching":false,"energeticEnabled":true,\n         "_note":"energeticEnabled is a retired v1 key and must be ignored",
         "autoShuffle":false,"shuffleInterval":45,"shakeToShuffle":false,
         "audioEnabled":true,"audioVolume":0.5,"intensityCeiling":"calm",
         "maxSessionSeconds":300}
        """.utf8)
        let s = try JSONDecoder().decode(KidSettings.self, from: legacy)
        XCTAssertEqual(s.defaultScene, "Ripples")
        XCTAssertEqual(s.maxSessionSeconds, 300)
        XCTAssertFalse(s.adaptiveContrast)   // new field → its default
    }
}
