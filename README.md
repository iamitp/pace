# Pace

Native macOS menu bar meter for OpenAI Codex and ChatGPT quota - live thrust, cap ETA, and the reset-credit ledger.

![Pace menu bar](assets/readme/menubar.png)

![Pace popover](assets/readme/popover.png)

## Why Pace

OpenAI's credits endpoint only returns *available* reset credits. The moment one is redeemed or expires it vanishes from the response, and no supported surface shows you where it went ([openai/codex#29618](https://github.com/openai/codex/issues/29618) asked for credit detail; the app now shows available credits and expiry, but still no history).

Pace keeps a local ledger, so every credit you redeem or let lapse is recorded with a timestamp. Your history stays yours.

It also reads the wire-level rate limits that actually gate the Codex engine - the same numbers Codex streams into its own session logs - which, since the July 2026 unified ChatGPT app, can differ substantially from what the app's Usage panel shows.

## Features

- Live thrust bars in the menu bar (2s latency whilst a session writes, zero cost idle)
- One big quota percentage
- Conditional cap ETA (e.g. "empty in 38m" only when the burn would beat the reset)
- Popover with 15-minute thrust chart
- 5-hour and weekly quota pools, including multiple weekly pools
- Banked reset credits with expiry dates and full redeemed/expired history
- Recent sessions from local Codex CLI logs

## How It Works / Privacy

Pace reads from:

- `~/.codex/sessions` rollout JSONLs (local Codex CLI session logs)
- `~/.codex/auth.json` (your local Codex credential file)

Pace calls only OpenAI's own usage endpoints, authenticated with your existing token. It makes no third-party calls, stores no telemetry, and sends nothing off the Mac. Session history, burn rates, and the reset ledger are computed and stored locally.

## Install

### Option A: Download from Releases

Download the notarised `.zip` from [Releases](https://github.com/iamitp/pace/releases), unzip, and drag `Pace.app` to `/Applications`.

### Option B: Brew

```bash
brew install --cask iamitp/tap/pace
```

### Option C: Build from Source

```bash
./script/build_and_run.sh
```

The build script generates a deterministic macOS `.icns` app icon and embeds it, along with a privacy manifest.

## Requirements

- macOS 13 or later
- Codex CLI installed and signed in, or the ChatGPT/Codex desktop app signed in

## FAQ

**Why does Pace disagree with the ChatGPT app's Usage panel?**

They are different meters. Since the July 2026 unification, the app's Usage panel reports the shared agentic pool, while the Codex engine's own sessions stream wire-level `rate_limits` that can sit at a very different number (observed 60+ points apart on launch day). Pace reads the wire meter, because that is the one that stops your sessions.

**Does Pace support Claude Code?**

An experimental combined mode exists - toggle "Also track Claude Code" in the settings menu, or set `PACE_CODEX_ONLY=0`. Codex-only is the default and better tested.

**What do the menu bar elements mean?**

The bars are live thrust (token flow over the last few minutes, faded-to-solid). The big number is the percentage of the 5-hour window remaining. The small number appears only when it matters: a dim countdown to the reset when you are low, or a bold cap ETA when your current burn would empty the window before the reset rescues you.

## Licence

MIT. Copyright (c) 2026 Amit Patnaik.
