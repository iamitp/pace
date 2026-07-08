# Show HN draft

## Title

Show HN: Pace, a macOS menu bar app that keeps a history of your Codex reset credits

## First comment

I use Claude Code and Codex side by side, and I kept getting surprised by rate
limits: no clear sense of how fast I was burning a window, or whether I would
hit the cap before it reset. So I built a menu bar app that puts both providers
on one dial with a pace projection.

While building it I hit something odd. Codex gives you "rate limit reset
credits" you can spend to clear a window. The endpoint that lists them drops a
credit the moment you redeem it or it expires, so there is no record of which
ones you used and which you let lapse. I noticed my count had quietly dropped
from 4 to 3 and could not tell why. There is an open issue about the missing
expiry visibility (openai/codex#29618).

Pace polls that endpoint on a timer and keeps a local ledger, so the banked
resets now show a "Past resets" section with used and expired credits, not just
the ones still available. As far as I can tell no other tool tracks that.

It is local-first: the poller reads your own token from ~/.codex/auth.json,
calls the same usage endpoint the Codex app uses, and writes JSON to your home
directory. No servers, no telemetry. Swift, MIT licensed, build from source.

There are already good usage trackers out there (ccusage, ClaudeBar, CodexBar,
Claude-Code-Usage-Monitor). The reset-credit ledger is the part I had not seen
anywhere, so I am mostly curious whether the credit-history problem bothers
anyone else or if I am the only one hoarding resets I forget to spend.

Repo: https://github.com/REPLACE_OWNER/pace
