// Seller-side license tool for kiddyproof. NEVER ships with the app.
//
//   swift Scripts/make_license.swift generate-keys
//       Creates secrets/license_private.key (gitignored) and prints the
//       public key to embed in Sources/KiddyproofCore/License.swift.
//
//   swift Scripts/make_license.swift issue customer@example.com
//       Prints a license key for that customer, signed with the private key.
//
// Key format: KIDDY.<base64url payload>.<base64url Ed25519 signature>
// Payload: {"e":email,"d":yyyy-MM-dd,"p":"pro"}
import Foundation
import CryptoKit

let secretsDir = "secrets"
let privatePath = "\(secretsDir)/license_private.key"

func base64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: make_license.swift generate-keys | issue <email>")
    exit(1)
}

switch args[1] {
case "generate-keys":
    if FileManager.default.fileExists(atPath: privatePath) {
        print("REFUSING: \(privatePath) already exists — delete it explicitly if you truly want a new keypair (existing customer keys would stop validating).")
        exit(1)
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(atPath: secretsDir, withIntermediateDirectories: true)
    try key.rawRepresentation.base64EncodedString().write(toFile: privatePath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privatePath)
    print("private key written to \(privatePath) — BACK THIS UP; it is the only copy.")
    print("public key (embed in License.publicKeyB64):")
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "issue":
    guard args.count >= 3 else { print("usage: make_license.swift issue <email>"); exit(1) }
    let email = args[2]
    guard let b64 = try? String(contentsOfFile: privatePath, encoding: .utf8),
          let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        print("no private key at \(privatePath) — run generate-keys first")
        exit(1)
    }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.timeZone = TimeZone(identifier: "UTC")
    let payload = try JSONEncoder().encode(["e": email, "d": df.string(from: Date()), "p": "pro"])
    let sig = try key.signature(for: payload)
    print("KIDDY.\(base64url(payload)).\(base64url(sig))")

default:
    print("unknown command \(args[1])")
    exit(1)
}
