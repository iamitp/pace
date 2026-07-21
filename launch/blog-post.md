# The token counter that never answered the real question

I have tried most of the Claude Code and Codex usage trackers. They are good at
what they do. They show a bar that fills up, a percentage of your window spent, a
countdown to the reset. I kept one in my menu bar for months.

And every time I looked at it, I had the same slightly hollow feeling. The number
told me I had burned through 60% of my week. It never told me whether that 60%
had been worth anything. I could not tell, from the meter, whether I had shipped
five features or spent the afternoon watching an agent retry the same failing
build. The usage was measured precisely. The value was invisible.

The thing is, the value is not actually hidden. It is sitting right there in the
logs. Every Codex session writes a rollout file under `~/.codex/sessions`, and
those files are not just token counts. They are the whole transcript: the task
you gave, every command the agent ran, every result it got back. Everything you
would need to say what a session accomplished is already on disk. The trackers
just throw it away and keep the number.

So I added a layer to my app that keeps it instead. It reads a session's
transcript, has a model summarise it, and shows a short retrospective in place of
the technical session name:

    worked on: address six code-review findings in the CLI modules
    produced:  committed fixes for suffix resolution and payee normalisation
    wasted:    some wheel-spin, repeated retries and a few error results
    useful:    35%

The last two lines are the ones I actually wanted. Useful versus wasted is the
question a token counter cannot answer and a transcript can, because the waste is
right there in the text: the same error retried five times, a long stretch with
no commits, a session that ended without shipping anything.

Getting it honest took one good failure. My first version read a session, saw
zero file writes in its heuristics, and declared "nothing shipped, 0% useful."
Except the session had committed two files. The writes had gone through shell
commands, not the named tool I was counting, so my signal was blind to them and
the model trusted the signal. The fix was not just to count commits properly. It
was to tell the model that the raw counts are hints, and the agent's own account
of what it did is the better evidence. Trust the story over the tally. After that
the same session came back as "committed suffix and payee fixes, some wheel-spin,
35% useful," which is exactly right.

It runs locally. The summariser reads the transcript you already streamed to
Codex while the session was live, so there is no new exposure, and it uses either
an `OPENAI_API_KEY` or the `codex` CLI you already have. Each session is
summarised once and cached. The app still does the ordinary usage things too:
5-hour and weekly windows for both Claude Code and Codex, pace projection, and a
local history of your banked reset credits.

The broader idea is one I keep running into with these tools. The data you want
is usually already on your machine, one layer down, in a log the client wrote and
then ignored. The vendor surfaces the convenient number and drops the context
around it. Keeping your own version of the context is often the entire product.

Pace is open source under MIT: https://github.com/iamitp/pace
