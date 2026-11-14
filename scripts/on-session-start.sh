#!/bin/bash
# SessionStart hook: keep the status line launcher pointed at this plugin
# version, and mention the status line once to people who haven't set it up.
source "$(dirname "$0")/lib.sh"
cn_have_jq || exit 0

input=$(cat)
cn_save_pointer

# The status line only shows in the terminal. Elsewhere, wait for a terminal
# session instead of using up the one-time hint.
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in cli) ;; *) exit 0 ;; esac

flag="$(cn_data_dir)/statusline-hint-shown"
[ -f "$flag" ] && exit 0

# Set up already? Look at every settings file that can hold statusLine.
cwd=$(jq -r '.cwd // empty' <<<"$input")
conf="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
for f in "$conf/settings.json" "$conf/settings.local.json" \
         ${cwd:+"$cwd/.claude/settings.json" "$cwd/.claude/settings.local.json"}; do
  [ -f "$f" ] || continue
  case "$(jq -r '.statusLine.command // empty' "$f" 2>/dev/null)" in
    *context-nudge*) exit 0 ;;
  esac
done

mkdir -p "$(cn_data_dir)" 2>/dev/null && : >"$flag" || exit 0
cn_emit "$(cn_msg statusline_hint)"
