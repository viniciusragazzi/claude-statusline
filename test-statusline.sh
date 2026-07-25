#!/bin/bash
# Tests for statusline.sh — focused on how the context window size is decided,
# which is where every bug in this project's history has come from (see
# ARCHITECTURE.md §10).
#
# Run: bash test-statusline.sh

# Overridable so the suite can be pointed at another revision of the script,
# e.g. to confirm it goes red against the version that had the bug:
#   git show HEAD~1:statusline.sh > /tmp/old.sh
#   STATUSLINE=/tmp/old.sh bash test-statusline.sh
SCRIPT="${STATUSLINE:-$(dirname "$0")/statusline.sh}"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

pass=0; fail=0

# Build a fake transcript carrying the token accounting we want.
mk_transcript() {
  local f="$TMPD/transcript-$1.jsonl"
  printf '{"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}\n' \
    "$2" "$3" "$4" > "$f"
  echo "$f"
}

# run <payload-json> -> rendered line with ANSI codes stripped
run() { bash "$SCRIPT" <<< "$1" | sed -E 's/\x1b\[[0-9;]*m//g'; }

check() {
  local name="$1" out="$2" expect="$3"
  if [[ "$out" == *"$expect"* ]]; then
    echo "  PASS  $name"; pass=$((pass+1))
  else
    echo "  FAIL  $name"
    echo "        expected to contain: $expect"
    echo "        got:                 $out"
    fail=$((fail+1))
  fi
}

# Percentages need a NUMERIC comparison: "25%" contains the substring "5%", so
# a naive substring check reports green on a wrong value (this actually
# happened while writing this suite).
check_pct() {
  local name="$1" out="$2" expect="$3"
  local got
  got=$(grep -oE '[0-9]+%' <<< "$out" | head -1 | tr -d '%')
  if [ "$got" = "$expect" ]; then
    echo "  PASS  $name"; pass=$((pass+1))
  else
    echo "  FAIL  $name"
    echo "        expected percentage: $expect"
    echo "        got:                 ${got:-<none>}   ($out)"
    fail=$((fail+1))
  fi
}

echo "== window size =="

# 1. Fresh session on a 1M model: the reported size must be honoured.
t=$(mk_transcript m1 50000 0 0)
out=$(run "$(jq -nc --arg t "$t" '{
  model:{id:"claude-opus-5",display_name:"claude-opus-5"},
  workspace:{current_dir:"/tmp/proj"}, transcript_path:$t,
  context_window:{context_window_size:1000000, used_percentage:5}}')")
check     "1M window renders /1M" "$out" "50k/1M"
check_pct "1M window renders 5%"  "$out" "5"

# 2. Same model, session that switched mid-flight: the live window is still
#    200k. Hardcoding "this model == 1M" would under-report here.
t=$(mk_transcript m2 2 579 84262)
out=$(run "$(jq -nc --arg t "$t" '{
  model:{id:"claude-opus-5",display_name:"claude-opus-5"},
  workspace:{current_dir:"/tmp/proj"}, transcript_path:$t,
  context_window:{context_window_size:200000, used_percentage:42}}')")
check     "switched session keeps 200k" "$out" "84k/200k"
check_pct "switched session shows 42%"  "$out" "42"

# 3. The regression this suite was written for: real window is 1M but
#    used_percentage is stale (computed against 200k). The tokens/% ratio
#    resolves to 200k and inflates the bar to 25%.
t=$(mk_transcript m3 50000 0 0)
out=$(run "$(jq -nc --arg t "$t" '{
  model:{id:"claude-opus-5",display_name:"claude-opus-5"},
  workspace:{current_dir:"/tmp/proj"}, transcript_path:$t,
  context_window:{context_window_size:1000000, used_percentage:25}}')")
check     "stale used_percentage does not win" "$out" "50k/1M"
check_pct "stale used_percentage does not inflate" "$out" "5"

# 4. No used_percentage at all: the size field alone must decide.
t=$(mk_transcript m4 50000 0 0)
out=$(run "$(jq -nc --arg t "$t" '{
  model:{id:"claude-opus-5",display_name:"claude-opus-5"},
  workspace:{current_dir:"/tmp/proj"}, transcript_path:$t,
  context_window:{context_window_size:1000000}}')")
check "size field decides without a percentage" "$out" "50k/1M"

echo "== legacy fallbacks (CLI not sending context_window_size) =="

# 5. [1m] suffix still detected.
t=$(mk_transcript m5 50000 0 0)
out=$(run "$(jq -nc --arg t "$t" '{
  model:{id:"claude-opus-4-7[1m]",display_name:"Claude Opus 4.7"},
  workspace:{current_dir:"/tmp/proj"}, transcript_path:$t,
  context_window:{used_percentage:77}}')")
check "[1m] suffix still maps to 1M" "$out" "50k/1M"

# 6. No signal at all: ratio resolves to the 200k default.
t=$(mk_transcript m6 50000 0 0)
out=$(run "$(jq -nc --arg t "$t" '{
  model:{id:"claude-opus-4-8",display_name:"Opus 4.8"},
  workspace:{current_dir:"/tmp/proj"}, transcript_path:$t,
  context_window:{used_percentage:25}}')")
check "ratio fallback resolves 200k" "$out" "50k/200k"

echo "== model name =="

# 7. Raw model id gets formatted.
t=$(mk_transcript m7 1000 0 0)
out=$(run "$(jq -nc --arg t "$t" '{
  model:{id:"claude-opus-5",display_name:"claude-opus-5"},
  workspace:{current_dir:"/tmp/proj"}, transcript_path:$t,
  context_window:{context_window_size:1000000, used_percentage:1}}')")
check "raw id renders as Opus 5" "$out" "Opus 5"

# 8. An already-friendly display name is left alone.
t=$(mk_transcript m8 1000 0 0)
out=$(run "$(jq -nc --arg t "$t" '{
  model:{id:"claude-opus-4-7",display_name:"Claude Opus 4.7"},
  workspace:{current_dir:"/tmp/proj"}, transcript_path:$t,
  context_window:{context_window_size:200000, used_percentage:1}}')")
check "friendly display name untouched" "$out" "Claude Opus 4.7"

echo
echo "passed: $pass | failed: $fail"
[ "$fail" -eq 0 ]
