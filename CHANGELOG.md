# Changelog

## v2.0.3 (2026-06-08)

Bug-fix and statusline-accuracy release. No breaking changes.

### Fixes
- **Duplicate concurrent API polling fixed** — a `stopAndReset()` + `start()` cycle (e.g. OAuth reconnect) let the cancelled old polling loop's deferred cleanup clobber the new loop's task handle, producing two loops polling the API in parallel (faster rate-limiting) and a possible parked-sleep hang. Loop teardown is now generation-guarded, so a superseded loop no longer touches shared state.
- **Stale logout reason cleared on recovery** — a transient `keychainLocked`/`networkError` reason persisted indefinitely and could later surface a misleading "Keychain locked" message on an unrelated 401. It's now cleared on successful token retrieval.

### Statusline
- **In/out tokens no longer jump up and down** — the headline `📥/📤` now shows monotonic per-session cumulative totals instead of the raw `context_window` occupancy (which legitimately falls on compaction and subagent turns).
- **Clean token separation** — `📥 IN` is base input only (cache excluded; `total_input_tokens` is cache-inclusive, so cache is subtracted), `📤 OUT` is output only, and cache is broken out separately as dimmed `✍️ CacheW` / `📖 CacheR`. Each is its own independent per-session cumulative, decoupled from the period/model rebaselining so it never resets mid-session.
- **Reasoning effort shown** — `.effort.level` (low/medium/high/xhigh/max) rendered with a 🧠 badge on the session line.
- **Lock + bar hardening** — stale-lock removal no longer deletes a live lock when `stat` can't read an mtime; `make_bar` coerces empty/non-numeric input to 0; mid-session model switches now attribute the pre-switch delta to the old model instead of discarding it.

### App
- **Current Session panel aligned** — reads the same cumulative base/out/cache figures as the CLI statusline (display-only; no stored history is altered). Period panels (5h/7d/month) are unchanged.

## v2.0.2 (2026-05-18)

Bug-fix and hardening release. No new features, no breaking changes. Internal code review found 12 high-confidence issues across OAuth, the usage view model, and the statusline shell script. All fixed. Plus one user-facing bug discovered during smoke-testing.

### Critical user-facing fix
- **No more "Waiting for Claude Code" after launch on OAuth users** — on a fresh app launch with `authMethod = oauth` already persisted, `OAuthManager` correctly set `isAuthenticated = true` in its initialiser, but the SwiftUI `.onChange(of:isAuthenticated)` only fires on transitions, not on the initial value. As a result `viewModel.connectOAuth(...)` was never called, the `UsageAPIClient` kept its default constructor (no OAuthManager handle), and it fell back to reading the empty `Claude Code-credentials` keychain item — producing the "Waiting for Claude Code" UI hint. Fixed by attaching a `.task` modifier to the `MenuBarExtra` label so the connect step runs once at scene setup, even when `isAuthenticated` was already true at launch.

### OAuth / Keychain
- **Surface keychain save failures** — login no longer pretends to succeed when `SecItemAdd` fails (e.g. locked keychain). The user sees the actual `OSStatus` and `isAuthenticated` stays `false` instead of trapping them in an "authenticated but unusable" state.
- **Corrupt `expiresAt` forces a refresh** — if the persisted expiry value is missing, unparseable, or non-finite (`nan`/`inf`), the app now treats the token as expired and refreshes instead of using a token whose expiry can't be evaluated.
- **Concurrent refreshes are actually deduplicated** — fixed an ownership bug where two near-simultaneous calls to `getAccessToken()` could both start a token-endpoint POST. The follower now rides the owner's `Task`, only the owner persists.
- **No more force-unwraps on constant URLs** — `URLComponents(authorizeURL)!` and `URL(tokenURL)!` replaced with guarded inits so a future typo in the constant becomes a logged error, not a launch-time crash.
- **Background refresh save status is checked** — failures are logged via `os_log` (subsystem `com.beniamincostas.ClaudeUsageTracker`).

### Usage view model
- **Crash-safe trim of percentage-reading buffers** — replaced `removeFirst(count - max)` with `suffix(max)`. Behavior identical at the boundary, immune to a future off-by-one regression.
- **Snapshot-clear logic gated on `isAPIDataFresh`** — previously `apiUsage != nil` was enough to clear the extra-token snapshot. If your API token went stale (network drop, expiry) while above 100%, the snapshot would never clear. Now it only clears when API data is genuinely fresh.
- **JSON parse failures are visible** — corrupted `monthly_usage.json` (half-written by a `statusline.sh` crash) used to silently freeze the UI on stale data. Now logged via `os_log` so the cause is diagnosable.
- **Explicit `@MainActor` on the API polling functions** — were already main-actor-isolated by the enclosing class, but now annotated so the contract survives any future call-site refactor. Removed a now-unnecessary `MainActor.run` hop.
- **One notification per threshold crossing** — when usage jumps from below 90% straight to ≥100% in one tick, all crossed thresholds are now correctly marked as notified (was: only the highest, which could re-fire if value oscillated back through a lower threshold).

### `statusline.sh`
- **Forces `LC_NUMERIC=C`** so percentage parsing works on locales that use `,` as the decimal separator (de_DE, fr_FR, …). Previously these locales hit an `integer expression expected` shell error.
- **Guards against non-macOS execution** — the script uses BSD-only `stat -f %m`; running it on Linux would silently misread the lock age. Exits cleanly with a message instead.
- **Hard `jq` dependency check** at the top, with a `brew install jq` hint. Previously a missing `jq` produced empty output with no diagnostic.
- **Awk `-v` for value passing** — the `DAY_IN`/`CAL_DAY_IN` fallback percentage calculation no longer interpolates shell variables into the awk program source, so a missing field can't become an awk syntax error that cascades into a downstream `[ -gt ]` failure.

### Verification
- Clean `swift build`.
- `bash -n statusline.sh` passes.
- Manual smoke tests: happy path, `LC_NUMERIC=de_DE`, `PATH` without `jq` — all behave as designed.

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
