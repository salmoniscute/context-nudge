#!/bin/bash
# Status line: model, context size against the hard threshold, cache time left, cost.
#   Opus 5.5 │ ▰▰▰▰▱▱▱▱▱▱ 87k/200k │ ⏱ cache 52m
#   Opus 5.5 │ ▰▰▰▰▱▱▱▱▱▱ 87k/200k │ ❄ cache cold │ $3.42
source "$(dirname "$0")/lib.sh"
if ! cn_have_jq; then echo "context-nudge: install jq"; exit 0; fi

input=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
model=$(jq -r '.model.display_name // empty' <<<"$input")
model_id=$(jq -r '.model.id // empty' <<<"$input")
[ -f "$transcript" ] || { echo "ctx –"; exit 0; }

# The status line redraws often; re-analyse only when the transcript grows.
size=$(wc -c <"$transcript" | tr -d ' ')
cache="${TMPDIR:-/tmp}/context-nudge-sl-$(printf '%s' "$transcript" | cksum | cut -d' ' -f1).json"
if [ -f "$cache" ] && [ "$(jq -r '.size' "$cache" 2>/dev/null)" = "$size" ]; then
  a=$(jq -c '.a' "$cache")
else
  a=$(cn_analyze "$transcript") || a='{"ok":false}'
  jq -nc --argjson a "$a" --arg s "$size" '{size: $s, a: $a}' >"$cache" 2>/dev/null
fi
[ "$(jq -r '.ok' <<<"$a")" = true ] || { echo "ctx –"; exit 0; }

SOFT=$(cn_int REMIND_AT_BREAKPOINT 100000)
HARD=$(cn_int REMIND_ALWAYS 200000)
ctx=$(jq -r '.ctx' <<<"$a")
ttl=$(jq -r '.ttl' <<<"$a")
last=$(jq -r '.last_ts // 0' <<<"$a")
cost=$(jq -r '.session_cost_s // empty' <<<"$a")

# The prompt cache is per model: after a /model switch the next turn re-writes
# the whole context, however recently the last one ran. Compare base ids so
# suffixes like "[1m]" or a date don't count as a switch.
switched=$(jq -rn --arg cur "$model_id" --arg last "$(jq -r '.model // empty' <<<"$a")" '
  def base: (capture("(?<id>claude-[a-z]+-[0-9]+(-[0-9](?![0-9]))?)") | .id) // .;
  $cur != "" and $last != "" and ($cur | base) != ($last | base)')

if   [ "$ctx" -ge "$HARD" ]; then color='\033[31m'
elif [ "$ctx" -ge "$SOFT" ]; then color='\033[33m'
else color='\033[32m'; fi
dim='\033[2m'
reset='\033[0m'
sep=" ${dim}│${reset} "

out=""
[ -n "$model" ] && out="${model}${sep}"
if [ "$HARD" -gt 0 ]; then
  # 10-cell bar filled toward the hard threshold, at least one cell once there is any context.
  cells=10
  filled=$(( ctx * cells / HARD ))
  [ "$filled" -gt "$cells" ] && filled=$cells
  [ "$filled" -eq 0 ] && [ "$ctx" -gt 0 ] && filled=1
  bar=""
  for ((i = 0; i < cells; i++)); do
    if [ "$i" -lt "$filled" ]; then bar="${bar}▰"; else bar="${bar}▱"; fi
  done
  out="${out}${color}${bar} $(( ctx / 1000 ))k${reset}${dim}/$(( HARD / 1000 ))k${reset}"
else
  # remind_always 0 means "always remind": there is no threshold to fill toward.
  out="${out}${color}$(( ctx / 1000 ))k${reset}"
fi

now=${CONTEXT_NUDGE_NOW:-$(date +%s)}
if [ "$switched" = true ]; then
  out="${out}${sep}❄ $(cn_msg cache_cold_model)"
elif [ "$last" -gt 0 ]; then
  left=$(( last + ttl - now ))
  if [ "$left" -le 0 ]; then
    out="${out}${sep}❄ $(cn_msg cache_cold)"
  else
    if [ "$left" -lt 60 ]; then t="<1m"; else t="$(( left / 60 ))m"; fi
    out="${out}${sep}${dim}⏱ $(cn_msg cache_left t="$t")${reset}"
  fi
fi

[ -n "$cost" ] && [ "$(cn_opt UNIT tokens)" = usd ] && out="${out}${sep}${cost}"
printf '%b\n' "$out"
