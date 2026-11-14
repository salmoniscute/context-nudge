---
name: report
description: Replay the user's own Claude Code history and estimate how much usage context-nudge's reminders would save, where their usage goes, and how often they would be reminded. Use when the user runs /context-nudge:report or asks whether context-nudge would help them.
argument-hint: "[days, default 30; 0 = all history]"
disable-model-invocation: true
---

# context-nudge report

Everything here runs locally on the user's transcripts. Do not send any of it anywhere.

1. Check that `python3` exists (`command -v python3`). If not, tell the user the report needs Python 3 (the reminders themselves don't) and stop.

2. Run the analysis. Use the number of days from the arguments if one was given (`$ARGUMENTS`), else 30. The script finds the user's settings and language itself (from what the reminder hooks last used, then their saved plugin settings, then the system language), so pass nothing else unless the user asks to try other thresholds (`--soft`, `--hard`, `--step`, `--idle-min`):

   ```bash
   python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/report.py" --days <days> --data "${CLAUDE_PLUGIN_DATA}"
   ```

   It prints JSON. Read it; don't show the raw JSON to the user.

   **Write the whole report in `language_name` from the JSON.** The user may have typed nothing but the command, so that field is the best signal; only if they have been writing to you in a different language in this conversation, use theirs instead.

3. If `sessions` is 0, say there's no history in that period and suggest a longer one (`/context-nudge:report 0` for everything). Stop.

4. Present the result in the user's language, using only numbers from the JSON. Keep it short:

   - **What actually happened:** if `actual.since` is set, start with this. Since `actual.since`, the reminders after a commit/push/PR (`actual.reminders.bp`) and for a very long context (`actual.reminders.long`) were shown `shown` times and followed `followed` times (`actual.followed_pct`% overall: a `/clear` or manual `/compact` within 30 minutes). Following them avoided re-reading about `actual.saved_tokens` tokens, `actual.saved_pct`% of what the usage would have been (with `unit` `usd`, also `actual.saved_usd` dollars). Mention `actual.reminders.idle.shown` and `actual.reminders.switch.shown` only as counts. If one kind is almost never followed, say so: it's a hint to raise that threshold. If `actual.since` is null, say in one line that tracking starts now and the next report will show it.
   - **Headline:** following every reminder would have saved between `savings_if_every_reminder_followed_pct.reread_80k.all`% and `reread_0k.all`% of their usage over the period (`period.from`–`period.to`, `sessions` sessions). Say right away that this is a ceiling: it assumes they follow every reminder and the next task needs little of the old context.
   - **Where usage goes:** a small table from `where_usage_goes_pct`. Name the parts plainly: re-reading the context from cache, output, re-writing the cache after it expired, writing new content to the cache.
   - **Which reminder matters most:** compare `bp` (after commit/push/PR), `long` (very long context), and `idle` (expired cache) in `reread_40k`. Each is measured alone, so they overlap and don't add up.
   - **How often they'd be reminded:** `reminders.per_day` per day, about once every `reminders.turns_per_reminder` turns.
   - **Biggest sessions:** up to 3 rows from `top_sessions` (project, date, max context, share of usage). If `largest_session_share_pct` is high, point out that a few marathon sessions drive most of the usage.
   - **Settings:** only if `settings_source` is `defaults`, add one short line that the default thresholds were used. Don't explain where settings come from otherwise.
   - **Units:** if `unit` is `usd`, also give `usage_usd_at_api_prices` and `savings_usd_reread_40k.all` in dollars. Otherwise stay with percentages and token counts, and say once that the weights come from API prices because Pro/Max limits don't publish how they count tokens.

5. End with one recommendation that follows from the numbers:
   - Reminders more often than every ~6 turns: suggest raising `remind_at_breakpoint` / `remind_always` in `/config`, and offer to re-run with higher values (`--soft`, `--hard`) to compare savings against reminder count.
   - `idle` is a large share: suggest the status line (`/context-nudge:setup-statusline`), the only place they can see an expired cache *before* sending a message.
   - Savings under ~10%: say plainly that they already keep sessions short and the plugin won't change much for them.
