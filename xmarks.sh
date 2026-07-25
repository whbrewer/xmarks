# xmarks — bashmarks-style bookmarks for coding-agent sessions
# (Claude Code and Codex CLI).
# Source from .bashrc:  source ~/.local/bin/xmarks.sh
#
#   xs [hash] [note...]    star/un-star (toggle). Inside a session, plain
#                          `xs` stars it, no hash needed. Outside one,
#                          `xs <hash>` targets any session by its xl HASH;
#                          a bare `xs` guesses the newest session for
#                          $PWD instead. Starring an already-starred
#                          session un-stars it (and clears its note).
#                          [note...] overwrites the auto summary/detail;
#                          cleared on un-star.
#   xg [hash]              cd to its dir and resume the session (any
#                          session's HASH from xl, starred or not)
#   xl [-l|--long] [-s|--starred] [-r|--reverse] [-n N] [pattern]  every
#                          session, oldest to newest (latest at the
#                          bottom); each row's HASH is an xg shortcut,
#                          starred rows get a * beside it. Last 20 by
#                          default; -s limits to starred sessions, a
#                          pattern filters (either lifts the cap); -n N
#                          overrides the count shown either way; -l
#                          shows a git-log-style paragraph per session
#                          instead of the oneline table, newest session
#                          first (like real `git log`, unlike the
#                          oneline table above); -r reverses whichever
#                          of those is the default order
#   xq                     is this session / directory starred?
#   xd <hash>              permanently delete a session's row (unlike
#                          un-starring via `xs`, this drops it from `xl`
#                          entirely -- summary/detail/note gone for good).
#                          Asks for confirmation first.
#
# All state lives in one file, ~/.xmarks/sessions.jsonl, one JSON object
# per session:
#   {date, session_id, dir, home, tool, reason, summary, detail, starred, note}
# date/reason/summary are auto-tracked by the hooks: the UserPromptSubmit
# hook seeds a row right after the first prompt (reason "in_progress",
# summary = that prompt's own text, no LLM call), so a session that dies
# without a clean exit -- a dropped SSH connection, say -- still shows up
# instead of vanishing entirely; SessionEnd overwrites reason/summary with
# the real outcome (a heuristic first message, patched in place with an
# LLM summary shortly after, unless XMARKS_AUTOSUMMARY=first). That same
# LLM pass also writes detail, a longer commit-message-style paragraph
# (what was done, key decisions, outcome) -- summary stays a short
# one-liner for the table, detail is only ever shown in `xl -l`'s
# per-session paragraph view, since it doesn't fit a table row.
# starred/note are only ever touched by `xs`, which toggles starred and
# clears note on un-star. note is optional free text that, when given,
# always wins over detail/summary for display; when absent, listings
# fall back to detail, then the short auto summary -- so a session never
# needs a manual description to be meaningfully listed.
# tool is "claude" or "codex" (default "claude") and home is the
# CLAUDE_CONFIG_DIR / CODEX_HOME the session lives in, so sessions from
# different accounts and tools coexist and resume correctly.
#
# Candidate homes when guessing: $XMARKS_CONFIG_DIRS (colon-separated)
# else every existing ~/.claude*; $XMARKS_CODEX_HOMES else $CODEX_HOME
# else every existing ~/.codex*. $XMARKS_SUMMARY_MODEL picks the model the
# SessionEnd hook's background job uses for summary/detail (default
# haiku, the cheapest/fastest tier); see hooks/xmarks-summarize-async.

# Resolved inside each function (not at source time): Claude Code's shell
# snapshots restore functions but not unexported variables, so a top-level
# assignment would be lost in `!` shells inside sessions.

# One-time migration from the old flat dotfiles (~/.xmarks as a plain
# file, ~/.xmarks-journal) to the ~/.xmarks/ directory layout, then from
# TSV to JSONL, then from separate marks.jsonl/journal.jsonl to one
# sessions.jsonl. Cheap and idempotent -- safe to call from every
# command; once migrated it's just a few stat checks that find nothing
# left to do.
am_migrate () {
  local dir="$HOME/.xmarks"
  # One-time migration from the pre-rename ~/.agentmarks/ directory (the
  # repo was called agentmarks before it became xmarks).
  if [ -d "$HOME/.agentmarks" ] && [ ! -e "$dir" ]; then
    mv "$HOME/.agentmarks" "$dir"
  fi
  if [ -f "$dir" ] && [ ! -d "$dir" ]; then
    # The old marks file and the new marks directory share this exact
    # path, so the file has to move out of the way before mkdir can
    # claim it.
    local tmp; tmp="$(mktemp "$HOME/.xmarks-migrate.XXXXXX")"
    mv "$dir" "$tmp"
    mkdir -p "$dir"
    mv "$tmp" "$dir/marks.tsv"
  else
    mkdir -p "$dir"
  fi
  if [ -f "$HOME/.xmarks-journal" ] && [ ! -f "$dir/journal.tsv" ]; then
    mv "$HOME/.xmarks-journal" "$dir/journal.tsv"
  fi
  rm -f "$HOME/.xmarks-journal.lock" "$HOME/.xmarks-journal.tmp" 2>/dev/null
  # TSV -> JSONL, one-time: the old marks.tsv (8 tab-separated columns) is
  # kept as marks.tsv.bak rather than deleted, so a conversion mistake is
  # recoverable. jq's split("\t") -- unlike bash's `read` -- doesn't
  # collapse adjacent delimiters, so old rows with an empty field convert
  # correctly.
  if [ -f "$dir/marks.tsv" ] && [ ! -f "$dir/marks.jsonl" ]; then
    jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t"))
      | .[]
      | {name: .[0], dir: .[1], session_id: .[2], note: .[3], date: .[4],
         first_message: .[5], home: .[6],
         tool: (if (.[7] // "") == "" then "claude" else .[7] end)}
    ' "$dir/marks.tsv" > "$dir/marks.jsonl" \
      && mv "$dir/marks.tsv" "$dir/marks.tsv.bak"
  fi
  # Same TSV -> JSONL move for the journal (date, session_id, dir, home,
  # reason, summary), kept as journal.tsv.bak.
  if [ -f "$dir/journal.tsv" ] && [ ! -f "$dir/journal.jsonl" ]; then
    jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t"))
      | .[]
      | {date: .[0], session_id: .[1], dir: .[2], home: .[3], reason: .[4],
         summary: .[5]}
    ' "$dir/journal.tsv" > "$dir/journal.jsonl" \
      && mv "$dir/journal.tsv" "$dir/journal.tsv.bak"
  fi
  # marks.jsonl + journal.jsonl -> one sessions.jsonl: a mark becomes
  # starred=true (+ name/note) on the journal row for the same session
  # id. A marked session with no matching journal row at all (a codex
  # mark -- the hooks are Claude-only -- or a mark that predates the
  # journal) becomes its own starred-only row instead. Both source files
  # are kept as .bak, never deleted.
  if { [ -f "$dir/marks.jsonl" ] || [ -f "$dir/journal.jsonl" ]; } \
       && [ ! -f "$dir/sessions.jsonl" ]; then
    if jq -nc \
      --slurpfile marks <(cat "$dir/marks.jsonl" 2>/dev/null) \
      --slurpfile journal <(cat "$dir/journal.jsonl" 2>/dev/null) '
      ($marks | map({key: .session_id, value: .}) | from_entries) as $markidx
      | ($journal | map(.session_id)) as $jsids
      | ($journal | map(
          . as $j
          | ($markidx[$j.session_id] // null) as $m
          | {date: $j.date, session_id: $j.session_id, dir: $j.dir,
             home: $j.home, tool: ($m.tool // "claude"),
             reason: $j.reason, summary: $j.summary,
             starred: ($m != null), name: ($m.name // null),
             note: (if $m != null and ($m.note // "-") != "-"
                    then $m.note else null end)}
        )) as $fromjournal
      | ($marks | map(select((.session_id as $sid | $jsids | index($sid)) == null))
                | map({date: .date, session_id: .session_id, dir: .dir,
                       home: .home, tool: (.tool // "claude"), reason: null,
                       summary: (if (.first_message // "-") == "-"
                                 then null else .first_message end),
                       starred: true, name: .name,
                       note: (if (.note // "-") == "-"
                              then null else .note end)})) as $marksonly
      | ($fromjournal + $marksonly)[]
    ' > "$dir/sessions.jsonl.new" && [ -s "$dir/sessions.jsonl.new" ]; then
      mv "$dir/sessions.jsonl.new" "$dir/sessions.jsonl"
      [ -f "$dir/marks.jsonl" ] && mv "$dir/marks.jsonl" "$dir/marks.jsonl.bak"
      [ -f "$dir/journal.jsonl" ] && mv "$dir/journal.jsonl" "$dir/journal.jsonl.bak"
    else
      # Conversion failed (or produced nothing) -- leave the source files
      # in place untouched rather than risk losing marks/journal history;
      # am_migrate will just retry next time it's called.
      rm -f "$dir/sessions.jsonl.new"
    fi
  fi
}

am_claude_dirs () {
  if [ -n "${XMARKS_CONFIG_DIRS:-}" ]; then
    printf '%s\n' "$XMARKS_CONFIG_DIRS" | tr ':' '\n'
  else
    local d
    for d in "$HOME"/.claude "$HOME"/.claude-*; do
      [ -d "$d/projects" ] && printf '%s\n' "$d"
    done
  fi
}

am_codex_homes () {
  if [ -n "${XMARKS_CODEX_HOMES:-}" ]; then
    printf '%s\n' "$XMARKS_CODEX_HOMES" | tr ':' '\n'
  elif [ -n "${CODEX_HOME:-}" ]; then
    printf '%s\n' "$CODEX_HOME"
  else
    local d
    for d in "$HOME"/.codex "$HOME"/.codex-*; do
      [ -d "$d/sessions" ] && printf '%s\n' "$d"
    done
  fi
}

am_proj_dir () {
  # Claude Code stores sessions under <config_dir>/projects/<munged cwd>,
  # where every non-alphanumeric character of the cwd becomes '-'.
  printf '%s/projects/%s' "$1" "$(printf '%s' "$2" | sed 's/[^A-Za-z0-9]/-/g')"
}

am_codex_latest () {
  # Newest codex session for cwd $2 under home $1. Codex files are date-
  # organized with no per-project dir, so scan newest-first (path order is
  # chronological) and match session_meta.cwd on line one.
  local f
  while IFS= read -r f; do
    if [ "$(head -1 "$f" | jq -r '.payload.cwd // empty' 2>/dev/null)" = "$2" ]; then
      printf '%s\n' "$f"; return 0
    fi
  done < <(find "$1/sessions" -name '*.jsonl' 2>/dev/null | sort -r | head -200)
  return 1
}

am_is_codex () {
  # Codex rollout files start with a session_meta record.
  head -c 200 "$1" 2>/dev/null | grep -q '"type":"session_meta"'
}

am_account () {
  # Short display name for a home dir: ~/.claude-work → work, ~/.codex → default.
  local b; b="$(basename "$1")"
  case "$b" in
    .claude|.codex) echo default ;;
    .claude-*) echo "${b#.claude-}" ;;
    .codex-*) echo "${b#.codex-}" ;;
    *) echo "$b" ;;
  esac
}

am_truncate () {
  # Truncate $1 to at most $2 chars total, ellipsis included, so the
  # displayed width never exceeds $2 (e.g. "traced Fugaku embedding
  # privacy risk, AIDRIN metrics" is exactly 52 chars, the default cap).
  local s="$1" max="$2"
  if [ "${#s}" -gt "$max" ]; then
    printf '%s...' "${s:0:$((max - 3))}"
  else
    printf '%s' "$s"
  fi
}

am_date_fmt () {
  # $1 = a stored "YYYY-MM-DD HH:MM" date, $2 = output format. GNU `date -d`
  # parses that directly; BSD/macOS date has no -d and needs the input
  # format spelled out via -j -f instead.
  date -d "$1" "$2" 2>/dev/null || date -j -f '%Y-%m-%d %H:%M' "$1" "$2" 2>/dev/null
}

am_relative_date () {
  # $1 = a stored "YYYY-MM-DD HH:MM" date, for xl's compact table (xl -l
  # keeps the full timestamp). Falls back to the raw string if it can't be
  # parsed (e.g. a hand-edited row).
  local then_epoch now_epoch diff
  then_epoch="$(am_date_fmt "$1" +%s)" || { printf '%s' "$1"; return; }
  now_epoch="$(date +%s)"
  diff=$((now_epoch - then_epoch))
  if [ "$diff" -lt 60 ]; then
    printf 'now'
  elif [ "$diff" -lt 3600 ]; then
    printf '%dm' "$((diff / 60))"
  elif [ "$diff" -lt 86400 ]; then
    printf '%dh' "$((diff / 3600))"
  elif [ "$diff" -lt 604800 ]; then
    printf '%dd' "$((diff / 86400))"
  elif [ "$(am_date_fmt "$1" +%Y)" = "$(date +%Y)" ]; then
    am_date_fmt "$1" '+%b %d'
  else
    am_date_fmt "$1" '+%b %d %Y'
  fi
}

am_page () {
  # Page like git does: only when stdout is the terminal itself, so
  # `xl | grep foo` or `xl > file` still gets plain, unpaged text. Honors
  # $PAGER; falls back to `less -FRX` (-F: quit if it fits one screen, -R:
  # show color codes as color instead of garbage, -X: don't clear the
  # screen on exit) so scrollback isn't wiped; falls back further to
  # `cat` if neither is available.
  if [ -t 1 ]; then
    if [ -n "${PAGER:-}" ]; then
      $PAGER
    elif command -v less >/dev/null 2>&1; then
      less -FRX
    else
      cat
    fi
  else
    cat
  fi
}

am_display_dir () {
  # $1 = raw dir, $2 = "1" for the full ~-shortened path (xl -l); else
  # just the basename, so default listings stay narrow.
  local dir="$1"
  case "$dir" in
    "$HOME") dir="~" ;;
    "$HOME"/*) dir="~${dir#"$HOME"}" ;;
  esac
  if [ "$2" != 1 ] && [ "$dir" != "~" ] && [ "$dir" != "/" ]; then
    dir="$(basename "$dir")"
  fi
  printf '%s' "$dir"
}

am_first_msg () {
  # First real user message of a session file ($1), one line, trimmed.
  if am_is_codex "$1"; then
    jq -r 'select(.type == "event_msg" and .payload.type == "user_message")
           | .payload.message' "$1" 2>/dev/null
  else
    jq -r 'select(.type == "user" and .isSidechain != true)
           | .message.content
           | if type == "string" then .
             else (map(select(.type == "text") | .text) | join(" ")) end' \
        "$1" 2>/dev/null
  fi | sed 's/^[[:space:]]*//' | grep -v -e '^<' -e '^$' \
     | head -1 | tr '\t' ' ' | cut -c1-70
}

xs () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  # A hash prefix naming an existing session, given outside a session, is
  # consumed as the target; every other argument (in-session always, or
  # anything left after a hash) is note text.
  local session_id="${CLAUDE_CODE_SESSION_ID:-}"
  local arg1="${1:-}"
  local hash_arg=""
  if [ -z "$session_id" ] && [ -n "$arg1" ] && [ -s "$SESSIONS_FILE" ] \
       && jq -e --arg h "$arg1" 'select(.session_id | startswith($h))' "$SESSIONS_FILE" >/dev/null 2>&1; then
    hash_arg="$arg1"; shift
  fi
  local note="$*"
  local sid file home tool markdir="$PWD"
  if [ -n "$session_id" ]; then
    # Running inside a Claude Code session (e.g. via `! xs`): no guessing,
    # no hash needed -- always this exact session.
    # (Codex exports no session id to child shells, so no codex equivalent.)
    tool=claude
    sid="$session_id"
    home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    file="$(am_proj_dir "$home" "$PWD")/$sid.jsonl"
    # The shell may have cd'd away from the session's start dir; find the
    # session by id and mark its real cwd, so xg lands in the right place.
    [ -f "$file" ] \
      || file="$(find "$home/projects" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1)"
    if [ -f "$file" ]; then
      markdir="$(grep -o '"cwd":"[^"]*"' "$file" | head -1 | cut -d'"' -f4)"
      markdir="${markdir:-$PWD}"
    fi
  elif [ -n "$hash_arg" ]; then
    # Target an existing session directly by its xl HASH, wherever it
    # lives -- no cwd guessing needed.
    local line; line="$(jq -c --arg h "$hash_arg" 'select(.session_id | startswith($h))' "$SESSIONS_FILE" | tail -1)"
    sid="$(jq -r '.session_id' <<<"$line")"
    markdir="$(jq -r '.dir' <<<"$line")"
    home="$(jq -r '.home' <<<"$line")"
    tool="$(jq -r '.tool // "claude"' <<<"$line")"
  else
    # Newest session for this dir across all claude config dirs + codex homes.
    local d f files=()
    while IFS= read -r d; do
      files+=( "$(am_proj_dir "$d" "$PWD")"/*.jsonl )
    done < <(am_claude_dirs)
    while IFS= read -r d; do
      f="$(am_codex_latest "$d" "$PWD")" && files+=( "$f" )
    done < <(am_codex_homes)
    file="$(ls -t "${files[@]}" 2>/dev/null | head -1)"
    [ -n "$file" ] || { echo "xs: no claude/codex sessions found for $PWD" >&2; return 1; }
    if am_is_codex "$file"; then
      tool=codex
      home="${file%/sessions/*}"
      sid="$(head -1 "$file" | jq -r '.payload.id')"
    else
      tool=claude
      home="${file%/projects/*}"
      sid="$(basename "$file" .jsonl)"
    fi
  fi
  # Preserve date/reason/summary/detail from any row the hooks already
  # wrote for this session -- only starred/note/dir/home/tool change here.
  # A brand-new row (no hook has run yet, or a codex session the hooks
  # never touch) falls back to the session's first message as its summary.
  local existing date reason summary detail starred existing_note
  existing="$([ -f "$SESSIONS_FILE" ] && jq -c --arg s "$sid" 'select(.session_id == $s)' "$SESSIONS_FILE" | tail -1)"
  if [ -n "$existing" ]; then
    date="$(jq -r '.date' <<<"$existing")"
    reason="$(jq -r '.reason // empty' <<<"$existing")"
    summary="$(jq -r '.summary // empty' <<<"$existing")"
    detail="$(jq -r '.detail // empty' <<<"$existing")"
    starred="$(jq -r '.starred // false' <<<"$existing")"
    existing_note="$(jq -r '.note // empty' <<<"$existing")"
  else
    date="$(date '+%F %H:%M')"
    reason=""
    summary="$(am_first_msg "$file")"
    detail=""
    starred=false
    existing_note=""
  fi
  # xs toggles: starring an already-starred session un-stars it instead
  # of needing a separate command; un-starring always clears the note
  # (matching the old xd's behavior), while (re-)starring keeps whatever
  # note was already there if none was typed just now.
  local new_starred=true
  [ "$starred" = true ] && new_starred=false
  if [ "$new_starred" = true ]; then
    [ -n "$note" ] || note="$existing_note"
  else
    note=""
  fi
  (
    flock -w 5 9 || true
    {
      [ -f "$SESSIONS_FILE" ] && jq -c --arg s "$sid" 'select(.session_id != $s)' "$SESSIONS_FILE"
      jq -nc --arg date "$date" --arg sid "$sid" --arg dir "$markdir" \
        --arg home "$home" --arg tool "$tool" --arg reason "$reason" --arg summary "$summary" \
        --arg detail "$detail" --argjson starred "$new_starred" --arg note "$note" \
        '{date: $date, session_id: $sid, dir: $dir, home: $home, tool: $tool,
          reason: (if $reason == "" then null else $reason end),
          summary: (if $summary == "" then null else $summary end),
          detail: (if $detail == "" then null else $detail end),
          starred: $starred,
          note: (if $note == "" then null else $note end)}'
    } > "$SESSIONS_FILE.tmp" && mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
  ) 9>"$SESSIONS_FILE.lock"
  if [ "$new_starred" = true ]; then
    echo "starred ${sid:0:6} → $sid  [$tool/$(am_account "$home")]  ($markdir)"
  else
    echo "unstarred ${sid:0:6} (session kept — see xl)"
  fi
}

xg () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  [ -s "$SESSIONS_FILE" ] || { echo "xg: no sessions yet" >&2; return 1; }
  local hash="${1:-}" line
  if [ -z "$hash" ]; then
    if command -v fzf >/dev/null 2>&1; then
      line="$(jq -r 'select(.starred == true) | [(.session_id[0:6]), (.note // .summary // "-"), (.summary // "-")] | @tsv' "$SESSIONS_FILE" \
        | fzf --delimiter='\t' --with-nth=1,2,3)" || return 1
      hash="$(printf '%s' "$line" | cut -f1)"
    else
      xl -s; printf 'usage: xg <hash>\n' >&2; return 1
    fi
  fi
  local dir sid home tool
  # Any session's HASH resumes it, starred or not.
  line="$(jq -c --arg h "$hash" 'select(.session_id | startswith($h))' "$SESSIONS_FILE" | tail -1)"
  [ -n "$line" ] || { echo "xg: no such session: $hash" >&2; return 1; }
  dir="$(jq -r '.dir' <<<"$line")"
  sid="$(jq -r '.session_id' <<<"$line")"
  home="$(jq -r '.home' <<<"$line")"
  tool="$(jq -r '.tool // "claude"' <<<"$line")"
  [ -d "$dir" ] || { echo "xg: directory gone: $dir" >&2; return 1; }
  cd "$dir" || return 1
  if [ "$tool" = codex ]; then
    home="${home:-$HOME/.codex}"
    if [ -z "$(find "$home/sessions" -name "*$sid.jsonl" -print -quit 2>/dev/null)" ]; then
      echo "xg: codex session $sid no longer exists in $home — you're in $dir" >&2
      return 1
    fi
    CODEX_HOME="$home" codex resume "$sid"
  else
    home="${home:-$HOME/.claude}"
    if [ ! -f "$(am_proj_dir "$home" "$dir")/$sid.jsonl" ]; then
      echo "xg: session $sid no longer exists in $home — you're in $dir" >&2
      return 1
    fi
    CLAUDE_CONFIG_DIR="$home" claude --resume "$sid"
  fi
}

xl () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  local long=0 starred_only=0 reverse=0 limit=20 limit_set=0
  while :; do
    case "${1:-}" in
      -l|--long|--full) long=1; shift ;;
      -s|--starred) starred_only=1; shift ;;
      -r|--reverse) reverse=1; shift ;;
      -n) limit="${2:-}"
          case "$limit" in
            ''|*[!0-9]*) echo "xl: -n requires a number" >&2; return 1 ;;
          esac
          limit_set=1; shift 2 ;;
      *) break ;;
    esac
  done
  [ -s "$SESSIONS_FILE" ] || {
    echo "xl: no sessions yet — install the SessionEnd hook: make install-hook" >&2
    return 1
  }
  # Color (like git) only for an interactive terminal, and never if the
  # user opted out with $NO_COLOR -- piping xl to a file or another
  # command gets plain text either way. Every colored field is wrapped
  # the same way on every row (even "-"), so the constant escape-code
  # overhead cancels out in column -t's width math instead of skewing it.
  local c_hash="" c_mark="" c_dim="" c_warn="" c_reset=""
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_hash=$'\033[33m'   # yellow, like git's commit hash
    c_mark=$'\033[36m'   # cyan, for the starred indicator
    c_dim=$'\033[2m'
    c_warn=$'\033[1;31m'
    c_reset=$'\033[0m'
  fi
  # -s (or a pattern) is already a small, deliberate subset -- no cap,
  # unless -n overrides it explicitly. Otherwise last 20 (or -n's count),
  # oldest to newest (latest at the bottom).
  local pattern="${1:-}"
  local use_cap=1
  [ "$limit_set" = 0 ] && { [ "$starred_only" = 1 ] || [ -n "$pattern" ]; } && use_cap=0
  local rows
  rows="$(
    { if [ "$starred_only" = 1 ]; then jq -c 'select(.starred == true)' "$SESSIONS_FILE"
      else cat "$SESSIONS_FILE"; fi; } \
    | tac \
    | { [ -n "$pattern" ] && grep -i -- "$pattern" || cat; } \
    | { [ "$use_cap" = 1 ] && head -n "$limit" || cat; } \
    | tac
  )"
  # AGENT is only worth a column/line when the listed sessions actually mix
  # tools; with everything on claude (the common case) it's a no-op value.
  local show_tool=0
  [ -n "$rows" ] && [ "$(jq -sc 'any(.[]; .tool == "codex")' <<<"$rows")" = true ] && show_tool=1
  # \x1f (not a literal tab) joins these fields: summary/note/reason can be
  # null, and bash's `read` collapses adjacent tab delimiters (tab counts
  # as IFS whitespace regardless of what IFS is set to) which would
  # silently shift every field after an empty one.
  local IFS=$'\x1f' date sid dir home reason summary detail note starred tool
  # $rows is oldest-to-newest. Default: compact table keeps that order
  # (newest at the bottom); -l flips it, matching real `git log`'s
  # newest-first convention. -r/--reverse flips whichever is the default
  # for the view in use (so `xl -l -r` matches `git log --reverse`).
  local flip=0
  [ "$long" != "$reverse" ] && flip=1
  if [ "$long" = 1 ]; then
    local first=1
    { printf '%s\n' "$rows" | { [ "$flip" = 1 ] && tac || cat; } \
    | jq -r '[.date, .session_id, .dir, .home, (.reason // ""), (.summary // ""), (.detail // ""),
              (.note // ""), (.starred // false), (.tool // "")] | join("\u001f")' \
    | while read -r date sid dir home reason summary detail note starred tool; do
        tool="${tool:-claude}"
        [ -n "$home" ] || { [ "$tool" = codex ] && home="$HOME/.codex" || home="$HOME/.claude"; }
        dir="$(am_display_dir "$dir" 1)"
        [ "$first" = 1 ] || printf '\n'
        first=0
        printf '%ssession %s%s\n' "$c_hash" "$sid" "$c_reset"
        [ "$starred" = true ] && printf 'Starred: %syes%s\n' "$c_mark" "$c_reset"
        [ "$tool" = codex ] && printf 'Tool:    %s%s%s\n' "$c_dim" "$tool" "$c_reset"
        [ "$reason" = in_progress ] && printf 'Status:  %sin progress%s\n' "$c_warn" "$c_reset"
        printf 'Account: %s\n' "$(am_account "$home")"
        printf 'Dir:     %s\n' "$dir"
        printf 'Date:    %s%s%s\n' "$c_dim" "$date" "$c_reset"
        printf '\n'
        printf '%s\n' "${note:-${detail:-${summary:--}}}" | fold -s -w 76 | sed 's/^/    /'
      done
    } | am_page
  else
    # AGE is right-justified by hand below: `column -t -R` is a GNU
    # (util-linux) extension, not available in BSD/macOS column.
    local agewidth=3 w
    while IFS= read -r w; do
      [ "${#w}" -gt "$agewidth" ] && agewidth="${#w}"
    done <<<"$(printf '%s\n' "$rows" | jq -r '.date' | while IFS= read -r w; do am_relative_date "$w"; printf '\n'; done)"
    { { if [ "$show_tool" = 1 ]; then
          printf 'HASH\tAGENT\tDIR\tSUMMARY\t%*s\n' "$agewidth" AGE
        else
          printf 'HASH\tDIR\tSUMMARY\t%*s\n' "$agewidth" AGE
        fi
        local maxlen="${XMARKS_NOTE_MAXLEN:-52}"
        printf '%s\n' "$rows" | { [ "$flip" = 1 ] && tac || cat; } \
        | jq -r '[.date, .session_id, .dir, .home, (.reason // ""), (.summary // ""), (.note // ""),
                  (.starred // false), (.tool // "")] | join("\u001f")' \
        | while read -r date sid dir home reason summary note starred tool; do
            dir="$(am_display_dir "$dir" 0)"
            date="$(printf '%*s' "$agewidth" "$(am_relative_date "$date")")"
            local shown="${note:-$summary}"; shown="${shown:--}"
            # Starred rows get a * beside the hash, in the same color the
            # old MARK column used, instead of a separate column. The mark
            # segment (star or space) is always emitted, colored either
            # way, so every row carries the same escape-code byte count --
            # otherwise column -t's raw-byte width math (it doesn't know
            # ANSI codes aren't visible) misjudges the HASH column whenever
            # starred and unstarred rows are mixed.
            local mark=" "
            [ "$starred" = true ] && mark="*"
            local hashfield="${c_hash}${sid:0:6}${c_reset}${c_mark}${mark}${c_reset}"
            if [ "$show_tool" = 1 ]; then
              printf '%s\t%s\t%s\t%s\t%s\n' \
                "$hashfield" "${tool:-claude}" "$dir" "$(am_truncate "$shown" "$maxlen")" "$date"
            else
              printf '%s\t%s\t%s\t%s\n' \
                "$hashfield" "$dir" "$(am_truncate "$shown" "$maxlen")" "$date"
            fi
          done
      # -c 1000: column -t silently drops trailing columns that don't fit
      # the terminal width instead of wrapping.
      } | column -t -s"$(printf '\t')" -c 1000
    } | am_page
  fi
}

# xq: is this session saved? Inside a Claude Code session (`! xq`) checks
# that exact session; outside, shows any starred sessions for the current
# directory.
xq () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  local hits
  local session_id="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -n "$session_id" ]; then
    hits="$(jq -r --arg s "$session_id" \
      'select(.session_id == $s and .starred == true) | "  " + .session_id[0:6] + "  (" + (.note // .summary // "-") + ")"' \
      "$SESSIONS_FILE" 2>/dev/null)"
    if [ -n "$hits" ]; then
      echo "this session is starred:"; printf '%s\n' "$hits"
    else
      echo "this session is NOT starred — star it with: xs [note...]"
      return 1
    fi
  else
    hits="$(jq -r --arg d "$PWD" \
      'select(.dir == $d and .starred == true) | "  " + .session_id[0:6] + "  (" + (.note // .summary // "-") + ")"' \
      "$SESSIONS_FILE" 2>/dev/null)"
    if [ -n "$hits" ]; then
      echo "starred sessions for $PWD:"; printf '%s\n' "$hits"
    else
      echo "no starred sessions for $PWD"
      return 1
    fi
  fi
}

# xd: permanently delete a session's row by its xl HASH -- unlike xs
# un-starring (which keeps the row, just drops the star), this removes it
# from sessions.jsonl entirely, so it's gone from xl for good. Confirms
# first since there's no undo.
xd () {
  am_migrate
  local SESSIONS_FILE="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  local arg1="${1:-}"
  [ -n "$arg1" ] || { echo "usage: xd <hash>" >&2; return 1; }
  [ -s "$SESSIONS_FILE" ] || { echo "xd: no sessions yet" >&2; return 1; }
  local line; line="$(jq -c --arg h "$arg1" 'select(.session_id | startswith($h))' "$SESSIONS_FILE" | tail -1)"
  [ -n "$line" ] || { echo "xd: no such session: $arg1" >&2; return 1; }
  local sid desc
  sid="$(jq -r '.session_id' <<<"$line")"
  desc="$(jq -r '.note // .detail // .summary // "-"' <<<"$line")"
  local reply
  read -r -p "delete session ${sid:0:6} ($desc)? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "xd: aborted"; return 1 ;;
  esac
  (
    flock -w 5 9 || true
    jq -c --arg s "$sid" 'select(.session_id != $s)' "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp" \
      && mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
  ) 9>"$SESSIONS_FILE.lock"
  echo "deleted ${sid:0:6} (was: \"$desc\")"
}

# Tab completion for xg/xs/xd: all three take a session HASH (a
# session_id prefix) as their argument, so all complete against the same
# list.
am_complete_xg () {
  local f="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
  [ -r "$f" ] || return 0
  local hashes
  hashes="$(jq -r '.session_id[0:6]' "$f" 2>/dev/null)"
  local cur=${COMP_WORDS[COMP_CWORD]}
  COMPREPLY=( $(compgen -W "$hashes" -- "$cur") )
}
if [ -n "$BASH_VERSION" ]; then
  complete -F am_complete_xg xg xs xd
fi

# Same completion for plain zsh (no bashcompinit): needs the zsh
# completion system already loaded (`autoload -Uz compinit && compinit`
# in .zshrc) -- if compdef isn't defined yet, this silently does nothing,
# same as the bash guard above.
if [ -n "$ZSH_VERSION" ] && typeset -f compdef >/dev/null 2>&1; then
  am_complete_xg_zsh () {
    local f="${XMARKS_SESSIONS:-$HOME/.xmarks/sessions.jsonl}"
    [ -r "$f" ] || return 0
    local -a hashes
    hashes=($(jq -r '.session_id[0:6]' "$f" 2>/dev/null))
    compadd -- "${hashes[@]}"
  }
  compdef am_complete_xg_zsh xg xs xd
fi
