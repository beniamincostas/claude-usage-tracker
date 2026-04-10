#!/bin/bash
set -euo pipefail

APP_NAME="ClaudeUsageTracker"
BUNDLE_ID="com.fiskaly.claude-usage-tracker"
VERSION="2.0.1"
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

# Copy statusline.sh as hidden file (referenced by installer, not shown in Finder)
cp "${SCRIPT_DIR}/statusline.sh" "${DMG_STAGING}/statusline.sh"

# Create the install script — .command extension opens Terminal on double-click
cat > "${DMG_STAGING}/Install.command" << 'INSTALL'
#!/bin/bash
# No set -e — we handle errors per step

APP_NAME="ClaudeUsageTracker"
BUNDLE_ID="com.fiskaly.claude-usage-tracker"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${SCRIPT_DIR}/${APP_NAME}.app"
DEST_DIR="$HOME/Applications"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_DIR}/${BUNDLE_ID}.plist"

# Track results for summary
NOTES=()
PASS="✓"
FAIL="✗"
R1="" R2="" R3="" R4="" R5="" R6=""

echo ""
echo "  Installing ${APP_NAME}..."
echo ""

if [ ! -d "$SOURCE" ]; then
    echo "  Error: ${APP_NAME}.app not found next to this script."
    echo "  Make sure you're running this from the mounted DMG."
    exit 1
fi

# Pre-checks (info only, never block)
HAS_CLAUDE=true; HAS_JQ=true
if ! command -v claude &>/dev/null; then
    HAS_CLAUDE=false
    NOTES+=("Claude Code CLI not found — install: npm install -g @anthropic-ai/claude-code && claude")
fi
if ! command -v jq &>/dev/null; then
    HAS_JQ=false
    NOTES+=("jq not found — token breakdowns need it: brew install jq")
fi

# 1. Copy app to ~/Applications (CRITICAL — abort if fails)
mkdir -p "$DEST_DIR"
pkill -f "${APP_NAME}" 2>/dev/null || true
sleep 0.3
rm -rf "${DEST_DIR}/${APP_NAME}.app"
if cp -R "$SOURCE" "${DEST_DIR}/" 2>/dev/null; then
    xattr -cr "${DEST_DIR}/${APP_NAME}.app" 2>/dev/null || true
    R1="$PASS"
else
    R1="$FAIL"
    echo "  $FAIL App copy failed — check disk space and permissions."
    exit 1
fi

# 2. Set up autostart (LaunchAgent)
mkdir -p "${LAUNCH_AGENT_DIR}" 2>/dev/null
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
if launchctl load "${LAUNCH_AGENT_PLIST}" 2>/dev/null; then
    R2="$PASS"
else
    R2="$FAIL"
    NOTES+=("Autostart failed — app works but won't start at login. Re-run install to fix.")
fi

# 3. Install statusline.sh for token tracking
CLAUDE_DIR="$HOME/.claude"
STATUSLINE_SRC="${SCRIPT_DIR}/statusline.sh"
STATUSLINE_DEST="${CLAUDE_DIR}/statusline.sh"

if [ -f "$STATUSLINE_SRC" ]; then
    mkdir -p "$CLAUDE_DIR" 2>/dev/null
    if [ -f "$STATUSLINE_DEST" ] && ! diff -q "$STATUSLINE_SRC" "$STATUSLINE_DEST" &>/dev/null; then
        cp "$STATUSLINE_DEST" "${STATUSLINE_DEST}.backup" 2>/dev/null
    fi
    if cp "$STATUSLINE_SRC" "$STATUSLINE_DEST" 2>/dev/null && chmod +x "$STATUSLINE_DEST"; then
        R3="$PASS"
    else
        R3="$FAIL"
        NOTES+=("Statusline install failed — token breakdowns won't work. Check ~/.claude/ permissions.")
    fi
else
    R3="$FAIL"
    NOTES+=("Statusline script not in DMG — token breakdowns not available.")
fi

# 4. Configure statusline in Claude Code settings.json
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
if command -v python3 &>/dev/null; then
    if python3 -c "
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
" "$SETTINGS_FILE" "$STATUSLINE_DEST" 2>/dev/null; then
        R4="$PASS"
    else
        R4="$FAIL"
        NOTES+=("Settings update failed — add statusLine config to ~/.claude/settings.json manually.")
    fi
else
    R4="$FAIL"
    NOTES+=("python3 not found — add statusLine config to ~/.claude/settings.json manually.")
fi

# 5. Launch app
if [ "$R2" = "$PASS" ]; then
    R5="$PASS"  # LaunchAgent started it via RunAtLoad
else
    # Fallback: open directly
    if open "${DEST_DIR}/${APP_NAME}.app" 2>/dev/null; then
        R5="$PASS"
    else
        R5="$FAIL"
        NOTES+=("Could not launch app — open ~/Applications/${APP_NAME}.app manually.")
    fi
fi

# === Summary ===
echo ""
echo "  $R1 App installed to ~/Applications"
echo "  $R2 Autostart at login"
echo "  $R3 Statusline (token tracking)"
echo "  $R4 Claude Code settings configured"
echo "  $R5 App launched"
echo ""

if [ ${#NOTES[@]} -gt 0 ]; then
    echo "  Notes:"
    for note in "${NOTES[@]}"; do
        echo "    - $note"
    done
    echo ""
fi

echo "  Next steps:"
echo "    1. Click the menu bar icon and choose OAuth or Keychain"
if [ "$HAS_CLAUDE" = true ]; then
    echo "    2. Restart Claude Code for token tracking (exit, then run 'claude')"
fi
echo ""
echo "  To uninstall (paste into Terminal):"
echo "    pkill ${APP_NAME}"
echo "    launchctl unload ${LAUNCH_AGENT_PLIST}"
echo "    rm ${LAUNCH_AGENT_PLIST}"
echo "    rm -rf ~/Applications/${APP_NAME}.app"
echo ""
INSTALL

chmod +x "${DMG_STAGING}/Install.command"

# Create concise README
cat > "${DMG_STAGING}/README.txt" << README
ClaudeUsageTracker v${VERSION}
==============================

INSTALL (paste in Terminal):

  bash /Volumes/ClaudeUsageTracker/Install.command

UNINSTALL:

  pkill ClaudeUsageTracker
  launchctl unload ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
  rm ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
  rm -rf ~/Applications/ClaudeUsageTracker.app

Docs: https://fiskaly.atlassian.net/wiki/spaces/fin/pages/2753200183
GitHub: https://github.com/beniamincostas/claude-usage-tracker
README

# Generate background image (dark theme with install instructions)
echo "   Generating background image..."
python3 "${SCRIPT_DIR}/generate-dmg-bg.py" "${DMG_STAGING}/.bg.png" "${VERSION}"

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
        set icon size of theViewOptions to 64
        set text size of theViewOptions to 11
        set background picture of theViewOptions to file ".background:bg.png"

        -- README (center top)
        set position of item "README.txt" to {330, 130}

        -- Secondary: drag to Applications (requires admin)
        set position of item "ClaudeUsageTracker.app" to {160, 360}
        set position of item "Applications" to {500, 360}

        -- Below visible area (scrollable, not on background)
        set position of item "Install.command" to {200, 520}
        set position of item "statusline.sh" to {460, 520}

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
