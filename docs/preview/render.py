"""Build the preview page: a mock Claude Code screen around the real hook
reminder and status line. Usage: render.py LANG HOOK_TXT STATUS_TXT > page.html"""
import html
import re
import sys

lang, hook_path, status_path = sys.argv[1:4]
hook = open(hook_path, encoding="utf-8").read().strip()
status = open(status_path, encoding="utf-8").read().strip()

# The surrounding conversation is made up; only the hook and status line are real.
TEXT = {
    "en": {
        "prompt": "add rate limiting to the API client and commit",
        "done": "Committed as 3f2a1c9. Requests now back off on 429s, with a token bucket of 10 req/s.",
    },
    "zh-TW": {
        "prompt": "幫 API client 加上 rate limiting，然後 commit",
        "done": "已 commit（3f2a1c9）。遇到 429 會自動退避，token bucket 上限每秒 10 個請求。",
    },
}[lang]

SGR = {"31": "red", "32": "green", "33": "yellow", "2": "dim"}


def emoji(s):
    """Escape text and give pictographs (💸, 🔄, ⏳) the color emoji font."""
    return re.sub(r"([\U0001F000-\U0001FAFF\u23f3])", r'<span class="emoji">\1</span>', html.escape(s))


def ansi_to_html(s):
    out, open_spans = [], 0
    for part in re.split(r"(\x1b\[[0-9;]*m)", s):
        m = re.fullmatch(r"\x1b\[([0-9;]*)m", part)
        if not m:
            out.append(html.escape(part))
            continue
        for code in (m.group(1) or "0").split(";"):
            if code in ("0", ""):
                out.append("</span>" * open_spans)
                open_spans = 0
            elif code in SGR:
                out.append(f'<span class="{SGR[code]}">')
                open_spans += 1
    out.append("</span>" * open_spans)
    return "".join(out)


commit = 'git add -A &amp;&amp; git commit -m "Add rate limiting to API client"'
print(f"""<!doctype html>
<html><head><meta charset="utf-8"><style>
  html, body {{ margin: 0; background: #0d1117; }}
  .term {{ box-sizing: border-box; width: 960px; height: 420px; padding: 22px 28px;
    font: 15px/1.55 Menlo, "SF Mono", "PingFang TC", monospace; color: #e6edf3; }}
  .row {{ display: flex; gap: 10px; margin-bottom: 12px; }}
  .row > :first-child {{ flex: none; }}
  .you {{ color: #8b949e; }}
  .dot {{ color: #3fb950; }}
  .tool {{ font-weight: bold; }}
  .out {{ color: #8b949e; padding-left: 20px; margin: -8px 0 12px; }}
  .hook {{ white-space: pre-wrap; color: #e3b341; padding-left: 20px; margin: 4px 0 16px; }}
  .input {{ border-top: 1px solid #30363d; border-bottom: 1px solid #30363d; padding: 6px 0; color: #8b949e; }}
  .status {{ padding: 6px 2px 0; }}
  .red {{ color: #f85149; }} .green {{ color: #3fb950; }} .yellow {{ color: #e3b341; }}
  .dim {{ color: #8b949e; }}
  .emoji {{ font-family: "Apple Color Emoji"; }}
</style></head><body><div class="term">
  <div class="row you"><span>&gt;</span><span>{html.escape(TEXT["prompt"])}</span></div>
  <div class="row"><span class="dot">⏺</span><span><span class="tool">Bash</span>({commit})</span></div>
  <div class="out">⎿ [main 3f2a1c9] Add rate limiting to API client · 3 files changed</div>
  <div class="row"><span class="dot">⏺</span><span>{html.escape(TEXT["done"])}</span></div>
  <div class="hook">{emoji(hook)}</div>
  <div class="input">&gt; </div>
  <div class="status">{ansi_to_html(status)}</div>
</div></body></html>""")
