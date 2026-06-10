#!/bin/bash
# Curtain local installer (developer convenience — end users drag the .app
# from the .dmg instead). Builds a release Curtain.app and drops it in
# /Applications, ad-hoc signed.
#
# Login-at-login and the optional Screen Sharing disconnect helper are now
# managed from inside the app via SMAppService — this script no longer writes
# a LaunchAgent, a /usr/local/bin helper, or a sudoers rule.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Curtain.app"

# Prefer the full release pipeline (icon, daemon plist, dmg) when present.
if [ -x "$REPO/Scripts/release.sh" ]; then
  echo "==> Building via release pipeline…"
  "$REPO/Scripts/release.sh"
  SRC="$REPO/dist/Curtain.app"
else
  echo "==> Building (release)…"
  cd "$REPO"
  swift build -c release
  TMP_PARENT="$(mktemp -d)"
  trap 'rm -rf "$TMP_PARENT"' EXIT
  SRC="$TMP_PARENT/Curtain.app"
  mkdir -p "$SRC/Contents/MacOS"
  cp "$REPO/.build/release/Curtain" "$SRC/Contents/MacOS/Curtain"
  cp "$REPO/.build/release/CurtainHelper" "$SRC/Contents/MacOS/CurtainHelper"
  codesign --force --options runtime --sign - "$SRC" 2>/dev/null || true
fi

echo "==> Installing $APP …"
rm -rf "$APP"
cp -R "$SRC" "$APP"

echo
echo "✅ Curtain installed to $APP"
echo
echo "Manual step (required so Curtain can block desk input):"
echo "  System Settings → Privacy & Security → Accessibility → enable \"Curtain\"."
echo
echo "Open Curtain, then in its settings:"
echo "  • Open at Login and the optional disconnect daemon are registered from"
echo "    inside the app (SMAppService) — no terminal commands needed."
echo "  • Set a desk password, and mark DisplayLink monitors if you use them."
