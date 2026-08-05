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

    func testTrialCountsDown() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(License.trialDaysLeft(firstLaunch: start, now: start), License.trialDays)
        let day3 = start.addingTimeInterval(3 * 86_400 + 60)
        XCTAssertEqual(License.trialDaysLeft(firstLaunch: start, now: day3), License.trialDays - 3)
        let after = start.addingTimeInterval(Double(License.trialDays) * 86_400 + 60)
        XCTAssertEqual(License.trialDaysLeft(firstLaunch: start, now: after), 0)
    }

    func testForwardDatedFirstLaunchClamped() {
        // A first-launch date in the future must not grant extra days.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(90 * 86_400)
        XCTAssertEqual(License.trialDaysLeft(firstLaunch: future, now: now), License.trialDays)
    }

    func testEntitlementPrecedence() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let lapsed = start.addingTimeInterval(Double(License.trialDays + 5) * 86_400)
        // expired without key
        XCTAssertEqual(License.entitlement(licenseKey: nil, firstLaunch: start, now: lapsed,
                                           publicKeyB64: pubB64), .expired)
        // licensed overrides lapsed trial
        let key = try makeKey()
        XCTAssertEqual(License.entitlement(licenseKey: key, firstLaunch: start, now: lapsed,
                                           publicKeyB64: pubB64),
                       .licensed(email: "kid@example.com"))
        // invalid key falls back to trial state
        XCTAssertEqual(License.entitlement(licenseKey: "KIDDY.bad.key", firstLaunch: start,
                                           now: start, publicKeyB64: pubB64),
                       .trial(daysLeft: License.trialDays))
    }
}
