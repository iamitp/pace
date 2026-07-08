#!/usr/bin/env python3
"""Poll Codex's local rate-limit state into ~/.claude/codex-usage.json.

The statusline bar (statusline.py · codex_part) reads this file for the
`N% wk` segment. Codex does not expose a usage CLI; instead it writes a
`rate_limits` block into each session rollout JSONL under ~/.codex/sessions
(payload.rate_limits inside `event_msg`/token_count events). The freshest
reading is the bearing event with the latest *timestamp* across recent
rollouts — not merely the newest file, since a just-started session can have
null tails while another session holds a fresher number.

Schema written (only what the bar needs, plus an updated_at freshness stamp
the briefing hook checks). No Claude-weekly field: there is no local source
for it on this box, and we do not fabricate.

  primary   = 5-hour window  (window_minutes 300)
  secondary = weekly window  (window_minutes 10080)  -> the bar's `% wk`
"""
import glob
import json
import os
import re
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

HOME = os.path.expanduser("~")
SESS_GLOB = os.path.join(HOME, ".codex", "sessions", "**", "*.jsonl")
OUT = os.path.join(HOME, ".claude", "codex-usage.json")
LEDGER = os.path.join(HOME, ".claude", "codex-resets-ledger.json")
CONFIG = os.path.join(HOME, ".codex", "config.toml")
AUTH = os.path.join(HOME, ".codex", "auth.json")
WHAM_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
WHAM_CREDITS_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
MAX_FILES = 500      # backstop cap on rollouts scanned
MAX_AGE_DAYS = 21    # ignore rollouts older than this; bounds cost as sessions accrue


def parse_ts(s):
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except Exception:
        return None


def auth_token_and_account():
    try:
        auth = json.load(open(AUTH, errors="ignore"))
        tokens = auth.get("tokens") or {}
        return (tokens.get("access_token") or "").strip(), (tokens.get("account_id") or "").strip()
    except Exception:
        return "", ""


def _window_from_live(w):
    """Map wham/usage's *_window shape onto our primary/secondary schema."""
    if not isinstance(w, dict):
        return None
    secs = w.get("limit_window_seconds")
    return {
        "used_percent": w.get("used_percent"),
        "window_minutes": int(secs // 60) if isinstance(secs, (int, float)) else None,
        "resets_at": w.get("reset_at"),
    }


def live_rate_limits():
    """Poll the same wham/usage endpoint the Codex app uses, so Pace tracks the
    live server truth for the account in ~/.codex/auth.json rather than lagging
    on the newest snapshot scraped from session rollout files."""
    token, account = auth_token_and_account()
    if not token:
        return None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": "Codex Pace local usage poller",
    }
    if account:
        headers["ChatGPT-Account-Id"] = account
    req = urllib.request.Request(WHAM_USAGE_URL, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            payload = json.load(resp)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    rate = payload.get("rate_limit")
    if not isinstance(rate, dict):
        return None
    primary = _window_from_live(rate.get("primary_window"))
    secondary = _window_from_live(rate.get("secondary_window"))
    if primary is None and secondary is None:
        return None
    # The account can carry more than one weekly pool (e.g. a separate
    # GPT-5.3-Codex-Spark limit). The Codex app sometimes headlines a different
    # pool than the main one, so capture them all and let Pace show the binding
    # (most-used) weekly plus any others, so the two surfaces reconcile.
    pools = []
    main_sec = _window_from_live(rate.get("secondary_window"))
    if main_sec:
        main_sec = dict(main_sec, name="Codex")
        pools.append(main_sec)
    for extra in payload.get("additional_rate_limits") or []:
        if not isinstance(extra, dict):
            continue
        name = extra.get("limit_name") or extra.get("metered_feature") or "Codex"
        sub = (extra.get("rate_limit") or {})
        w = _window_from_live(sub.get("secondary_window")) if isinstance(sub, dict) else None
        if w:
            pools.append(dict(w, name=str(name)))
    def used_of(p):
        try:
            return float(p.get("used_percent") or 0)
        except Exception:
            return 0.0
    # Binding weekly = the pool closest to its cap; that is the one that stops you.
    # The Codex app shows the main weekly pool as "Weekly"; mirror that exactly.
    _ = used_of  # (pools still captured for reference, not surfaced)
    return {
        "plan_type": payload.get("plan_type"),
        "email": payload.get("email"),
        "account_id": payload.get("account_id"),
        "primary": primary,
        "secondary": secondary,
        "weekly_pools": pools,
    }


def freshest_rate_limits():
    cutoff = time.time() - MAX_AGE_DAYS * 86400
    files = [p for p in glob.glob(SESS_GLOB, recursive=True)
             if os.path.getmtime(p) >= cutoff]
    files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    files = files[:MAX_FILES]
    best_ts = None
    best_rl = None
    best_nonzero_ts = None
    best_nonzero_rl = None
    for path in files:
        try:
            with open(path, errors="ignore") as fh:
                for line in fh:
                    if '"rate_limits"' not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    rl = (obj.get("payload") or {}).get("rate_limits")
                    if not isinstance(rl, dict):
                        continue
                    ts = parse_ts(obj.get("timestamp"))
                    if ts is None:
                        continue
                    if best_ts is None or ts > best_ts:
                        best_ts, best_rl = ts, rl
                    primary = rl.get("primary") if isinstance(rl.get("primary"), dict) else {}
                    secondary = rl.get("secondary") if isinstance(rl.get("secondary"), dict) else {}
                    try:
                        primary_used = float(primary.get("used_percent"))
                        secondary_used = float(secondary.get("used_percent"))
                    except Exception:
                        primary_used = secondary_used = 0.0
                    if primary_used > 0 or secondary_used > 0:
                        if best_nonzero_ts is None or ts > best_nonzero_ts:
                            best_nonzero_ts, best_nonzero_rl = ts, rl
        except Exception:
            continue
    if best_ts and best_rl and best_nonzero_ts and best_nonzero_rl:
        primary = best_rl.get("primary") if isinstance(best_rl.get("primary"), dict) else {}
        secondary = best_rl.get("secondary") if isinstance(best_rl.get("secondary"), dict) else {}
        try:
            zero_pair = float(primary.get("used_percent")) == 0.0 and float(secondary.get("used_percent")) == 0.0
        except Exception:
            zero_pair = False
        if zero_pair and best_ts - best_nonzero_ts <= timedelta(minutes=30):
            return best_nonzero_ts, best_nonzero_rl
    return best_ts, best_rl


def codex_model():
    model = effort = None
    try:
        txt = open(CONFIG, errors="ignore").read()
        m = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"', txt)
        e = re.search(r'(?m)^\s*model_reasoning_effort\s*=\s*"([^"]+)"', txt)
        model = m.group(1) if m else None
        effort = e.group(1) if e else None
    except Exception:
        pass
    return model, effort


def window(rl, key):
    w = rl.get(key) or {}
    if not isinstance(w, dict):
        return None
    return {
        "used_percent": w.get("used_percent"),
        "window_minutes": w.get("window_minutes"),
        "resets_at": w.get("resets_at"),
    }


def load_reset_ledger():
    try:
        data = json.load(open(LEDGER, errors="ignore"))
        if isinstance(data, dict) and isinstance(data.get("credits"), dict):
            return data
    except Exception:
        pass
    return {"credits": {}}


def save_reset_ledger(ledger):
    tmp = LEDGER + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(ledger, fh, indent=2)
    os.replace(tmp, LEDGER)


def credit_label(c):
    description = str(c.get("description") or "")
    return "Referral" if "inviting" in description.lower() else str(c.get("profile_user_id") or "Codex Team")


def reconcile_reset_ledger(credits):
    """Fold a successful credits fetch into the persistent ledger and return
    the resolved (redeemed/expired) history. The wham endpoint drops a credit
    from its response entirely once it is consumed or lapses, so the only
    durable record of used/expired resets is what this ledger accumulates."""
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat()
    ledger = load_reset_ledger()
    entries = ledger["credits"]
    seen = set()
    for c in credits:
        if not isinstance(c, dict):
            continue
        cid = str(c.get("id") or f"{c.get('granted_at')}|{c.get('expires_at')}")
        seen.add(cid)
        e = entries.setdefault(cid, {"first_seen": now_iso})
        e["granted_at"] = c.get("granted_at") or e.get("granted_at")
        e["expires_at"] = c.get("expires_at") or e.get("expires_at")
        e["label"] = credit_label(c)
        e["status"] = str(c.get("status") or "available")
        e["last_seen"] = now_iso
        if e["status"] != "available" and not e.get("resolved_at"):
            e["resolved_at"] = c.get("redeemed_at") or now_iso
    for cid, e in entries.items():
        if cid in seen or e.get("status") not in (None, "available"):
            continue
        exp = parse_ts(e.get("expires_at"))
        e["status"] = "expired" if exp and now >= exp else "redeemed"
        e["resolved_at"] = e.get("resolved_at") or now_iso
    save_reset_ledger(ledger)
    history = [e for e in entries.values()
               if e.get("status") != "available" and e.get("expires_at")]
    history.sort(key=lambda e: str(e.get("resolved_at") or ""), reverse=True)
    return [{
        "granted_at": e.get("granted_at"),
        "expires_at": e.get("expires_at"),
        "label": e.get("label") or "Codex Team",
        "status": e.get("status"),
        "resolved_at": e.get("resolved_at"),
    } for e in history[:8]]


def reset_credits_summary():
    try:
        auth = json.load(open(AUTH, errors="ignore"))
        token = ((auth.get("tokens") or {}).get("access_token") or "").strip()
    except Exception:
        return {}
    if not token:
        return {}

    def fetch(url):
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "User-Agent": "Codex Pace local usage poller",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=8) as resp:
                return json.load(resp)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            return None

    out = {}
    # Per-credit detail (undocumented but what the Codex app itself uses;
    # the wham/usage summary block only carries available_count).
    detail = fetch(WHAM_CREDITS_URL)
    if isinstance(detail, dict):
        all_credits = [c for c in (detail.get("credits") or []) if isinstance(c, dict)]
        out["resets_history"] = reconcile_reset_ledger(all_credits)
        credits = [c for c in all_credits if c.get("status") == "available"]
        detailed_credits = []
        for c in credits:
            expires_at = c.get("expires_at")
            if not expires_at:
                continue
            detailed_credits.append({
                "granted_at": c.get("granted_at"),
                "expires_at": expires_at,
                "label": credit_label(c),
            })
        expiries = sorted(str(c["expires_at"]) for c in credits if c.get("expires_at"))
        out["resets_detail"] = detailed_credits
        if isinstance(detail.get("available_count"), (int, float)):
            out["resets_available"] = int(detail["available_count"])
        if expiries:
            out["resets_next_expiry"] = expiries[0]
            out["resets_expire_at"] = expiries[0]  # key Pace's metadata reader parses
            out["resets_expiries"] = expiries
    if "resets_available" in out:
        return out

    payload = fetch(WHAM_USAGE_URL)
    if not isinstance(payload, dict):
        return out
    summary = payload.get("rate_limit_reset_credits") or {}
    if not isinstance(summary, dict):
        return out
    if isinstance(summary.get("available_count"), (int, float)):
        out["resets_available"] = int(summary["available_count"])
    for key in ("expires_at", "expiry", "expire_at", "expiresAt"):
        if summary.get(key):
            out["resets_expire_at"] = summary[key]
            break
    return out


def main():
    # Prefer the live wham/usage endpoint (server truth, same source the Codex
    # app reads). Fall back to scraping session rollout files only when the live
    # call fails, so a network blip degrades to the last snapshot rather than
    # blanking the feed.
    live = live_rate_limits()
    model, effort = codex_model()
    if live is not None:
        out = {
            "updated_at": int(time.time()),
            "source_reading_at": datetime.now(timezone.utc).isoformat(),
            "source": "wham/usage",
            "plan_type": live.get("plan_type"),
            "account_email": live.get("email"),
            "account_id": live.get("account_id"),
            "primary": live.get("primary"),
            "secondary": live.get("secondary"),
            "weekly_pools": live.get("weekly_pools") or [],
        }
    else:
        ts, rl = freshest_rate_limits()
        if rl is None:
            # No reading available — leave any existing file untouched rather than
            # blanking a previously-good value or inventing one.
            return 0
        out = {
            "updated_at": int(time.time()),
            "source_reading_at": ts.astimezone(timezone.utc).isoformat() if ts else None,
            "source": "session-scrape",
            "plan_type": rl.get("plan_type"),
            "primary": window(rl, "primary"),
            "secondary": window(rl, "secondary"),
        }
    out.update(reset_credits_summary())
    if model:
        out["model"] = model
    if effort:
        out["model_reasoning_effort"] = effort
    tmp = OUT + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(out, fh, indent=2)
    os.replace(tmp, OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
