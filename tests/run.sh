#!/bin/bash
# Self-contained tests: build fake transcripts, run the scripts, check output.
# Usage: bash tests/run.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_PLUGIN_DATA="$WORK/data" TMPDIR="$WORK/tmp"
# Never touch the real ~/.claude/context-nudge, even if run from inside a hook.
export CONTEXT_NUDGE_HOME="$WORK/home-none"
unset CONTEXT_NUDGE_CONFIG
mkdir -p "$TMPDIR"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n       got: %s\n' "$1" "$2"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
none() { [ -z "$2" ] && ok "$1" || bad "$1" "$2"; }

# --- transcript builders ---------------------------------------------------
T=""
new()    { T="$WORK/$1.jsonl"; : >"$T"; }
prompt() { jq -nc --arg ts "$1" --arg t "$2" \
  '{type:"user",isSidechain:false,timestamp:$ts,message:{role:"user",content:$t}}' >>"$T"; }
# asst ID MODEL TS INPUT CACHE_READ CW_1H CW_5M OUTPUT [BASH_CMD TOOL_ID]
asst() {
  local content='[{"type":"text","text":"hi"}]'
  [ -n "${9:-}" ] && content=$(jq -nc --arg c "${9}" --arg id "${10}" \
    '[{"type":"tool_use","id":$id,"name":"Bash","input":{"command":$c}}]')
  jq -nc --arg id "$1" --arg m "$2" --arg ts "$3" --argjson c "$content" \
     --argjson in "$4" --argjson cr "$5" --argjson w1 "$6" --argjson w5 "$7" --argjson out "$8" \
    '{type:"assistant",isSidechain:false,timestamp:$ts,
      message:{id:$id,model:$m,role:"assistant",content:$c,
        usage:{input_tokens:$in,cache_read_input_tokens:$cr,cache_creation_input_tokens:($w1+$w5),
               cache_creation:{ephemeral_1h_input_tokens:$w1,ephemeral_5m_input_tokens:$w5},output_tokens:$out}}}' >>"$T"
}
result() { jq -nc --arg id "$1" --argjson e "$2" \
  '{type:"user",isSidechain:false,message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,is_error:$e,content:"x"}]}}' >>"$T"; }

stop()   { jq -nc --arg t "$T" --arg s "$1" '{session_id:$s,transcript_path:$t}' | "$S/on-stop.sh" | jq -r '.systemMessage // empty'; }
submit() { jq -nc --arg t "$T" '{session_id:"p",transcript_path:$t,prompt:"x"}' | "$S/on-prompt.sh" | jq -r '.systemMessage // empty'; }
analyze() { grep -E '"type":"(assistant|user)"' "$T" | jq -nR --slurpfile p "$S/prices.json" -f "$S/analyze.jq"; }

# LC_ALL would override the per-test LANG values below.
unset LC_ALL LC_MESSAGES
# Run under a UTF-8 ctype whatever the caller's locale, so multibyte bugs
# (bash 3.2 reading "$var▰" as one variable name) show up here and not only on
# the user's machine. LC_CTYPE does not affect the message language.
for l in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
  if locale -a 2>/dev/null | grep -qx "$l"; then export LC_CTYPE=$l; break; fi
done
export CONTEXT_NUDGE_LANGUAGE=en
# Keep "auto" deterministic: don't fall back to this Mac's system language.
export CONTEXT_NUDGE_NO_SYSTEM_LANG=1
# Logic tests use fixed thresholds so they don't depend on the shipped defaults.
export CONTEXT_NUDGE_REMIND_AT_BREAKPOINT=60000 CONTEXT_NUDGE_REMIND_ALWAYS=150000

echo "analysis"
new cost
prompt 2026-11-13T10:00:00.000Z "fix the bug"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 10 100000 5000 0 1000
asst m1 claude-opus-5-5 2026-11-13T10:00:06.000Z 10 100000 5000 0 1000   # same message, second content block
a=$(analyze)
has "duplicate lines counted once" "$(jq -r .session_cost_s <<<"$a")" '$0.08'
has "context = input + cache read + cache write" "$(jq -r .ctx <<<"$a")" 105010
has "1-hour TTL detected" "$(jq -r .ttl <<<"$a")" 3600
has "rewrite cost uses 2x input for 1h" "$(jq -r .rewrite_cost_s <<<"$a")" '$0.84'

new model-ids
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 'claude-sonnet-5-5[1m]' 2026-11-13T10:00:05.000Z 0 0 0 1000000 0
has "model id with suffix is priced (5m write = 1.25x)" "$(jq -r .session_cost_s <<<"$(analyze)")" '$2.50'
new model-dated
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-haiku-4-5-20251001 2026-11-13T10:00:05.000Z 1000000 0 0 0 0
has "dated model id maps to its family" "$(jq -r .session_cost_s <<<"$(analyze)")" '$1.00'

echo "stop hook"
new long
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 155000 1000 0 500
has "long context reminds" "$(stop s-long)" "Context is at 156k tokens"
none "same level stays quiet" "$(stop s-long)"
asst m2 claude-opus-5-5 2026-11-13T10:01:00.000Z 0 190000 0 0 500
none "still within step stays quiet" "$(stop s-long)"
asst m3 claude-opus-5-5 2026-11-13T10:02:00.000Z 0 210000 0 0 500
has "next step reminds again" "$(stop s-long)" "210k"
asst m4 claude-opus-5-5 2026-11-13T10:03:00.000Z 0 20000 0 0 500
none "after /compact, small context is quiet" "$(stop s-long)"
asst m5 claude-opus-5-5 2026-11-13T10:04:00.000Z 0 160000 0 0 500
has "after /compact, counting restarts" "$(stop s-long)" "160k"

new defaults
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 160000 0 0 500
none "default: 160k mid-task is quiet" "$(CONTEXT_NUDGE_REMIND_ALWAYS= stop s-def)"
asst m2 claude-opus-5-5 2026-11-13T10:01:00.000Z 0 210000 0 0 500
has "default: 210k reminds" "$(CONTEXT_NUDGE_REMIND_ALWAYS= stop s-def)" "210k"

new small
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 40000 0 0 500
none "small context is quiet" "$(stop s-small)"

new commit
prompt 2026-11-13T10:00:00.000Z "add the feature and commit"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 70000 0 0 500 'git add -A && git commit -m "feat"' t1
result t1 false
asst m2 claude-opus-5-5 2026-11-13T10:00:09.000Z 0 71000 0 0 200
has "commit in a mid-size session reminds" "$(stop s-commit)" "Just committed"

new commit-old
prompt 2026-11-13T10:00:00.000Z "commit"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 70000 0 0 500 'git commit -m x' t1
result t1 false
prompt 2026-11-13T10:05:00.000Z "now explain this function"
asst m2 claude-opus-5-5 2026-11-13T10:05:09.000Z 0 72000 0 0 200
none "a commit from an earlier turn does not count" "$(stop s-commit-old)"

new commit-failed
prompt 2026-11-13T10:00:00.000Z "commit"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 70000 0 0 500 'git commit -m x' t1
result t1 true
none "failed commit does not count" "$(stop s-commit-failed)"

new not-commit
prompt 2026-11-13T10:00:00.000Z "search"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 70000 0 0 500 'git log --grep commit' t1
result t1 false
none "git log --grep commit is not a commit" "$(stop s-not-commit)"

new pr
prompt 2026-11-13T10:00:00.000Z "open a PR"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 80000 0 0 500 'gh pr create --fill' t1
result t1 false
has "PR creation reminds" "$(stop s-pr)" "PR is out"

new turn-read
prompt 2026-11-13T10:00:00.000Z "refactor and commit"
for i in 1 2 3 4 5 6 7 8 9; do asst "m$i" claude-opus-5-5 "2026-11-13T10:00:0$i.000Z" 0 150000 1000 0 100; done
asst m10 claude-opus-5-5 2026-11-13T10:00:10.000Z 0 151000 0 0 100 'git commit -m x' t1
result t1 false
msg=$(stop s-turn)
has "tokens: says how much the turn re-read" "$msg" "processed 1.5M tokens in total"
has "usd: dollars instead" "$(CONTEXT_NUDGE_UNIT=usd stop s-turn-usd)" "at API prices"
new one-call
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 160000 0 0 500
msg=$(stop s-one)
case "$msg" in *processed*) bad "single call: no re-read detail" "$msg" ;; *) ok "single call: no re-read detail" ;; esac

new unknown
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 some-other-model 2026-11-13T10:00:05.000Z 0 160000 0 0 500
msg=$(stop s-unknown)
has "unknown model still reminds" "$msg" "160k"
case "$msg" in *'$'*) bad "unknown model shows no price" "$msg" ;; *) ok "unknown model shows no price" ;; esac

echo "languages"
M="$S/messages.json"
missing=$(jq -r '(.en | keys) as $k | to_entries[] | select(.key != "_note" and .key != "en") | .key as $l | .value as $v | $k[] | select($v[.] == null) | "\($l).\(.)"' "$M")
none "every language has every key" "$missing"
placeholders=$(jq -r 'def ph: [scan("\\{[a-z_]+\\}")] | sort;
  .en as $en | to_entries[] | select(.key != "_note" and .key != "en") | .key as $l | .value | to_entries[]
  | select((.value | ph) != ($en[.key] | ph)) | "\($l).\(.key)"' "$M")
none "translations keep the same placeholders" "$placeholders"

new lang
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 160000 0 0 1
has "zh-TW"    "$(CONTEXT_NUDGE_LANGUAGE=zh-TW stop l1)" "Context 已到 160k"
has "zh-CN"    "$(CONTEXT_NUDGE_LANGUAGE=zh-CN stop l2)" "上下文已到 160k"
has "ja"       "$(CONTEXT_NUDGE_LANGUAGE=ja stop l3)"    "160k トークンに達しました"
has "ko"       "$(CONTEXT_NUDGE_LANGUAGE=ko stop l4)"    "160k 토큰에 도달했습니다"
has "auto: zh_TW -> Traditional"   "$(CONTEXT_NUDGE_LANGUAGE=auto LANG=zh_TW.UTF-8 stop l5)" "Context 已到"
has "auto: zh_HK -> Traditional"   "$(CONTEXT_NUDGE_LANGUAGE=auto LANG=zh_HK.UTF-8 stop l6)" "Context 已到"
has "auto: zh_CN -> Simplified"    "$(CONTEXT_NUDGE_LANGUAGE=auto LANG=zh_CN.UTF-8 stop l7)" "上下文已到"
has "auto: ja_JP -> Japanese"      "$(CONTEXT_NUDGE_LANGUAGE=auto LANG=ja_JP.UTF-8 stop l8)" "トークン"
has "auto: fr_FR -> English"       "$(CONTEXT_NUDGE_LANGUAGE=auto LANG=fr_FR.UTF-8 stop l9)" "Context is at"
has "auto: no LANG -> English"     "$(CONTEXT_NUDGE_LANGUAGE=auto LANG= stop l10)" "Context is at"
has "zh-Hant spelling accepted"    "$(CONTEXT_NUDGE_LANGUAGE=zh-Hant stop l11)" "Context 已到"
has "unknown setting -> English"   "$(CONTEXT_NUDGE_LANGUAGE=xx stop l12)" "Context is at"

echo "prompt hook (expired cache)"
new idle
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 95000 5000 0 500
t0=$(jq -nr '"2026-11-13T10:00:05Z" | fromdateiso8601')
has "away past the 1h TTL warns" "$(CONTEXT_NUDGE_NOW=$((t0 + 7300)) submit)" "2 hours since the last turn"
has "usd: warning includes the rewrite cost" "$(CONTEXT_NUDGE_UNIT=usd CONTEXT_NUDGE_NOW=$((t0 + 7300)) submit)" '$0.80'
msg=$(CONTEXT_NUDGE_NOW=$((t0 + 7300)) submit)
has "tokens (default): no dollar amount" "$msg" "without the cache discount"
case "$msg" in *'$'*) bad "tokens mode shows no \$" "$msg" ;; *) ok "tokens mode shows no \$" ;; esac
none "away under the TTL is quiet" "$(CONTEXT_NUDGE_NOW=$((t0 + 1800)) submit)"

new idle-5m
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 95000 0 5000 500
has "5-minute TTL detected" "$(CONTEXT_NUDGE_NOW=$((t0 + 600)) submit)" "10 minutes"

new idle-small
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 10000 0 0 500
none "small context does not warn" "$(CONTEXT_NUDGE_NOW=$((t0 + 7300)) submit)"

echo "status line"
new sl
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 87000 0 0 500
sl=$(jq -nc --arg t "$T" '{transcript_path:$t,model:{display_name:"Opus 5.5"}}' | CONTEXT_NUDGE_NOW=$((t0 + 60)) "$S/statusline.sh")
has "shows context" "$sl" "87k"
has "shows hard threshold" "$sl" "/150k"
has "shows model name" "$sl" "Opus 5.5"
has "bar fills toward hard threshold" "$sl" "▰▰▰▰▰▱▱▱▱▱"
has "shows cache time left" "$sl" "cache 4m"
case "$sl" in *'$'*) bad "tokens mode: no cost" "$sl" ;; *) ok "tokens mode: no cost" ;; esac
sl=$(jq -nc --arg t "$T" '{transcript_path:$t}' | CONTEXT_NUDGE_UNIT=usd CONTEXT_NUDGE_NOW=$((t0 + 60)) "$S/statusline.sh")
has "usd mode: shows cost" "$sl" '$0.03'
sl=$(jq -nc --arg t "$T" '{transcript_path:$t}' | CONTEXT_NUDGE_NOW=$((t0 + 4000)) "$S/statusline.sh")
has "shows cold cache" "$sl" "cache cold"
case "$sl" in *⏱*) bad "cold cache: no countdown" "$sl" ;; *) ok "cold cache: no countdown" ;; esac
sl=$(jq -nc --arg t "$T" '{transcript_path:$t}' | CONTEXT_NUDGE_LANGUAGE=ja CONTEXT_NUDGE_NOW=$((t0 + 4000)) "$S/statusline.sh")
has "cold cache is translated" "$sl" "キャッシュ切れ"
sl=$(jq -nc --arg t "$T" '{transcript_path:$t,model:{id:"claude-sonnet-5-5"}}' | CONTEXT_NUDGE_NOW=$((t0 + 60)) "$S/statusline.sh")
has "model switch: cache shown cold" "$sl" "cache cold (model switched)"
case "$sl" in *⏱*) bad "model switch: no countdown" "$sl" ;; *) ok "model switch: no countdown" ;; esac
sl=$(jq -nc --arg t "$T" '{transcript_path:$t,model:{id:"claude-opus-5-5[1m]"}}' | CONTEXT_NUDGE_NOW=$((t0 + 60)) "$S/statusline.sh")
has "same model with suffix: still warm" "$sl" "cache 4m"
# The copied status line reads its language from config.json next to it.
cp -R "$S" "$WORK/copy"; echo '{"language":"ko"}' >"$WORK/copy/config.json"
sl=$(jq -nc --arg t "$T" '{transcript_path:$t}' | CONTEXT_NUDGE_LANGUAGE= CONTEXT_NUDGE_NOW=$((t0 + 4000)) "$WORK/copy/statusline.sh")
has "copied status line uses config.json" "$sl" "캐시 만료"
sl=$(jq -nc --arg t "$T" '{transcript_path:$t}' | CONTEXT_NUDGE_REMIND_ALWAYS=0 CONTEXT_NUDGE_NOW=$((t0 + 60)) "$S/statusline.sh" 2>&1)
has "remind_always 0: shows context" "$sl" "87k"
case "$sl" in *rror*|*/0k*|*▱*) bad "remind_always 0: no bar, no error" "$sl" ;; *) ok "remind_always 0: no bar, no error" ;; esac
has "missing transcript" "$(echo '{}' | "$S/statusline.sh")" "ctx –"

echo "status line launcher"
new launch
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 87000 0 0 500
H="$WORK/home"; mkdir -p "$H"
cp "$S/statusline-launcher.sh" "$H/statusline.sh"
lsl() { jq -nc --arg t "$T" '{transcript_path:$t}' | env -u CONTEXT_NUDGE_LANGUAGE CONTEXT_NUDGE_NOW=$((t0 + 4000)) "$H/statusline.sh"; }
has "no pointer yet: says to send a message" "$(lsl)" "send a message"
# A hook run records where the plugin and its /config values live.
jq -nc --arg t "$T" '{session_id:"ln",transcript_path:$t}' \
  | CONTEXT_NUDGE_HOME="$H" CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_OPTION_LANGUAGE=ja "$S/on-stop.sh" >/dev/null
has "hook writes pointer" "$(jq -r .root "$H/plugin.json")" "$ROOT"
has "launcher runs the plugin's status line" "$(lsl)" "87k"
has "launcher follows /config values" "$(lsl)" "キャッシュ切れ"
echo '{"language":"ko"}' >"$H/config.json"
has "config.json overrides /config" "$(lsl)" "캐시 만료"
rm "$H/config.json"
jq -nc --arg t "$T" '{session_id:"ln",transcript_path:$t,prompt:"x"}' \
  | CONTEXT_NUDGE_HOME="$H" CLAUDE_PLUGIN_ROOT="$ROOT" "$S/on-prompt.sh" >/dev/null
has "prompt hook keeps pointer" "$(jq -r .root "$H/plugin.json")" "$ROOT"
jq -nc --arg r "$WORK/gone" '{root:$r}' >"$H/plugin.json"
has "stale pointer: says to send a message" "$(lsl)" "send a message"
rm -rf "$WORK/nohome"
jq -nc --arg t "$T" '{session_id:"ln",transcript_path:$t}' \
  | CONTEXT_NUDGE_HOME="$WORK/nohome" CLAUDE_PLUGIN_ROOT="$ROOT" "$S/on-stop.sh" >/dev/null
[ -e "$WORK/nohome" ] && bad "no status line: hook creates nothing" "$(ls "$WORK/nohome")" || ok "no status line: hook creates nothing"

echo "model switch"
new sw
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 87000 0 0 500
# sl SESSION MODEL_ID NAME: render the status line, which records the current model.
slm() { jq -nc --arg t "$T" --arg s "$1" --arg id "$2" --arg n "$3" \
  '{session_id:$s,transcript_path:$t,model:{id:$id,display_name:$n}}' | CONTEXT_NUDGE_NOW=$((t0 + 60)) "$S/statusline.sh" >/dev/null; }
sub() { jq -nc --arg t "$T" --arg s "$1" '{session_id:$s,transcript_path:$t,prompt:"x"}' \
  | CONTEXT_NUDGE_NOW=$((t0 + 60)) "$S/on-prompt.sh" | jq -r '.systemMessage // empty'; }
slm sw1 claude-sonnet-5-5 "Sonnet 5.5"
msg=$(sub sw1)
has "switch warns while cache is warm" "$msg" "Model switched (Opus 5.5 → Sonnet 5.5)"
has "switch: tokens mode" "$msg" "87k tokens of context, without the cache discount"
msg=$(jq -nc --arg t "$T" '{session_id:"sw1",transcript_path:$t,prompt:"x"}' \
  | CONTEXT_NUDGE_UNIT=usd CONTEXT_NUDGE_NOW=$((t0 + 60)) "$S/on-prompt.sh" | jq -r '.systemMessage // empty')
has "switch: usd priced at the new model" "$msg" "about \$"
slm sw2 claude-opus-5-5 "Opus 5.5"
none "same model: no switch warning" "$(sub sw2)"
slm sw3 "claude-opus-5-5[1m]" "Opus 5.5 (1M)"
none "same model with suffix: no switch warning" "$(sub sw3)"
none "no status line: no switch warning" "$(sub sw-none)"
has "model name from id" "$(source "$S/lib.sh"; cn_model_name claude-sonnet-5-5-20261101)" "Sonnet 5.5"

echo "partial pricing"
new partial
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 100000 0 0 500
asst m2 some-other-model 2026-11-13T10:00:10.000Z 0 160000 0 0 500
has "partial: flagged" "$(analyze | jq -r .cost_partial)" true
sl=$(jq -nc --arg t "$T" '{transcript_path:$t}' | CONTEXT_NUDGE_UNIT=usd CONTEXT_NUDGE_NOW=$((t0 + 60)) "$S/statusline.sh")
has "partial: status line shows lower bound" "$sl" "≥\$"
has "partial: reminder says at least" "$(CONTEXT_NUDGE_UNIT=usd stop s-partial)" "this session ≥ \$"
new fullprice
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 100000 0 0 500
has "all priced: not partial" "$(analyze | jq -r .cost_partial)" false

echo "report"
if command -v python3 >/dev/null; then
  mkdir -p "$WORK/projects/p1"
  cp "$WORK/commit.jsonl" "$WORK/projects/p1/a.jsonl"
  cp "$WORK/idle.jsonl" "$WORK/projects/p1/b.jsonl"
  r=$(python3 -I "$S/report.py" --dir "$WORK/projects" --days 0)
  has "report counts sessions" "$(jq -r .sessions <<<"$r")" 2
  has "report has usage breakdown" "$(jq -r '.where_usage_goes_pct | keys | join(",")' <<<"$r")" "cache_read"
  has "report has savings scenarios" "$(jq -r '.savings_if_every_reminder_followed_pct | keys | join(",")' <<<"$r")" "reread_40k"
  has "report uses given thresholds" "$(python3 -I "$S/report.py" --dir "$WORK/projects" --days 0 --soft 123 | jq -r .settings.soft)" 123
  has "report survives bad numbers" "$(python3 -I "$S/report.py" --dir "$WORK/projects" --days 0 --soft '${user_config.x}' | jq -r .settings.soft)" 100000
  has "report with no history" "$(python3 -I "$S/report.py" --dir "$WORK/none" | jq -r .sessions)" 0

  # Settings: the Stop hook saves what it used; the report reads the same file.
  # HOME points at the sandbox so the real ~/.claude/plugins/data can't leak in.
  R() { HOME="$WORK/home" python3 -I "$S/report.py" --dir "$WORK/projects" --days 0 --settings /nonexistent "$@"; }
  rm -f "$CLAUDE_PLUGIN_DATA/effective.json"
  has "no saved settings -> defaults" "$(R --data "$CLAUDE_PLUGIN_DATA" | jq -r .settings_source)" defaults
  has "no saved settings -> English without a locale" "$(LANG= R --data "$CLAUDE_PLUGIN_DATA" | jq -r .language)" en
  has "locale decides the language" "$(LANG=ja_JP.UTF-8 R --data "$CLAUDE_PLUGIN_DATA" | jq -r .language)" ja
  new eff; prompt 2026-11-13T10:00:00.000Z x; asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 1000 0 0 1
  CONTEXT_NUDGE_LANGUAGE=ko CONTEXT_NUDGE_REMIND_AT_BREAKPOINT=77000 CONTEXT_NUDGE_UNIT=usd stop s-eff >/dev/null
  has "hook saves what it used" "$(jq -r .remind_at_breakpoint "$CLAUDE_PLUGIN_DATA/effective.json")" 77000
  r=$(R --data "$CLAUDE_PLUGIN_DATA")
  has "report reads the hook's settings" "$(jq -r .settings_source <<<"$r")" hook
  has "report uses the hook's threshold" "$(jq -r .settings.soft <<<"$r")" 77000
  has "report uses the hook's language" "$(jq -r .language_name <<<"$r")" 한국어
  has "report uses the hook's unit" "$(jq -r .unit <<<"$r")" usd
  has "command-line numbers win" "$(R --data "$CLAUDE_PLUGIN_DATA" --soft 5000 | jq -r .settings.soft)" 5000
  has "unfilled placeholder is ignored" "$(R --data '${CLAUDE_PLUGIN_DATA}' --data "$CLAUDE_PLUGIN_DATA" | jq -r .settings_source)" hook
  echo '{"pluginConfigs":{"context-nudge@context-nudge":{"options":{"remind_always":250000,"language":"zh-CN"}}}}' >"$WORK/settings.json"
  r=$(HOME="$WORK/home" python3 -I "$S/report.py" --dir "$WORK/projects" --days 0 --data "$WORK/empty" --settings "$WORK/settings.json")
  has "falls back to pluginConfigs" "$(jq -r .settings_source <<<"$r")" settings.json
  has "pluginConfigs threshold" "$(jq -r .settings.hard <<<"$r")" 250000
  has "pluginConfigs language" "$(jq -r .language <<<"$r")" zh-CN
else
  echo "  skip (no python3)"
fi

echo "robustness"
new broken
prompt 2026-11-13T10:00:00.000Z "x"
asst m1 claude-opus-5-5 2026-11-13T10:00:05.000Z 0 160000 0 0 500
printf '{"type":"assistant","message":{"id":"m2","usage":' >>"$T"   # half-written last line
has "half-written line is skipped" "$(stop s-broken)" "160k"
none "no transcript, no output" "$(echo '{"session_id":"x"}' | "$S/on-stop.sh")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
