#!/bin/bash
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "?"')
model_id=$(echo "$input" | jq -r '.model.id // ""')
dir=$(basename "$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')")
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
thinking=$(echo "$input" | jq -r '.thinking.enabled // empty')
rl_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
rl_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
rl_5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
rl_7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

total=0
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  tokens=$(tac "$transcript" 2>/dev/null | grep -m1 -oE '"input_tokens":[0-9]+' | head -1 | grep -oE '[0-9]+')
  cache_read=$(tac "$transcript" 2>/dev/null | grep -m1 -oE '"cache_read_input_tokens":[0-9]+' | head -1 | grep -oE '[0-9]+')
  cache_creation=$(tac "$transcript" 2>/dev/null | grep -m1 -oE '"cache_creation_input_tokens":[0-9]+' | head -1 | grep -oE '[0-9]+')
  total=$(( ${tokens:-0} + ${cache_read:-0} + ${cache_creation:-0} ))
fi

if [ -n "$used_pct" ] && [ "$total" -gt 0 ] && awk "BEGIN { exit !($used_pct > 0.1) }"; then
  derived=$(awk "BEGIN { printf \"%.0f\", $total / ($used_pct / 100) }")
  if [ "$derived" -gt 500000 ]; then
    max_tokens=1000000
  else
    max_tokens=200000
  fi
elif [[ "$model_id" == *"[1m]"* ]] || [[ "$model_id" == *"-1m"* ]]; then
  max_tokens=1000000
else
  max_tokens=200000
fi

if [ -n "$used_pct" ]; then
  ui=$(printf '%.0f' "$used_pct" 2>/dev/null || echo 0)
  [ "$total" -eq 0 ] && total=$(( max_tokens * ui / 100 ))
else
  if [ "$total" -gt 0 ]; then
    ui=$(awk "BEGIN { printf \"%.0f\", ($total / $max_tokens) * 100 }")
  else
    ui=0
  fi
fi

fmt_tokens() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    awk "BEGIN { printf \"%.1fM\", $n / 1000000 }"
  elif [ "$n" -ge 1000 ]; then
    awk "BEGIN { printf \"%.0fk\", $n / 1000 }"
  else
    echo "$n"
  fi
}

pct_color() {
  local p=$1
  if [ "$p" -ge 80 ]; then echo '\033[0;31m'
  elif [ "$p" -ge 50 ]; then echo '\033[0;33m'
  else echo '\033[0;32m'
  fi
}

fmt_remaining() {
  local ts=$1
  local target
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    target=$ts
  else
    target=$(date -d "$ts" +%s 2>/dev/null) || return
  fi
  [ -z "$target" ] || [ "$target" = "0" ] && return
  local now=$(date +%s)
  local diff=$(( target - now ))
  [ "$diff" -le 0 ] && return
  local d=$(( diff / 86400 ))
  local h=$(( (diff % 86400) / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then
    printf '%dd %dh%02dm' "$d" "$h" "$m"
  elif [ "$h" -gt 0 ]; then
    printf '%dh%02dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

used_str=$(fmt_tokens "$total")
max_str=$(fmt_tokens "$max_tokens")

segments=10
filled=$(( ui * segments / 100 ))
[ "$filled" -gt "$segments" ] && filled=$segments
[ "$filled" -lt 0 ] && filled=0
empty=$(( segments - filled ))

bar=""
for ((i=0; i<filled; i++)); do bar+="█"; done
for ((i=0; i<empty; i++)); do bar+="░"; done

ctx_color=$(pct_color "$ui")

modelinfo="$model"
extras=""
[ -n "$effort" ] && extras+="$effort"
[ "$thinking" = "true" ] && { [ -n "$extras" ] && extras+="+think" || extras="think"; }
[ -n "$extras" ] && modelinfo+=" \033[2m$extras\033[0m"

rlstr=""
if [ -n "$rl_5h" ] || [ -n "$rl_7d" ]; then
  rlstr=" \033[2m|\033[0m "
  if [ -n "$rl_5h" ]; then
    rl5=$(printf '%.0f' "$rl_5h")
    c5=$(pct_color "$rl5")
    rlstr+=$(printf "5h ${c5}%s%%\033[0m" "$rl5")
    if [ -n "$rl_5h_reset" ]; then
      rem=$(fmt_remaining "$rl_5h_reset")
      [ -n "$rem" ] && rlstr+=$(printf " \033[2m%s\033[0m" "$rem")
    fi
  fi
  if [ -n "$rl_7d" ]; then
    rl7=$(printf '%.0f' "$rl_7d")
    c7=$(pct_color "$rl7")
    [ -n "$rl_5h" ] && rlstr+=" \033[2m·\033[0m "
    rlstr+=$(printf "7d ${c7}%s%%\033[0m" "$rl7")
    if [ -n "$rl_7d_reset" ]; then
      rem7=$(fmt_remaining "$rl_7d_reset")
      [ -n "$rem7" ] && rlstr+=$(printf " \033[2m%s\033[0m" "$rem7")
    fi
  fi
fi

if [ -n "$cost" ]; then
  coststr=$(printf ' \033[2m|\033[0m \033[2m$%.4f\033[0m' "$cost")
else
  coststr=''
fi

printf "\033[2m|\033[0m \033[0;36m%s\033[0m \033[2m|\033[0m \033[0;35m%b\033[0m \033[2m|\033[0m ${ctx_color}%s %s%% \033[2m(%s/%s)\033[0m%b%s" \
  "$dir" "$modelinfo" "$bar" "$ui" "$used_str" "$max_str" "$rlstr" "$coststr"
