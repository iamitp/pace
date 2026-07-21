# Show HN draft

## Title

Show HN: Pace, a Claude Code and Codex usage tracker that tells you what the tokens bought

## First comment

There are a lot of good tools now that show how much of your Claude Code or Codex
quota you have burned. I used a few of them. The number never told me what I
actually wanted to know: was the spend worth anything?

So I added a layer to my menu bar app. Your Codex session logs under
~/.codex/sessions are not just token counts, they hold the whole transcript: the
task, every tool call, every result. Pace reads a session, has a model summarise
it, and shows a plain-English retrospective instead of a technical session name:

  worked on: address six code-review findings in the CLI modules
  produced:  committed fixes for suffix resolution and payee normalisation
  wasted:    some wheel-spin, repeated retries and a few error results
  useful:    35%

The useful-versus-wasted part is the bit I care about. The transcript exposes it
directly: commits and passing builds on one side, the same error retried five
times or a session that ended with nothing shipped on the other. An early version
got this confidently wrong (called a session "nothing shipped" because my file
write detector missed shell-based patches), which was a useful lesson: the raw
counts lie, so the model is told to trust the agent's own narration over the
heuristics.

It runs locally. The summariser reads the transcript you already streamed to
Codex during the session, and uses either an OPENAI_API_KEY or the codex CLI you
already have. Results cache so each session is summarised once. Pace also does the
ordinary things: 5-hour and weekly windows for both providers, pace projection,
and a local history of your banked reset credits.

Swift menu bar app plus a Python summariser, MIT, build from source.

Repo: https://github.com/iamitp/pace

Curious whether "what did my tokens actually produce" is a question other people
have, or if I am the only one who kept staring at a percentage wanting more.
