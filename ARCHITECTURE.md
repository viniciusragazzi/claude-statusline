# Architecture

This document explains how `statusline.sh` works internally, the contracts it depends on, and the bugs we've hit along the way. It exists so future contributors (including future me) can change things without re-learning the gotchas.

If you only want to **use** the statusline, see [README](README.md). If you want to **modify** it or build something similar, this is the right place.

---

## 1. Overview

`statusline.sh` is a single bash script that Claude Code invokes on every render. It reads a JSON payload from stdin, parses the fields it cares about, and prints a single colored line to stdout. That line becomes the status line shown below the prompt.

Key constraints:

- **stdin-driven** — Claude Code pipes JSON in; we don't fetch anything ourselves
- **single-shot** — fires on every prompt render, must be fast (<200ms ideal)
- **bash + jq only** — no language runtime, no dependencies beyond what comes with a typical dev box
- **idempotent** — same input always produces same output, no side effects

---

## 2. Status line JSON contract

Claude Code provides these fields on stdin (only the ones we care about):

| Path | Type | Meaning |
|------|------|---------|
| `.model.display_name` | string | Human-readable model name (e.g. `Claude Opus 4.7`) |
| `.model.id` | string | Model identifier — may include suffixes like `[1m]` or `-1m` indicating context window |
| `.workspace.current_dir` | string | Absolute path of cwd |
| `.cwd` | string | Fallback for current dir |
| `.context_window.used_percentage` | number | Claude's report of % context consumed |
| `.transcript_path` | string | Path to the session's JSONL transcript file |
| `.effort.level` | string | `low`/`medium`/`high`/`xhigh`/`max` — only present on reasoning models |
| `.thinking.enabled` | boolean | Whether extended thinking is on |
| `.rate_limits.five_hour.used_percentage` | number | % of 5-hour subscription window used |
| `.rate_limits.five_hour.resets_at` | number | **Unix epoch seconds** when 5h window resets |
| `.rate_limits.seven_day.used_percentage` | number | % of weekly window used |
| `.rate_limits.seven_day.resets_at` | number | **Unix epoch seconds** when 7d window resets |
| `.cost.total_cost_usd` | number | Session cost in USD |
| `.worktree.name` | string | Worktree slug, only present in `--worktree` sessions |
| `.worktree.branch` | string | Git branch backing the worktree (often same as name) |

**Upstream reference:** Anthropic's official Claude Code statusline docs are at <https://code.claude.com/docs/en/statusline>. They cover the supported fields, the command interface, and how to wire a script into `settings.json`. Read those first if you're new to Claude Code statuslines.

**Why this doc still exists:** in practice we hit several cases where the official docs were incomplete or out of date — `resets_at` documented as ISO 8601 but actually epoch seconds (§6), and `used_percentage` behavior after a window switch isn't covered at all (§9). The field list above was cross-checked against the actual binary at `/root/.local/share/claude/versions/<version>` via `strings` — when the binary disagreed with the docs, the binary won.

---

## 3. Token counting from transcript

`context_window.used_percentage` alone isn't enough — we want absolute token counts (`84k/200k`). Claude Code doesn't ship token totals in the status line JSON, so we derive them from the **transcript file**.

The transcript is JSONL; each line is one event. We grab the last message's API token accounting:

```bash
tokens=$(tac "$transcript" | grep -m1 -oE '"input_tokens":[0-9]+' | head -1 | grep -oE '[0-9]+')
cache_read=$(tac "$transcript" | grep -m1 -oE '"cache_read_input_tokens":[0-9]+' | head -1 | grep -oE '[0-9]+')
cache_creation=$(tac "$transcript" | grep -m1 -oE '"cache_creation_input_tokens":[0-9]+' | head -1 | grep -oE '[0-9]+')
total=$(( ${tokens:-0} + ${cache_read:-0} + ${cache_creation:-0} ))
```

Why `tac | grep -m1`: we want the **last** occurrence (latest message). Reversing the file and stopping at first match is faster than scanning all lines.

Why sum all three: a single API request reports input as three buckets (new, cache-read, cache-created). The sum approximates "current context in flight." For a long conversation, this number is close to the real context size because each request re-sends the whole conversation as input (mostly cache-read).

When the transcript file is missing or unparseable, `total` stays `0`. The display logic respects that (§5).

---

## 4. Window size detection

Opus has two context window sizes: 200k (default) and 1M (opt-in via `claude-opus-4-*[1m]` or `-1m` suffix). We need to know which one is active to render the bar correctly.

Detection order (first match wins):

```
1. model_id contains [1m] or -1m  →  max_tokens = 1M
2. derived = total / (used_pct/100)
   if derived > 500k                →  max_tokens = 1M
   else                             →  max_tokens = 200k
3. (no signal)                      →  max_tokens = 200k (assume default)
```

**Why model_id wins over derived:** the user explicitly chose a window via configuration. The derived ratio can lag behind reality (see §9 bug history) — model_id is authoritative.

The 500k threshold for derived is arbitrary but safe: any ratio that puts the inferred max above 500k is almost certainly 1M (no 200k session has ratios that would imply 500k+).

---

## 5. Percentage display

Two sources of truth compete:

- `context_window.used_percentage` — what Claude Code reports
- `total / max_tokens` — what we compute from transcript + detected window

We **prefer the computed value when we have real transcript data** because Claude's `used_pct` can be stale after a window switch (§9). Only when the transcript is empty/missing do we fall back to Claude's number.

```
if total > 0:   ui = round(total / max_tokens * 100)
elif used_pct:  ui = round(used_pct)
else:           ui = 0
```

---

## 6. Rate limits & reset times

For Claude.ai subscribers (Pro/Max), Claude Code surfaces both windows:

- `five_hour` — rolling 5-hour usage
- `seven_day` — rolling weekly usage

The reset timestamp is **Unix epoch seconds (number)**, not ISO 8601. This tripped up earlier community statusline scripts because it's not in the official docs. We confirmed by `strings` on the binary.

For display, we compute `target - now` and format:

- `≥1 day`: `3d 5h10m`
- `≥1 hour`: `2h14m`
- `<1 hour`: `45m`

Negative diffs (already reset) are suppressed.

---

## 7. Token display fallback

When `total > 0` we show `used/max` (e.g. `84k/200k`).
When `total == 0` we show only `max` (e.g. `1M`) — no fake "used" number.

The previous version synthesized `total = max * pct / 100` as a fallback, but this produces garbage after a window switch (see §9 bug-2). Honest absence beats fake precision.

---

## 8. Display rendering

Single `printf` with ANSI color codes. Sections separated by dim `|`:

```
| dir | model effort+think | bar% used/max | 5h X% NhMm · 7d Y% Nd NhMm | $cost
```

Colors by `pct_color()` thresholds:

- `< 50%` → green
- `50–79%` → yellow
- `≥ 80%` → red

Same thresholds apply to context %, 5h %, and 7d %. Consistency over precision.

The bar uses 10 segments of `█` (filled) and `░` (empty). Rounding mode is floor (truncate). So 19% shows `█░░░░░░░░░`, not `██░░░░░░░░`.

---

## 9. Known gotchas

### Claude Code's `used_percentage` can be stale after a window switch

When the user changes context window mid-session (e.g. via `/1m` command or settings change), Claude Code may continue reporting the old `used_percentage` for one or more renders before recomputing. If you echo that value blindly, the displayed % is wrong (see §10 bug-2).

**Mitigation:** compute % from `total / max_tokens` when we have transcript data.

### `resets_at` is epoch seconds, not ISO 8601

Official docs (and at least one community blog post) say ISO 8601. The binary's docstring says number. The binary is right. Always treat as integer Unix timestamp.

### Transcript may not have token info for the very first message

On a fresh session before any API round-trip completes, the transcript might be empty or only contain user-side events without `input_tokens`. Our code handles `total = 0` gracefully (display max-only).

### `model.id` format varies

Seen forms: `claude-opus-4-7`, `claude-opus-4-6[1m]`, `claude-opus-4-7-1m`. Both `[1m]` and `-1m` indicate 1M context. We match both.

### Bunny Fonts CDN can be slow on first render

Not strictly a statusline issue (the docs page uses Bunny Fonts) but worth noting: first render of a page from a clean cache takes ~200-400ms longer than subsequent renders due to font load. Statusline itself uses zero external assets — no CDN dependency.

### GitHub Pages `https_enforced` won't accept boolean as string

When enabling HTTPS via `gh api -X PUT pages -f https_enforced=true`, `-f` sends the value as a string and the API returns 422. Use `-F https_enforced=true` (capital F = real type). Saved in memory `github-pages-cert-kick`.

### Pages cert provisioning can stall silently

GitHub's Let's Encrypt automation occasionally takes 15-30 min instead of the typical 2-5. Toggling the custom domain via API (clear cname → wait 15s → re-set cname) kicks the workflow loose. Memory `github-pages-cert-kick` has the full recipe.

---

## 10. Bug history

### bug-1 — token count synthesized from used_pct when transcript was empty
*Commit: `fix: don't synthesize token count when transcript is empty` (2026-05-14)*

When transcript parse returned `total = 0`, we backfilled with `total = max_tokens * used_pct / 100`. With `max_tokens = 1M` and `used_pct = 77`, that produced `total = 770000`, displayed as `770k/1M @ 77%`. The 770k was fake — the actual session had way fewer tokens.

**Fix:** removed the backfill. When `total = 0`, display only the max window size (`77% 1M`), not synthetic tokens.

### bug-2 — percentage was echoed from stale `used_pct` after window switch
*Commit: `fix: compute % from real tokens / max, not stale used_pct` (2026-05-14)*

When a user switched their session from 200k to 1M context, Claude Code continued reporting `used_percentage = 77` for at least one render — even though `total / 1M` was only ~15%. We were echoing that stale value, producing wildly wrong displays.

**Also fixed in same commit:** detection of window size prioritized the `derived` ratio over `model.id`. When `used_pct` was stale, `derived = total / used_pct` resolved to ~200k, overriding the explicit `[1m]` in `model.id`. Now `model.id` wins; `derived` is only consulted when `model.id` is silent.

Both bugs were reported by a friend of [@euviniciusragazzi](https://www.instagram.com/euviniciusragazzi/) after switching Opus 4.7 to 1M mid-session.

---

## 11. Testing

There's no automated test suite yet — bash + integration with Claude Code makes harness setup non-trivial. Manual testing recipe:

```bash
# Fake a Claude Code render
echo '<json payload>' | bash /root/.claude/scripts/statusline.sh
```

Useful test payloads:

```bash
# 200k mode, mid-session
echo '{
  "model":{"display_name":"Claude Opus 4.7","id":"claude-opus-4-7"},
  "workspace":{"current_dir":"/tmp/test"},
  "context_window":{"used_percentage":42},
  "transcript_path":"/tmp/fake-transcript.jsonl"
}' | bash statusline.sh

# 1M mode, right after switch (stale used_pct, real tokens still low)
echo '{
  "model":{"display_name":"Claude Opus 4.7","id":"claude-opus-4-7[1m]"},
  "workspace":{"current_dir":"/tmp/test"},
  "context_window":{"used_percentage":77},
  "transcript_path":"/tmp/fake-transcript.jsonl"
}' | bash statusline.sh
# Expected: "15% 152k/1M" (computed from actuals, not stale 77%)

# No transcript available
echo '{
  "model":{"display_name":"Claude Opus 4.7","id":"claude-opus-4-7[1m]"},
  "workspace":{"current_dir":"/tmp/test"},
  "context_window":{"used_percentage":77}
}' | bash statusline.sh
# Expected: "77% 1M" (no fake tokens)
```

Where `/tmp/fake-transcript.jsonl` contains a line like:

```json
{"input_tokens":2000,"cache_read_input_tokens":148000,"cache_creation_input_tokens":2000}
```

Before merging a change, run all three scenarios mentally (or actually) and confirm output makes sense.

---

## 12. Design principles

These are the rules we keep coming back to. When in doubt:

- **Trust ground truth over reported values.** Claude's JSON is a hint; the transcript is closer to fact. Compute when possible.
- **Honest absence beats fake precision.** If we don't know something, show that we don't know. Don't synthesize.
- **The status line shouldn't lie.** Every number on screen must be derivable from real data. No vibes-based defaults.
- **Match what Claude Code actually does, not what the docs say.** When the binary disagrees with the docs, the binary wins. `strings $(which claude)` is your friend.
- **Keep it bash + jq.** Adding a language runtime is a slippery slope. Every install becomes harder.

---

## 13. References

- **Claude Code statusline docs** — <https://code.claude.com/docs/en/statusline> · official spec for the JSON contract, command interface, and `settings.json` wiring
- **`/statusline` slash command** — type `/statusline` in any Claude Code session to launch the official interactive setup agent. It reads your shell PS1, asks what fields you want, and writes a custom `statusline-command.sh` + updates `settings.json`. Use it as an **alternative starting point** if you want to roll your own from scratch instead of forking this script.
- **Claude Code changelog** — <https://code.claude.com/docs/en/changelog> · check here when behavior changes between versions
