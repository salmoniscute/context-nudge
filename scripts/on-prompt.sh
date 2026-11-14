#!/bin/bash
# UserPromptSubmit hook: if the person comes back after the prompt cache has
# expired, say what re-loading this long context costs.
source "$(dirname "$0")/lib.sh"
cn_have_jq || exit 0

input=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
a=$(cn_analyze "$transcript") || exit 0
[ "$(jq -r '.ok' <<<"$a")" = true ] || exit 0

MIN=$(cn_int IDLE_MIN_TOKENS 30000)
ctx=$(jq -r '.ctx' <<<"$a")
ttl=$(jq -r '.ttl' <<<"$a")
last=$(jq -r '.last_ts // empty' <<<"$a")
[ -n "$last" ] && [ "$ctx" -ge "$MIN" ] || exit 0

now=${CONTEXT_NUDGE_NOW:-$(date +%s)}
gap=$(( now - last ))
[ "$gap" -gt "$ttl" ] || exit 0

mins=$(( gap / 60 ))
k=$(( ctx / 1000 ))
cost=$(jq -r '.rewrite_cost_s // empty' <<<"$a")

if [ "$mins" -ge 120 ]; then away=$(cn_msg hours n="$(( mins / 60 ))"); else away=$(cn_msg minutes n="$mins"); fi
c=""
if [ "$(cn_opt UNIT tokens)" = usd ] && [ -n "$cost" ]; then c=$(cn_msg idle_cost cost="$cost"); fi
[ -n "$c" ] || c=$(cn_msg idle_detail_tokens)
cn_emit "$(cn_msg idle away="$away" k="$k" detail="$c")"
