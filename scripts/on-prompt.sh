#!/bin/bash
# UserPromptSubmit hook: if the person comes back after the prompt cache has
# expired, or switched model since the last response, say what re-loading this
# long context costs.
source "$(dirname "$0")/lib.sh"
cn_have_jq || exit 0

input=$(cat)
cn_save_pointer
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
a=$(cn_analyze "$transcript") || exit 0
[ "$(jq -r '.ok' <<<"$a")" = true ] || exit 0

MIN=$(cn_int IDLE_MIN_TOKENS 30000)
ctx=$(jq -r '.ctx' <<<"$a")
ttl=$(jq -r '.ttl' <<<"$a")
last=$(jq -r '.last_ts // empty' <<<"$a")
[ -n "$last" ] && [ "$ctx" -ge "$MIN" ] || exit 0

k=$(( ctx / 1000 ))
session=$(jq -r '.session_id // empty' <<<"$input" | tr -cd 'A-Za-z0-9_-')
cwd=$(jq -r '.cwd // empty' <<<"$input")
logit() { cn_log remind --arg k "$1" --arg s "$session" --arg c "$cwd" --argjson x "$ctx" \
  '{kind: $k, session: $s, cwd: $c, ctx: $x}'; }
usd=false; [ "$(cn_opt UNIT tokens)" = usd ] && usd=true

# Switched model since the last response (the status line records the current
# one): the new model has no cache of this conversation, however recent it is.
f="$(cn_shared_dir)/$session.model.json"
if [ -n "$session" ] && [ -f "$f" ]; then
  cur_id=$(jq -r '.id // empty' "$f" 2>/dev/null)
  last_id=$(jq -r '.model // empty' <<<"$a")
  if [ -n "$cur_id" ] && [ -n "$last_id" ] && [ "$(cn_model_base "$cur_id")" != "$(cn_model_base "$last_id")" ]; then
    to=$(jq -r '.name // empty' "$f" 2>/dev/null); [ -n "$to" ] || to=$(cn_model_name "$cur_id")
    c=""
    if $usd; then
      cost=$(jq -rn --slurpfile p "$CN_DIR/prices.json" --arg id "$(cn_model_base "$cur_id")" \
        --argjson ctx "$ctx" --argjson ttl "$ttl" '
        ($p[0].models[$id].input // null) as $i
        | if $i == null then empty else
            ($ctx * $i * (if $ttl == 3600 then 2 else 1.25 end) / 1000000) as $x
            | if $x < 0.01 then "<$0.01" else ($x * 100 | round) as $c
              | "$\($c / 100 | floor).\($c % 100 | if . < 10 then "0\(.)" else tostring end)" end
          end')
      [ -n "$cost" ] && c=$(cn_msg idle_cost cost="$cost")
    fi
    [ -n "$c" ] || c=$(cn_msg idle_detail_tokens)
    logit switch
    cn_emit "$(cn_msg model_switch from="$(cn_model_name "$last_id")" to="$to" k="$k" detail="$c")"
    exit 0
  fi
fi

now=${CONTEXT_NUDGE_NOW:-$(date +%s)}
gap=$(( now - last ))
[ "$gap" -gt "$ttl" ] || exit 0

mins=$(( gap / 60 ))
cost=$(jq -r '.rewrite_cost_s // empty' <<<"$a")

if [ "$mins" -ge 120 ]; then away=$(cn_msg hours n="$(( mins / 60 ))"); else away=$(cn_msg minutes n="$mins"); fi
c=""
if $usd && [ -n "$cost" ]; then c=$(cn_msg idle_cost cost="$cost"); fi
[ -n "$c" ] || c=$(cn_msg idle_detail_tokens)
logit idle
cn_emit "$(cn_msg idle away="$away" k="$k" detail="$c")"
