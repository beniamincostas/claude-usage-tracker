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

# Create the install script inside DMG — no admin rights required
cat > "${DMG_STAGING}/Install (no admin).command" << 'INSTALL'
#!/bin/bash
set -euo pipefail

APP_NAME="ClaudeUsageTracker"
BUNDLE_ID="com.fiskaly.claude-usage-tracker"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${SCRIPT_DIR}/${APP_NAME}.app"
DEST_DIR="$HOME/Applications"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_DIR}/${BUNDLE_ID}.plist"

echo ""
echo "  Installing ${APP_NAME}..."
echo ""

if [ ! -d "$SOURCE" ]; then
    echo "  Error: ${APP_NAME}.app not found next to this script."
    echo "  Make sure you're running this from the mounted DMG."
    exit 1
fi

# 1. Copy app to ~/Applications
mkdir -p "$DEST_DIR"
pkill -f "${APP_NAME}" 2>/dev/null || true
sleep 0.3
rm -rf "${DEST_DIR}/${APP_NAME}.app"
cp -R "$SOURCE" "${DEST_DIR}/"
xattr -cr "${DEST_DIR}/${APP_NAME}.app" 2>/dev/null || true
echo "  [1/3] Copied to ${DEST_DIR}/${APP_NAME}.app"

# 2. Set up autostart (LaunchAgent)
mkdir -p "${LAUNCH_AGENT_DIR}"
cat > "${LAUNCH_AGENT_PLIST}" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BUNDLE_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DEST_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLISTEOF

launchctl unload "${LAUNCH_AGENT_PLIST}" 2>/dev/null || true
launchctl load "${LAUNCH_AGENT_PLIST}" 2>/dev/null || true
echo "  [2/3] Autostart configured (launches at login)"

# 3. Launch the app now
open "${DEST_DIR}/${APP_NAME}.app"
echo "  [3/3] App launched — check your menu bar!"

echo ""
echo "  Done! No admin rights were needed."
echo ""
echo "  To uninstall later:"
echo "    rm -rf ~/Applications/${APP_NAME}.app"
echo "    launchctl unload ${LAUNCH_AGENT_PLIST}"
echo "    rm ${LAUNCH_AGENT_PLIST}"
echo ""
INSTALL

chmod +x "${DMG_STAGING}/Install (no admin).command"

# Create README
cat > "${DMG_STAGING}/README.txt" << 'README'
ClaudeUsageTracker — Menu Bar Usage Monitor
============================================

Install (no admin rights needed):

1. Open the DMG
2. Open Terminal (Spotlight: Cmd+Space → type "Terminal")
3. Paste this command and press Enter:

   bash "/Volumes/ClaudeUsageTracker/Install (no admin).command"

4. The app installs to ~/Applications, sets up autostart,
   and launches automatically. Look for the usage indicator
   in your menu bar.

Requirements:
- macOS 13+ (Apple Silicon)
- Claude Code installed and logged in

The app reads your Claude Code OAuth token from Keychain
to fetch usage data from the Anthropic API every 2-5 minutes.
No tokens are consumed — it only reads usage metadata.

To uninstall:
- Delete ~/Applications/ClaudeUsageTracker.app
- Run: launchctl unload ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
- Run: rm ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
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
