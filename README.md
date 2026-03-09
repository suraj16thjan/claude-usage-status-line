# Claude Code Status Bar

A bash script that displays a rich, color-coded status bar for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), showing model info, context window usage, and API rate-limit consumption at a glance.

## Preview

```
● Claude Sonnet 4 in my-project  CTX ━━━━──────── 40%
Current session  Resets in 2 hr 14 min  23% used
  ━━━━──────────────
Weekly limits
Learn more about usage limits
  All models  Resets Wed 3:00 PM  47% used
  ━━━━━━━━──────────
Last updated: 3 minutes ago
```

## What It Shows

The script renders a compact terminal dashboard with the following sections:

**Header line** — the active model name, working directory, and a context-window usage bar with percentage.

**Session usage** — your rolling 5-hour rate-limit utilization, a progress bar, and the time remaining until the window resets.

**Weekly usage** — your rolling 7-day rate-limit utilization across all models, with the reset timestamp shown in local time.

**Extra usage** *(conditional)* — if extra-usage billing is enabled on your account, shows spend vs. monthly limit with its own progress bar.

All bars and percentages are color-coded: green when under 50%, yellow at 50–79%, and red at 80%+.

## How It Works

The script accepts a JSON payload on **stdin** (provided automatically by Claude Code's status-bar hook) containing model metadata, workspace info, and context-window stats.

For rate-limit data it uses two sources, preferring whichever is freshest:

1. **Native fields** — `five_hour`, `seven_day`, and `extra_usage` objects passed in the stdin JSON by newer versions of Claude Code.
2. **Cached API fetch** — the script calls `https://api.anthropic.com/api/oauth/usage` using your locally stored OAuth token, caches the response in `/tmp/.claude_usage_cache`, and refreshes it at most once per minute.

Timezone conversions and ISO-8601 relative-time formatting are handled by small inline Python helpers.

## Requirements

- **bash** 4+
- **jq** — JSON parsing
- **python3** — timezone math and money formatting
- **curl** — API calls (only needed when native usage data isn't supplied)
- **macOS Keychain** *or* `~/.claude/.credentials.json` — OAuth credentials for the API fallback

## Installation

1. Save the script (e.g. as `~/.claude/status_bar.sh`).
2. Make it executable:
   ```bash
   chmod +x ~/.claude/status_bar.sh
   ```
3. Register it as your Claude Code status bar hook. In your Claude Code settings (`.claude/settings.json`), point the status bar command to the script:
   ```json
   {
     "status_bar_command": "~/.claude/status_bar.sh"
   }
   ```

## Configuration

There is nothing to configure beyond installation. The script auto-detects credentials from the macOS Keychain first, then falls back to the JSON credentials file. Cache staleness is hard-coded to 60 seconds.

## License

MIT
