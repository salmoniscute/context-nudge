#!/bin/bash
# Stop hook: after Claude finishes a turn, nudge when a long session reaches a
# natural stopping point (commit, push, PR) or simply gets very long.
source "$(dirname "$0")/lib.sh"
cn_have_jq || exit 0

input=$(cat)
[ "$(jq -r '.stop_hook_active // false' <<<"$input")" = true ] && exit 0
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
session=$(jq -r '.session_id // "unknown"' <<<"$input" | tr -cd 'A-Za-z0-9_-')
cwd=$(jq -r '.cwd // empty' <<<"$input")

cn_save_effective
cn_save_pointer
a=$(cn_analyze "$transcript") || exit 0
[ "$(jq -r '.ok' <<<"$a")" = true ] || exit 0

SOFT=$(cn_int REMIND_AT_BREAKPOINT 100000)
HARD=$(cn_int REMIND_ALWAYS 200000)
STEP=$(cn_int REMIND_STEP 50000)

ctx=$(jq -r '.ctx' <<<"$a")
bp=$(jq -r '.breakpoint // empty' <<<"$a")

# Per-session memory: when we last reminded, and the largest context seen since.
dir=$(cn_state_dir) || exit 0
state="$dir/$session.json"
last_remind=0; last_seen=0
if [ -f "$state" ]; then
  last_remind=$(jq -r '.last_remind // 0' "$state" 2>/dev/null || echo 0)
  last_seen=$(jq -r '.last_seen // 0' "$state" 2>/dev/null || echo 0)
fi
# Context dropped sharply (/compact): start counting again.
if [ "$ctx" -lt $(( last_seen * 7 / 10 )) ]; then last_remind=0; fi

kind=""
if [ -n "$bp" ] && [ "$ctx" -ge "$SOFT" ]; then kind=breakpoint; fi
if [ -z "$kind" ] && [ "$ctx" -ge "$HARD" ]; then kind=long; fi
if [ -n "$kind" ] && [ "$last_remind" -gt 0 ] && [ "$ctx" -lt $(( last_remind + STEP )) ]; then kind=""; fi

if [ -n "$kind" ]; then last_remind=$ctx; fi
printf '{"last_remind":%s,"last_seen":%s}\n' "$last_remind" "$ctx" > "$state"
# Forget sessions untouched for a week.
find "$dir" -name '*.json' -mtime +7 -delete 2>/dev/null

[ -n "$kind" ] || exit 0

k=$(( ctx / 1000 ))
detail=""
if [ "$(cn_opt UNIT tokens)" = usd ]; then
  total=$(jq -r '.session_cost_s // empty' <<<"$a")
  round=$(jq -r '.round_cost_s // empty' <<<"$a")
  if [ -n "$total" ] && [ "$(jq -r '.cost_partial' <<<"$a")" = true ]; then detail=$(cn_msg money_partial total="$total")
  elif [ -n "$total" ] && [ -n "$round" ] && [ "$round" != "$total" ]; then detail=$(cn_msg money_full total="$total" round="$round")
  elif [ -n "$total" ]; then detail=$(cn_msg money_total total="$total"); fi
fi
if [ -z "$detail" ]; then
  # Only worth saying when the turn re-read the context many times over.
  read_total=$(jq -r '.round_read' <<<"$a")
  if [ "$read_total" -ge $(( ctx * 3 )) ]; then
    detail=$(cn_msg detail_tokens round="$(jq -r '.round_read_s' <<<"$a")")
  fi
fi

if [ "$kind" = breakpoint ]; then
  msg=$(cn_msg breakpoint what="$(cn_msg "what_$bp")" k="$k" detail="$detail")
else
  msg=$(cn_msg long k="$k" detail="$detail")
fi
cn_log remind --arg k "$kind" --arg s "$session" --arg c "$cwd" --argjson x "$ctx" \
  '{kind: $k, session: $s, cwd: $c, ctx: $x}'
cn_emit "$msg"
