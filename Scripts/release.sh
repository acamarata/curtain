#!/bin/bash
# Curtain release pipeline (maintainer-only).
#
# Builds both executables, assembles a distributable Curtain.app with its
# privileged-helper daemon and baked icon, code-signs it, and packages a
# drag-to-Applications .dmg with a checksum.
#
# Default signing is ad-hoc ("-"), which ships today without an Apple Developer
# account. The notarization swap is a single guarded block near the signing
# step: set SIGN_IDENTITY to your Developer ID and uncomment the notarytool
# lines to graduate to a fully notarized build.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"
# Derive a monotonically-increasing build number from the commit count so
# CFBundleVersion never regresses across releases, even on rebuilds of the same tag.
BUILD_INT="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 1)"
APP_ID="io.acamarata.curtain"
HELPER_LABEL="io.acamarata.curtain.helper"
ENTITLEMENTS="$REPO/curtain.entitlements"

# Signing identity. "-" = ad-hoc (ships now). Override with a Developer ID for
# notarized builds, e.g. SIGN_IDENTITY="Developer ID Application: Aric Camarata (TEAMID)".
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILD_DIR="$REPO/.build/release"
DIST="$REPO/dist"
APP="$DIST/Curtain.app"
DMG="$DIST/Curtain-$VERSION.dmg"

echo "==> Curtain release $VERSION (build $BUILD_INT)"

# --- a. Build both executables ------------------------------------------------
echo "==> swift build -c release"
swift build -c release

CURTAIN_BIN="$BUILD_DIR/Curtain"
HELPER_BIN="$BUILD_DIR/CurtainHelper"
[ -x "$CURTAIN_BIN" ] || { echo "ERROR: $CURTAIN_BIN not built"; exit 1; }
[ -x "$HELPER_BIN" ]  || { echo "ERROR: $HELPER_BIN not built"; exit 1; }

# --- b. Assemble Curtain.app --------------------------------------------------
echo "==> Assembling Curtain.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources" \
         "$APP/Contents/Library/LaunchDaemons"

cp "$CURTAIN_BIN" "$APP/Contents/MacOS/Curtain"
cp "$HELPER_BIN"  "$APP/Contents/MacOS/CurtainHelper"

# Privileged helper daemon plist. SMAppService.daemon(plistName:) loads this
# from Contents/Library/LaunchDaemons. BundleProgram is relative to the bundle.
# Placement: Contents/MacOS/ is intentional per launchd.plist(5); both MacOS and
# Contents/Library/LaunchDaemons placements are valid — this repo uses MacOS for
# binary-colocation with the main executable.
cat > "$APP/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HELPER_LABEL</string>
  <key>BundleProgram</key>
  <string>Contents/MacOS/CurtainHelper</string>
  <key>MachServices</key>
  <dict>
    <key>$HELPER_LABEL</key>
    <true/>
  </dict>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>$APP_ID</string>
  </array>
</dict>
</plist>
PLIST

# Bake the icon at build time (the binary is the asset source via --render-icon).
echo "==> Baking app icon"
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/Curtain.iconset"
"$CURTAIN_BIN" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

# Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Curtain</string>
  <key>CFBundleDisplayName</key><string>Curtain</string>
  <key>CFBundleIdentifier</key><string>$APP_ID</string>
  <key>CFBundleExecutable</key><string>Curtain</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleVersion</key><string>$BUILD_INT</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Aric Camarata. MIT License.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# --- c. Code sign ------------------------------------------------------------
# Sign inner-out: the helper binary first, then the app bundle. --options runtime
# opts into the Hardened Runtime; --timestamp requests a secure timestamp (this
# warns under ad-hoc signing and is harmless — a real timestamp lands once a
# Developer ID identity is used).
#
# curtain.entitlements carries NO App Sandbox key: a CGEventTap and a global
# Accessibility client cannot run sandboxed, and Curtain depends on both.
# disable-library-validation is intentionally left OFF (false): Curtain only
# loads Apple-signed frameworks (login.framework, IOKit), which pass library
# validation on their own. The file is comment-free because AMFI's entitlements
# parser rejects XML comments at sign time.
echo "==> Code signing (identity: $SIGN_IDENTITY)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/CurtainHelper" 2>&1 | sed 's/^/    /'
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "ERROR: codesign failed (helper)"; exit 1; }

codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP" 2>&1 | sed 's/^/    /'
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "ERROR: codesign failed (app bundle)"; exit 1; }

# === NOTARIZATION SWAP (when enrolled in the Apple Developer Program) =========
# To graduate to a notarized build:
#   1. Set the identity at invocation:
#        SIGN_IDENTITY="Developer ID Application: Aric Camarata (TEAMID)" ./Scripts/release.sh
#      (the codesign block above already uses $SIGN_IDENTITY and the entitlements
#      file, so no other signing change is needed).
#   2. Uncomment the submit + staple lines below. notarytool needs a stored
#      keychain profile created once with:
#        xcrun notarytool store-credentials curtain-notary \
#          --apple-id "you@example.com" --team-id "TEAMID" --password "<app-specific-pw>"
#
# NOTARY_PROFILE="curtain-notary"
# NOTARIZE_ZIP="$DIST/Curtain-$VERSION-notarize.zip"
# echo "==> Notarizing"
# ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
# xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
# xcrun stapler staple "$APP"
# rm -f "$NOTARIZE_ZIP"
# ==============================================================================

# --- d. Package the .dmg (drag-to-Applications layout) -----------------------
echo "==> Building $DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)/Curtain"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Curtain.app"
ln -s /Applications "$STAGE/Applications"

# hdiutil keeps this dependency-free. create-dmg would give a prettier window,
# but a plain drag layout (app + /Applications symlink) is enough and portable.
hdiutil create -volname "Curtain $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"

# --- e. Summary --------------------------------------------------------------
echo
echo "==> Done."
echo "    App:      $APP"
echo "    DMG:      $DMG"
echo "    SHA-256:  $(cat "$DMG.sha256")  ($(basename "$DMG"))"
echo
echo "==> codesign verify:"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true
echo "==> spctl assessment (ad-hoc/unnotarized will be rejected — expected):"
spctl -a -vv "$APP" 2>&1 | sed 's/^/    /' || true
echo
echo "Note: an ad-hoc build is unnotarized. End users opening the .dmg may need to"
echo "strip the quarantine flag once:  xattr -dr com.apple.quarantine /Applications/Curtain.app"
echo "Enroll in the Apple Developer Program and use the NOTARIZATION SWAP block above to remove that step."
