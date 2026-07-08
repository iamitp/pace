# The reset credits OpenAI quietly forgets

Codex has a feature that is easy to miss until you need it: rate limit reset
credits. When you hit a wall, you can spend a banked credit to clear the window
and keep working. You earn them over time, and they sit in your account waiting.

Last week I noticed my count had dropped from four to three, and I could not work
out why. None of them looked close to expiring. I had not consciously spent one.
The number just changed.

So I went digging, and found the reason the change was invisible: the endpoint
that lists your credits, `rate-limit-reset-credits`, only returns the ones that
are still available. The instant a credit is redeemed or lapses, it vanishes
from the response. There is no history object, no "used" list, no expiry log.
The count goes down and that is all you get. Other people have noticed the same
gap; there is an open issue about the missing expiry dates,
[openai/codex#29618](https://github.com/openai/codex/issues/29618).

For my own case I reconstructed what happened from Codex's local session logs.
The rollout files under `~/.codex/sessions` record the rate-limit state on every
request, and the trail was clear: my 5-hour window hit 100% mid-afternoon, and a
few minutes later both windows snapped to zero and the weekly reset date jumped
forward. That is the fingerprint of a redeemed credit. The one that got spent was
the oldest, the one closest to expiring, which is exactly the one you would want
to burn first. Nothing was lost. But I only knew that because I went and read the
logs by hand, and most people are not going to do that.

The fix is not complicated, and it is the kind of thing the client should do for
you. Poll the credits endpoint on a schedule. Every time you see a credit, write
it to a local ledger. When a credit you have seen before disappears from the
response, mark it: redeemed if it went before its expiry date, expired if it went
after. Now you have the history the API refuses to keep.

I built that into Pace, a small macOS menu bar app I use to watch Claude Code and
Codex usage. It already showed the available credits with their expiry dates.
Now it keeps the ledger too, so the banked resets have a "Past resets" section
with used and expired badges next to the ones I still hold. When a credit gets
spent, I can see which one and when, instead of watching a number tick down and
wondering.

Everything runs locally. The poller reads my own token from `~/.codex/auth.json`,
calls the same usage endpoint the official Codex client calls, and writes JSON to
my home directory. No servers, nothing leaves the machine. It is open source
under MIT if you want the ledger, or just the trick.

The broader point is small but it keeps coming up with these tools. The data you
need is usually there, one layer down, in a local log or an undocumented endpoint
the client already talks to. The vendor surfaces the number that is convenient
and drops the context around it. Keeping your own ledger is often the whole
product.

Pace: https://github.com/REPLACE_OWNER/pace
