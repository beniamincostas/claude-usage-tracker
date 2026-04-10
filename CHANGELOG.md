# Changelog

## v2.0.1 (2026-04-10)

### UI Fixes
- **White text for buttons & toggles** — "Switch Account", "Quit", "Cancel", and Simple/Detailed picker now readable on dark background
- **Escalating progress bar colors** — distinct colors at each threshold: 90% light red, 95% stronger red, 100% vivid red
- **Fixed grey bar override** — bars no longer turn grey when data is stale; danger colors always show through
- **Version label in footer** — shows current version (e.g. v2.0.1) next to the Quit button

### DMG Installer
- **Dark fiskaly-themed DMG** — background matches app design with teal accents and branding
- **Install.command** — double-click opens Terminal and runs the installer (no manual paste needed)
- **Command-line first** — install command shown on background, drag-to-Applications as secondary option
- **Hidden statusline** — .statusline.sh bundled as hidden file, auto-installed by Install.command
- **Admin rights note** — drag-to-Applications section notes admin requirement
- **Removed verbose README** — install script output provides all setup info

### Fixes
- **Update checker version** — currentVersion now matches release tag (no false update alerts)

## v2.0.0 (2026-04-09)

## v2.0.0-beta (2026-04-09)

### New Features
- **OAuth login** — authenticate directly with Anthropic via browser (PKCE flow)
- **Auth choice screen** — pick OAuth or Claude Code Keychain on first launch
- **Switch Account** — change auth method anytime from the popover footer
- **Simple / Detailed toggle** — segmented control to show/hide token breakdowns
- **Token data hints** — contextual messages when Details is ON but data is missing
- **Status banners** — runtime error messages in the popover (expired token, missing CLI, etc.)
- **Update checker** — notifies on launch if a newer GitHub release exists with changelog
- **Auth method label** — footer shows "OAuth" or "Keychain"

### Security
- PKCE with SHA-256 code challenge + CSRF state validation (rejects bare codes)
- Own token storage in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Refresh gate prevents concurrent token refresh races
- Network errors preserve refresh tokens (no unnecessary session loss)
- Keychain-locked detection (sleep/wake) waits instead of logging out
- No debug logging in production (tokens never written to disk)
- Update checker validates URLs (https + github.com only)
- Error messages truncated (no server response leaked to UI)

### Install
- Resilient install.sh with per-step ✓/✗ summary
- Pre-checks for Claude Code CLI and jq (info only, never block)
- Specific resolution commands for each missing dependency
- Fallback app launch if LaunchAgent fails

### Improvements
- Smart token refresh — sleeps until actual expiry, not fixed 30min
- OAuth users get active polling rate (was blocked by keychainApproved check)
- logout() clears all auth state including authMethod
- connectOAuth cancels old polling before switching token source
- stopAndReset cleans up all watchers, timers, and polling tasks
- Cached ISO8601DateFormatter for countdown functions
- Reactive auth method label via @AppStorage
- Cleaned dead code: debug logging, cost columns, unused format variables

### From v1.3.0
- Bundled statusline.sh for token breakdowns
- 16 security and logic fixes
- 8 token counting fixes
- Removed inaccurate cost estimates from statusline
- Cleaner model names and statusline display

## v1.3.0 (2026-04-09)

### New Features
- Bundled statusline.sh — token breakdowns work out of the box
- First-launch consent dialog for Keychain access
- jq and Claude Code CLI dependency checks during install
- Statusline backup before overwriting
- Restart reminder after install

### Bug Fixes
- 16 security and logic fixes (consent bypass, FileWatcher race, atomic writes, etc.)
- 8 token counting fixes (session eviction, model-switch double-count, spurious resets)
- Fix double-launch on install
- Fix uninstall instructions

### Improvements
- Removed inaccurate cost estimates from statusline
- Cleaner statusline display (5h + 7d rows only)
- Cleaner model names (stripped "[1m]" suffix)
- Expanded DMG README with full install guide

## v1.2.0 (2026-04-08)

### Initial Release
- Menu bar usage monitoring with 5h/7d/monthly views
- Anthropic OAuth API integration
- Per-model token breakdowns (Opus, Sonnet)
- Alert notifications at 90/95/100%
- Styled DMG with Terminal-based install
- Custom app icon
