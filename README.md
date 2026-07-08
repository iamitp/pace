# Pace

**OpenAI deletes your Codex reset-credit history the moment a credit is used or expires. Pace keeps a local ledger of it.**

Pace is a macOS menu bar app that shows your live Claude Code and OpenAI Codex
rate-limit usage in one place: the 5-hour and weekly windows, how fast you are
burning them, and whether you are on pace to hit a cap before it resets.

It also does one thing no other tool does. Codex hands out "rate limit reset
credits" (banked resets you can spend to clear a window). The official
`rate-limit-reset-credits` endpoint drops a credit from its response the instant
you redeem it or it lapses, so there is no way to see which credits you used,
which you let expire, or when. Pace polls that endpoint on a schedule and keeps
a persistent local ledger, so your banked resets show a **Past resets** history
with used / expired badges alongside the ones you still hold.

The transparency gap is a known one: [openai/codex#29618](https://github.com/openai/codex/issues/29618).

## Screenshots

<!-- add: menu bar dial, banked-reset ledger card with Past resets, pace projection -->

## Features

- **Claude Code + Codex in one dial** — 5-hour and weekly windows for both, colour-coded.
- **Pace projection** — compares burn rate to elapsed time in the window and flags when you are running hot enough to hit the cap early.
- **Banked-reset ledger** — available resets with per-credit grant and expiry dates, plus a Past resets history of used and expired credits that the API itself no longer reports.
- **Live server truth** — reads the same `wham/usage` endpoint the Codex app uses, so the numbers match, and falls back to local session snapshots if the network blips.

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
git clone https://github.com/REPLACE_OWNER/pace.git
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
