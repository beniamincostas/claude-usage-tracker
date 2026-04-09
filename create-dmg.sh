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
echo "=== Generating app icon ==="
ICON_DIR="${SCRIPT_DIR}/.build/icon"
mkdir -p "${ICON_DIR}"
python3 "${SCRIPT_DIR}/generate-icon.py" "${ICON_DIR}"

echo ""
echo "=== Creating .app bundle ==="
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${ICON_DIR}/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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

# Copy statusline.sh to staging (will be installed to ~/.claude/)
cp "${SCRIPT_DIR}/statusline.sh" "${DMG_STAGING}/statusline.sh"

# Create the install script inside DMG — no admin rights required
cat > "${DMG_STAGING}/install.sh" << 'INSTALL'
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

# Check dependencies
if ! command -v jq &>/dev/null; then
    echo ""
    echo "  ⚠ WARNING: 'jq' is not installed."
    echo "  The app will show rate limit percentages (from API),"
    echo "  but token breakdowns will not work without jq."
    echo ""
    echo "  To install jq:"
    echo "    brew install jq"
    echo ""
    echo "  If you don't have Homebrew:"
    echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo "    brew install jq"
    echo ""
    read -p "  Continue without jq? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "  Install jq first, then re-run this script."
        exit 1
    fi
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
echo "  [2/5] Autostart configured (launches at login)"

# 3. Install statusline.sh for token tracking
CLAUDE_DIR="$HOME/.claude"
STATUSLINE_SRC="${SCRIPT_DIR}/statusline.sh"
STATUSLINE_DEST="${CLAUDE_DIR}/statusline.sh"

if [ -f "$STATUSLINE_SRC" ]; then
    mkdir -p "$CLAUDE_DIR"
    cp "$STATUSLINE_SRC" "$STATUSLINE_DEST"
    chmod +x "$STATUSLINE_DEST"
    echo "  [3/5] Statusline script installed"
else
    echo "  [3/5] Statusline script not found — skipping (token breakdown won't be available)"
fi

# 4. Configure statusline in Claude Code settings.json
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
if command -v python3 &>/dev/null; then
    python3 -c "
import json, os, sys, tempfile
path = sys.argv[1]
sl_path = sys.argv[2]
try:
    with open(path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}
settings['statusLine'] = {'type': 'command', 'command': sl_path}
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
with os.fdopen(tmp_fd, 'w') as f:
    json.dump(settings, f, indent=2)
os.replace(tmp_path, path)
" "$SETTINGS_FILE" "$STATUSLINE_DEST"
    echo "  [4/5] Claude Code settings updated (statusline enabled)"
else
    echo "  [4/5] python3 not found — add statusLine config to ~/.claude/settings.json manually"
fi

# 5. App launched via LaunchAgent (RunAtLoad=true)
echo "  [5/5] App launched — check your menu bar!"

echo ""
echo "  Done! No admin rights were needed."
echo ""
echo "  To uninstall later (paste into Terminal):"
echo "    pkill ${APP_NAME}"
echo "    launchctl unload ${LAUNCH_AGENT_PLIST}"
echo "    rm ${LAUNCH_AGENT_PLIST}"
echo "    rm -rf ~/Applications/${APP_NAME}.app"
echo ""
INSTALL

chmod +x "${DMG_STAGING}/install.sh"

# Create README — named so it's obvious in the DMG
cat > "${DMG_STAGING}/README — NO ADMIN INSTALL.txt" << 'README'
ClaudeUsageTracker — Menu Bar Usage Monitor
============================================

INSTALL (no admin rights needed):

1. Open this DMG
2. Open Terminal (Cmd+Space → type "Terminal" → Enter)
3. Paste this command and press Enter:

   bash "/Volumes/ClaudeUsageTracker/install.sh"

4. Done! Look for the usage indicator in your menu bar.
   The app auto-starts at login.

Requirements:
- macOS 13+ (Apple Silicon)
- Claude Code installed and logged in

The app reads your Claude Code OAuth token from Keychain
to fetch usage data from the Anthropic API every 2-5 minutes.
No tokens are consumed — it only reads usage metadata.

To uninstall (paste into Terminal):

  pkill ClaudeUsageTracker
  launchctl unload ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
  rm ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
  rm -rf ~/Applications/ClaudeUsageTracker.app
README

# Generate background image (arrow pointing app → Applications)
echo "   Generating background image..."
python3 "${SCRIPT_DIR}/generate-dmg-bg.py" "${DMG_STAGING}/.bg.png"

# Create a temporary read-write DMG (need r/w to apply Finder styling)
DMG_RW="${DMG_DIR}/${APP_NAME}-rw.dmg"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDRW \
    -size 10m \
    "${DMG_RW}"

# Detach any stale mounts of this volume name
hdiutil detach "/Volumes/${APP_NAME}" 2>/dev/null || true

# Mount the read-write DMG
DEVICE=$(hdiutil attach "${DMG_RW}" -readwrite -noverify -noautoopen | awk '/Apple_APFS|Apple_HFS/{print $1; exit}')
MOUNT_POINT="/Volumes/${APP_NAME}"
echo "   Mounted at: ${MOUNT_POINT}"

# Move background into hidden .background folder (Finder convention)
mkdir -p "${MOUNT_POINT}/.background"
mv "${MOUNT_POINT}/.bg.png" "${MOUNT_POINT}/.background/bg.png"

# Apply Finder window styling via AppleScript
echo "   Styling DMG window..."
osascript << 'APPLESCRIPT'
tell application "Finder"
    tell disk "ClaudeUsageTracker"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 580}

        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:bg.png"

        -- Row 1: App (left) → Applications (right)
        set position of item "ClaudeUsageTracker.app" to {150, 190}
        set position of item "Applications" to {500, 190}

        -- Row 2: Install script + README (below)
        set position of item "install.sh" to {180, 380}
        set position of item "README — NO ADMIN INSTALL.txt" to {480, 380}

        close
        open
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Ensure .DS_Store is flushed
sync

# Detach
hdiutil detach "${MOUNT_POINT}" -quiet 2>/dev/null || hdiutil detach "${DEVICE}" -force

# Convert to compressed read-only DMG
hdiutil convert "${DMG_RW}" -format UDZO -o "${DMG_FILE}"

# Clean up
rm -f "${DMG_RW}"
rm -rf "${DMG_STAGING}"

echo ""
echo "=== Done ==="
echo "DMG created: ${DMG_FILE}"
echo ""
ls -lh "${DMG_FILE}"
