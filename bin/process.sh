#!/usr/bin/env bash
#
# process.sh — the blog-pipeline driver.
#
# For every unprocessed audio file at the root of sync/, it:
#   1. skips it if its content hash is already in logs/processed.tsv
#   2. transcribes it verbatim            (bin/transcribe.sh)
#   3. cleans the transcript, voice-preserving (claude -p + prompts/cleanup.md)
#   4. word-diffs verbatim vs cleaned     (git diff --word-diff)
#   5. bundles a COPY of the audio + the three text artifacts into
#      drafts/<date>-<slug>/, and leaves the original — plus a transcript
#      beside it — in sync/ so the phone keeps both for a grace period
#   6. records the hash and fires a desktop notification
#   7. reaps recordings whose grace period in sync/ has expired
#
# Invariants (see PLAN.md §4.1):
#   - re-running is always safe; an existing bundle is never overwritten
#   - the bundle copy in drafts/ is the ARCHIVE and is never deleted. sync/ is a
#     conveyor belt, not the archive: the original lingers there for
#     SYNC_KEEP_DAYS so it stays readable on the phone, and only that transport
#     copy is ever reaped — never before its hash is recorded in processed.tsv
#   - a per-file failure is logged and skipped; it never aborts the batch
#
# OS-agnostic (Linux now, macOS later): only the lock primitive and a couple of
# stat/date flags differ, and both branches live here.
#
# Retention:
#   SYNC_KEEP_DAYS  days a processed recording and its transcript linger in
#                   sync/ (i.e. on the phone) before being reaped (default 14)
#
# Test / backend-swap seams (env overrides, all optional):
#   TRANSCRIBE    command run as "<cmd> <audio>" -> transcript on stdout
#   CLAUDE_BIN    the claude CLI (default: claude)
#   CLEANUP_MODEL model for the cleanup/structure calls (default: claude-sonnet-5;
#                 CLAUDE_MODEL still overrides it, as it always did)
#   NOTIFY        the notifier command (default: bin/notify.sh)
#
# Everything above is resolved in lib/config.sh, which also re-roots the whole
# tree (BLOG_ROOT) and applies a profile (BLOG_PROFILE) — see profiles/default.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# One resolution point for every path, prompt, model and knob below. SYNC is the
# single Syncthing folder shared with the phone (where it is called /blog);
# recordings land at its root, and sync/Obsidian/ is the notes vault — the audio
# glob in main() is deliberately non-recursive, so the vault (and the post
# suggestions inside it) is invisible to this script.
# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"

# Cleanup is a constrained voice-preserving transform — Sonnet handles it well
# and burns less of the subscription. The curator (suggest.sh) uses Opus.
CLAUDE_MODEL="$CLEANUP_MODEL"

# Audio extensions we handle (matched case-insensitively).
AUDIO_EXTS=(m4a mp3 opus ogg wav)

mkdir -p "$SYNC" "$DRAFTS" "$WORK" "$LOGS"

# --- logging ----------------------------------------------------------------
log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  # to the log file and to stderr (systemd/launchd capture stderr in the journal)
  printf '%s %s\n' "$ts" "$*" | tee -a "$PROCESS_LOG" >&2
}

notify() {
  # never let a notifier problem escape
  "$NOTIFY" "$1" "${2:-}" >/dev/null 2>&1 || log "WARN notify failed: $1"
}

# --- portable primitives ----------------------------------------------------
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'   # macOS
  fi
}

file_mtime_epoch() {
  # GNU stat first, then BSD/macOS stat
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

epoch_to_date() {
  # GNU date first, then BSD/macOS date
  date -d "@$1" '+%Y-%m-%d' 2>/dev/null || date -r "$1" '+%Y-%m-%d'
}

# --- single-instance lock (flock on Linux, mkdir elsewhere) -----------------
LOCK_CREATED_DIR=""
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$WORK/.process.lock"
    if ! flock -n 9; then
      log "another instance holds the lock; exiting"
      exit 0
    fi
  else
    local d="$WORK/.process.lock.d"
    if ! mkdir "$d" 2>/dev/null; then
      log "another instance holds the lock; exiting"
      exit 0
    fi
    LOCK_CREATED_DIR="$d"
    trap 'rmdir "$LOCK_CREATED_DIR" 2>/dev/null || true' EXIT
  fi
}

# --- helpers ----------------------------------------------------------------
already_processed() {
  # true if hash ($1) appears in column 1 of processed.tsv
  [ -f "$PROCESSED" ] && cut -f1 "$PROCESSED" | grep -qxF "$1"
}

# Read text on stdin, emit a filesystem-safe slug from the first ~5 words.
slugify() {
  # Uppercase umlauts are transliterated *before* the ASCII lowercase, which
  # only maps a-z — otherwise a leading "Ü" is dropped (mirrors bin/note.sh).
  local s
  s="$(sed -e 's/Ä/Ae/g' -e 's/Ö/Oe/g' -e 's/Ü/Ue/g' \
       | tr '[:upper:]' '[:lower:]' \
       | sed -e 's/ä/ae/g' -e 's/ö/oe/g' -e 's/ü/ue/g' -e 's/ß/ss/g' \
       | tr -c 'a-z0-9' ' ' \
       | tr -s ' ')"
  # shellcheck disable=SC2086  # deliberate word-split; only [a-z0-9 ] remain
  set -- $s
  local out="" i=0 w
  for w in "$@"; do
    out="${out:+$out-}$w"
    i=$((i + 1))
    [ "$i" -ge 5 ] && break
  done
  printf '%s' "$out"
}

# Given a desired base path, return the first non-existing variant, adding
# -2, -3, ... on collision so an existing bundle is never overwritten.
dedup_dest() {
  local base="$1" dest="$1" n=2
  while [ -e "$dest" ]; do
    dest="${base}-${n}"
    n=$((n + 1))
  done
  printf '%s' "$dest"
}

# Run a pure text transform through the Claude subscription (never an API key).
#   $1 prompt file   $2 input file (stdin)   $3 output file (stdout)
# Runs from work/ with FS/exec tools denied, so the transform cannot touch the
# repo — it only reads stdin and writes stdout. Used for both the voice-
# preserving cleanup and the optional structure suggestion.
claude_transform() {
  local prompt_file="$1" in_file="$2" out_file="$3" rc=0
  # Feed the instructions AND the input as ONE stdin stream, delimited by
  # explicit markers, with no prompt argument. Passing the prompt as -p and the
  # text on stdin is ambiguous: claude sometimes ignores the piped input and
  # replies "no transcript arrived" instead of transforming it. A single marked
  # stream is deterministic (verified against the transcripts that failed).
  {
    cat "$prompt_file"
    # The style anchor is one file read by every step (see prompts/style-anchor.md),
    # appended after the instructions and before the input markers.
    if [ -f "$ANCHOR" ]; then printf '\n\n'; cat "$ANCHOR"; fi
    printf '\n\n===== BEGIN INPUT (process ONLY the text between the markers; output nothing else) =====\n'
    cat "$in_file"
    printf '\n===== END INPUT =====\n'
  } | ( cd "$WORK" && "$CLAUDE_BIN" -p \
        --model "$CLAUDE_MODEL" \
        --output-format text \
        --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Task" ) \
      > "$out_file" || rc=$?
  # Usage ledger (see bin/stats.sh): stream size in chars, reconstructed from
  # the parts (prompt + anchor + input; the markers are noise). ~4 chars/token.
  local in_chars
  in_chars=$(( $(wc -c < "$prompt_file") + $(wc -c < "$in_file") ))
  [ -f "$ANCHOR" ] && in_chars=$((in_chars + $(wc -c < "$ANCHOR")))
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "process:$(basename "$prompt_file" .md)" \
    "$CLAUDE_MODEL" "$in_chars" "$(wc -c < "$out_file" | tr -d ' ')" \
    >> "$LOGS/usage.tsv"
  return $rc
}

# --- process one audio file (returns non-zero on failure) -------------------
process_one() {
  local audio="$1"
  local origname hash tmp date slug dest rel
  origname="$(basename "$audio")"

  hash="$(sha256 "$audio")" || { log "ERROR could not hash: $origname"; return 1; }

  if already_processed "$hash"; then
    # Already bundled, and deliberately still sitting here: it lingers in sync/
    # for SYNC_KEEP_DAYS so the phone keeps it. Counted by the caller rather
    # than logged — otherwise every 15-minute run reprints the whole set.
    return 2
  fi

  log "START $origname ($hash)"
  tmp="$(mktemp -d "$WORK/proc.XXXXXX")"

  # 1. transcribe (verbatim)
  if ! "$TRANSCRIBE" "$audio" > "$tmp/verbatim.md" 2>>"$PROCESS_LOG"; then
    log "ERROR transcription failed: $origname"
    notify "blog-pipeline: transcription failed" "$origname"
    rm -rf "$tmp"
    return 1
  fi
  if [ ! -s "$tmp/verbatim.md" ]; then
    log "ERROR empty transcript: $origname"
    notify "blog-pipeline: empty transcript" "$origname"
    rm -rf "$tmp"
    return 1
  fi

  # 2. clean (voice-preserving)
  if ! claude_transform "$CLEANUP_PROMPT" "$tmp/verbatim.md" "$tmp/cleaned.md" 2>>"$PROCESS_LOG"; then
    log "ERROR cleanup failed: $origname"
    notify "blog-pipeline: cleanup failed" "$origname"
    rm -rf "$tmp"
    return 1
  fi
  if [ ! -s "$tmp/cleaned.md" ]; then
    log "ERROR empty cleaned output: $origname"
    notify "blog-pipeline: cleanup produced nothing" "$origname"
    rm -rf "$tmp"
    return 1
  fi

  # Safety net: the ⟦unsure⟧ confidence marks (see transcribe.sh) live in
  # verbatim.md only; the prompt tells the cleaner to resolve them, and this
  # guarantees none leak into cleaned.md — the corpus the verbatim gate
  # compares against.
  sed -e 's/⟦unsure⟧//g' -e 's|⟦/unsure⟧||g' "$tmp/cleaned.md" > "$tmp/cleaned.stripped" \
    && mv "$tmp/cleaned.stripped" "$tmp/cleaned.md"

  # 2b. optional structure suggestion — a SEPARATE artifact, never merged into
  #     cleaned.md. Failure here is non-fatal: the draft is still valuable.
  if [ "$STRUCTURE" = 1 ]; then
    if claude_transform "$STRUCTURE_PROMPT" "$tmp/cleaned.md" "$tmp/structure.md" 2>>"$PROCESS_LOG" \
       && [ -s "$tmp/structure.md" ]; then
      log "structure suggestion written for $origname"
    else
      log "WARN structure step failed for $origname (continuing without it)"
      rm -f "$tmp/structure.md"
    fi
  fi

  # 3. word-diff (exits 1 when files differ — that is the normal case)
  ( cd "$tmp" && git diff --word-diff --no-index -- verbatim.md cleaned.md ) \
    > "$tmp/changes.diff" || true

  # 4. name the bundle: date from the recording's mtime, slug from the cleaned
  #    text (filler already removed, so the leading words are "meaningful").
  date="$(epoch_to_date "$(file_mtime_epoch "$audio")")"
  slug="$(head -c 2000 "$tmp/cleaned.md" | slugify)"
  [ -n "$slug" ] || slug="memo"
  dest="$(dedup_dest "$DRAFTS/${date}-${slug}")"

  # 5. assemble the bundle. Text artifacts first, then the audio — COPIED, not
  #    moved: the original stays in sync/ so the phone keeps the recording for
  #    SYNC_KEEP_DAYS, and reap_sync removes that transport copy later. A
  #    failure before this point still leaves the audio in sync/ for retry.
  mkdir -p "$dest"
  local a
  for a in verbatim.md cleaned.md changes.diff structure.md; do
    [ -f "$tmp/$a" ] && mv "$tmp/$a" "$dest/"
  done
  if ! cp "$audio" "$dest/$origname"; then
    log "ERROR could not copy audio into bundle: $origname (bundle left at $dest)"
    notify "blog-pipeline: bundling failed" "$origname"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"

  # 5b. the transcript, next to the recording in sync/, sharing its basename so
  #     the pair is obvious in a file browser and is reaped together. Derived
  #     and regenerable, so unlike a bundle it may be rewritten. It sits at the
  #     sync/ root, OUTSIDE the Obsidian vault, so it never enters the notes
  #     corpus — drafts/<bundle>/cleaned.md is already the corpus entry.
  local companion="$SYNC/${origname%.*}.md"
  cp "$dest/cleaned.md" "$companion" \
    || log "WARN could not place a transcript next to $origname in sync/"

  # 5c. count the grace period from processing, not from recording: a memo that
  #     syncs across days later would otherwise be reaped the moment it lands.
  touch "$audio" "$companion" 2>/dev/null || true

  # 6. record (hash \t original \t root-relative bundle \t iso-timestamp) + notify
  rel="${dest#"$BLOG_ROOT"/}"
  printf '%s\t%s\t%s\t%s\n' \
    "$hash" "$origname" "$rel" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$PROCESSED"
  log "DONE $origname -> $rel"
  notify "New draft: ${date}-${slug}" "from $origname"
  return 0
}

# --- reap expired transport copies from sync/ -------------------------------
# Deletes ONLY the sync/ copy of a recording, and only when both hold:
#   - its content hash is in processed.tsv, so drafts/ has the permanent copy
#   - it has sat here longer than SYNC_KEEP_DAYS (measured from processing)
# Its transcript companion goes with it, so the pair appears and disappears
# together. An unprocessed recording is never touched, however old it is.
reap_sync() {
  local f hash companion reaped=0
  local find_args=() ext first=1
  for ext in "${AUDIO_EXTS[@]}"; do
    if [ "$first" = 1 ]; then find_args+=( -iname "*.$ext" ); first=0
    else find_args+=( -o -iname "*.$ext" ); fi
  done

  while IFS= read -r f; do
    [ -f "$f" ] || continue
    hash="$(sha256 "$f")" || continue
    already_processed "$hash" || continue      # not bundled yet — leave it
    companion="$SYNC/$(basename "${f%.*}").md"
    rm -f "$f" "$companion"
    reaped=$((reaped + 1))
    log "REAP $(basename "$f") from sync/ (>${SYNC_KEEP_DAYS}d; drafts/ copy kept)"
  done < <(find "$SYNC" -maxdepth 1 -type f -mtime +"$SYNC_KEEP_DAYS" \
                \( "${find_args[@]}" \) 2>/dev/null)

  [ "$reaped" -eq 0 ] || log "reaped $reaped expired recording(s) from sync/"
}

# --- main -------------------------------------------------------------------
main() {
  acquire_lock

  # A crashed run (SIGKILL, power loss) never fires the EXIT trap; sweep any
  # scratch dir old enough that it can't belong to a live run.
  find "$WORK" -maxdepth 1 -name 'proc.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

  log "scan: $SYNC"

  # Non-recursive on purpose: audio sits at the root of the shared folder, and
  # sync/Obsidian/ (notes + post suggestions) must never be walked.
  shopt -s nullglob nocaseglob
  local files=() ext
  for ext in "${AUDIO_EXTS[@]}"; do
    files+=("$SYNC"/*."$ext")
  done
  shopt -u nullglob nocaseglob

  if [ "${#files[@]}" -eq 0 ]; then
    log "nothing to do"
  else
    local processed=0 failed=0 lingering=0 f rc
    for f in "${files[@]}"; do
      rc=0
      process_one "$f" || rc=$?
      case "$rc" in
        0) processed=$((processed + 1)) ;;
        2) lingering=$((lingering + 1)) ;;   # already bundled, still in its grace period
        *) failed=$((failed + 1)); log "continuing after error on $(basename "$f")" ;;
      esac
    done
    log "batch done: ${processed} handled, ${failed} failed, ${lingering} awaiting reap"
  fi

  # Always, even when there was nothing to process — the grace period expires
  # on its own clock, not on the arrival of new audio.
  reap_sync
}

main "$@"
