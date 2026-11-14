#!/usr/bin/env python3
"""Replay your own Claude Code history and estimate what context-nudge would save.

Reads ~/.claude/projects/*/*.jsonl locally and prints JSON. Nothing leaves the machine.

Usage weight = API list price. That is the only public proxy: how Pro/Max limits
weigh each kind of token isn't published. Percentages are the meaningful output.
"""
import argparse
import glob
import json
import os
import re
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
PRICES = json.load(open(os.path.join(HERE, "prices.json")))
ID_RE = re.compile(r"claude-[a-z]+-[0-9]+(-[0-9](?![0-9]))?")
BP_RE = re.compile(r"\bgh\s+pr\s+(create|merge)\b|\bgit(\s+-[Cc]\s+\S+)*\s+(push|commit)\b|\b(npm|pnpm|yarn)\s+publish\b")
CMD_ECHO = re.compile(r"^\s*<(command-name|command-message|local-command-stdout)")


def num(value, default):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def price(model):
    m = ID_RE.search(model or "")
    return PRICES["models"].get(m.group(0)) if m else None


def epoch(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def is_prompt(e):
    if e.get("type") != "user" or e.get("isSidechain") or e.get("isMeta"):
        return False
    c = (e.get("message") or {}).get("content")
    if isinstance(c, str):
        return not CMD_ECHO.match(c)
    if isinstance(c, list):
        kinds = [b.get("type") for b in c if isinstance(b, dict)]
        return "tool_result" not in kinds and ("text" in kinds or "image" in kinds)
    return False


def load(path):
    """One entry per API call (deduplicated by message id), in order."""
    calls, order, rnd, bash, err, cwd = {}, [], 0, {}, {}, None
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if not isinstance(e, dict):
                continue
            cwd = cwd or e.get("cwd")
            if e.get("type") == "assistant" and not e.get("isSidechain"):
                m = e.get("message") or {}
                if not m.get("id") or not m.get("usage") or m.get("model") == "<synthetic>":
                    continue
                if m["id"] not in calls:
                    order.append(m["id"])
                calls[m["id"]] = dict(u=m["usage"], model=m.get("model"), ts=epoch(e.get("timestamp")), r=rnd)
                for b in m.get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash":
                        bash[b.get("id")] = ((b.get("input") or {}).get("command") or "", rnd)
            elif e.get("type") == "user":
                c = (e.get("message") or {}).get("content")
                if isinstance(c, list):
                    for b in c:
                        if isinstance(b, dict) and b.get("type") == "tool_result":
                            err[b.get("tool_use_id")] = b.get("is_error") is True
                if is_prompt(e):
                    rnd += 1
    bp_rounds = {r for tid, (cmd, r) in bash.items() if not err.get(tid) and BP_RE.search(cmd)}
    out = []
    for i in order:
        c = calls[i]
        u, p = c["u"], price(c["model"])
        if not p:
            continue
        mult = PRICES.get("fast_multiplier", 2) if u.get("speed") == "fast" else 1
        cc = u.get("cache_creation") or {}
        inp = u.get("input_tokens") or 0
        cr = u.get("cache_read_input_tokens") or 0
        cw = u.get("cache_creation_input_tokens") or 0
        cw1 = cc.get("ephemeral_1h_input_tokens") or 0
        cw5 = cc.get("ephemeral_5m_input_tokens")
        cw5 = max(cw - cw1, 0) if cw5 is None else cw5
        o = u.get("output_tokens") or 0
        rate = p.get("long") if p.get("long") and inp + cr + cw > p["long"]["above"] else p
        pin, pcr, pout = (rate[k] * mult / 1e6 for k in ("input", "cache_read", "output"))
        out.append(dict(
            ts=c["ts"], r=c["r"], ctx=inp + cr + cw, inp=inp, cr=cr, cw=cw, out=o,
            ttl=3600 if cw1 else 300,
            p_in=pin, p_cr=pcr, p_cw=pin * (2 if cw1 >= cw5 else 1.25),
            c_in=inp * pin, c_cr=cr * pcr, c_cw=(cw5 * 1.25 + cw1 * 2) * pin, c_out=o * pout))
    return out, bp_rounds, cwd


def breakdown(calls):
    b = dict(cache_read=0.0, output=0.0, cache_rewrite_after_expiry=0.0, cache_write_new=0.0, uncached_input=0.0)
    t = dict(cache_read=0, output=0, cache_write=0, uncached_input=0)
    prev = None
    for c in calls:
        b["cache_read"] += c["c_cr"]
        b["output"] += c["c_out"]
        b["uncached_input"] += c["c_in"]
        expired = prev is not None and c["ts"] and c["ts"] - prev > c["ttl"] and c["cw"] > 0.5 * c["ctx"]
        b["cache_rewrite_after_expiry" if expired else "cache_write_new"] += c["c_cw"]
        t["cache_read"] += c["cr"]; t["output"] += c["out"]; t["cache_write"] += c["cw"]; t["uncached_input"] += c["inp"]
        prev = c["ts"] or prev
    return b, t


def simulate(calls, bp_rounds, cfg, reread, triggers=("bp", "long", "idle")):
    """Replay with every reminder obeyed. After a /clear the session restarts at its
    base context plus `reread` tokens (what has to be read again to continue)."""
    if not calls:
        return 0.0, 0
    base = min(c["ctx"] for c in calls[:3])
    floor = base + reread
    cut_by, saved, clears, last_remind, prev_ctx, prev_ts = 0, 0.0, 0, 0, 0, None
    for i, c in enumerate(calls):
        if prev_ctx and c["ctx"] < prev_ctx * 0.7:  # a real /compact or /clear happened
            cut_by, last_remind = 0, 0
        prev_ctx = c["ctx"]
        new_round = i == 0 or c["r"] != calls[i - 1]["r"]
        if "idle" in triggers and new_round and prev_ts and c["ts"] and c["ts"] - prev_ts > c["ttl"]:
            if c["ctx"] - cut_by >= cfg["idle_min"] and c["ctx"] > floor:
                cut_by, clears, last_remind = c["ctx"] - floor, clears + 1, 0
        cf = max(c["ctx"] - cut_by, floor) if cut_by else c["ctx"]
        cut = c["ctx"] - cf
        from_write = min(cut, c["cw"])
        from_read = min(cut - from_write, c["cr"])
        from_input = min(cut - from_write - from_read, c["inp"])
        saved += from_write * c["p_cw"] + from_read * c["p_cr"] + from_input * c["p_in"]
        prev_ts = c["ts"] or prev_ts
        if i == len(calls) - 1 or calls[i + 1]["r"] != c["r"]:  # Stop hook runs here
            kind = None
            if "bp" in triggers and c["r"] in bp_rounds and cf >= cfg["soft"]:
                kind = "bp"
            if not kind and "long" in triggers and cf >= cfg["hard"]:
                kind = "long"
            if kind and last_remind and cf < last_remind + cfg["step"]:
                kind = None
            if kind and c["ctx"] > floor:
                cut_by, clears, last_remind = c["ctx"] - floor, clears + 1, 0
    return saved, clears


FOLLOW_WINDOW = 1800  # a /clear or /compact within 30 minutes counts as following


def load_events(data_dirs, since):
    """Events the hooks logged (reminders shown, /clear, /compact), oldest first."""
    seen, out = set(), []
    for d in data_dirs:
        try:
            fh = open(os.path.join(d, "events.jsonl"), errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if line in seen:
                    continue
                seen.add(line)
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if isinstance(e, dict) and isinstance(e.get("t"), (int, float)) and e["t"] >= since:
                    out.append(e)
    out.sort(key=lambda e: e["t"])
    return out


def saved_after(ctx, calls):
    """Tokens and API-price dollars not re-read because the context restarted
    small: every later call would otherwise have carried `ctx` minus the new
    starting size, read from cache."""
    if not calls:
        return 0, 0.0
    diff = max(ctx - calls[0]["ctx"], 0)
    return diff * len(calls), sum(diff * c["p_cr"] for c in calls)


def actual(events):
    """What happened after the reminders that were really shown."""
    kinds = {"breakpoint": "bp", "long": "long", "idle": "idle", "switch": "switch"}
    stats = {k: {"shown": 0, "followed": 0} for k in kinds.values()}
    tokens, usd, used = 0, 0.0, set()
    for i, e in enumerate(events):
        if e.get("ev") != "remind" or e.get("kind") not in kinds:
            continue
        k = kinds[e["kind"]]
        stats[k]["shown"] += 1
        # The expired-cache and model-switch reminders arrive after the message
        # is sent; following them means /clear next time, which can't be paired.
        if k not in ("bp", "long"):
            continue
        for j in range(i + 1, len(events)):
            a = events[j]
            if a["t"] - e["t"] > FOLLOW_WINDOW:
                break
            if j in used:
                continue
            if a.get("ev") == "clear" and a.get("cwd") and a.get("cwd") == e.get("cwd"):
                calls = load(a["transcript"])[0] if a.get("transcript") and os.path.exists(a["transcript"]) else []
            elif (a.get("ev") == "compact" and a.get("trigger") == "manual"
                  and a.get("session") and a.get("session") == e.get("session")):
                # Calls after this compaction, up to the next one in the session.
                end = next((b["t"] for b in events[j + 1:]
                            if b.get("ev") == "compact" and b.get("session") == a.get("session")), None)
                calls = load(a["transcript"])[0] if a.get("transcript") and os.path.exists(a["transcript"]) else []
                calls = [c for c in calls if (c["ts"] or 0) > a["t"] and (end is None or (c["ts"] or 0) <= end)]
            else:
                continue
            used.add(j)
            stats[k]["followed"] += 1
            t, u = saved_after(e.get("ctx") or 0, calls)
            tokens += t; usd += u
            break
    pairable = stats["bp"]["shown"] + stats["long"]["shown"]
    followed = stats["bp"]["followed"] + stats["long"]["followed"]
    return {
        "since": datetime.fromtimestamp(events[0]["t"]).strftime("%Y-%m-%d") if events else None,
        "reminders": stats,
        "followed_pct": pct(followed, pairable) if pairable else None,
        "saved_tokens": tokens,
        "saved_usd": round(usd, 2),
    }


DEFAULTS = dict(language="auto", unit="tokens", remind_at_breakpoint=100000, remind_always=200000,
                remind_step=50000, idle_min_tokens=30000)
LANG_NAMES = {"en": "English", "zh-TW": "繁體中文", "zh-CN": "简体中文", "ja": "日本語", "ko": "한국어"}


def lang_code(value):
    """Same mapping as cn_lang in lib.sh."""
    v = (value or "").lower().replace("_", "-")
    if v.startswith(("zh-tw", "zh-hk", "zh-mo", "zh-hant")):
        return "zh-TW"
    for prefix, code in (("zh", "zh-CN"), ("ja", "ja"), ("ko", "ko")):
        if v.startswith(prefix):
            return code
    return "en"


def system_lang():
    loc = os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANG") or ""
    if loc in ("", "C", "POSIX") or loc.startswith("C."):
        if sys.platform == "darwin" and not os.environ.get("CONTEXT_NUDGE_NO_SYSTEM_LANG"):
            try:
                import subprocess
                out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"],
                                     capture_output=True, text=True, timeout=2).stdout
                loc = out.strip("() \n\t").split(",")[0].strip(' "\n\t')
            except Exception:
                pass
    return loc


def find_options(obj):
    """First dict under obj holding one of our option keys."""
    if isinstance(obj, dict):
        if any(k in obj for k in DEFAULTS):
            return obj
        for v in obj.values():
            hit = find_options(v)
            if hit:
                return hit
    return None


def resolve_settings(data_dirs, settings_files, cli):
    """Where the report's settings come from, best first:
    1. effective.json that the Stop hook writes with what it actually used
    2. pluginConfigs saved by /config in a settings.json
    3. ~/.claude/context-nudge/config.json written by setup-statusline
    then the defaults. Numbers passed on the command line win over all of them."""
    found, source = None, "defaults"
    candidates = []
    for d in data_dirs:
        for f in glob.glob(os.path.join(d, "effective.json")):
            candidates.append(f)
    candidates = sorted(set(candidates), key=lambda f: -os.path.getmtime(f))
    for f in candidates:
        try:
            found, source = json.load(open(f)), "hook"
            break
        except (OSError, ValueError):
            pass
    if found is None:
        for f in settings_files:
            try:
                cfgs = json.load(open(f)).get("pluginConfigs") or {}
            except (OSError, ValueError, AttributeError):
                continue
            for name, val in cfgs.items():
                if "context-nudge" in name:
                    hit = find_options(val)
                    if hit:
                        found, source = hit, "settings.json"
                        break
            if found:
                break
    if found is None:
        try:
            found, source = json.load(open(os.path.expanduser("~/.claude/context-nudge/config.json"))), "statusline config"
        except (OSError, ValueError):
            found = {}
    s = dict(DEFAULTS)
    s.update({k: v for k, v in (found or {}).items() if k in DEFAULTS and v not in (None, "")})
    for key, val in cli.items():
        if val is not None and num(val, None) is not None:
            s[key] = num(val, None)
    for key in ("remind_at_breakpoint", "remind_always", "remind_step", "idle_min_tokens"):
        s[key] = num(s[key], DEFAULTS[key])
    s["language"] = lang_code(system_lang() if s["language"] == "auto" else s["language"])
    s["unit"] = "usd" if str(s["unit"]).lower() == "usd" else "tokens"
    return s, source


def pct(part, whole):
    return round(part / whole * 100, 1) if whole else 0.0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--days", default="30", help="look back this many days (0 = everything)")
    ap.add_argument("--dir", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--data", action="append", default=[],
                    help="plugin data dir holding effective.json (repeatable)")
    ap.add_argument("--settings", action="append", default=None,
                    help="settings.json to search for pluginConfigs (repeatable)")
    ap.add_argument("--soft"); ap.add_argument("--hard"); ap.add_argument("--step"); ap.add_argument("--idle-min")
    a = ap.parse_args()
    data_dirs = [d for d in a.data if d and "${" not in d]
    plugins_data = os.environ.get("CONTEXT_NUDGE_PLUGINS_DATA") or os.path.expanduser("~/.claude/plugins/data")
    data_dirs += glob.glob(os.path.join(plugins_data, "*context-nudge*"))
    settings_files = a.settings if a.settings is not None else [
        os.path.expanduser("~/.claude/settings.json"), os.path.join(os.getcwd(), ".claude", "settings.json"),
        os.path.join(os.getcwd(), ".claude", "settings.local.json")]
    opts, source = resolve_settings(data_dirs, settings_files, {
        "remind_at_breakpoint": a.soft, "remind_always": a.hard, "remind_step": a.step, "idle_min_tokens": a.idle_min})
    cfg = dict(soft=opts["remind_at_breakpoint"], hard=opts["remind_always"], step=opts["remind_step"], idle_min=opts["idle_min_tokens"])
    days = num(a.days, 30)
    since = time.time() - days * 86400 if days > 0 else 0

    sessions = []
    for path in glob.glob(os.path.join(a.dir, "*", "*.jsonl")):
        if os.path.getmtime(path) < since:
            continue
        calls, bp_rounds, cwd = load(path)
        calls = [c for c in calls if not since or (c["ts"] or 0) >= since]
        if calls:
            sessions.append((path, calls, bp_rounds, cwd))

    total_b = dict(cache_read=0.0, output=0.0, cache_rewrite_after_expiry=0.0, cache_write_new=0.0, uncached_input=0.0)
    total_t = dict(cache_read=0, output=0, cache_write=0, uncached_input=0)
    scen = {r: {k: [0.0, 0] for k in ("all", "bp", "long", "idle")} for r in (0, 40000, 80000)}
    rows, first_ts, last_ts = [], None, None
    for path, calls, bp_rounds, cwd in sessions:
        b, t = breakdown(calls)
        for k in total_b: total_b[k] += b[k]
        for k in total_t: total_t[k] += t[k]
        for r in scen:
            for k, trig in (("all", ("bp", "long", "idle")), ("bp", ("bp",)), ("long", ("long",)), ("idle", ("idle",))):
                s, n = simulate(calls, bp_rounds, cfg, r, trig)
                scen[r][k][0] += s; scen[r][k][1] += n
        ts = [c["ts"] for c in calls if c["ts"]]
        if ts:
            first_ts = min(first_ts or ts[0], min(ts)); last_ts = max(last_ts or ts[-1], max(ts))
        rows.append(dict(
            project=os.path.basename(cwd) if cwd else os.path.basename(os.path.dirname(path)),
            started=datetime.fromtimestamp(min(ts)).strftime("%Y-%m-%d") if ts else None,
            api_calls=len(calls), turns=len({c["r"] for c in calls}),
            max_context=max(c["ctx"] for c in calls),
            usd=round(sum(b.values()), 2),
            saved_usd=round(simulate(calls, bp_rounds, cfg, 40000)[0], 2)))

    total = sum(total_b.values())
    act = actual(load_events(data_dirs, since))
    # Share of the usage there would have been without the followed reminders.
    act["saved_pct"] = pct(act["saved_usd"], total + act["saved_usd"]) if act["saved_usd"] else 0.0
    days_span = max((last_ts - first_ts) / 86400, 1) if first_ts and last_ts else 1
    turns = sum(r["turns"] for r in rows)
    rows.sort(key=lambda r: -r["usd"])
    for r in rows:
        r["share_of_usage_pct"] = pct(r["usd"], total)
    report = {
        "period": {"days": days or None,
                   "from": datetime.fromtimestamp(first_ts).strftime("%Y-%m-%d") if first_ts else None,
                   "to": datetime.fromtimestamp(last_ts).strftime("%Y-%m-%d") if last_ts else None},
        "sessions": len(rows),
        "api_calls": sum(r["api_calls"] for r in rows),
        "language": opts["language"],
        "language_name": LANG_NAMES[opts["language"]],
        "unit": opts["unit"],
        "settings": cfg,
        "settings_source": source,
        "usage_usd_at_api_prices": round(total, 2),
        "tokens": total_t,
        "where_usage_goes_pct": {k: pct(v, total) for k, v in sorted(total_b.items(), key=lambda x: -x[1])},
        "savings_if_every_reminder_followed_pct": {
            f"reread_{r // 1000}k": {k: pct(v[0], total) for k, v in scen[r].items()} for r in scen},
        "savings_usd_reread_40k": {k: round(v[0], 2) for k, v in scen[40000].items()},
        "turns": turns,
        "actual": act,
        "reminders": {"total": scen[40000]["all"][1],
                      "per_day": round(scen[40000]["all"][1] / days_span, 1),
                      "turns_per_reminder": round(turns / scen[40000]["all"][1], 1) if scen[40000]["all"][1] else None},
        "top_sessions": rows[:5],
        "largest_session_share_pct": rows[0]["share_of_usage_pct"] if rows else 0,
        "notes": [
            "Usage is weighted by API list prices; how Pro/Max limits weigh each token type is not published.",
            "Savings assume every reminder is followed and the next task needs at most the re-read amount of old context: an upper bound.",
            "Subagent transcripts are not included.",
        ],
    }
    json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
