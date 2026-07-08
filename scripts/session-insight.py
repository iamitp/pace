#!/usr/bin/env python3
"""Turn a Codex session rollout into a plain-English retrospective.

Pace already reads ~/.codex/sessions/**/*.jsonl for token counts. Those files
also hold the full transcript: the task, every tool call, every result. This
script distils one session into a compact summary, has a model read it, and
returns structured JSON describing what was worked on, what it produced, and how
much of the spend was useful versus wasted.

Model backends. The default is the `codex` CLI, so there is no API key to set up
and no metered cost: it spends the ChatGPT plan quota you already pay for. Set
PACE_INSIGHT_BACKEND=openai (with OPENAI_API_KEY) if you would rather use the
metered API.
  1. codex CLI (default) -> `codex exec` using the ChatGPT plan you already have.
  2. OPENAI_API_KEY       -> OpenAI Chat Completions (opt in via backend=openai).
  3. --dry-run            -> skip the model, print the extracted transcript only.

Results cache to ~/.claude/pace-session-insights.json keyed by session id, so a
session is summarised once and re-read for free. Everything stays local; the
transcript is the same content you already streamed to Codex during the session.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
SESS_GLOB = os.path.join(HOME, ".codex", "sessions", "**", "*.jsonl")
CACHE = os.path.join(HOME, ".claude", "pace-session-insights.json")
MODEL = os.environ.get("PACE_INSIGHT_MODEL", "gpt-5-mini")
MAX_TRANSCRIPT_CHARS = 12000

WASTE_MARKERS = ("error", "failed", "traceback", "exception", "not found",
                 "no such file", "command not found", "exit code 1", "denied")

SCHEMA_HINT = {
    "one_line": ("A short tag the way a busy person files it in their own notes: "
                 "the subject or project FIRST, then a 2-4 word action, joined by "
                 "' · '. Five or six words MAX. Examples of the exact style: "
                 "'Peeku · App Store downloads', 'Fincom · card-suffix fixes', "
                 "'LG washtower · installation', 'Pace · session insights'. "
                 "Lead with the noun/subject, never a verb. NO gerunds ('Getting', "
                 "'Checking', 'Sorting'), NO full sentences, NO tool names, file "
                 "paths, or jargon ('refactor', 'CLI', 'endpoint')."),
    "worked_on": "one sentence: the concrete task in plain terms",
    "produced": "one sentence: what actually resulted (files, commits, answers, a sent message) or 'nothing shipped'",
    "wasted": "one sentence: tokens spent with no payoff (loops, failed retries) or 'no obvious waste'",
    "useful_percent": "integer 0-100, share of the work that moved toward the goal",
}


def latest_session():
    files = glob.glob(SESS_GLOB, recursive=True)
    if not files:
        return None
    return max(files, key=os.path.getmtime)


def resolve_path(arg):
    if arg is None:
        return latest_session()
    if os.path.isfile(arg):
        return arg
    hits = [p for p in glob.glob(SESS_GLOB, recursive=True) if arg in os.path.basename(p)]
    return max(hits, key=os.path.getmtime) if hits else None


def extract(path):
    """Fold a rollout into a compact transcript plus heuristic waste signals."""
    session_id = None
    cwd = None
    task = None
    narration = []
    tool_calls = []          # substantive calls, excludes TUI plumbing
    tool_errors = 0
    file_writes = 0
    commits = 0
    checks = 0
    tokens = 0
    # Plumbing calls: driving a sub-agent's TUI, planning scratchpads, searches.
    # Counting their back-to-back repeats as "loops" is what produced a false
    # "nothing shipped" verdict, so they are excluded from the loop signal.
    PLUMBING = {"write_stdin", "update_plan", "tool_search_call"}
    for line in open(path, errors="ignore"):
        try:
            obj = json.loads(line)
        except Exception:
            continue
        payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
        ptype = payload.get("type")
        if obj.get("type") == "session_meta" or ptype is None and payload.get("id"):
            session_id = session_id or payload.get("id") or payload.get("session_id")
            cwd = cwd or payload.get("cwd")
        if ptype == "user_message" and task is None:
            task = (payload.get("message") or "").strip()
        elif ptype == "agent_message":
            msg = (payload.get("message") or "").strip()
            if msg:
                narration.append(msg)
        elif ptype == "function_call":
            name = payload.get("name") or "tool"
            args = (payload.get("arguments") or "")
            if name not in PLUMBING:
                tool_calls.append(name)
            # Real work shows up inside shell commands as much as in named tools,
            # so inspect the arguments, not just the tool name.
            blob = args
            if name in ("apply_patch", "write", "edit") or "*** Begin Patch" in blob or "apply_patch" in blob:
                file_writes += 1
            if re.search(r"\bgit\s+commit\b", blob):
                commits += 1
            if "py_compile" in blob or re.search(r"\b(swift build|npm test|pytest|xcodebuild)\b", blob):
                checks += 1
        elif ptype == "function_call_output":
            out = json.dumps(payload.get("output") or payload).lower()
            if any(m in out for m in WASTE_MARKERS):
                tool_errors += 1
        elif ptype == "token_count":
            info = payload.get("info") or payload
            for k in ("total_tokens", "total", "tokens"):
                v = (info or {}).get(k) if isinstance(info, dict) else None
                if isinstance(v, (int, float)):
                    tokens = max(tokens, int(v))

    # Back-to-back identical substantive calls are a loop/retry smell.
    repeats = 0
    for i in range(1, len(tool_calls)):
        if tool_calls[i] == tool_calls[i - 1]:
            repeats += 1

    lines = []
    if task:
        lines.append("TASK: " + task[:1500])
    if narration:
        lines.append("\nWHAT THE AGENT SAID IT DID:")
        for n in narration[:12]:
            lines.append("- " + n[:400])
    if tool_calls:
        from collections import Counter
        counts = Counter(tool_calls)
        lines.append("\nTOOLS USED: " + ", ".join(f"{k}×{v}" for k, v in counts.most_common(12)))
    transcript = "\n".join(lines)[:MAX_TRANSCRIPT_CHARS]

    return {
        "session_id": session_id or os.path.basename(path),
        "path": path,
        "cwd": cwd,
        "tokens": tokens,
        "signals": {
            "tool_calls": len(tool_calls),
            "tool_errors": tool_errors,
            "file_writes": file_writes,
            "commits": commits,
            "checks": checks,
            "repeated_calls": repeats,
        },
        "transcript": transcript,
    }


def build_prompt(data):
    sig = data["signals"]
    return (
        "You are summarising one AI coding session for a usage dashboard. "
        "Be concrete and honest; if the session spun its wheels, say so.\n"
        "The signals below are rough heuristics, not ground truth. The agent's "
        "own narration is the best evidence of what actually happened; if a "
        "signal and the narration disagree, trust the narration.\n\n"
        f"Heuristic signals: {sig['tool_calls']} substantive tool calls, "
        f"{sig['tool_errors']} error-like results, {sig['file_writes']} patch writes, "
        f"{sig['commits']} git commits, {sig['checks']} build/compile checks, "
        f"{sig['repeated_calls']} back-to-back repeated calls, ~{data['tokens']} tokens.\n\n"
        f"{data['transcript']}\n\n"
        "Return ONLY a JSON object with these keys:\n"
        + json.dumps(SCHEMA_HINT, indent=2)
    )


def call_openai(prompt):
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        return None
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "response_format": {"type": "json_object"},
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.load(resp)
        return data["choices"][0]["message"]["content"]
    except (urllib.error.URLError, TimeoutError, KeyError, json.JSONDecodeError) as exc:
        print(f"openai backend failed: {exc}", file=sys.stderr)
        return None


def call_codex(prompt):
    codex = None
    for cand in (os.path.join(HOME, ".local/bin/codex"), "codex"):
        if os.path.isfile(cand) or cand == "codex":
            codex = cand
            break
    try:
        proc = subprocess.run(
            [codex, "exec", prompt + "\n\nReply with only the JSON object, no prose."],
            capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        print(f"codex backend failed: {exc}", file=sys.stderr)
        return None
    return proc.stdout


def parse_json(text):
    if not text:
        return None
    m = re.search(r"\{.*\}", text, re.DOTALL)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except Exception:
        return None


def load_cache():
    try:
        return json.load(open(CACHE))
    except Exception:
        return {}


def save_cache(cache):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(cache, fh, indent=2)
    os.replace(tmp, CACHE)


def run_model(prompt):
    # Default to the no-key codex CLI (spends ChatGPT plan quota, no metered
    # cost). Opt into the metered API with PACE_INSIGHT_BACKEND=openai.
    if os.environ.get("PACE_INSIGHT_BACKEND") == "openai":
        return call_openai(prompt) or call_codex(prompt)
    return call_codex(prompt) or call_openai(prompt)


def summarise_one(path):
    """Extract, summarise, and return the enriched insight dict (or None)."""
    data = extract(path)
    insight = parse_json(run_model(build_prompt(data)))
    if insight is None:
        return None
    insight["session_id"] = data["session_id"]
    insight["cwd"] = data["cwd"]
    insight["tokens"] = data["tokens"]
    insight["signals"] = data["signals"]
    return insight


def substantial_sessions(days, min_lines):
    """Recent rollouts worth summarising, newest first. Skips tiny sub-agent
    runs (few lines) that carry no meaningful task."""
    cutoff = time.time() - days * 86400
    paths = [p for p in glob.glob(SESS_GLOB, recursive=True)
             if os.path.getmtime(p) >= cutoff]
    paths.sort(key=os.path.getmtime, reverse=True)
    out = []
    for p in paths:
        try:
            lines = 0
            with open(p, errors="ignore") as fh:
                for lines, _ in enumerate(fh, 1):
                    if lines >= min_lines:
                        break
            if lines >= min_lines:
                out.append(p)
        except Exception:
            continue
    return out


def run_batch(limit, days, min_lines):
    """Pre-summarise up to `limit` recent substantial sessions not yet cached.
    This is what the background launchd job calls so the Sessions tab is already
    populated by the time you open it."""
    cache = load_cache()
    done = 0
    for path in substantial_sessions(days, min_lines):
        if done >= limit:
            break
        # Cheap uuid-from-filename check avoids re-reading cached sessions.
        m = re.search(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                      os.path.basename(path))
        if m and m.group(0) in cache:
            continue
        insight = summarise_one(path)
        if insight is None:
            continue
        cache[insight["session_id"]] = insight
        save_cache(cache)  # persist after each so a slow batch is resumable
        done += 1
        print(f"summarised {insight['session_id'][:8]}: {insight.get('one_line','')}", file=sys.stderr)
    print(f"batch done: {done} new insight(s)", file=sys.stderr)
    return 0


def main():
    ap = argparse.ArgumentParser(description="Summarise a Codex session.")
    ap.add_argument("session", nargs="?", help="session id fragment or rollout path; default = latest")
    ap.add_argument("--dry-run", action="store_true", help="print the extracted transcript, skip the model")
    ap.add_argument("--no-cache", action="store_true", help="ignore any cached insight")
    ap.add_argument("--force", action="store_true", help="recompute even if cached")
    ap.add_argument("--batch", type=int, metavar="N", help="pre-summarise up to N recent uncached sessions")
    ap.add_argument("--days", type=int, default=3, help="how far back --batch looks (default 3)")
    ap.add_argument("--min-lines", type=int, default=40, help="skip sessions shorter than this (default 40)")
    args = ap.parse_args()

    if args.batch is not None:
        return run_batch(args.batch, args.days, args.min_lines)

    path = resolve_path(args.session)
    if not path:
        print("no session found", file=sys.stderr)
        return 1
    data = extract(path)

    if args.dry_run:
        print(json.dumps({k: data[k] for k in ("session_id", "cwd", "tokens", "signals")}, indent=2))
        print("\n--- transcript ---\n" + data["transcript"])
        return 0

    cache = {} if args.no_cache else load_cache()
    if not args.force and data["session_id"] in cache:
        print(json.dumps(cache[data["session_id"]], indent=2))
        return 0

    insight = summarise_one(path)
    if insight is None:
        print("no model backend produced a valid insight (set OPENAI_API_KEY or install codex)", file=sys.stderr)
        return 2

    if not args.no_cache:
        cache[insight["session_id"]] = insight
        save_cache(cache)
    print(json.dumps(insight, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
