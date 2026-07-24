---
name: mark
description: Bookmark the current Claude Code session with xmarks, auto-generating a short summary as the note. Use when the user says /mark or asks to bookmark, mark, or save this session for later.
---

# Mark this session

Save an xmarks bookmark for the current session by running the `xs`
command, so the user can later find it in `xl -s` and run `xg <hash>` in
a terminal to cd back to this directory and resume this exact
conversation.

## Steps

1. **Determine the note.** If arguments were given, they are the note —
   use them verbatim. Otherwise write a summary of the session in at
   most 10 words, stating what was actually worked on or decided, not
   the topic alone ("designed pact schema v2, settled on TSV storage",
   not "discussion about pact").

2. **Save it** with Bash:

   ```bash
   xs <note>
   ```

   `xs` is on PATH (installed by xmarks' `make install`). Inside a
   Claude Code session it reads `CLAUDE_CODE_SESSION_ID` and
   `CLAUDE_CONFIG_DIR` from the environment, so it stars this exact
   session on the right account with no guessing — no hash argument
   needed here. Do not quote the note as a single argument — `xs` joins
   all of its arguments into the note.

3. **Confirm to the user**: echo back the note you wrote, and the
   session's HASH (from `xs`'s own output) they can later use as
   `xg <hash>` from any terminal.

## Failure modes

- `xs: command not found` — xmarks isn't installed; tell the user to
  run `make install` in the xmarks repo.
- If the session is already starred, running `xs` again un-stars it
  (toggle behavior) instead of updating the note — check `xq` first if
  unsure, and warn the user before running `xs` on an already-starred
  session.
