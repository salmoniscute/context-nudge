#!/bin/bash
# Shared helpers for context-nudge. Sourced by the hook and status line scripts.

CN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cn_have_jq() { command -v jq >/dev/null 2>&1; }

# Option lookup, first match wins:
#   CLAUDE_PLUGIN_OPTION_<KEY>  set by Claude Code for hooks, from /config
#   CONTEXT_NUDGE_<KEY>         env override (tests, power users)
#   CONTEXT_NUDGE_CONFIG        colon-separated JSON files, first match wins.
#                               The status line launcher sets it: the status
#                               line gets no plugin env, so it reads the user's
#                               config.json and the /config values the hooks saved.
#   config.json next to the scripts  older status line installs copied the
#                               scripts and wrote this file next to them
cn_opt() {
  local key="$1" def="$2" v f k
  v=$(eval "printf '%s' \"\${CLAUDE_PLUGIN_OPTION_${key}:-\${CONTEXT_NUDGE_${key}:-}}\"")
  if [ -z "$v" ]; then
    k=$(printf '%s' "$key" | tr 'A-Z' 'a-z')
    local IFS=:
    for f in ${CONTEXT_NUDGE_CONFIG:-} "$CN_DIR/config.json"; do
      [ -f "$f" ] || continue
      v=$(jq -r --arg k "$k" '.[$k] // empty' "$f" 2>/dev/null)
      [ -n "$v" ] && break
    done
  fi
  printf '%s' "${v:-$def}"
}

cn_int() {
  local v; v=$(cn_opt "$1" "$2")
  case "$v" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}

# Map a language setting or locale (zh_TW.UTF-8, zh-Hant, ja_JP, ...) to a
# messages.json block. Anything without a translation falls back to en.
cn_lang() {
  local l; l=$(cn_opt LANGUAGE auto)
  if [ "$l" = auto ]; then
    l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    # Apps started from the Dock or VS Code on macOS often have no LANG at all,
    # but the system language is still known.
    case "$l" in ''|C|C.*|POSIX)
      if [ -z "${CONTEXT_NUDGE_NO_SYSTEM_LANG:-}" ] && command -v defaults >/dev/null 2>&1; then
        # Prints ( "zh-Hant-TW", "en-US" ); keep the first entry.
        l=$(defaults read -g AppleLanguages 2>/dev/null | tr -d '()" \n\t' | cut -d, -f1)
      fi ;;
    esac
  fi
  l=$(printf '%s' "$l" | tr 'A-Z_' 'a-z-')
  case "$l" in
    zh-tw*|zh-hk*|zh-mo*|zh-hant*) echo zh-TW ;;
    zh*)                           echo zh-CN ;;
    ja*)                           echo ja ;;
    ko*)                           echo ko ;;
    *)                             echo en ;;
  esac
}

# cn_msg KEY [name=value ...]: the localized string with {name} filled in.
cn_msg() {
  local key="$1" vars='{}' kv; shift
  for kv in "$@"; do
    vars=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' <<<"$vars")
  done
  jq -r --arg l "$(cn_lang)" --arg key "$key" --argjson v "$vars" \
    '(.[$l][$key] // .en[$key] // "") | gsub("\\{(?<n>[a-z_]+)\\}"; ($v[.n] // ""))' \
    "$CN_DIR/messages.json"
}

cn_data_dir() { printf '%s' "${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/context-nudge}"; }

cn_state_dir() {
  local d; d="$(cn_data_dir)/state"
  mkdir -p "$d" 2>/dev/null && printf '%s' "$d"
}

# Hooks are the one place that reliably receives the user's /config options.
# Save what they resolved to, so /context-nudge:report can use the same values.
# A directory both the hooks and the copied status line can reach. The status
# line gets no CLAUDE_PLUGIN_DATA, so this can't live under cn_data_dir.
cn_shared_dir() {
  local d="${TMPDIR:-/tmp}/context-nudge-shared"
  mkdir -p "$d" 2>/dev/null && printf '%s' "$d"
}

# claude-opus-5-5[1m] / claude-opus-5-5-20261101 -> claude-opus-5-5
CN_JQ_BASE='def base: (capture("(?<id>claude-[a-z]+-[0-9]+(-[0-9](?![0-9]))?)") | .id) // .;'
cn_model_base() { jq -rn --arg m "$1" "$CN_JQ_BASE"' $m | base'; }
# claude-opus-5-5 -> Opus 5.5, for models we only know by id.
cn_model_name() {
  jq -rn --arg m "$1" "$CN_JQ_BASE"'
    ($m | base) as $b
    | if ($b | startswith("claude-")) then
        ($b | split("-") | .[1:]) as $p
        | ($p[0][0:1] | ascii_upcase) + $p[0][1:] + " " + ($p[1:] | join("."))
      else $m end'
}

cn_save_effective() {
  local f; f="$(cn_data_dir)/effective.json"
  mkdir -p "$(cn_data_dir)" 2>/dev/null || return 0
  jq -n --arg language "$(cn_lang)" --arg unit "$(cn_opt UNIT tokens)" \
    --argjson soft "$(cn_int REMIND_AT_BREAKPOINT 100000)" --argjson hard "$(cn_int REMIND_ALWAYS 200000)" \
    --argjson step "$(cn_int REMIND_STEP 50000)" --argjson idle "$(cn_int IDLE_MIN_TOKENS 30000)" \
    '{language: $language, unit: $unit, remind_at_breakpoint: $soft, remind_always: $hard,
      remind_step: $step, idle_min_tokens: $idle, updated: now | floor}' >"$f.tmp" 2>/dev/null \
    && mv "$f.tmp" "$f"
}

# Where the status line launcher lives (setup-statusline puts it here).
cn_home() { printf '%s' "${CONTEXT_NUDGE_HOME:-$HOME/.claude/context-nudge}"; }

# Tell the status line launcher where this plugin version and its data live.
# Only once the status line is set up, and only rewritten when it changes.
cn_save_pointer() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 0
  local h f m; h=$(cn_home); f="$h/plugin.json"
  [ -d "$h" ] || return 0
  m=$(jq -nc --arg r "$CLAUDE_PLUGIN_ROOT" --arg d "$(cn_data_dir)" '{root: $r, data: $d}')
  [ "$(cat "$f" 2>/dev/null)" = "$m" ] && return 0
  printf '%s\n' "$m" >"$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
}

# Append one event to the local log that /context-nudge:report reads to see
# whether reminders were followed. Takes jq args; the filter builds the rest.
#   cn_log remind --arg kind idle --argjson ctx 90000 '{kind: $kind, ctx: $ctx}'
cn_log() {
  local ev="$1" d f; shift
  d=$(cn_data_dir); f="$d/events.jsonl"
  mkdir -p "$d" 2>/dev/null || return 0
  jq -nc --arg ev "$ev" --argjson t "${CONTEXT_NUDGE_NOW:-$(date +%s)}" "$@" \
    | jq -c --arg ev "$ev" --argjson t "${CONTEXT_NUDGE_NOW:-$(date +%s)}" '{t: $t, ev: $ev} + .' >>"$f" 2>/dev/null
  # Keep it small: a few thousand recent events is plenty for the report.
  if [ "$(wc -c <"$f" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    tail -n 2000 "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  fi
}

# Print the analysis JSON for a transcript, or nothing on failure.
cn_analyze() {
  [ -f "$1" ] || return 1
  grep -E '"type":"(assistant|user)"' "$1" 2>/dev/null \
    | jq -nR --slurpfile p "$CN_DIR/prices.json" -f "$CN_DIR/analyze.jq" 2>/dev/null
}

cn_emit() { jq -n --arg m "$1" '{systemMessage: $m}'; }
