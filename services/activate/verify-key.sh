#!/usr/bin/env bash
# Mints a key with the service's own signing code and checks it against the
# app's real License.swift. Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/../.."

[ -f secrets/license_private.key ] || { echo "no secrets/license_private.key"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

node -e '
  const { issueAppKey } = require("./services/activate/license");
  const fs = require("fs");
  const seed = fs.readFileSync("secrets/license_private.key", "utf8").trim();
  fs.writeFileSync(process.argv[1], issueAppKey("verify@kiddyproof.app", seed));
' "$tmp/key.txt"

cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
let key = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let payload = License.verify(key: key) else {
    print("FAIL: License.verify rejected the minted key"); exit(1)
}
print("ok  verify      -> e=\(payload.e) d=\(payload.d) p=\(payload.p)")
let lapsed = Date(timeIntervalSinceNow: -86_400 * 90)
guard case .licensed(let email) = License.entitlement(licenseKey: key, firstLaunch: lapsed) else {
    print("FAIL: a lapsed trial with this key is not .licensed"); exit(1)
}
print("ok  entitlement -> licensed(\(email))")
var parts = key.split(separator: ".").map(String.init)
parts[1] = String(parts[1].dropLast()) + (parts[1].hasSuffix("A") ? "B" : "A")
guard License.verify(key: parts.joined(separator: ".")) == nil else {
    print("FAIL: a tampered key verified"); exit(1)
}
print("ok  tampered key rejected")
SWIFT

swiftc -O Sources/KiddyproofCore/License.swift "$tmp/main.swift" -o "$tmp/verify"
"$tmp/verify" "$tmp/key.txt"
echo "all good"
