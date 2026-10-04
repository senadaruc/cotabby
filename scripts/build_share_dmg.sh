#!/usr/bin/env bash
# build_share_dmg.sh - build a DMG of this checkout to give to other people.
#
# What it builds: the "Cotabby Dev" app, Release configuration. The Dev variant on purpose: it
# compiles Sparkle out (COTABBY_DEV), so a shared custom build never replaces itself with the
# upstream release from the official appcast, and it installs next to an official Cotabby.
#
# How it signs: Developer ID Application with the hardened runtime and the app's entitlements
# (Cotabby.entitlements), nested code re-signed inside-out as the release workflow does. Then:
#   - with a working notarytool keychain profile (default "cotabby-notary"), the DMG is notarized
#     and stapled, and opens on any Mac without warnings;
#   - without one, the DMG is still signed, and the first open on another Mac needs
#     System Settings > Privacy & Security > "Open Anyway".
#
# Unlike kickstart.sh it changes nothing on this Mac: no permission resets, no preferences, no
# Application Support (memory and models stay). The archived app is unregistered from Launch
# Services afterwards so this Mac keeps opening the installed copy.
#
# Usage: bash scripts/build_share_dmg.sh [--no-notarize]
#   COTABBY_SHARE_IDENTITY   signing identity (default: the first "Developer ID Application")
#   COTABBY_NOTARY_PROFILE   notarytool keychain profile (default: cotabby-notary)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
OUT_DIR="$REPO_ROOT/build/share"
VENV_DIR="/tmp/Cotabby-dmg-venv"
PROFILE="${COTABBY_NOTARY_PROFILE:-cotabby-notary}"
notarize=true
[[ "${1:-}" == "--no-notarize" ]] && notarize=false

note() { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

identity="${COTABBY_SHARE_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[[ -n "$identity" ]] || { echo "No Developer ID Application identity in the keychain." >&2; exit 1; }
team_id="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$identity")"
note "signing as: $identity"

version="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
version="${version:-0.0.0}-$(git rev-parse --short HEAD)"
archive="$OUT_DIR/CotabbyDev.xcarchive"
dmg="$OUT_DIR/Cotabby-Dev-$version.dmg"
rm -rf "$archive" "$dmg" "$OUT_DIR/DerivedData"
mkdir -p "$OUT_DIR"

step "Building Cotabby Dev $version"
"$REPO_ROOT/scripts/prepare_cotabby_workspace.sh"
xcodebuild archive \
    -workspace "$REPO_ROOT/build/cotabby-dependencies/Cotabby.xcworkspace" \
    -scheme "Cotabby Dev" \
    -configuration Release \
    -archivePath "$archive" \
    -derivedDataPath "$OUT_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team_id" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    MARKETING_VERSION="$version" \
    -quiet
app="$archive/Products/Applications/Cotabby Dev.app"

step "Signing"
# Inside-out, as the release workflow does: Xcode can leave Sparkle's helpers ad-hoc signed, and
# notarization rejects any ad-hoc code inside a Developer ID app. The app keeps its entitlements.
frameworks="$app/Contents/Frameworks"
for code in \
    "$frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "$frameworks/Sparkle.framework/Versions/B/Updater.app" \
    "$frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
    "$frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
    "$frameworks/Sparkle.framework" \
    "$frameworks/llama.framework"; do
    [[ -e "$code" ]] && codesign --force --options runtime --timestamp --sign "$identity" "$code"
done
codesign --force --options runtime --timestamp --sign "$identity" \
    --entitlements "$REPO_ROOT/Cotabby/Cotabby.entitlements" "$app"
codesign --verify --deep --strict "$app"

step "Packaging"
[[ -x "$VENV_DIR/bin/python3" ]] || python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python3" -c "import dmgbuild" 2>/dev/null \
    || "$VENV_DIR/bin/python3" -m pip install --quiet "dmgbuild[badge_icons]>=1.6.0"
"$VENV_DIR/bin/python3" "$REPO_ROOT/scripts/build_release_dmg.py" \
    --app-path "$app" \
    --output-path "$dmg" \
    --background-path "$REPO_ROOT/assets/release/dmg_background.png" \
    --background-2x-path "$REPO_ROOT/assets/release/dmg_background@2x.png" \
    --volume-name "Cotabby Dev"
codesign --force --sign "$identity" --timestamp "$dmg"
codesign --verify --strict "$dmg"

# Launch Services registered the archived app; this Mac should keep opening the installed one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" || true

if $notarize && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    step "Notarizing (usually a few minutes)"
    xcrun notarytool submit "$dmg" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
    note "notarized: opens on any Mac without warnings"
else
    $notarize && note "notarytool profile \"$PROFILE\" is not usable; the DMG is signed but not notarized"
    note "on another Mac, the first open needs System Settings > Privacy & Security > Open Anyway"
fi

rm -rf "$OUT_DIR/DerivedData"
step "DMG ready: $dmg"
