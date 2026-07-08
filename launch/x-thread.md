# X thread draft

**1/**
Codex hands out "reset credits" you can spend to clear a rate limit window.

The problem: the moment you use one or it expires, the API deletes it. There is
no history. I noticed my count drop from 4 to 3 and had no idea which one went
or why.

So I built the ledger OpenAI does not give you.

**2/**
Pace is a macOS menu bar app. Claude Code and Codex on one dial: the 5-hour and
weekly windows, burn rate, and whether you are on pace to hit the cap before it
resets.

**3/**
The part I have not seen anywhere else: banked resets with a "Past resets"
history. It polls the credits endpoint on a timer and keeps a local record, so
used and expired credits stay visible after the API drops them.

The missing expiry visibility is a known gripe: openai/codex#29618.

**4/**
Local-first. The poller reads your own token from ~/.codex/auth.json, calls the
same usage endpoint the Codex client uses, and writes JSON to your home
directory. No servers, no telemetry.

**5/**
Swift, macOS 13+, MIT. Build from source.

There are already solid usage trackers (ccusage, ClaudeBar, CodexBar). I built
Pace for the credit-history gap. If you hoard resets and forget to spend them,
this is for you.

https://github.com/REPLACE_OWNER/pace
