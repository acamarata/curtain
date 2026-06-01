#!/bin/bash
# Curtain installer — builds the app, installs it as a login menu-bar agent,
# and sets up the (optional) root helper that disconnects a Screen Sharing session.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Curtain.app"
AGENT="$HOME/Library/LaunchAgents/io.acamarata.curtain.plist"
HELPER="/usr/local/bin/curtain-endsession"
SUDOERS="/etc/sudoers.d/curtain-endsession"

echo "==> Building (release)…"
cd "$REPO"
swift build -c release
BIN="$REPO/.build/release/Curtain"

echo "==> Installing $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Curtain"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Curtain</string>
  <key>CFBundleIdentifier</key><string>io.acamarata.curtain</string>
  <key>CFBundleExecutable</key><string>Curtain</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
# Ad-hoc sign so TCC (Accessibility) can pin a stable identity.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> Installing root helper (disconnect Screen Sharing on idle/unlock)…"
TMP_HELPER="$(mktemp)"
cat > "$TMP_HELPER" <<'HELPER'
#!/bin/bash
# Ends the active Screen Sharing session. launchd respawns the listener,
# so Screen Sharing stays available for the next connection.
pkill -f ScreenSharingSubscriber 2>/dev/null
pkill -x screensharingd 2>/dev/null
pkill -f "RemoteManagement.*[Ss]creen" 2>/dev/null
exit 0
HELPER
osascript -e "do shell script \"install -m 755 '$TMP_HELPER' '$HELPER' && printf 'admin ALL=(root) NOPASSWD: $HELPER\n' > '$SUDOERS' && chmod 440 '$SUDOERS' && visudo -cf '$SUDOERS'\" with administrator privileges"
rm -f "$TMP_HELPER"

echo "==> Installing login agent…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.acamarata.curtain</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Curtain</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
launchctl unload "$AGENT" 2>/dev/null || true
launchctl load -w "$AGENT"

cat <<EOF

✅ Curtain installed.

ONE manual step (required so Curtain can block desk input):
  System Settings → Privacy & Security → Accessibility → enable "Curtain".
  Then from the Curtain menu (🔒/👁 in the menu bar): quit & it relaunches at login,
  or run:  launchctl kickstart -k gui/\$(id -u)/io.acamarata.curtain

First-time setup from the menu bar:
  • Set Password…                  (typed at the desk to end a session)
  • Mark Current Externals as DisplayLink  (if you use DisplayLink monitors)
EOF
