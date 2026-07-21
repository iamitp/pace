# X thread draft

**1/**
Every Claude Code and Codex usage tracker shows the same thing: how many tokens
you burned.

None of them tell you what the tokens bought.

So I built one that reads your sessions and tells you what actually shipped, and
what just spun its wheels.

**2/**
Your Codex logs under ~/.codex/sessions aren't just counts. They hold the whole
transcript: the task, every tool call, every result.

Pace reads a session, has a model summarise it, and shows this instead of a
technical name:

worked on / produced / wasted / useful %

**3/**
Example, real session:

worked on: six code-review fixes in the CLI
produced: committed suffix + payee-normalisation fixes
wasted: some wheel-spin, repeated retries
useful: 35%

That "useful vs wasted" line is the whole point. The transcript shows it: commits
and green builds vs the same error retried five times.

**4/**
It runs locally. It reads the transcript you already sent to Codex during the
session, and uses either your OPENAI_API_KEY or the codex CLI you already have.
Cached, so each session is summarised once.

**5/**
It still does the basics too: 5h and weekly windows for both providers, pace
projection, and a local history of your banked reset credits.

Swift menu bar app + Python summariser. MIT. Build from source.

https://github.com/iamitp/pace
