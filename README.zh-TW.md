# context-nudge

[English](README.md)

**在對的時機開新的 session，讓 Claude Code 的用量額度撐更久。**

session 越長，每一輪就越耗用量，因為 Claude 每次呼叫工具都會重讀整段對話。context-nudge 會注意「現在開新 session 最划算」的時刻，直接在 Claude Code 裡用一行訊息提醒你：

```
💸 剛 commit 完，context 已經 140k tokens（剛才這一輪總共處理了 2.1M tokens，因為每次呼叫工具都會重讀整段 context）。
   下一件事如果跟這個任務無關，先 /clear 再開始會省很多用量。
```

適用 Pro、Max 方案，也適用按量計費的 API key。提醒訊息支援 English、繁體中文、简体中文、日本語、한국어。

## 安裝前

你需要：

- **終端機版的 Claude Code**（`claude` 指令）。安裝 plugin 要用到它。VS Code 面板裡不能安裝 plugin，在那裡輸入 `/plugin` 會顯示無法使用，請改在終端機執行下面的安裝指令。
- **`jq`**，提醒功能會用到。macOS 15 以上內建；其他系統請執行 `brew install jq`（macOS）或 `sudo apt install jq`（Debian/Ubuntu）。可以用 `jq --version` 確認有沒有裝好。
- **`python3`**（選用），只有 `/context-nudge:report` 會用到。可以用 `python3 --version` 確認。

## 安裝

**1. 在終端機執行：**

```bash
claude plugin marketplace add OWNER/context-nudge
claude plugin install context-nudge@context-nudge
```

看到 `✔ Successfully installed plugin: context-nudge@context-nudge` 就是裝好了。另外出現「userConfig options not yet set」是正常的，因為每個選項都有預設值。

如果你已經在終端機的 Claude Code 裡面，也可以直接輸入 `/plugin marketplace add OWNER/context-nudge` 和 `/plugin install context-nudge@context-nudge`。

**2. 重新啟動 Claude Code。** 關掉再開一個新的 session。plugin 是在 session 啟動時載入的。

**3. 確認有沒有裝好。** 在新的 session 裡輸入：

```
/context-nudge:report
```

你會看到一份最近 30 天的簡短報告：用量花在哪裡，以及照提醒做能省多少。看得到報告，就代表 plugin 裝好了。這個指令需要 `python3`；沒有的話，可以在終端機執行 `claude plugin list`，看到 `context-nudge@context-nudge` 顯示 `✔ enabled` 就代表裝好了。

**4.（選用）加上 status line。** 輸入 `/context-nudge:setup-statusline`，Claude 會幫你設定好。詳見 [Status line](#status-line)。

## 你會看到什麼、該怎麼做

session 還短的時候，什麼都不會出現。只有在開新 session 真的能省到用量時，plugin 才會提醒你。

| 你會看到 | 什麼時候 | 該怎麼做 |
| --- | --- | --- |
| 💸 **剛 commit 完／剛 push 完／PR 剛送出**，context 已經… | 一輪結束時剛成功執行 `git commit`、`git push`、`gh pr create` 或 `npm publish`，而且 context 超過 100k tokens | 要開始做無關的事：輸入 `/clear`。要繼續做同一件事：不用理它。 |
| 💸 **Context 已到 …k tokens** | context 超過 200k tokens，就算任務還沒做完 | 任務做完了：`/clear`。還在做，但前面的對話已經用不到：`/compact`。 |
| 🔄 **換了模型（… → …）** | 用 `/model` 換成別的模型後送出訊息。新模型沒有這段對話的快取。需要裝 status line。 | 這次送出已經重新載入了 context。如果問題跟前面無關，下次換模型前先 `/clear`。 |
| ⏳ **距離上一輪已經…，快取過期了** | 離開超過快取時效（通常是 1 小時）後再送出訊息 | 這次送出已經重新載入了 context。如果問題跟這個 session 無關，下次先 `/clear` 再問。 |

提醒過一次後，要等 context 再多 50k tokens 才會再提醒，不會每一輪都跳出來。`/compact` 之後會重新計算。

這兩個指令的作用：

- `/clear`：開一個全新的空白 session。下一件事不需要前面的內容時使用。
- `/compact`：把目前的對話摘要起來，接著從摘要繼續。任務還沒做完、但對話已經很長時使用。

## 指令

| 指令 | 作用 |
| --- | --- |
| `/context-nudge:report` | 重播你最近 30 天的紀錄：用量花在哪裡、照提醒做能省多少、多久會提醒一次、哪些 session 最耗用量。`/context-nudge:report 7` 看最近 7 天，`/context-nudge:report 0` 看全部。全部在本機執行。 |
| `/context-nudge:setup-statusline` | 安裝 status line。如果你原本已經有 status line，Claude 會先問你要取代還是兩個一起顯示。 |

## Status line

```
Opus 5.5 │ ▰▰▰▰▰▰▰▱▱▱ 140k/200k │ ⏱ 快取 52m
Opus 5.5 │ ▰▰▰▰▰▰▰▱▱▱ 140k/200k │ ❄ 快取已過期
```

- `▰▰▰▰▰▰▰▱▱▱ 140k/200k` 是目前的 context 大小，進度條以 `remind_always` 門檻為滿格：100k 以下是綠色，超過 100k 變黃色，超過 200k 變紅色。
- `⏱ 快取 52m` 是快取還剩多久過期。
- `unit` 設成 `usd` 時，最後會多顯示 session 花費。顯示 `≥$3.42` 代表有部分回應的模型不在價格表上，實際花費會更高。
- `❄ 快取已過期（換了模型）` 在 `/model` 換模型後出現，因為新模型還沒有這段對話的快取。
- `❄ 快取已過期` 只在快取過期後出現。這是唯一能在你**送出訊息之前**就看到的警告，也正是它還派得上用場的時候。

執行一次 `/context-nudge:setup-statusline` 就能裝好。之後會跟著 plugin 一起更新，也和提醒共用同一組[設定](#設定)。status line 會顯示在終端機版的 Claude Code 裡。

進度條以 `remind_always`（預設 200k）為滿格，不是模型的 context 上限。就算上限是 1M tokens，每一輪還是會重送整段 context，所以花費跟著 context 大小增加。

## 設定

每個選項都有合理的預設值，不改也可以。想看目前的設定，在終端機執行：

```bash
claude plugin configure context-nudge@context-nudge
```

要修改的話，把想改的選項用 JSON 傳進去，沒寫到的選項會保持原樣：

```bash
echo '{"language": "zh-TW", "remind_always": "250000"}' | claude plugin configure context-nudge@context-nudge --values-stdin
```

在 Claude Code 裡也可以用 `/plugin configure context-nudge@context-nudge`。**改完要重新啟動 Claude Code** 才會生效。

| 選項 | 預設 | 意思 |
| --- | --- | --- |
| `language` | `auto` | `en`、`zh-TW`、`zh-CN`、`ja`、`ko`，或 `auto` |
| `unit` | `tokens` | `tokens`，或 `usd`（以 API 價格估算金額，給按量計費的 API 使用者） |
| `remind_at_breakpoint` | `100000` | context 超過這個大小時，commit、push、PR 會觸發提醒 |
| `remind_always` | `200000` | context 超過這個大小時，任務做到一半也會提醒 |
| `remind_step` | `50000` | 提醒過後，要等 context 再多這麼多才會再提醒 |
| `idle_min_tokens` | `30000` | context 至少這麼大，才會警告快取過期 |

覺得提醒太頻繁？把 `remind_at_breakpoint` 和 `remind_always` 調高。`/context-nudge:report` 會顯示目前的設定大概多久提醒一次，Claude 也可以用其他數值重算一次，讓你比較。

`language` 設成 `auto` 時，會依序參考 `LC_ALL`、`LC_MESSAGES`、`LANG`：`zh_TW`、`zh_HK`、`zh_MO`、`zh-Hant` 顯示繁體中文；其他 `zh` 開頭的顯示簡體中文；`ja` 顯示日文；`ko` 顯示韓文；其他一律顯示英文。如果完全沒有設定語系（在 macOS 上從 Dock 或 VS Code 啟動的程式很常這樣），會改用 macOS 的系統語言。如果顯示的語言還是不對，請直接設定 `language`。

## 更新與移除

更新：

```bash
claude plugin marketplace update context-nudge
claude plugin update context-nudge@context-nudge
```

更新後重新啟動 Claude Code。status line 會在你送出下一則訊息後換成新版本。如果你的 status line 是在這個版本之前裝的，請再執行一次 `/context-nudge:setup-statusline`，之後就會自動保持最新。

移除：

```bash
claude plugin uninstall context-nudge@context-nudge
```

如果有裝 status line，也要從 `~/.claude/settings.json` 刪掉 `statusLine` 那一項，並刪除 `~/.claude/context-nudge` 資料夾。

## 疑難排解

**出現 `/plugin isn't available in this environment`。** 你是在 VS Code 面板裡輸入的。請改在終端機用上面的 `claude plugin …` 指令安裝。

**出現 `claude: command not found`。** 終端機版的 Claude Code 還沒安裝。請照 Claude Code 官方的安裝說明裝好，再重新執行安裝指令。

**從來沒看過提醒。** 如果你的 session 都在 100k tokens 以內，這是正常的。想確認有沒有在運作，可以暫時把 `remind_always` 設成 `1000`（見[設定](#設定)），重新啟動 Claude Code 後隨便問一個問題，回覆完應該就會看到提醒。確認完記得改回 `200000`。如果還是沒出現，請確認 `jq --version` 能正常執行，以及 `claude plugin list` 顯示 plugin 已啟用。

**提醒的語言不對。** 直接設定 `language`（見[設定](#設定)），然後重新啟動 Claude Code。status line 也會使用同一個設定。

**報告說它用的是預設門檻。** 剛裝好時這是正常的。只要 Claude 回覆過一次，plugin 就會記下你的設定，之後的報告就會用你的設定。

## 真的有用嗎？

我們重播了 16 個真實的 session（以 API 價格計約 $250 的用量），看看用量花在哪裡、照提醒做會有什麼差別：

| 用量花在哪裡 | 比例 |
| --- | --- |
| 從快取重讀 context | 55% |
| Output | 17% |
| 快取過期後重新寫入 | 16% |
| 新內容寫入快取 | 12% |

用預設門檻、每次提醒都照做的話，用量可以減少**約 48–60%**：如果每次 `/clear` 後要重新讀回 80k tokens 才能繼續，省 48%；完全不用讀回的話，省 60%。提醒頻率大約每 8 輪一次。這是上限，因為它假設你每次都照做，而且下一個任務不需要前面的 context。省下來的大多來自少數幾個超長 session（其中一個 900k tokens 的 session 就佔了全部用量的 40%）。如果你本來就常常 `/clear`，效果會小很多。

這只是一個人的紀錄。執行 `/context-nudge:report` 看看你自己的。

## 注意事項

- **全部在你的電腦上執行。** plugin 讀的是 Claude Code 原本就存在本機的對話紀錄，不會傳送任何資料。
- **Pro/Max 額度怎麼計算 token 沒有公開**，所以 plugin 不會顯示「用掉額度的 %」，只顯示 token 數。快取讀取在 API 上比其他 token 便宜很多，對額度的消耗很可能也比較少，所以「處理了多少」這個數字看起來會比實際影響大一些。真正貴的是快取過期後的重新寫入。
- **`unit: usd` 用的是 API 牌價**，放在 [`scripts/prices.json`](scripts/prices.json)（2026-11-03 更新）。不在價格表裡的模型會改用 token 顯示。如果只有部分回應用了這種模型，金額會顯示成下限（`≥$3.42`）。
- **Subagent** 有自己的對話紀錄，不算在內。
- **數字可能會落後一次回應。** Claude Code 是非同步寫入對話紀錄的，plugin 讀取時，這一輪的最後一次回應有時還沒寫進去。

## 授權

MIT
