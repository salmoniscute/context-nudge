#!/bin/bash
# context-nudge status line launcher. setup-statusline copies this file to
# ~/.claude/context-nudge/statusline.sh and points settings.json at it.
#
# It runs the status line of whichever plugin version is installed now, so a
# plugin update takes effect without re-running setup. The hooks keep
# plugin.json next to this file up to date: where the plugin lives (root) and
# where its /config values are saved (data/effective.json).
here="$(cd "$(dirname "$0")" && pwd)"
ptr="$here/plugin.json"
root=""; data=""
if [ -f "$ptr" ] && command -v jq >/dev/null 2>&1; then
  root=$(jq -r '.root // empty' "$ptr" 2>/dev/null)
  data=$(jq -r '.data // empty' "$ptr" 2>/dev/null)
fi
if [ -z "$root" ] || [ ! -x "$root/scripts/statusline.sh" ]; then
  # Right after a plugin update the old folder may be gone until a hook runs.
  echo "context-nudge: send a message to finish updating"
  exit 0
fi
# config.json here is the user's own override; effective.json holds /config.
export CONTEXT_NUDGE_CONFIG="$here/config.json${data:+:$data/effective.json}"
exec "$root/scripts/statusline.sh"
