# Beta v2.0 — OAuth + Unified Auth

## Overview

v2.0 adds a proper OAuth login flow. Users authenticate directly with Anthropic via browser — no Keychain reading from other apps. Keychain mode remains as a fallback for users who prefer it.

## Feature Comparison

| Feature | v1.3.0 | v2.0 Beta |
|---------|--------|-----------|
| Auth method | Keychain only | OAuth OR Keychain (user choice) |
| Claude Code required | Yes (for API data) | No (OAuth works independently) |
| Keychain access | Reads another app's token | Stores own tokens |
| Token refresh | Depends on Claude Code | App handles its own (smart refresh) |
| Re-login | Never | Once; auto-refreshes while app runs |
| Token details | Always shown | Toggle (Simple / Detailed) |
| Update check | No | Yes (on launch, from GitHub) |
| Error messages | Basic | Contextual with resolution steps |

## Experience Tiers

**Tier 1 — OAuth + Detailed** (best):
- All percentages, countdowns, alerts + token breakdowns per model
- Needs: OAuth login + Claude Code CLI + jq + statusline

**Tier 2 — OAuth + Simple** (good):
- Percentages, countdowns, alerts, extra usage credits
- Needs: OAuth login only

**Tier 3 — Keychain + Simple** (fallback):
- Same as Tier 2 but uses Claude Code's token
- Needs: Claude Code CLI installed + logged in

## OAuth Flow

1. User clicks "Login with Anthropic"
2. Browser opens to `claude.ai/oauth/authorize` with PKCE challenge
3. User logs in with Anthropic account
4. Browser shows `code#state` string
5. User pastes it into the app
6. App exchanges code for access + refresh tokens
7. Tokens stored in app's own Keychain
8. Smart refresh: sleeps until 5min before expiry, refreshes automatically

## Error Handling

Every error shows: what happened, why, and how to fix it.

### Auth Screen Messages
| Situation | Message |
|-----------|---------|
| Session expired | "Session expired. Please log in again." |
| No saved login | "No saved login found. Please authenticate." |
| Network error | "Cannot reach Anthropic. Check your connection." |
| Fresh launch | No message — just the choice buttons |

### Popover Status Banners
| Situation | Message |
|-----------|---------|
| Keychain 401 | "Token expired — run any prompt in Claude Code to refresh, or switch to OAuth" |
| Keychain no token | "Waiting for Claude Code — run 'claude' in Terminal to log in" |
| Rate limited | Orange dot (silent backoff) |
| Network error | Silent retry |

### Token Details Hints (toggle ON, no data)
| Check | Hint |
|-------|------|
| statusline.sh missing | "Re-run install.sh to set up token tracking" |
| monthly_usage.json missing | "Start a Claude Code session for token data" |
| No usage data | "Waiting for Claude Code session data..." |

## Install Summary

install.sh reports per-step results:
```
  ✓ App installed to ~/Applications
  ✓ Autostart at login
  ✓ Statusline (token tracking)
  ✗ Claude Code settings configured
  ✓ App launched

  Notes:
    - jq not found — token breakdowns need it: brew install jq
```

## Security

- PKCE SHA-256 + CSRF state validation (bare codes rejected)
- Tokens: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Refresh gate: single concurrent refresh allowed
- Network errors preserve tokens (no unnecessary logout)
- Keychain-locked (sleep/wake): waits, doesn't logout
- No debug logging (tokens never on disk)
- Update URLs validated (https + github.com only)
- Error messages truncated (no server data leaked)

## Token Lifecycle

- Access token: ~8 hours (Anthropic default), auto-refreshed before expiry
- Refresh token: valid as long as app is polling (every 2-5 min)
- App fully quit for weeks → refresh token may expire → re-login needed
- Network outage → tokens preserved, retries on recovery

## Files Changed from v1.3.0

### New
- `OAuthManager.swift` — PKCE flow, token exchange, refresh, Keychain storage
- `AuthChoiceView.swift` — auth method selection UI with contextual messages
- `UpdateChecker.swift` — GitHub release version check

### Modified
- `App.swift` — unified auth state (@AppStorage-driven), logout, update check
- `UsageAPIClient.swift` — optional OAuthManager for token source
- `UsageViewModel.swift` — connectOAuth(), stopAndReset(), statusMessage, tokenDataHint
- `UsagePopoverView.swift` — Simple/Detailed toggle, status banner, auth label
- `Components/PeriodUsageView.swift` — hides token pills when totalTokens == 0
- `create-dmg.sh` — resilient install.sh, version 2.0.0-beta
- `statusline.sh` — cleaned dead code (cost columns, unused format vars)

## Testing

### Fresh Install
```bash
bash "/Volumes/ClaudeUsageTracker/install.sh"
```

### Run Beta (alongside v1.3.0)
```bash
open ~/Applications/ClaudeUsageTrackerBeta.app
```

### Test OAuth
1. Click beta icon → "Login with Anthropic"
2. Browser opens → log in → copy code#state
3. Paste → Submit → verify data within 2 min

### Test Keychain
1. Click beta icon → "Use Claude Code Keychain"
2. Approve → verify data appears

### Test Switch
1. Click "Switch Account" in footer
2. Choose other method → verify data

### Test Toggle
1. Click "Simple | Detailed" in header
2. Simple: percentages only, no token pills
3. Detailed: full token breakdowns + today/monthly/all-time

## Branch

`beta/oauth-login` — not merged to main. v1.3.0 on main is untouched.

### Safe Points
- `53b2c81` — before toggle
- `5378c10` — before error handling
- `aac17a4` — before 26-fix review
- `ef2d3f9` — current (all fixes applied)
