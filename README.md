# xmarks

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell: bash | zsh](https://img.shields.io/badge/shell-bash%20%7C%20zsh-89e051.svg)](#install)
[![Requires: jq](https://img.shields.io/badge/requires-jq-orange.svg)](#install)

Bashmarks-style bookmarks for coding-agent sessions (Claude Code and Codex
CLI): save a mark, later jump back with one command that cd's into the
directory *and* resumes the exact session. See `DESIGN.md` for the
design notes.

## Install

```bash
make install
echo 'source ~/.local/bin/xmarks.sh' >> ~/.bashrc
```

`make install` puts `xmarks.sh` plus the `xs/xg/xl/xd` command wrappers
into `~/.local/bin` (override with `PREFIX=...`); `make uninstall` removes
them. The wrappers exist because shells inside a Claude Code session
(`! xs ...`) never read `.bashrc`; in interactive shells the sourced
functions shadow them. Only `xg` truly needs to be a function — the wrapper
version resumes fine but can't leave your shell in the starred session's
directory, which is why the `source` line is still worth adding (put it
above your bashrc's "not interactive" guard).

Requires `jq` (for first-message previews). `fzf` is optional — if present,
`xg` with no argument opens a fuzzy picker.

Sourcing `xmarks.sh` also registers tab completion for `xg`/`xs`/`xd` —
press `<TAB>` after any of them to complete an existing session's HASH.
Under bash this needs no separate step. Under zsh it needs the
completion system loaded first — if `xg <TAB>` doesn't do anything, add
this to `~/.zshrc` *before* the `source ~/.local/bin/xmarks.sh` line:

```bash
autoload -Uz compinit && compinit
```

## Usage

```bash
xs [hash] [note...]   # star/un-star (toggle). Inside a session, plain
                      # `xs` stars it, no hash needed. Outside one,
                      # `xs <hash>` targets any session by its xl HASH;
                      # a bare `xs` guesses the newest session for the
                      # current dir instead. Starring an already-starred
                      # session un-stars it (and clears its note).
                      # [note...] is optional and, when given, always
                      # overwrites whatever description (auto or
                      # previous) was showing; it's cleared on un-star.
xg [hash]             # cd there and resume the session (any session's
                      # HASH from xl, starred or not)
xl [-l|--long] [-s|--starred] [-r|--reverse] [-n N] [pattern]  # every
                      # session, oldest to newest (latest at the bottom);
                      # last 20 by default. -s limits to starred sessions;
                      # a pattern filters by substring (either lifts the
                      # cap); -n N overrides the count shown either way.
                      # -l is a git-log-style paragraph view (full hash,
                      # dir, untruncated summary), newest session first,
                      # instead of the oneline table. -r reverses
                      # whichever of those is the default order
xq                    # is this session/dir starred? (inside a session: `! xq`)
xd <hash>             # permanently delete a session's row (asks for
                      # confirmation first). Unlike un-starring via `xs`,
                      # the row is gone from `xl` for good.
xf [-n N] [-r] <pattern>  # search every session's actual transcript --
                      # not just xl's summary/note/detail -- for a real
                      # user prompt matching pattern. For "I know I asked
                      # this somewhere, which session was it?" One row
                      # per matching session (earliest match, oldest
                      # first, uncapped by default, same HASH `xg` takes,
                      # starred rows marked the same way as `xl`); a
                      # session with more than one matching message shows
                      # "(+N more)". -n caps the count, -r reverses the
                      # order. Two passes under the hood: a raw grep
                      # across every transcript file to shortlist
                      # candidates cheaply, then a jq parse of just those
                      # to match against clean prompt text instead of raw
                      # JSON bytes (so a hit inside a tool-call payload or
                      # assistant reply doesn't count).
xj [-n N] [-r] [pattern]  # list background jobs (Bash calls run with
                      # run_in_background: true) across every session,
                      # oldest first -- for "I kicked this off last night,
                      # which session was it in?" without needing to
                      # remember any keyword. One row per job (a session
                      # can start several); same HASH/star conventions as
                      # `xl`/`xf`. A pattern filters by substring against
                      # the command. Needs the PostToolUse hook (below) --
                      # it's what populates the job list in the first
                      # place.
```

The best way to star a session is from *inside* it:

```
! xs the one where we designed the pact schema
```

Shells spawned by Claude Code export `CLAUDE_CODE_SESSION_ID`, so this stars
the exact session — no guessing, no hash needed. Run outside a session,
`xs <hash>` targets any session directly by its `xl` HASH; a bare `xs`
falls back to the most recent session for the current directory, across
all tools and accounts. The `[note...]` is optional — if you skip it,
`xl` falls back to the session's auto-generated summary/detail once one
exists (see below), so a session never needs a manual description to show
up meaningfully.

All state lives in one file, `~/.xmarks/sessions.jsonl` (one JSON object
per line, one per session, override with `$XMARKS_SESSIONS`). Starring
a session with `xs` doesn't create a separate record — it just sets
`starred`/`note` on that session's existing row, alongside the
`date`/`reason`/`summary`/`detail` fields the hooks already track (see
below). If a session's transcript is gone, `xg` still cd's to the
directory and warns.

Upgrading from an older version migrates automatically the first time any
command runs — the old `~/.xmarks` file and `~/.xmarks-journal` are moved
in place, TSV `marks.tsv`/`journal.tsv` from a pre-JSONL version are
converted to `marks.jsonl`/`journal.jsonl`, and — the last step — those
two files are merged into one `sessions.jsonl` (a mark becomes
`starred: true` plus `name`/`note` on the journal row for the same
session id; a marked session with no journal row at all, e.g. a Codex
mark or one that predates the journal, becomes its own starred-only row).
Every intermediate file is kept as `.bak`, never deleted, so a conversion
mistake is always recoverable.

## Session journal: auto-summaries on exit (and before)

`make install-hook` registers a `SessionEnd` hook and a `UserPromptSubmit`
hook in every `~/.claude*` settings.json (each backed up to `.bak` first).
When a Claude Code session ends, the SessionEnd hook updates that
session's row with the real outcome: `reason`, an auto-generated
`summary`, and a longer `detail` — by default it asks haiku via
`claude -p` for both in one call: `summary` is ≤12 words for the `xl`
table columns, `detail` is a 2-4 sentence commit-message-style paragraph
(what was done, key decisions, outcome) shown in `xl -l`'s per-session
view (a few seconds, a fraction of a cent per session). Override the
model with `XMARKS_SUMMARY_MODEL` (any `--model` value `claude -p`
accepts) or set `XMARKS_AUTOSUMMARY=first` to skip the LLM entirely and
use the session's first user message as `summary` (`detail` stays unset
in that case). Starred sessions keep their `name`/`note` untouched — this
only ever updates `date`/`reason`/`summary`/`detail`.

The UserPromptSubmit hook writes an earlier, cheaper version of that same
update the moment the *first* prompt is sent — no LLM call, just that
prompt's own text (truncated) as the summary, with `reason` set to
`in_progress`. This exists for sessions that never reach a clean exit —
an SSH connection dropping partway through, say — which would otherwise
vanish entirely; the first prompt is usually the best one-line summary of
the session's intent anyway. If SessionEnd does fire afterward, it
overwrites `reason`/`summary` with the real outcome as usual — never two
rows for one session. Later prompts in the same session are a no-op for
this hook (it exits as soon as it sees a row already exists).

Browse everything with `xl` (oldest to newest, latest at the bottom; last
20 by default) or `xl <pattern>` to filter by substring, uncapped. `-n
<N>` overrides the count shown either way — `xl -n 5` for just the last
5, `xl -s -n 3` for the 3 most recent starred sessions. Every
row gets a HASH column (the first 6 characters of its session id) that
`xg <hash>` resumes directly — so a session never needs an `xs` at all to
be one command away — and starred rows get a `*` beside their hash.
`xl -s`/`--starred` narrows the
same listing to just starred sessions (what a plain `xl` used to show
before it grew to cover every session). The default view is a
`git log --oneline`-style table: it hides ACCOUNT, shows just the dir's
basename, shortens SUMMARY to keep things narrow (preferring the
manual note over the auto-summary when a session has one), and trails
with an AGE column (`3h`, `2d`, falling back to `Jul 20` or `Jul 20
2025` past a week — kubectl's `AGE` convention) instead of a full
timestamp, plus a PROMPTS column: how many real user prompts that
session had (a cheap count the SessionEnd hook takes from the
transcript alongside the summary — `-` for older rows recorded before
this existed). `xl -l`/
`--long` is `git log`-style instead — one paragraph block per session,
newest first (like real `git log`, the reverse of the oneline table's
oldest-first order), with the full session id, account, full path, the
exact `Date:`, and the note if set, else the longer LLM-generated
`detail`, else the short `summary`, wrapped like a commit body. `-r`/
`--reverse` flips whichever of those is the default order for the view
in use — `xl -r` puts the newest session at the top of the table,
`xl -l -r` matches real `git log --reverse` and puts the oldest session
first. Like git, both views color the
hash (and mark) and page through `$PAGER`/`less` when run at a terminal —
plain, unpaged text otherwise (piping to a file or another command), and
`NO_COLOR=1` turns colors off. `make uninstall-hook` removes all three hooks.

The SessionEnd hook itself always returns in well under a second: it
writes the heuristic summary synchronously, then — if an LLM summary is
wanted — launches a fully detached background job
(`xmarks-summarize-async`, via `setsid`) that asks the LLM and patches the
row in place once it's ready. This matters because SessionEnd hooks get
killed if they run too long; earlier versions called `claude -p` inline
and could be cancelled outright (losing the update) if that call stalled
— e.g. from a spend-limit block. Now a stalled or failed LLM call just
leaves the heuristic summary in place; the hook itself never waits on it.

## Background job tracking

`make install-hook` also registers a `PostToolUse` hook, matched to just
the `Bash` tool so it's a no-op for every other tool call. It fires after
every Bash call and, when that call was made with `run_in_background:
true`, appends a row (`date`, `session_id`, `dir`, `command`) to
`~/.xmarks/jobs.jsonl` (override with `$XMARKS_JOBS`) — a foreground
command is never logged. This is for "I kicked something off last night
across four or five sessions, which one was it?": browse the log with
`xj` (see Usage above), which resumes into the right session the same way
`xl`/`xf` do — no need to remember any wording, since the hook already
recorded it as it happened. Like the SessionEnd hook, this always returns
immediately (PostToolUse fires after the tool result is already back with
Claude, so there's nothing to block).

## Multiple accounts and tools

Each row records which tool it belongs to (`claude` or `codex`) and the
home dir its session lives in (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`, e.g.
`~/.claude-personal` vs `~/.claude-work`). `xg` dispatches accordingly —
`CLAUDE_CONFIG_DIR=... claude --resume` or `CODEX_HOME=... codex resume` —
so sessions from every account and both tools share one file, and `xl`
shows an ACCOUNT column for each (plus an AGENT column, but only when
starred sessions from both `claude` and `codex` actually coexist —
otherwise it's dropped as a repeated no-op value).

When saving from inside a Claude Code session, the session's own id and
config dir are used (Codex doesn't export a session id to child shells, so
there's no Codex equivalent). When guessing from a plain shell, `xs`
searches every existing `~/.claude*` and `~/.codex*` home and takes the
newest session for the current dir, whichever tool it came from. Codex has
no per-project session layout, so its side of the search scans recent
rollout files for a matching `cwd`. Restrict or reorder candidates with
`XMARKS_CONFIG_DIRS` / `XMARKS_CODEX_HOMES` (colon-separated).
