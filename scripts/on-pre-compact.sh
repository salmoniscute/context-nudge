#!/bin/bash
# PreCompact hook: log compactions for /context-nudge:report. Only a manual
# /compact can count as following a reminder; auto-compaction is logged too
# so the report can leave it out.
source "$(dirname "$0")/lib.sh"
cn_have_jq || exit 0
input=$(cat)
cn_log compact --arg tg "$(jq -r '.trigger // empty' <<<"$input")" \
  --arg s "$(jq -r '.session_id // empty' <<<"$input" | tr -cd 'A-Za-z0-9_-')" \
  --arg c "$(jq -r '.cwd // empty' <<<"$input")" --arg tr "$(jq -r '.transcript_path // empty' <<<"$input")" \
  '{trigger: $tg, session: $s, cwd: $c, transcript: $tr}'
exit 0
