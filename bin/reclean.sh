#!/usr/bin/env bash
#
# reclean.sh — re-run the cleanup pass over existing draft bundles.
#
# For every bundle in drafts/ (or only the bundles named as arguments, by path
# or by directory name), it re-cleans verbatim.md with the CURRENT
# prompts/cleanup.md and replaces cleaned.md. Exists for prompt upgrades: when
# cleanup.md's mandate changes, the archive can be brought up to it without
# re-transcribing anything.
#
# What it preserves:
#   - cleaned.orig.md  the first cleaned.md ever replaced is kept beside it,
#     once — drafts/ is gitignored, so this backup is the only undo there is.
#     Later recleans keep that oldest original, never the previous run.
#   - mtime            the new cleaned.md inherits the old one's mtime.
#     suggest.sh orders and budgets the corpus by mtime; without this every
#     recleaned note would jump to "newest" and crowd out the truly recent.
#   - the bundle path  never renamed, even though the slug came from the old
#     cleaned text — posts' `sources:` lines point at these paths.
#
# What it regenerates: cleaned.md, changes.diff, and the transcript companion
# in sync/ when the recording is still in its grace period there.
#
# Takes process.sh's lock (waiting up to 10 minutes for it), so it can never
# race the 15-minute timer; while it runs, timer runs skip harmlessly.
#
# Env (the same seams as process.sh): CLAUDE_BIN, CLAUDE_MODEL (default
# claude-sonnet-5 — cleanup stays the constrained transform Sonnet handles).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SYNC="$REPO_DIR/sync"
DRAFTS="$REPO_DIR/drafts"
WORK="$REPO_DIR/work"
LOGS="$REPO_DIR/logs"
PROMPTS="$REPO_DIR/prompts"
RECLEAN_LOG="$LOGS/reclean.log"
CLEANUP_PROMPT="$PROMPTS/cleanup.md"
ANCHOR="$PROMPTS/style-anchor.md"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-5}"

AUDIO_EXTS=(m4a mp3 opus ogg wav)

mkdir -p "$WORK" "$LOGS"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$RECLEAN_LOG" >&2
}

# --- single-instance lock: process.sh's, since both rewrite bundle artifacts.
# Unlike the timer jobs this is a manual one-shot, so it WAITS instead of
# yielding — up to 10 minutes, which outlasts any single process.sh batch.
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$WORK/.process.lock"
    if ! flock -w 600 9; then
      log "could not take the process lock within 10 minutes; aborting"
      exit 1
    fi
  else
    local d="$WORK/.process.lock.d" waited=0
    until mkdir "$d" 2>/dev/null; do
      waited=$((waited + 5))
      if [ "$waited" -gt 600 ]; then
        log "could not take the process lock within 10 minutes; aborting"
        exit 1
      fi
      sleep 5
    done
    trap 'rmdir "$WORK/.process.lock.d" 2>/dev/null || true' EXIT
  fi
}

# Same contract as process.sh's claude_transform: subscription auth, run from
# work/ with FS/exec tools denied — reads stdin, writes stdout, nothing else.
claude_transform() {
  local prompt_file="$1" in_file="$2" out_file="$3" rc=0
  {
    cat "$prompt_file"
    if [ -f "$ANCHOR" ]; then printf '\n\n'; cat "$ANCHOR"; fi
    printf '\n\n===== BEGIN INPUT (process ONLY the text between the markers; output nothing else) =====\n'
    cat "$in_file"
    printf '\n===== END INPUT =====\n'
  } | ( cd "$WORK" && "$CLAUDE_BIN" -p \
        --model "$CLAUDE_MODEL" \
        --output-format text \
        --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Task" ) \
      > "$out_file" || rc=$?
  local in_chars
  in_chars=$(( $(wc -c < "$prompt_file") + $(wc -c < "$in_file") ))
  [ -f "$ANCHOR" ] && in_chars=$((in_chars + $(wc -c < "$ANCHOR")))
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "reclean:$(basename "$prompt_file" .md)" \
    "$CLAUDE_MODEL" "$in_chars" "$(wc -c < "$out_file" | tr -d ' ')" \
    >> "$LOGS/usage.tsv"
  return $rc
}

# --- reclean one bundle (returns non-zero on failure) ------------------------
reclean_one() {
  local dir="$1" name tmp audio companion a ext
  name="$(basename "$dir")"

  if [ ! -f "$dir/verbatim.md" ]; then
    log "SKIP $name: no verbatim.md"
    return 2
  fi
  if [ ! -f "$dir/cleaned.md" ]; then
    log "SKIP $name: no cleaned.md to replace"
    return 2
  fi

  tmp="$(mktemp -d "$WORK/reclean.XXXXXX")"

  if ! claude_transform "$CLEANUP_PROMPT" "$dir/verbatim.md" "$tmp/cleaned.md" 2>>"$RECLEAN_LOG"; then
    log "ERROR cleanup failed: $name"
    rm -rf "$tmp"
    return 1
  fi
  if [ ! -s "$tmp/cleaned.md" ]; then
    log "ERROR empty cleaned output: $name"
    rm -rf "$tmp"
    return 1
  fi

  if cmp -s "$tmp/cleaned.md" "$dir/cleaned.md"; then
    log "UNCHANGED $name"
    rm -rf "$tmp"
    return 0
  fi

  # cp -p keeps the old mtime on both the backup and the reference copy the
  # new file inherits it from (touch -r is portable; GNU touch -d "@..." not).
  [ -f "$dir/cleaned.orig.md" ] || cp -p "$dir/cleaned.md" "$dir/cleaned.orig.md"
  cp -p "$dir/cleaned.md" "$tmp/mtime.ref"
  mv "$tmp/cleaned.md" "$dir/cleaned.md"
  touch -r "$tmp/mtime.ref" "$dir/cleaned.md"

  # changes.diff stays what it always was: verbatim vs the CURRENT cleaned.
  ( cd "$dir" && git diff --word-diff --no-index -- verbatim.md cleaned.md ) \
    > "$dir/changes.diff" || true

  # If the recording still lingers in sync/, refresh the transcript companion
  # beside it. touch -r the audio so the pair keeps one reap clock.
  for ext in "${AUDIO_EXTS[@]}"; do
    for a in "$dir"/*."$ext"; do
      [ -f "$a" ] || continue
      audio="$SYNC/$(basename "$a")"
      companion="$SYNC/$(basename "${a%.*}").md"
      if [ -f "$audio" ] && [ -f "$companion" ]; then
        cp "$dir/cleaned.md" "$companion"
        touch -r "$audio" "$companion" 2>/dev/null || true
        log "companion refreshed: $(basename "$companion")"
      fi
    done
  done

  rm -rf "$tmp"
  log "RECLEANED $name"
  return 0
}

# --- main ---------------------------------------------------------------------
main() {
  acquire_lock

  find "$WORK" -maxdepth 1 -name 'reclean.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

  local dirs=() d
  if [ "$#" -gt 0 ]; then
    for d in "$@"; do
      [ -d "$d" ] || d="$DRAFTS/$(basename "$d")"
      if [ -d "$d" ]; then dirs+=("$d"); else log "SKIP $d: no such bundle"; fi
    done
  else
    shopt -s nullglob
    dirs=("$DRAFTS"/*/)
    shopt -u nullglob
  fi

  if [ "${#dirs[@]}" -eq 0 ]; then
    log "nothing to reclean"
    return 0
  fi

  log "reclean: ${#dirs[@]} bundle(s), model $CLAUDE_MODEL, prompt $(basename "$CLEANUP_PROMPT")"

  local done=0 failed=0 skipped=0 rc
  for d in "${dirs[@]}"; do
    rc=0
    reclean_one "${d%/}" || rc=$?
    case "$rc" in
      0) done=$((done + 1)) ;;
      2) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)); log "continuing after error on $(basename "$d")" ;;
    esac
  done
  log "reclean done: ${done} recleaned, ${failed} failed, ${skipped} skipped"
  [ "$failed" -eq 0 ]
}

main "$@"
