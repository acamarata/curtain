#!/bin/bash
# Curtain release pipeline (maintainer-only).
#
# Builds both executables, assembles a distributable Curtain.app with its
# privileged-helper daemon and baked icon, code-signs it, and packages a
# drag-to-Applications .dmg with a checksum.
#
# Default signing is ad-hoc ("-"), which ships today without an Apple Developer
# account. Notarization is env-var-gated: set SIGN_IDENTITY to your Developer ID
# plus a notary credential source (CURTAIN_NOTARY_PROFILE, or the App Store Connect
# API key trio CURTAIN_NOTARY_KEY+CURTAIN_NOTARY_KEY_ID+CURTAIN_NOTARY_ISSUER, or
# CURTAIN_NOTARY_APPLE_ID+CURTAIN_TEAM_ID+CURTAIN_NOTARY_APP_PASSWORD) to
# graduate to a fully notarized build. No script edits required.
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

# Notarization credentials (only consulted when SIGN_IDENTITY is a real Developer
# ID, i.e. not unset and not "-"). Three accepted sources, tried in this order:
#
#   1. CURTAIN_NOTARY_PROFILE — a notarytool keychain profile name, created once
#      via `xcrun notarytool store-credentials`. Most convenient interactively.
#   2. CURTAIN_NOTARY_KEY + CURTAIN_NOTARY_KEY_ID + CURTAIN_NOTARY_ISSUER — an
#      App Store Connect API key (.p8 file path, key ID, issuer UUID).
#   3. CURTAIN_NOTARY_APPLE_ID + CURTAIN_TEAM_ID + CURTAIN_NOTARY_APP_PASSWORD —
#      an Apple ID with an app-specific password.
#
# The API key (2) is preferred over the Apple ID (3) for automation and is the
# right choice for CI: it is a file plus two identifiers, so it drops into GitHub
# Actions secrets cleanly, and it is not tied to an individual Apple ID's
# app-specific password, which is bound to that account's 2FA state and silently
# starts returning "HTTP 401 Invalid credentials" once revoked or regenerated —
# a failure that otherwise only surfaces mid-release, after a full signed build.
# Real values are supplied by the maintainer's environment, never hardcoded here.
CURTAIN_TEAM_ID="${CURTAIN_TEAM_ID:-}"
CURTAIN_NOTARY_PROFILE="${CURTAIN_NOTARY_PROFILE:-}"
CURTAIN_NOTARY_KEY="${CURTAIN_NOTARY_KEY:-}"
CURTAIN_NOTARY_KEY_ID="${CURTAIN_NOTARY_KEY_ID:-}"
CURTAIN_NOTARY_ISSUER="${CURTAIN_NOTARY_ISSUER:-}"
CURTAIN_NOTARY_APPLE_ID="${CURTAIN_NOTARY_APPLE_ID:-}"
CURTAIN_NOTARY_APP_PASSWORD="${CURTAIN_NOTARY_APP_PASSWORD:-}"

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
         "$APP/Contents/Library/LaunchDaemons" \
         "$APP/Contents/Library/LaunchAgents"

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

# Main-app crash-relaunch supervision (T-P1-E08-03). SMAppService.agent(plistName:)
# loads this from Contents/Library/LaunchAgents. KeepAlive.SuccessfulExit=false
# tells launchd to relaunch Curtain ONLY after an abnormal exit (non-zero exit
# status, or death by signal) — a clean `NSApp.terminate` (exit 0) does not
# trigger a relaunch. RunAtLoad is deliberately omitted: launch-at-login remains
# solely LoginItem.swift's job via SMAppService.mainApp; this agent's only job is
# crash supervision of an already-running process, so it must never itself start
# the app at registration/login time (that would double-launch alongside
# LoginItem). See AppSupervisor.swift for the registration call and the
# SMAppService.agent-vs-companion-supervisor decision writeup.
cat > "$APP/Contents/Library/LaunchAgents/$APP_ID.supervisor.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$APP_ID.supervisor</string>
  <key>BundleProgram</key>
  <string>Contents/MacOS/Curtain</string>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
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
# Selected purely by which environment variables are set:
#   - SIGN_IDENTITY unset or "-": ad-hoc build (today's default), no notarization.
#   - SIGN_IDENTITY set to a real Developer ID: requires a notary credential
#     source too (CURTAIN_NOTARY_PROFILE, or the Apple-ID/team-ID/app-password
#     triple). A real identity with no credential source is a half-configured
#     state and fails loudly rather than silently shipping an ad-hoc build under
#     a real signing identity.
if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> WARNING: ad-hoc/unnotarized build. Set SIGN_IDENTITY plus notary credentials (CURTAIN_NOTARY_PROFILE, or CURTAIN_NOTARY_KEY+CURTAIN_NOTARY_KEY_ID+CURTAIN_NOTARY_ISSUER, or CURTAIN_NOTARY_APPLE_ID+CURTAIN_TEAM_ID+CURTAIN_NOTARY_APP_PASSWORD) to produce a notarized release."
else
  NOTARY_AUTH_ARGS=()
  if [[ -n "$CURTAIN_NOTARY_PROFILE" ]]; then
    NOTARY_AUTH_ARGS=(--keychain-profile "$CURTAIN_NOTARY_PROFILE")
  elif [[ -n "$CURTAIN_NOTARY_KEY" && -n "$CURTAIN_NOTARY_KEY_ID" && -n "$CURTAIN_NOTARY_ISSUER" ]]; then
    # Fail here rather than letting notarytool fail after the (slow) upload: a
    # missing .p8 is a typo in the path 100% of the time, and the error it would
    # otherwise produce arrives minutes later and reads like an auth rejection.
    if [[ ! -f "$CURTAIN_NOTARY_KEY" ]]; then
      echo "ERROR: CURTAIN_NOTARY_KEY is set but no file exists at: $CURTAIN_NOTARY_KEY"
      exit 1
    fi
    NOTARY_AUTH_ARGS=(--key "$CURTAIN_NOTARY_KEY" --key-id "$CURTAIN_NOTARY_KEY_ID" --issuer "$CURTAIN_NOTARY_ISSUER")
  elif [[ -n "$CURTAIN_NOTARY_APPLE_ID" && -n "$CURTAIN_TEAM_ID" && -n "$CURTAIN_NOTARY_APP_PASSWORD" ]]; then
    NOTARY_AUTH_ARGS=(--apple-id "$CURTAIN_NOTARY_APPLE_ID" --team-id "$CURTAIN_TEAM_ID" --password "$CURTAIN_NOTARY_APP_PASSWORD")
  else
    echo "ERROR: SIGN_IDENTITY is set to a real Developer ID but no notary credential source is configured."
    echo "       Set one of:"
    echo "         - CURTAIN_NOTARY_PROFILE (a notarytool keychain profile name), or"
    echo "         - CURTAIN_NOTARY_KEY + CURTAIN_NOTARY_KEY_ID + CURTAIN_NOTARY_ISSUER (App Store Connect API key), or"
    echo "         - CURTAIN_NOTARY_APPLE_ID + CURTAIN_TEAM_ID + CURTAIN_NOTARY_APP_PASSWORD."
    echo "       Refusing to ship a real-identity build without notarization (half-configured is worse than ad-hoc)."
    exit 1
  fi

  NOTARIZE_ZIP="$DIST/Curtain-$VERSION-notarize.zip"
  echo "==> Notarizing"
  ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
  xcrun notarytool submit "$NOTARIZE_ZIP" "${NOTARY_AUTH_ARGS[@]}" --wait
  xcrun stapler staple "$APP"
  rm -f "$NOTARIZE_ZIP"
fi
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

# Emit the standard "<hash>  <filename>" two-field format (not a bare hash), and use the
# basename so the sidecar is verifiable with `shasum -a 256 -c Curtain-X.Y.Z.dmg.sha256`
# from whatever directory the user downloaded both files into. A bare hash, or one naming
# this build machine's absolute path, makes the -c verb fail on the end user's machine.
( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

# --- e. Summary --------------------------------------------------------------
echo
echo "==> Done."
echo "    App:      $APP"
echo "    DMG:      $DMG"
echo "    SHA-256:  $(cat "$DMG.sha256")"
echo
echo "==> codesign verify:"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true
echo "==> spctl assessment (ad-hoc/unnotarized will be rejected — expected):"
spctl -a -vv "$APP" 2>&1 | sed 's/^/    /' || true
echo
echo "Note: an ad-hoc build is unnotarized. End users opening the .dmg may need to"
echo "strip the quarantine flag once:  xattr -dr com.apple.quarantine /Applications/Curtain.app"
echo "Enroll in the Apple Developer Program and use the NOTARIZATION SWAP block above to remove that step."
