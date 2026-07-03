#!/bin/bash
# Builds, bundles, signs, notarizes, and disk-images kiddyproof.
#
# Usage:
#   Scripts/package.sh                                # unsigned dev bundle + DMG (ad-hoc)
#   SIGN_IDENTITY="Developer ID Application: You (TEAMID)" Scripts/package.sh
#   SIGN_IDENTITY=... NOTARY_PROFILE=kiddyproof Scripts/package.sh   # + notarize + staple
#
#   VERSION=0.2.0 …                                   # override the marketing version
#
# One-time setup for notarization:
#   xcrun notarytool store-credentials kiddyproof --apple-id you@example.com \
#       --team-id TEAMID --password <app-specific-password>
#
# After a release build, publish dist/kiddyproof-<version>.dmg and add an item to
# site/appcast.xml using the EdDSA signature this script prints (sign_update).
#
# IMPORTANT (the Launch-Services silent-disable race, POC step 11): always verify a
# packaged build by launching dist/kiddyproof.app from Finder — NOT from a shell —
# and confirm the health gate refuses to arm until Accessibility is granted to the
# *bundled* app and it is relaunched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD_NUM="$(date +%Y%m%d%H%M)"
DIST="$ROOT/dist"
APP="$DIST/kiddyproof.app"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"
BIN="$ROOT/.build/release"

echo "==> assembling $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/kiddyproof" "$BIN/kiddywatchdog" "$APP/Contents/MacOS/"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

# SwiftPM links Sparkle at @rpath but only embeds the build-dir rpath; point the
# bundled binary at Contents/Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/kiddyproof" 2>/dev/null || true

sign() {
    # Sparkle's nested executables must be signed inside-out (per Sparkle docs),
    # then the watchdog, then the app itself with hardened runtime + entitlements.
    local id="$1" fwk="$APP/Contents/Frameworks/Sparkle.framework"
    codesign -f -s "$id" -o runtime "$fwk/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign -f -s "$id" -o runtime "$fwk/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
    codesign -f -s "$id" -o runtime "$fwk/Versions/B/Autoupdate" 2>/dev/null || true
    codesign -f -s "$id" -o runtime "$fwk/Versions/B/Updater.app" 2>/dev/null || true
    codesign -f -s "$id" -o runtime "$fwk"
    codesign -f -s "$id" -o runtime "$APP/Contents/MacOS/kiddywatchdog"
    codesign -f -s "$id" -o runtime \
        --entitlements "$ROOT/Resources/kiddyproof.entitlements" "$APP"
}

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> signing with: $SIGN_IDENTITY"
    sign "$SIGN_IDENTITY"
    codesign --verify --deep --strict "$APP"
    echo "==> signature OK"
else
    echo "==> no SIGN_IDENTITY — ad-hoc signing (local testing only, will not notarize)"
    sign "-"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> notarizing (profile: $NOTARY_PROFILE)"
    ditto -c -k --keepParent "$APP" "$DIST/kiddyproof.zip"
    xcrun notarytool submit "$DIST/kiddyproof.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$DIST/kiddyproof.zip"
fi

echo "==> building DMG"
STAGE="$DIST/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/kiddyproof-$VERSION.dmg"
hdiutil create -volname "kiddyproof" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "==> done: $DMG"
if [[ -x "$SPARKLE_BIN/sign_update" ]]; then
    echo "==> appcast enclosure attributes (paste into site/appcast.xml):"
    # Reads the EdDSA key from the login keychain — the FIRST run prompts for access
    # and can only be approved interactively; rerun manually if it fails here.
    "$SPARKLE_BIN/sign_update" "$DMG" \
        || echo "(sign_update needs interactive keychain approval — run: $SPARKLE_BIN/sign_update $DMG)"
fi
