import XCTest
import CryptoKit
@testable import KiddyproofCore

final class LicenseTests: XCTestCase {

    // A throwaway keypair for tests — signs like the real tool does.
    private let priv = Curve25519.Signing.PrivateKey()
    private var pubB64: String { priv.publicKey.rawRepresentation.base64EncodedString() }

    private func makeKey(email: String = "kid@example.com",
                         date: String = "2026-08-04",
                         plan: String = "pro",
                         tamper: Bool = false) throws -> String {
        let payload = try JSONEncoder().encode(License.Payload(e: email, d: date, p: plan))
        let sig = try priv.signature(for: payload)
        var body = License.base64urlEncode(payload)
        if tamper {
            let flipped = payload + Data(" ".utf8)
            body = License.base64urlEncode(flipped)
        }
        return "KIDDY.\(body).\(License.base64urlEncode(sig))"
    }

    func testValidKeyVerifies() throws {
        let key = try makeKey()
        let payload = License.verify(key: key, publicKeyB64: pubB64)
        XCTAssertEqual(payload?.e, "kid@example.com")
        XCTAssertEqual(payload?.p, "pro")
    }

    func testWhitespaceTolerated() throws {
        let key = "  " + (try makeKey()) + "\n"
        XCTAssertNotNil(License.verify(key: key, publicKeyB64: pubB64))
    }

    func testTamperedPayloadRejected() throws {
        let key = try makeKey(tamper: true)
        XCTAssertNil(License.verify(key: key, publicKeyB64: pubB64))
    }

    func testWrongPublicKeyRejected() throws {
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let key = try makeKey()
        XCTAssertNil(License.verify(key: key, publicKeyB64: other))
    }

    func testGarbageRejected() {
        XCTAssertNil(License.verify(key: "", publicKeyB64: pubB64))
        XCTAssertNil(License.verify(key: "KIDDY.abc", publicKeyB64: pubB64))
        XCTAssertNil(License.verify(key: "NOPE.a.b", publicKeyB64: pubB64))
        XCTAssertNil(License.verify(key: "KIDDY.!!!.???", publicKeyB64: pubB64))
    }

    // Trial math is exercised against an explicit trialDays so these stay
    // meaningful whichever way the paywall switch is set in License.swift.
    func testTrialCountsDown() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(License.trialDaysLeft(firstLaunch: start, now: start, trialDays: 3), 3)
        let day1 = start.addingTimeInterval(86_400 + 60)
        XCTAssertEqual(License.trialDaysLeft(firstLaunch: start, now: day1, trialDays: 3), 2)
        let day3 = start.addingTimeInterval(3 * 86_400 + 60)
        XCTAssertEqual(License.trialDaysLeft(firstLaunch: start, now: day3, trialDays: 3), 0)
    }

    func testForwardDatedFirstLaunchClamped() {
        // A first-launch date in the future must not grant extra days.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(90 * 86_400)
        XCTAssertEqual(License.trialDaysLeft(firstLaunch: future, now: now, trialDays: 3), 3)
    }

    // MARK: Hard paywall (trialDays == 0)

    func testHardPaywallGrantsNoTrialOnFirstLaunch() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(License.trialDaysLeft(firstLaunch: start, now: start, trialDays: 0), 0)
        XCTAssertEqual(License.entitlement(licenseKey: nil, firstLaunch: start, now: start,
                                           publicKeyB64: pubB64, trialDays: 0), .expired)
    }

    func testHardPaywallStillHonoursAValidKey() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let key = try makeKey()
        XCTAssertEqual(License.entitlement(licenseKey: key, firstLaunch: start, now: start,
                                           publicKeyB64: pubB64, trialDays: 0),
                       .licensed(email: "kid@example.com"))
    }

    func testHardPaywallRejectsInvalidKeyWithNoTrialFallback() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(License.entitlement(licenseKey: "KIDDY.bad.key", firstLaunch: start,
                                           now: start, publicKeyB64: pubB64, trialDays: 0),
                       .expired)
    }

    // Guards the shipped configuration itself: this branch must ship with the
    // paywall on. Flipping trialDays back to a positive number should fail here
    // as a deliberate reminder to update the site and Terms copy too.
    func testShippedBuildHasPaywallEnabled() {
        XCTAssertEqual(License.trialDays, 0)
        XCTAssertFalse(License.offersTrial)
    }

    func testEntitlementPrecedence() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let lapsed = start.addingTimeInterval(8 * 86_400)
        // expired without key
        XCTAssertEqual(License.entitlement(licenseKey: nil, firstLaunch: start, now: lapsed,
                                           publicKeyB64: pubB64, trialDays: 3), .expired)
        // licensed overrides lapsed trial
        let key = try makeKey()
        XCTAssertEqual(License.entitlement(licenseKey: key, firstLaunch: start, now: lapsed,
                                           publicKeyB64: pubB64, trialDays: 3),
                       .licensed(email: "kid@example.com"))
        // invalid key falls back to trial state while a trial is on offer
        XCTAssertEqual(License.entitlement(licenseKey: "KIDDY.bad.key", firstLaunch: start,
                                           now: start, publicKeyB64: pubB64, trialDays: 3),
                       .trial(daysLeft: 3))
    }
}
