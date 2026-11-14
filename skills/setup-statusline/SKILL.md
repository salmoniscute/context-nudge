---
name: setup-statusline
description: Install or update the context-nudge status line (context size, session cost, cold-cache marker). Use when the user runs /context-nudge:setup-statusline or asks to show context or cost in the status line.
disable-model-invocation: true
---

# Set up the context-nudge status line

Plugins cannot set the status line themselves, so this copies the script to a stable place and points the user's settings at it.

1. Check that `jq` is installed (`command -v jq`). If it is missing, tell the user to install it (`brew install jq`, `apt install jq`) and stop.

2. Install the launcher. It is a small script that runs the status line of whichever plugin version is installed, so plugin updates and `/config` changes apply without running this again. The plugin's own folder changes on every update, so settings must point at the launcher, not at the plugin:

   ```bash
   mkdir -p ~/.claude/context-nudge
   cp "${CLAUDE_PLUGIN_ROOT}/scripts/statusline-launcher.sh" ~/.claude/context-nudge/statusline.sh
   chmod +x ~/.claude/context-nudge/statusline.sh
   jq -nc --arg r "${CLAUDE_PLUGIN_ROOT}" --arg d "${CLAUDE_PLUGIN_DATA}" '{root: $r, data: $d}' \
     > ~/.claude/context-nudge/plugin.json
   ```

   The hooks keep `plugin.json` current from then on. The status line uses the same `/config` options as the reminders.

   Older versions of this command copied all the scripts and wrote `config.json`. If `~/.claude/context-nudge/` still has `lib.sh`, `analyze.jq`, `prices.json` or `messages.json`, delete them. If it has `config.json`, show the user its contents and ask whether to keep it: it overrides `/config` for the status line only. If they don't need that, delete it.

3. Read `~/.claude/settings.json` (it may not exist).
   - No `statusLine` key, or it already points at `~/.claude/context-nudge/statusline.sh`: set it as below.
   - A different `statusLine` already exists: show the user its command and ask whether to **replace** it or **combine** both. To combine, write a small wrapper `~/.claude/context-nudge/combined.sh` that saves stdin, runs their existing command and `statusline.sh` with that same stdin, and prints both joined by ` · `. Point `statusLine` at the wrapper.

   ```json
   "statusLine": { "type": "command", "command": "~/.claude/context-nudge/statusline.sh" }
   ```

   Edit only the `statusLine` key and keep every other setting.

4. Run it once against the current session to show the user what it looks like:

   ```bash
   echo '{"transcript_path":"<this session transcript>","model":{"display_name":"<current model>"}}' | ~/.claude/context-nudge/statusline.sh
   ```

   If you do not know the transcript path, skip this step.

5. Tell the user, in their language, that it shows `<model> │ <bar> <tokens>/<threshold> │ ⏱ <cache time left> │ <cost>` (the bar fills toward the `remind_always` threshold, the cache part turns into `❄ <cache expired>` once the cache expires or right after switching model, the cost only when `unit` is `usd`), that the color turns yellow at 100k and red at 200k, and that it follows the plugin's `/config` options and updates together with the plugin, so there is no need to run this command again.
