# claude-statusline

A rich status line for [Claude Code](https://claude.com/claude-code) — built because the recent updates removed the built-in context indicator.

```
| my-project | Claude Opus 4.7 xhigh+think | ████░░░░░░ 42% 84k/200k | 5h 24% 2h14m · 7d 33% 3d 5h10m | $2.5497
```

## What it shows

| Segment | Description |
|---|---|
| **dir** | Basename of the current working directory |
| **model** | Display name + effort level + `think` if extended thinking is on |
| **context bar** | Unicode progress bar + % + absolute tokens used / total. Auto-detects 200k vs 1M windows from `tokens / %` ratio. |
| **5h** | % of 5-hour rate limit used + time until reset (e.g. `2h14m`). Claude.ai subscribers only, shows after the first API response. |
| **7d** | % of weekly rate limit used + time until reset (e.g. `3d 5h10m`). |
| **$** | Session cost in USD |

Color coding (context %, 5h, 7d):

- 🟢 green `< 50%`
- 🟡 yellow `50–79%`
- 🔴 red `≥ 80%`

Everything except `dir` and `model` is shown only when present in the status line JSON, so you don't see blanks on a fresh session.

## Install

```bash
curl -fsSL git.viniciusragazzi.com.br/statusline | bash
```

Or, if you'd rather inspect first:

```bash
git clone https://github.com/viniciusragazzi/claude-statusline.git
cd claude-statusline
./install.sh
```

The installer:

1. Drops `statusline.sh` into `~/.claude/scripts/`
2. Backs up your `~/.claude/settings.json` (`.bak.<timestamp>`)
3. Adds a `statusLine` field via `jq` — keeps the rest of your settings untouched

**Requires:** `jq`, `bash`, `date` (GNU coreutils). Claude Code already running once so `~/.claude/` exists.

## Uninstall

Edit `~/.claude/settings.json` and remove the `statusLine` block, or restore the `.bak.*` file the installer made.

## How it works (briefly)

Claude Code calls the configured `statusLine.command` with a JSON payload piped to stdin on every render. The script reads:

- `.model.display_name`, `.model.id`
- `.workspace.current_dir`
- `.context_window.used_percentage`
- `.transcript_path` — parsed for the last `input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens` to compute absolute usage
- `.effort.level`, `.thinking.enabled`
- `.rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` — `resets_at` is **Unix epoch seconds**, not ISO 8601 (this is a common gotcha that broke earlier community scripts)
- `.cost.total_cost_usd`

Window size is derived from the live data (`tokens / used_percentage`) and snapped to 200k or 1M, so 1M-context models like `claude-opus-4-6[1m]` show the correct total without hardcoded model lists.

For full details — the JSON contract, percentage computation rules, bug history, testing recipe — see [ARCHITECTURE.md](ARCHITECTURE.md). The official Claude Code statusline spec lives at <https://code.claude.com/docs/en/statusline>.

## License

MIT
