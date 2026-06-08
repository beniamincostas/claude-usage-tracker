# Claude Usage Tracker

macOS menu bar app for real-time Claude Code usage monitoring. Shows 5-hour window, 7-day, daily, and monthly usage with alerts at 90% / 95% / 100% thresholds.

**Latest:** v2.0.3 · macOS 13+ (Apple Silicon) · ~2 MB · MIT

[Download v2.0.3](https://github.com/beniamincostas/claude-usage-tracker/releases/latest) · [Changelog](CHANGELOG.md)

## Install

1. Download `ClaudeUsageTracker-v2.0.3.dmg` from [the latest release](https://github.com/beniamincostas/claude-usage-tracker/releases/latest)
2. Open the DMG
3. Open Terminal and run:

   ```sh
   bash /Volumes/ClaudeUsageTracker/Install.command
   ```

The installer puts the app in `~/Applications`, registers a LaunchAgent for autostart, and (if you opt in) installs `statusline.sh` for detailed token tracking.

**Upgrading from a previous version?** Same command — no uninstall needed. The in-app update checker also prompts you when a newer release is published.

## Authentication

On first launch, pick one:

- **Login with Anthropic** (recommended). OAuth 2.0 with PKCE, browser flow, token stored in the app's own Keychain entry and auto-refreshed. Works without Claude Code.
- **Claude Code Keychain** (fallback). Reads Claude Code's OAuth token via `/usr/bin/security`. Requires Claude Code installed and logged in.

Switch anytime from the popover footer.

## What it shows

| Section | Source | Mode |
|---|---|---|
| 5-hour rate limit + countdown | Anthropic OAuth API | always |
| 7-day rate limit + Opus/Sonnet sub-buckets | Anthropic OAuth API | always |
| Extra usage credits (if enabled) | Anthropic OAuth API | always |
| Per-model token breakdowns (Opus, Sonnet, …) | `~/.claude/monthly_usage.json` | Detailed |
| Today + monthly totals + all-time historicals | `~/.claude/monthly_usage.json` | Detailed |

The API is polled every 2 min while you're active, 5 min when idle. **It consumes zero Claude tokens** — it's a metadata endpoint.

## Requirements

| | |
|---|---|
| Simple mode (OAuth) | macOS 13+ Apple Silicon, Anthropic Pro/Max account |
| Detailed token breakdowns | Claude Code CLI installed and logged in, `jq` (`brew install jq`) |

## Build from source

```sh
git clone https://github.com/beniamincostas/claude-usage-tracker.git
cd claude-usage-tracker
./build.sh          # builds, signs ad-hoc, installs to ~/Applications, registers LaunchAgent
./create-dmg.sh     # produces dist/ClaudeUsageTracker-vX.Y.Z.dmg
```

Pure Swift Package Manager, no Xcode project. Uses Command Line Tools (`/Library/Developer/CommandLineTools`) so no Xcode license is needed.

## Uninstall

```sh
pkill ClaudeUsageTracker
launchctl unload ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
rm ~/Library/LaunchAgents/com.fiskaly.claude-usage-tracker.plist
rm -rf ~/Applications/ClaudeUsageTracker.app
```

This does NOT touch `~/.claude/` — your statusline, settings, and historical usage data are preserved.

## Architecture

```
┌─────────────────────┐     ┌──────────────────────┐
│ Anthropic OAuth API │     │ ~/.claude/           │
│ (every 2-5 min)     │     │ monthly_usage.json   │
└─────────┬───────────┘     └──────────┬───────────┘
          │ HTTPS GET                  │ DispatchSource
          │ OAuth or Keychain token    │ file watcher
          ▼                            ▼
┌──────────────────────────────────────────────────┐
│            UsageViewModel (@MainActor)           │
└──────────────────────┬───────────────────────────┘
                       ▼
┌──────────────────────────────────────────────────┐
│ AuthChoiceView (OAuth / Keychain)                │
│ MenuBarLabel → UsagePopoverView (Simple/Detail)  │
└──────────────────────────────────────────────────┘
```

## Security

- OAuth 2.0 with PKCE (SHA-256 challenge), CSRF state validation
- Tokens stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Refresh dedup prevents concurrent token-endpoint requests
- Keychain save failures are surfaced to the UI (v2.0.2+)
- Corrupt `expiresAt` forces a refresh rather than silently using a token whose expiry can't be evaluated (v2.0.2+)
- All HTTPS via system URLSession (TLS 1.2+ enforced by macOS)
- Only one endpoint contacted: `https://api.anthropic.com/api/oauth/usage`
- Failures logged via `os_log` under `com.beniamincostas.ClaudeUsageTracker`
- No data sent to third parties. No tokens consumed. No admin rights required.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Waiting for Claude Code" stuck on OAuth | Fixed in v2.0.2. On v2.0.1: log out + back in. |
| Menu-bar icon missing after install | Check `System Settings → Control Center → Menu Bar Only` — third-party items may be hidden. |
| Token counts show 0 in Detailed mode | Restart Claude Code (`exit` then `claude`). Verify `jq` is on PATH. |
| Session expired (OAuth) | Click "Switch Account" → log in again. |
| `statusline.sh` errors on non-English locale | Fixed in v2.0.2 (forces `LC_NUMERIC=C`). |
| App doesn't start at login | Re-run `bash /Volumes/ClaudeUsageTracker/Install.command` from the DMG. |

## Contributing

Issues and PRs welcome. Branch off `main`, not `master`. Build with `./build.sh` before opening a PR.

## License

MIT. See [CHANGELOG.md](CHANGELOG.md) for the full release history.

---

_Built by Finance Engineering · fiskaly GmbH · [@beniamincostas](https://linkedin.com/in/beniamincostas)_
