#!/bin/bash
# Status line: context size, session cost, and whether the cache has gone cold.
#   ctx 87k · $3.42
#   ctx 87k · $3.42 · ❄ cache cold
source "$(dirname "$0")/lib.sh"
if ! cn_have_jq; then echo "context-nudge: install jq"; exit 0; fi

input=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
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

if   [ "$ctx" -ge "$HARD" ]; then color='\033[31m'
elif [ "$ctx" -ge "$SOFT" ]; then color='\033[33m'
else color='\033[32m'; fi
reset='\033[0m'

out="${color}ctx $(( ctx / 1000 ))k${reset}"
[ -n "$cost" ] && [ "$(cn_opt UNIT tokens)" = usd ] && out="$out · $cost"
now=${CONTEXT_NUDGE_NOW:-$(date +%s)}
[ "$last" -gt 0 ] && [ $(( now - last )) -gt "$ttl" ] && out="$out · ❄ $(cn_msg cache_cold)"
printf '%b\n' "$out"
