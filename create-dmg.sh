#!/bin/bash
set -euo pipefail

APP_NAME="ClaudeUsageTracker"
BUNDLE_ID="com.fiskaly.claude-usage-tracker"
VERSION="1.2.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build/release"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
DMG_DIR="${SCRIPT_DIR}/dist"
DMG_STAGING="${DMG_DIR}/staging"
DMG_FILE="${DMG_DIR}/${APP_NAME}-v${VERSION}.dmg"

export DEVELOPER_DIR=/Library/Developer/CommandLineTools

echo "=== Building ${APP_NAME} v${VERSION} ==="
cd "$SCRIPT_DIR"
swift build -c release 2>&1

echo ""
echo "=== Creating .app bundle ==="
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Built by Beniamin Costas — linkedin.com/in/beniamincostas — Finance Engineering @ fiskaly GmbH</string>
</dict>
</plist>
PLIST

echo "   Bundle created: ${APP_DIR}"

echo ""
echo "=== Signing .app bundle (ad-hoc) ==="
codesign --force --deep --sign - "${APP_DIR}"
echo "   Signed."

echo ""
echo "=== Creating DMG ==="
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_STAGING}"

# Copy app to staging
cp -R "${APP_DIR}" "${DMG_STAGING}/"

# Symlink to system Applications folder (standard drag-to-install target)
ln -s /Applications "${DMG_STAGING}/Applications"

# Create the install-autostart script inside DMG
cat > "${DMG_STAGING}/Install Autostart.command" << 'INSTALL'
#!/bin/bash
# Sets up ClaudeUsageTracker to launch automatically at login.
# This installs a LaunchAgent — no admin rights required.

set -euo pipefail

APP_NAME="ClaudeUsageTracker"
BUNDLE_ID="com.fiskaly.claude-usage-tracker"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_DIR}/${BUNDLE_ID}.plist"

# Find the app — check both /Applications and ~/Applications
if [ -d "/Applications/${APP_NAME}.app" ]; then
    APP_PATH="/Applications/${APP_NAME}.app"
elif [ -d "$HOME/Applications/${APP_NAME}.app" ]; then
    APP_PATH="$HOME/Applications/${APP_NAME}.app"
else
    echo ""
    echo "  Please drag ${APP_NAME}.app to Applications first!"
    echo ""
    exit 1
fi

mkdir -p "${LAUNCH_AGENT_DIR}"

# Use plistlib for safe XML escaping (handles spaces and special chars in paths)
python3 -c "
import plistlib, sys
plist = {
    'Label': sys.argv[1],
    'ProgramArguments': [sys.argv[2]],
    'RunAtLoad': True,
    'KeepAlive': False,
}
with open(sys.argv[3], 'wb') as f:
    plistlib.dump(plist, f)
" "${BUNDLE_ID}" "${APP_PATH}/Contents/MacOS/${APP_NAME}" "${LAUNCH_AGENT_PLIST}"

# Activate the LaunchAgent immediately (no need to log out/in)
launchctl unload "${LAUNCH_AGENT_PLIST}" 2>/dev/null || true
launchctl load "${LAUNCH_AGENT_PLIST}" 2>/dev/null || true

# Also open the app right now
open "${APP_PATH}"

echo ""
echo "  Done! ${APP_NAME} is running and will auto-start at login."
echo "  To remove autostart: rm ${LAUNCH_AGENT_PLIST}"
echo ""
INSTALL

chmod +x "${DMG_STAGING}/Install Autostart.command"

# Create README
cat > "${DMG_STAGING}/README.txt" << 'README'
ClaudeUsageTracker — Menu Bar Usage Monitor
============================================

Setup (no admin rights needed):

1. Drag ClaudeUsageTracker.app to the Applications folder
2. Double-click "Install Autostart" to set up auto-launch and start the app
3. Look for the usage indicator in your menu bar

First launch: macOS may ask "Are you sure you want to open this?"
 → Click "Open" to confirm.

Requirements:
- macOS 13+ (Apple Silicon)
- Claude Code installed and logged in

The app reads your Claude Code OAuth token from Keychain
to fetch usage data from the Anthropic API every 2-5 minutes.
No tokens are consumed — it only reads usage metadata.

To uninstall:
- Delete /Applications/ClaudeUsageTracker.app
- Run: launchctl unload ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
- Delete ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
README

# Create DMG
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_FILE}"

# Clean up staging
rm -rf "${DMG_STAGING}"

echo ""
echo "=== Done ==="
echo "DMG created: ${DMG_FILE}"
echo ""
ls -lh "${DMG_FILE}"
