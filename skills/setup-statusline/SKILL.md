---
name: setup-statusline
description: Install or update the context-nudge status line (context size, session cost, cold-cache marker). Use when the user runs /context-nudge:setup-statusline or asks to show context or cost in the status line.
disable-model-invocation: true
---

# Set up the context-nudge status line

Plugins cannot set the status line themselves, so this copies the script to a stable place and points the user's settings at it.

1. Check that `jq` is installed (`command -v jq`). If it is missing, tell the user to install it (`brew install jq`, `apt install jq`) and stop.

2. Copy the scripts to a stable location. The plugin's own folder changes on every update, so do not point settings at it:

   ```bash
   mkdir -p ~/.claude/context-nudge
   cp "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh" "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh" \
      "${CLAUDE_PLUGIN_ROOT}/scripts/analyze.jq" "${CLAUDE_PLUGIN_ROOT}/scripts/prices.json" \
      "${CLAUDE_PLUGIN_ROOT}/scripts/messages.json" \
      ~/.claude/context-nudge/
   chmod +x ~/.claude/context-nudge/statusline.sh
   ```

   The copied status line doesn't receive the plugin's `/config` options, so write the ones it uses to `~/.claude/context-nudge/config.json`. For `language`, use the language the user is writing to you in (`en`, `zh-TW`, `zh-CN`, `ja`, `ko`; anything else is `en`) unless they ask for another one. For `unit`, use `tokens` (Pro/Max plans) unless they changed it in `/config` or ask to see cost, then use `usd` (pay-as-you-go API users). Keep the thresholds at the defaults unless they changed them in `/config`:

   ```json
   { "language": "zh-TW", "unit": "tokens", "remind_at_breakpoint": 100000, "remind_always": 200000 }
   ```

   If that file already exists, keep its values and only fill in missing keys.

3. Read `~/.claude/settings.json` (it may not exist).
   - No `statusLine` key, or it already points at `~/.claude/context-nudge/statusline.sh`: set it as below.
   - A different `statusLine` already exists: show the user its command and ask whether to **replace** it or **combine** both. To combine, write a small wrapper `~/.claude/context-nudge/combined.sh` that saves stdin, runs their existing command and `statusline.sh` with that same stdin, and prints both joined by ` · `. Point `statusLine` at the wrapper.

   ```json
   "statusLine": { "type": "command", "command": "~/.claude/context-nudge/statusline.sh" }
   ```

   Edit only the `statusLine` key and keep every other setting.

4. Run it once against the current session to show the user what it looks like:

   ```bash
   echo '{"transcript_path":"<this session transcript>"}' | ~/.claude/context-nudge/statusline.sh
   ```

   If you do not know the transcript path, skip this step.

5. Tell the user, in their language, that it shows `<model> │ <bar> <tokens>/<threshold> │ ⏱ <cache time left> │ <cost>` (the bar fills toward the `remind_always` threshold, the cache part turns into `❄ <cache expired>` once the cache expires, the cost only when `unit` is `usd`), that the color turns yellow at 100k and red at 200k, that the status line language and unit are set in `~/.claude/context-nudge/config.json`, and that after a plugin update they should run this command again to pick up new prices and translations.
