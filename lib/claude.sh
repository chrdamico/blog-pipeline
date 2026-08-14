#!/usr/bin/env bash
#
# lib/claude.sh — the one way this pipeline calls a model.
#
# Every stage feeds a prepared stream in on stdin and reads text out on stdout.
# Nothing else: no tools, no filesystem, no network, no API key. That contract
# used to be written out four times — bin/process.sh, bin/reclean.sh,
# bin/suggest.sh and bin/ab.sh each carried their own copy of the invocation, the
# tool restriction and the usage-ledger row — which is three chances to fix a bug
# in one place and leave it in the others.
#
# THE TOOL RESTRICTION IS AN ALLOWLIST NOW, and that is the substantive change.
# It used to be
#
#   --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Task"
#
# which is fail-OPEN: it names the tools known when it was written, so any tool
# the CLI gains afterwards is permitted by default, in four places at once, while
# every comment in the repo goes on claiming the call "can only read stdin and
# write stdout". `--tools ""` disables the built-in set outright (verified
# against the installed CLI: a text transform still works, and a prompt that asks
# for the Read tool answers that it has none). A new tool cannot widen it.
#
# Sourced after lib/config.sh, whose CLAUDE_BIN, WORK and USAGE_TSV it reads.

if [ -z "${BLOG_CLAUDE_LOADED:-}" ]; then
BLOG_CLAUDE_LOADED=1

# What the last call cost. Set here rather than parsed back out of the usage
# ledger, where a lookup would have to guess which row was ours; read by
# prov_write_meta for the bundle's meta.json.
BLOG_LAST_IN_CHARS=0
BLOG_LAST_OUT_CHARS=0
BLOG_LAST_SECONDS=0

# blog_claude <stream-file> <out-file> <model> <job-label> [in_chars]
#
# Runs from WORK with no tools, so the call can only read its stdin and write its
# stdout. The exit status is the CLI's.
#
# in_chars is the size recorded in the ledger, and it is a parameter because the
# cleanup stages deliberately report the sum of the PARTS (prompt + directive +
# input) rather than the assembled stream: the markers are framing,
# not material, and meta.json has been reporting it that way since the first
# bundle. Left empty it measures the stream, which is what the curator wants.
blog_claude() {
  local stream="$1" out="$2" model="$3" job="$4" in_chars="${5:-}"
  local rc=0 started out_chars
  mkdir -p "$WORK" 2>/dev/null || true
  started="$(date +%s)"
  ( cd "$WORK" && "$CLAUDE_BIN" -p \
      --model "$model" \
      --output-format text \
      --tools "" \
  ) < "$stream" > "$out" || rc=$?
  [ -n "$in_chars" ] || in_chars="$(wc -c < "$stream" | tr -d ' ')"
  out_chars="$(wc -c < "$out" | tr -d ' ')"
  # Usage ledger (see bin/stats.sh): stream sizes in chars — ~4 chars/token is
  # close enough for a gut feeling, which is all this is for.
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$job" "$model" "$in_chars" "$out_chars" \
    >> "$USAGE_TSV"
  BLOG_LAST_IN_CHARS="$in_chars"
  BLOG_LAST_OUT_CHARS="$out_chars"
  BLOG_LAST_SECONDS=$(( $(date +%s) - started ))
  return $rc
}

# blog_cleanup_stream <prompt-file> <input-file> <stream-file>
#
# The cleanup stages' stream, assembled once for both bin/process.sh and
# bin/reclean.sh (a reclean must send byte-for-byte what the original run sent,
# or the comparison it exists for is not a comparison).
#
# Instructions AND input arrive as ONE stdin stream delimited by explicit
# markers, with no prompt argument. Passing the prompt as -p and the text on
# stdin is ambiguous: claude sometimes ignores the piped input and replies "no
# transcript arrived" instead of transforming it. A single marked stream is
# deterministic (verified against the transcripts that failed).
#
# The order is instructions + DIRECTIVE + input, and the directive sits LAST
# because position is what makes it work — see profiles/base.env for the
# measurement that settled it.
#
# Leaves the parts' total size in BLOG_STREAM_CHARS, for blog_claude's in_chars.
BLOG_STREAM_CHARS=0
blog_cleanup_stream() {
  local prompt_file="$1" in_file="$2" stream="$3"
  {
    cat "$prompt_file"
    if [ -n "$CLEANUP_DIRECTIVE" ] && [ -f "$CLEANUP_DIRECTIVE" ]; then
      printf '\n\n'; cat "$CLEANUP_DIRECTIVE"
    fi
    printf '\n\n===== BEGIN INPUT (process ONLY the text between the markers; output nothing else) =====\n'
    cat "$in_file"
    printf '\n===== END INPUT =====\n'
  } > "$stream"

  local n
  n=$(( $(wc -c < "$prompt_file") + $(wc -c < "$in_file") ))
  [ -n "$CLEANUP_DIRECTIVE" ] && [ -f "$CLEANUP_DIRECTIVE" ] \
    && n=$((n + $(wc -c < "$CLEANUP_DIRECTIVE")))
  BLOG_STREAM_CHARS="$n"
  return 0
}

fi   # BLOG_CLAUDE_LOADED
