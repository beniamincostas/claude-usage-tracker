# Changelog

## v2.0.0-beta (2026-04-09)

### New Features
- **OAuth login** — authenticate directly with Anthropic via browser (PKCE flow)
- **Auth choice screen** — pick OAuth or Claude Code Keychain on first launch
- **Switch Account** — change auth method anytime from the popover footer
- **Auth method label** — footer shows "OAuth" or "Keychain" so you know which is active
- **Update checker** — notifies on launch if a newer GitHub release exists, shows changelog

### Improvements
- No Claude Code dependency for API data (OAuth mode)
- Own token storage in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Auto token refresh every 30 min (no manual re-login)
- Refresh gate prevents concurrent refresh races
- Logout properly cancels all polling, watchers, and timers
- connectOAuth cancels old polling before switching token source
- No-token detection bounces user to auth screen (no blank dashboard)
- URL validation on update checker (https + github.com only)
- Error messages truncated (no raw server response leaked to UI)
- Existing refresh token preserved when server omits it in response

### From v1.3.0
- Bundled statusline.sh for token breakdowns
- First-launch consent dialog for Keychain access
- jq and Claude Code CLI dependency checks during install
- Statusline backup before overwriting
- 16 security and logic fixes
- 8 token counting fixes
- Removed inaccurate cost estimates from statusline
- Cleaner model names (stripped "[1m]" suffix)

## v1.3.0 (2026-04-09)

### New Features
- Bundled statusline.sh — token breakdowns work out of the box
- First-launch consent dialog for Keychain access
- jq dependency check during install
- Claude Code CLI check during install
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
