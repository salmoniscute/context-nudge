#!/bin/bash
# Render the README preview images from the plugin's real output.
# Builds a fake transcript, runs the actual Stop hook and status line on it,
# then draws them inside a mock Claude Code screen with headless Chrome.
# Usage: bash docs/preview/make.sh   (writes docs/preview/preview.<lang>.png)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
S="$ROOT/scripts"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found; set CHROME=/path/to/chrome" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Keep everything away from the real ~/.claude and the user's settings.
export CLAUDE_PLUGIN_DATA="$WORK/data" TMPDIR="$WORK/tmp" CONTEXT_NUDGE_HOME="$WORK/none"
export CONTEXT_NUDGE_NO_SYSTEM_LANG=1 LC_CTYPE=en_US.UTF-8
unset CLAUDE_PLUGIN_ROOT CONTEXT_NUDGE_CONFIG LC_ALL 2>/dev/null || true
mkdir -p "$TMPDIR"

# One turn of 15 tool calls re-reading a ~140k context, ending in a commit.
T="$WORK/session.jsonl"
jq -nc '{type:"user",isSidechain:false,timestamp:"2026-11-13T10:00:00.000Z",
         message:{role:"user",content:"add rate limiting to the API client and commit"}}' >"$T"
for i in $(seq 1 15); do
  ts=$(printf '2026-11-13T10:%02d:00.000Z' "$i")
  read_=$(( 125000 + i * 1000 ))
  if [ "$i" -eq 14 ]; then
    content='[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git add -A && git commit -m \"Add rate limiting\""}}]'
  else
    content='[{"type":"text","text":"working"}]'
  fi
  jq -nc --arg id "m$i" --arg ts "$ts" --argjson c "$content" --argjson cr "$read_" \
    '{type:"assistant",isSidechain:false,timestamp:$ts,
      message:{id:$id,model:"claude-opus-5-5",role:"assistant",content:$c,
        usage:{input_tokens:2,cache_read_input_tokens:$cr,cache_creation_input_tokens:900,
               cache_creation:{ephemeral_1h_input_tokens:900,ephemeral_5m_input_tokens:0},output_tokens:300}}}' >>"$T"
  [ "$i" -eq 14 ] && jq -nc '{type:"user",isSidechain:false,
      message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",is_error:false,content:"ok"}]}}' >>"$T"
done
last_ts=$(jq -rn '"2026-11-13T10:15:00Z" | fromdateiso8601')

for lang in en zh-TW; do
  export CONTEXT_NUDGE_LANGUAGE=$lang
  rm -rf "$CLAUDE_PLUGIN_DATA"
  jq -nc --arg t "$T" '{session_id:"preview",transcript_path:$t}' \
    | "$S/on-stop.sh" | jq -r '.systemMessage' >"$WORK/hook.txt"
  jq -nc --arg t "$T" '{transcript_path:$t,model:{display_name:"Opus 5.5",id:"claude-opus-5-5"}}' \
    | CONTEXT_NUDGE_NOW=$(( last_ts + 60 )) "$S/statusline.sh" >"$WORK/status.txt"
  [ -s "$WORK/hook.txt" ] && [ "$(cat "$WORK/hook.txt")" != null ] \
    || { echo "the hook printed no reminder for $lang" >&2; exit 1; }
  python3 -I "$HERE/render.py" "$lang" "$WORK/hook.txt" "$WORK/status.txt" >"$WORK/page.html"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=960,420 --screenshot="$HERE/preview.$lang.png" "file://$WORK/page.html" >/dev/null 2>&1
  # Cut the empty space below the status line (needs Pillow; skipped without it).
  python3 -I - "$HERE/preview.$lang.png" <<'PY' || true
import sys
from PIL import Image, ImageChops
p = sys.argv[1]; im = Image.open(p).convert("RGB")
box = ImageChops.difference(im, Image.new("RGB", im.size, im.getpixel((0, 0)))).getbbox()
if box: im.crop((0, 0, im.width, min(im.height, box[3] + 44))).save(p, optimize=True)
PY
  echo "wrote docs/preview/preview.$lang.png"
done
