# Beta v2.0 — OAuth Authentication

## What's Different from v1.3.0

v1.3.0 reads Claude Code's OAuth token from macOS Keychain. v2.0 adds a proper OAuth login flow — users authenticate directly with Anthropic via browser. No Keychain reading from other apps.

| Feature | v1.3.0 | v2.0 Beta |
|---------|--------|-----------|
| Auth method | Claude Code Keychain only | OAuth login OR Keychain (user choice) |
| Claude Code required | Yes (for API data) | No (OAuth works independently) |
| Keychain access | Reads another app's token | Stores own tokens in own Keychain entry |
| Token refresh | Depends on Claude Code | App handles its own refresh (every 30 min) |
| Re-login frequency | Never (Claude Code handles it) | Once; auto-refreshes as long as app runs |

## OAuth Flow

1. User clicks "Login with Anthropic" in the app
2. Browser opens to `claude.ai/oauth/authorize` with PKCE challenge
3. User logs in with their Anthropic account
4. Browser shows a `code#state` string
5. User pastes it into the app
6. App exchanges code for access + refresh tokens
7. Tokens stored in app's own Keychain (`com.fiskaly.claude-usage-tracker.oauth`)
8. Auto-refresh every 30 min — no manual re-login needed

## Technical Details

### New Files
- `OAuthManager.swift` — PKCE flow, token exchange, refresh, Keychain storage
- `AuthChoiceView.swift` — auth method selection UI
- `UpdateChecker.swift` — GitHub release version check

### Modified Files
- `App.swift` — unified auth state (OAuth + Keychain), logout, update check
- `UsageAPIClient.swift` — optional OAuthManager for token source
- `UsageViewModel.swift` — connectOAuth(), stopAndReset()
- `UsagePopoverView.swift` — Switch Account button, auth method label

### Security
- PKCE with SHA-256 code challenge
- CSRF state validation on code exchange
- Tokens stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Refresh gate prevents concurrent token refresh races
- No-token detection bounces to auth screen
- Update checker validates URLs (https + github.com only)
- Error messages truncated (no server response leaked)

### Token Lifecycle
- Access token: ~1 hour, auto-refreshed every 30 min
- Refresh token: valid as long as there's activity (app polls every 2-5 min)
- Sleep mode (planned): stop polling when Claude is closed, token refreshes only when Claude is active
- Re-login required only after extended inactivity (weeks) with app fully quit

## Testing

### Install Beta
```bash
# Beta runs alongside v1.3.0 as a separate app
open ~/Applications/ClaudeUsageTrackerBeta.app
```

### Test OAuth Flow
1. Click beta menu bar icon
2. Choose "Login with Anthropic"
3. Browser opens — log in
4. Copy the code#state string
5. Paste in the app, click Submit
6. Verify data appears within 2 minutes

### Test Keychain Flow
1. Click beta menu bar icon
2. Choose "Use Claude Code Keychain"
3. Approve the consent dialog
4. Verify data appears

### Test Switching
1. Click "Switch Account" in footer
2. Choose the other auth method
3. Verify data appears with new method

### Test Logout
1. Click "Switch Account"
2. Verify auth choice screen appears
3. Verify no data is being fetched (check menu bar)

## Known Limitations
- Beta uses bundle ID `com.fiskaly.claude-usage-tracker-beta` (separate from v1.3.0)
- OAuth code must be manually pasted (no localhost redirect server)
- Refresh token may expire after weeks of app being fully quit
- Token breakdowns still require Claude Code + statusline + jq (both OAuth and Keychain)

## Branch
`beta/oauth-login` — not merged to main, v1.3.0 on main is untouched.
