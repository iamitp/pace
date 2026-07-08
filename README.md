# Pace

**A macOS menu bar app that turns your Claude Code and Codex usage into something you can actually read.**

Pace shows your live Claude Code and OpenAI Codex rate-limit usage in one place:
the 5-hour and weekly windows, how fast you are burning them, and whether you are
on pace to hit a cap before it resets.

It also keeps a local history of your Codex "rate limit reset credits" (the banked
resets you can spend to clear a window). The credits endpoint lists only the ones
currently available, so once you redeem a credit or it expires it drops off the
list. Pace polls on a schedule and remembers them, so your banked resets show a
**Past resets** history with used / expired badges alongside the ones you still
hold.

## Screenshots

<!-- add: menu bar dial, banked-reset ledger card with Past resets, pace projection -->

## Features

- **Session intelligence** — every usage tracker shows how many tokens you spent. Pace tells you what they *bought*. It reads the full transcript already sitting in your Codex session logs, has a model summarise it, and shows a plain-English line per session: what you worked on, what it produced, and how much of the spend was useful versus wheel-spinning on a failing build. See [Session intelligence](#session-intelligence) below.
- **Claude Code + Codex in one dial** — 5-hour and weekly windows for both, colour-coded.
- **Pace projection** — compares burn rate to elapsed time in the window and flags when you are running hot enough to hit the cap early.
- **Banked-reset ledger** — available resets with per-credit grant and expiry dates, plus a Past resets history of used and expired credits that the live endpoint no longer lists.
- **Live server truth** — reads the same `wham/usage` endpoint the Codex app uses, so the numbers match, and falls back to local session snapshots if the network blips.

## Session intelligence

Your Codex session logs under `~/.codex/sessions` are not just token counts. They
hold the whole transcript: the task you gave, every tool call, every result.
`scripts/session-insight.py` distils one session into a compact summary, has a
model read it, and returns a structured retrospective:

```
$ python3 scripts/session-insight.py            # latest session
{
  "one_line": "Fixed card-suffix and payee normalisation across two commits.",
  "worked_on": "Address six code-review findings in the CLI and library modules.",
  "produced": "Committed fixes for suffix resolution and payee normalisation.",
  "wasted": "Some wheel-spin: repeated retries and several error results.",
  "useful_percent": 35
}
```

It reads real signals from the log (commits, compile checks, patch writes, error
results, retry loops) and is told to trust the agent's own narration over the
heuristics, so the verdict is honest rather than a guess from raw counts.

Model backends, tried in order: `OPENAI_API_KEY` (OpenAI Chat Completions), then
the `codex` CLI you already have (uses your ChatGPT plan). Results cache to
`~/.claude/pace-session-insights.json`, so each session is summarised once.
Use `--dry-run` to see exactly what would be sent to the model before enabling it.

### Which backend, and what it costs

A session is small to summarise: about 700 input tokens and 150 output tokens,
because Pace sends a trimmed transcript, not the raw log. Set `PACE_INSIGHT_MODEL`
to pick the model (default `gpt-5-mini`).

| Backend | Cost | Notes |
| --- | --- | --- |
| `codex` CLI | no API charge | Uses your ChatGPT plan, but spends the same rate-limit quota Pace is watching, and is slower (a full agent turn). Fine for the odd on-demand session. |
| `gpt-5-nano` | ~$0.0001 / session | ~10,000 sessions per dollar. Near-free; good enough for one-line summaries. |
| `gpt-5-mini` | ~$0.0005 / session | ~2,000 sessions per dollar. The default; sharper useful-vs-wasted calls. |

At roughly 20 substantive sessions a day, `gpt-5-mini` runs about **$0.28 a
month**. Summarising *every* session including sub-agent runs is still only about
**$1.40 a month**. Caching means each session is billed once, however often you
look at it.

## How it works

Everything runs locally against sources you already have:

- **Codex** — a small Python poller (`scripts/codex-usage-poll.py`) reads your
  own token from `~/.codex/auth.json`, calls the Codex usage and reset-credit
  endpoints, and writes `~/.claude/codex-usage.json` plus a
  `~/.claude/codex-resets-ledger.json` ledger. Nothing leaves your machine.
- **Claude Code** — reads the rate-limit data Claude Code already writes locally.

## Install

Build from source (Swift 6, macOS 13+):

```sh
git clone https://github.com/iamitp/pace.git
cd pace
swift build -c release
./script/build_and_run.sh   # builds Pace.app and launches it
```

Then set up the Codex poller so the data stays fresh:

```sh
# edit the path inside the plist to point at your clone, then:
cp scripts/com.pace.codex-usage-poll.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.pace.codex-usage-poll.plist
```

Optional: point `PACE_TODO_FILE` at a markdown file whose `## ` headings are
your tasks to get a todo count in the panel.

## Privacy

Pace is local-first and has no telemetry, analytics, or servers. Your tokens
never leave your Mac; they are used only to call the same OpenAI endpoints the
official Codex client calls. All usage and ledger data is written to files in
your home directory.

## License

MIT — see [LICENSE](LICENSE).
