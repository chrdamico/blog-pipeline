#!/usr/bin/env bash
#
# suggest.sh — the post-suggestion job.
#
# Reads everything the author has captured (cleaned voice memos in drafts/ and
# typed notes in sync/Obsidian/), looks for places where two or more notes
# converge, and writes them up as candidate posts into sync/Obsidian/Posts/,
# where Syncthing carries them to the phone.
#
# The pool is CAPPED. When it overflows, one Claude call judges the whole pool
# as a set — quality *and* coverage, so two near-duplicates lose to two
# different ideas — and the losers move to Posts/Discarded/ for TRASH_DAYS.
# Discarded/ deliberately SYNCS to the phone: an eviction stays visible and
# reversible there (move it back out) for the whole retention window.
#
# Invariants (mirroring bin/process.sh):
#   - the model never deletes anything: it returns a decision, this script acts
#     on it, and only after the decision validates against the actual pool
#   - the model never writes prose: candidates are stitched from the author's
#     own sentences, and a mechanical gate (verbatim_gate) rejects any candidate
#     whose sentences are not overwhelmingly verbatim from the corpus. Every
#     accepted post gets a provenance report in Posts/.provenance/ (laptop-only).
#   - rejections are never silent: the near-miss is kept in Posts/Rejected/
#     (synced, REJECT_DAYS) with its gate report, logged to logs/gate.tsv, fed
#     back to the next generation call, and announced in the notification.
#   - Posts/Keep/ is never judged, never evicted, never rewritten. Moving a file
#     into it on the phone is how you promote it out of the pool. The job reads
#     it for exactly one purpose: a kept post's sentences are claimed, so they
#     are not spent again (build_claimed) — and ONLY a kept post's are.
#   - eviction is a move to Discarded/, never an rm; age-out is the only deletion
#   - anonymization is enforced at the synced boundary from both sides: the
#     name scout extends the alias map before candidates are written, and the
#     alias sweep rewrites any synced post a mapped name still appears in
#     (bin/suggest.sh --sweep-only runs just the sweep)
#   - nothing is ever overwritten; name collisions get -2, -3, ...
#   - generation runs every run, even on unchanged notes: reuse holes and the
#     corpus sample fall differently each day, so new stitchings stay possible
#
# Optional environment:
#   MAX_LONG      long posts kept in the pool        (default 4)
#   MAX_SHORT     short posts kept in the pool       (default 8)
#   MAX_NEW       candidates proposed per run        (default 8)
#   TRASH_DAYS    how long evicted posts linger      (default 14)
#   CORPUS_MAX    max chars of notes fed to Claude   (default 150000)
#   ARCHIVE_DAYS  root notes older than this move to Obsidian/Archive/ (default 14)
#   VERBATIM_MIN  min % of a candidate's sentences that must be verbatim (default 85)
#   GLUE_MAX_WORDS  max words for a non-verbatim (glue) sentence (default 12)
#   NEW_SLACK_EVERY  1 model-written sentence tolerated per this many sentences
#                 of post (default 25; posts shorter than that allow none)
#   REJECT_DAYS   how long gate-rejected candidates stay in Posts/Rejected/ (default 30)
#   REUSE_MIN_WORDS  sentences shorter than this are never claimed (default 6)
#   REUSE_DROP_PCT   how often a claimed sentence is enforced in a run (default 75);
#                 claims are kind-scoped — a long's sentence is free for a short
#   ALIASES       real-name -> alias-pool map, TSV (default private/aliases.tsv);
#                 auto-extended by the name scout (NAME_SCAN=0 disables it,
#                 SELF_NAME names the author, who is never aliased)
#   CURATE_MODEL  model for the curator calls        (default claude-opus-5;
#                 CLAUDE_MODEL still overrides it, as it always did)
#   TYPO_FIX      proofread typed notes in place, once each (default 1; 0 off)
#   TYPO_MODEL    model for the typo pass             (default claude-sonnet-5)
#   TYPO_MIN_LEN  words shorter than this are never "corrected" (default 4)
#   TYPO_MAX_PCT  max % of a note's words a single pass may change (default 5)
#   CLAUDE_BIN / NOTIFY   swap the backend commands (used by the test harness)
#   SUGGEST_SCHEDULED  set by the timer unit; a slot whose day already
#                 succeeded (logs/suggest.lastdone) exits immediately
#
# All of it — paths, prompts, models, knobs — is resolved in lib/config.sh,
# which also re-roots the whole tree (BLOG_ROOT) and applies a profile
# (BLOG_PROFILE). profiles/default.env is the full inventory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"
# shellcheck source=../lib/provenance.sh
. "$REPO_DIR/lib/provenance.sh"

# Curation is the judgment-heavy step — reading the whole corpus, deciding what
# is post-worthy, and writing in the author's voice — so it gets Opus. The
# mechanical cleanup in process.sh runs on Sonnet, and the typo pass (the most
# mechanical call in the pipeline: one word in, the same word spelled right
# out) on Sonnet as well.
CLAUDE_MODEL="$CURATE_MODEL"

# The persona whose generation call is currently being written up. Empty for
# the anonymous single call that is the default and, until PERSONAS is set,
# the only one there is (see generate_all).
PERSONA=""

mkdir -p "$POSTS" "$POSTS/Keep" "$TRASH" "$REJECTED" "$ARCHIVE" "$PROVENANCE" "$WORK" "$LOGS"

# --- logging ----------------------------------------------------------------
log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$SUGGEST_LOG" >&2
}

notify() {
  "$NOTIFY" "$1" "${2:-}" >/dev/null 2>&1 || log "WARN notify failed: $1"
}

# --- portable primitives (mirroring process.sh) ------------------------------
file_mtime_epoch() {
  # GNU stat first, then BSD/macOS stat
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

epoch_to_date() {
  # GNU date first, then BSD/macOS date
  date -d "@$1" '+%Y-%m-%d' 2>/dev/null || date -r "$1" '+%Y-%m-%d'
}

# When the note was CREATED, as best the filesystem knows. Both available
# clocks overshoot creation in different ways — birth time (GNU stat %W, 0 =
# unknown; BSD/macOS stat -f %B) is when Syncthing first wrote the LOCAL file,
# mtime is the last edit (Syncthing preserves the phone's) — so the earlier of
# the two is the closest estimate. mv preserves both: never the archival date.
file_created_epoch() {
  local b m
  m="$(file_mtime_epoch "$1")"
  b="$(stat -c %W "$1" 2>/dev/null || stat -f %B "$1" 2>/dev/null || echo 0)"
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if [ "$b" -gt 0 ] && [ "$b" -lt "$m" ]; then printf '%s' "$b"; else printf '%s' "$m"; fi
}

# Content hash of a file (mirroring process.sh's, for the same reason: identity
# by content, so a rename is not a new file).
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'   # macOS
  fi
}

# Portable line shuffle (shuf is GNU-only): decorate with rand(), sort, strip.
shuffle_lines() {
  awk 'BEGIN { srand() } { printf "%.9f\t%s\n", rand(), $0 }' | sort -n | cut -f2-
}

# --- single-instance lock (its own, independent of process.sh) --------------
LOCK_CREATED_DIR=""
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$WORK/.suggest.lock"
    if ! flock -n 9; then log "another instance holds the lock; exiting"; exit 0; fi
  else
    local d="$WORK/.suggest.lock.d"
    if ! mkdir "$d" 2>/dev/null; then log "another instance holds the lock; exiting"; exit 0; fi
    LOCK_CREATED_DIR="$d"
    trap 'rmdir "$LOCK_CREATED_DIR" 2>/dev/null || true' EXIT
  fi
}

# --- helpers ----------------------------------------------------------------
# Read text on stdin, emit a filesystem-safe slug from the first ~6 words.
slugify() {
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
    [ "$i" -ge 6 ] && break
  done
  printf '%s' "$out"
}

# First non-existing variant of <base>.<ext>, adding -2, -3, ... on collision.
dedup_file() {
  local base="$1" ext="$2" dest="$1.$2" n=2
  while [ -e "$dest" ]; do dest="${base}-${n}.${ext}"; n=$((n + 1)); done
  printf '%s' "$dest"
}

dedup_md() { dedup_file "$1" md; }

# Value of a single-line YAML frontmatter key, or empty. Header region only, so
# a body line that happens to start with "title:" can't shadow the real one.
fm_field() {
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1  && $0 == "---" { exit }
    NR > 1 {
      if (index($0, k ": ") == 1) { print substr($0, length(k) + 3); exit }
    }' "$1"
}

# Frontmatter `sources:` list, flattened to a comma-separated line.
fm_sources() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR > 1  && $0 == "---" { exit }
    /^sources:/ { insrc = 1; next }
    insrc && /^  - / { printf "%s%s", sep, substr($0, 5); sep = ", " }
    insrc && !/^  - / { exit }
    END { print "" }' "$1"
}

# The post minus its frontmatter.
post_body() {
  awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm == 1 && $0 == "---" { fm = 2; next }
    fm != 1 { print }' "$1"
}

# A pool file's kind: frontmatter first, filename as a fallback. Empty means
# "not ours" — such a file is left strictly alone by curation.
pool_kind_of() {
  local k
  k="$(fm_field "$1" kind)"
  if [ -z "$k" ]; then
    # Anchored to the date prefix our own names carry, so a slug that happens
    # to contain "-long-" (…-short-a-long-day.md) can't lie about its kind.
    case "$(basename "$1")" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-long-*)  k=long ;;
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-short-*) k=short ;;
    esac
  fi
  printf '%s' "$k"
}

# Run one Claude call over a prepared stdin stream. Same contract as
# process.sh's claude_transform: subscription auth, never an API key; run from
# work/ with FS/exec tools denied, so the call can only read stdin and write
# stdout. $1 = stream file, $2 = output file, $3 = model (default CLAUDE_MODEL —
# the typo pass is the one caller that overrides it).
claude_call() {
  local rc=0 model="${3:-$CLAUDE_MODEL}"
  ( cd "$WORK" && "$CLAUDE_BIN" -p \
      --model "$model" \
      --output-format text \
      --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Task" \
  ) < "$1" > "$2" || rc=$?
  # Usage ledger (see bin/stats.sh): stream sizes in chars — ~4 chars/token is
  # close enough for a gut feeling, which is all this is for.
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" suggest "$model" \
    "$(wc -c < "$1" | tr -d ' ')" "$(wc -c < "$2" | tr -d ' ')" >> "$USAGE_TSV"
  return $rc
}

# --- verbatim gate ------------------------------------------------------------
# The stitching contract, enforced. The prompt asks the model to assemble posts
# out of the author's own sentences; this is the part that doesn't take its word
# for it. Every sentence of the candidate body is searched for in the corpus:
#
#   VERBATIM  found character-for-character in one of the notes
#   TWEAKED   found after trimming up to 3 words off either end (a seam trim);
#             what remains must still be >= 60% of the sentence
#   GLUE      not found, but short enough (<= GLUE_MAX_WORDS words) to be a
#             connective the prompt allows
#   NEW       not found and too long to be glue — the model wrote prose
#
# A candidate passes only if it has no NEW sentences and at most
# max(1, (100-VERBATIM_MIN)% of its sentences) GLUE ones. The per-sentence
# classification doubles as the provenance report.
#
# $1 = body file, $2 = corpus file (with "### NOTE id=" markers). The report
# goes to stdout; the exit status is the verdict.
verbatim_gate() {
  awk -v min_pct="$VERBATIM_MIN" -v glue_max="$GLUE_MAX_WORDS" \
      -v new_every="$NEW_SLACK_EVERY" '
    function norm(s) {
      gsub(/[\342\200\230\342\200\231]/, "\x27", s)   # curly apostrophes
      gsub(/[\342\200\234\342\200\235]/, "\"", s)     # curly double quotes
      gsub(/[[:space:]]+/, " ", s)
      sub(/^ +/, "", s); sub(/ +$/, "", s)
      return tolower(s)
    }
    # which note contains s verbatim? empty if none
    function source_of(s,   i) {
      for (i = 1; i <= nids; i++) if (index(ntext[ids[i]], s)) return ids[i]
      return ""
    }
    # seam trims: drop up to 3 words from either end; accept if what remains is
    # still most of the sentence and is verbatim somewhere
    function tweaked_source_of(s,   w, n, a, b, core, i, src) {
      n = split(s, w, " ")
      for (a = 0; a <= 3; a++) for (b = 0; b <= 3; b++) {
        if (a + b == 0 || n - a - b < 3) continue
        core = w[a + 1]
        for (i = a + 2; i <= n - b; i++) core = core " " w[i]
        if (length(core) >= 0.6 * length(s)) {
          src = source_of(core)
          if (src != "") return src
        }
      }
      return ""
    }
    NR == FNR {   # first file: the corpus, keyed by note id
      if ($0 ~ /^### NOTE id=/) { id = substr($0, 13); ids[++nids] = id; next }
      if (id != "") raw[id] = raw[id] " " $0
      next
    }
    FNR == 1 { for (i = 1; i <= nids; i++) ntext[ids[i]] = norm(raw[ids[i]]) }
    {         # second file: the candidate body, markdown decorations stripped.
      # Lines are joined with \n, NOT a space: a line break is a sentence
      # boundary too, or an unpunctuated line ending (the author writes those)
      # fuses with the next sentence into a phantom "sentence" that exists
      # nowhere in the corpus and falsely reads as NEW. A real sentence
      # wrapped across lines just splits into fragments, and a fragment of a
      # verbatim sentence still matches as a substring.
      line = $0
      sub(/^[[:space:]]*(#+|[-*>]|[0-9]+\.)[[:space:]]+/, "", line)
      body = body "\n" line
    }
    END {
      gsub(/[.!?][[:space:]]+/, "&\n", body)
      n = split(body, sents, "\n")
      for (i = 1; i <= n; i++) {
        s = norm(sents[i])
        if (length(s) < 16) continue    # too short to judge; free either way
        counted++
        d = sents[i]; gsub(/[[:space:]]+/, " ", d); sub(/^ /, "", d)
        src = source_of(s)
        if (src != "") {
          verbatim++; printf "- VERBATIM [%s] %s\n", src, d
        } else if ((src = tweaked_source_of(s)) != "") {
          tweaked++;  printf "- TWEAKED  [%s] %s\n", src, d
        } else if (split(s, wtmp, " ") <= glue_max) {
          glue++;     printf "- GLUE     %s\n", d
        } else {
          new_++;     printf "- NEW      %s\n", d
        }
      }
      allowed_glue = int(counted * (100 - min_pct) / 100)
      if (allowed_glue < 1) allowed_glue = 1
      # Proportional mercy for NEW: one model-written sentence tolerated per
      # new_every sentences of post. Short posts (< new_every sentences) stay
      # at zero — in 8 sentences, 1 invented one is an eighth of the post; in
      # 46 it is noise the author will delete on review.
      allowed_new = int(counted / new_every)
      pass = (counted > 0 && new_ <= allowed_new && glue <= allowed_glue)
      printf "\ngate: %s — %d verbatim, %d tweaked, %d glue (max %d), %d new (max %d) of %d sentences\n",
             pass ? "PASS" : "FAIL", verbatim, tweaked, glue, allowed_glue, new_, allowed_new, counted
      exit pass ? 0 : 1
    }' "$2" "$1"
}

# --- anonymization ------------------------------------------------------------
# Script-driven, never model-driven — and randomized PER POST: aliases.tsv
# (gitignored) maps each real name to a POOL of fictional ones,
#
#   Timo<TAB>Ben, Jonas, Karim
#   Martin Kowalski<TAB>the hardware guy, the connector whisperer
#
# and every candidate draws its own alias from the pool, so the same person
# reads differently from one post to the next and the posts cannot be joined
# up. Within a post the draw is consistent (one alias per person) and two
# people never share an alias; across posts it avoids repeating the previous
# post's pick (logs/aliases.last). Names are matched as exact substrings — use
# full names to avoid collisions inside other words. Rows with an IDENTICAL
# pool are one person under variant spellings (Lea/Leah — whisper drifts on
# names): they share a single draw per post, so the variants never split
# into two fictional people. Distinct people need distinct pools. Applied to title and body
# after the verbatim gate (the gate must compare against the corpus as
# written) and before anything lands in the synced pool. The corpus, drafts
# and notes keep the real names: they are private memory, and the aliases
# apply at the boundary where text leaves it.

# Draw this post's real->alias map into $1, one TAB-separated pair per line.
make_alias_map() {
  local out="$1"
  : > "$out"
  [ -s "$ALIASES" ] || return 0
  [ -f "$ALIAS_STATE" ] || : > "$ALIAS_STATE"

  awk -F'\t' -v seed="$((RANDOM * 32768 + RANDOM))" -v state="$ALIAS_STATE" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    BEGIN {
      srand(seed)
      while ((getline l < state) > 0) {
        t = index(l, "\t"); if (t) last[substr(l, 1, t - 1)] = substr(l, t + 1)
      }
      close(state)
    }
    NF >= 2 && $1 != "" {
      real = $1
      # variant spellings of one person carry an identical pool: reuse the
      # draw already made for it, so the variants stay one fictional person
      if ($2 in poolpick) { printf "%s\t%s\n", real, poolpick[$2]; next }
      m = split($2, pool, ",")
      # prefer an alias that is neither last post_s pick nor taken in this post;
      # relax step by step rather than ever leaking the real name
      k = 0
      for (i = 1; i <= m; i++) { a = trim(pool[i]); if (a != "" && a != last[real] && !(a in used)) cand[++k] = a }
      if (k == 0) for (i = 1; i <= m; i++) { a = trim(pool[i]); if (a != "" && !(a in used)) cand[++k] = a }
      if (k == 0) for (i = 1; i <= m; i++) { a = trim(pool[i]); if (a != "") cand[++k] = a }
      if (k == 0) next
      choice = cand[int(rand() * k) + 1]
      used[choice] = 1
      poolpick[$2] = choice
      printf "%s\t%s\n", real, choice
    }' "$ALIASES" > "$out"

  # remember the choices so the next post avoids repeating them
  if [ -s "$out" ]; then
    local merged
    merged="$(mktemp "$WORK/.alias.XXXXXX")"
    awk -F'\t' '{ last[$1] = $2 } END { for (r in last) printf "%s\t%s\n", r, last[r] }' \
      "$ALIAS_STATE" "$out" > "$merged" && mv "$merged" "$ALIAS_STATE" || rm -f "$merged"
  fi
}

# Apply a drawn map (longest names first, so "Martin Kowalski" wins over a
# separate "Martin" entry): exact substring replacement, stdin -> stdout.
apply_aliases() {
  local map="$1"
  if [ ! -s "$map" ]; then cat; return 0; fi
  awk -F'\t' '
    NR == FNR { if (NF >= 2) { keys[++nk] = $1; val[$1] = $2 } next }
    !sorted {
      for (i = 2; i <= nk; i++) {
        k = keys[i]
        for (j = i - 1; j >= 1 && length(keys[j]) < length(k); j--) keys[j + 1] = keys[j]
        keys[j + 1] = k
      }
      sorted = 1
    }
    {
      line = $0
      for (i = 1; i <= nk; i++) {
        out = ""
        while ((p = index(line, keys[i])) > 0) {
          out = out substr(line, 1, p - 1) val[keys[i]]
          line = substr(line, p + length(keys[i]))
        }
        line = out line
      }
      print line
    }' "$map" -
}

# --- alias sweep ----------------------------------------------------------------
# The rear guard to the name scout's front door: every run, every synced post
# (pool, Keep/, Discarded/, Rejected/) is checked for real names from ALIASES
# and rewritten with a fresh alias draw when one is found. Catches posts that
# predate the map, hand edits, and anything the scout missed — idempotent,
# because an already-clean file contains no mapped name and is left untouched.
# The `sources:` block is exempt: those are real note paths the pool needs to
# keep pointing at (they stay a known, accepted leak of note-filename slugs).
# mtime is preserved so Discarded/ aging keeps measuring from eviction.
# `bin/suggest.sh --sweep-only` runs just this (plus the lock) and exits.

# Emit $1 minus its frontmatter `sources:` list — the text a sweep may judge.
strip_sources() {
  awk '
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm == 1 && $0 == "---" { fm = 2; print; next }
    fm == 1 && /^sources:/ { insrc = 1; next }
    fm == 1 && insrc && /^  - / { next }
    fm == 1 { insrc = 0 }
    { print }' "$1"
}

# Does $1 contain any real name from ALIASES (word-bounded)?
has_real_name() {
  local name
  while IFS=$'\t' read -r name _; do
    [ -n "$name" ] || continue
    case $name in '#'*) continue ;; esac
    grep -qwF "$name" "$1" && return 0
  done < "$ALIASES"
  return 1
}

# apply_aliases, but leaving the frontmatter `sources:` block untouched.
#   $1 = alias map, $2 = file; result on stdout
apply_aliases_outside_sources() {
  local map="$1" file="$2"
  if [ ! -s "$map" ]; then cat "$file"; return 0; fi
  awk -F'\t' '
    NR == FNR { if (NF >= 2) { keys[++nk] = $1; val[$1] = $2 } next }
    !sorted {
      for (i = 2; i <= nk; i++) {
        k = keys[i]
        for (j = i - 1; j >= 1 && length(keys[j]) < length(k); j--) keys[j + 1] = keys[j]
        keys[j + 1] = k
      }
      sorted = 1
    }
    {
      if (FNR == 1 && $0 == "---") fm = 1
      else if (fm == 1 && $0 == "---") fm = 2
      skip = 0
      if (fm == 1) {
        if ($0 ~ /^sources:/) insrc = 1
        else if (insrc && $0 !~ /^  - /) insrc = 0
        if (insrc) skip = 1
      }
      line = $0
      if (!skip) {
        for (i = 1; i <= nk; i++) {
          out = ""
          while ((p = index(line, keys[i])) > 0) {
            out = out substr(line, 1, p - 1) val[keys[i]]
            line = substr(line, p + length(keys[i]))
          }
          line = out line
        }
      }
      print line
    }' "$map" "$file"
}

alias_sweep() {
  [ -s "$ALIASES" ] || return 0
  local f map="$TMP/sweep.map" bare="$TMP/sweep.bare" fixed="$TMP/sweep.fixed"
  local ref="$TMP/sweep.ref" changed=0
  shopt -s nullglob
  for f in "$POSTS"/*.md "$POSTS"/Keep/*.md "$POSTS"/Discarded/*.md "$POSTS"/Rejected/*.md; do
    strip_sources "$f" > "$bare"
    has_real_name "$bare" || continue
    make_alias_map "$map"
    cp -p "$f" "$ref"
    apply_aliases_outside_sources "$map" "$f" > "$fixed" && mv "$fixed" "$f"
    touch -r "$ref" "$f"
    changed=$((changed + 1))
    log "SWEEP anonymized $(basename "$f")"
  done
  shopt -u nullglob
  if [ "$changed" -gt 0 ]; then
    notify "$changed synced post(s) re-anonymized" "real names swept from Posts/"
  fi
}

# --- name scout ---------------------------------------------------------------
# "ALL names, forever": aliases.tsv covers whoever was known when it was last
# edited, but new people keep entering the notes. Before any candidate is
# written, one model call (prompts/names.md) lists every person name in the
# generation output; the SCRIPT then extends aliases.tsv with a reserve pool
# for each name it does not already know — detection is model-assisted, the
# replacement stays script-driven, and make_alias_map picks the new rows up in
# the same run. Spelling variants arrive on one line (f: Lea|Leah) and share
# one pool; a variant of an already-known name inherits that name's pool. If
# the call fails or answers garbage, ALL candidates are withheld this run:
# synced text is never written without a completed name pass.

# Up to $2 unused reserve aliases for gender $1, one per line. $3/$4 are the
# candidate and corpus files — an alias visible in either would collide with
# a real person, so it is skipped, as is anything in the live map.
pick_reserve() {
  local g="$1" want="$2" cand="$3" corpus="$4" a picked=0 list
  case "$g" in
    f) list="$RESERVE_F $RESERVE_X" ;;
    m) list="$RESERVE_M $RESERVE_X" ;;
    *) list="$RESERVE_X $RESERVE_F $RESERVE_M" ;;
  esac
  for a in $list; do
    [ -f "$ALIASES" ] && grep -qwF "$a" "$ALIASES" && continue
    [ -f "$corpus" ] && grep -qwF "$a" "$corpus" && continue
    grep -qwF "$a" "$cand" && continue
    printf '%s\n' "$a"
    picked=$((picked + 1))
    [ "$picked" -ge "$want" ] && return 0
  done
  [ "$picked" -ge 1 ]
}

# Scan the generation output ($2) for person names and extend ALIASES with any
# new ones. 0 = safe to write candidates; 1 = withhold them all (fail closed).
extend_aliases() {
  local tmp="$1" cand="$2"
  [ "$NAME_SCAN" = 1 ] || return 0
  local stream="$tmp/names.in" resp="$tmp/names.out"
  {
    cat "$NAMES_PROMPT"
    printf '\n===== BEGIN POSTS =====\n'
    cat "$cand"
    printf '\n===== END POSTS =====\n'
  } > "$stream"
  if ! claude_call "$stream" "$resp" 2>>"$SUGGEST_LOG" || [ ! -s "$resp" ]; then
    log "ERROR name scout call failed"
    return 1
  fi
  grep -qx 'NONE' "$resp" && return 0

  [ -f "$ALIASES" ] || { mkdir -p "$(dirname "$ALIASES")"; : > "$ALIASES"; }

  local data=0 added=0 line g names s pool new
  while IFS= read -r line; do
    case "$line" in
      'f: '*|'m: '*|'x: '*) g="${line%%:*}"; names="${line#*: }" ;;
      *) continue ;;   # not a data line (models sometimes add noise)
    esac
    data=$((data + 1))
    pool=""
    new=""
    while IFS= read -r s; do
      s="$(printf '%s' "$s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$s" ] || continue
      [ "$s" = "$SELF_NAME" ] && continue
      # hallucination guard: the name must literally occur in the candidates
      grep -qF "$s" "$cand" || continue
      if awk -F'\t' -v n="$s" '$1 == n { found = 1 } END { exit !found }' "$ALIASES"; then
        # known spelling — remember its pool for any new sibling spelling
        [ -n "$pool" ] || pool="$(awk -F'\t' -v n="$s" '$1 == n { print $2; exit }' "$ALIASES")"
        continue
      fi
      # a "new name" that is one of our own aliases is a collision to untangle
      # by hand, not to auto-map
      grep -qwF "$s" "$ALIASES" && { log "WARN name scout: '$s' collides with an existing alias — left alone"; continue; }
      new="${new:+$new$'\n'}$s"
    done <<< "$(printf '%s' "$names" | tr '|' '\n')"
    [ -n "$new" ] || continue
    if [ -z "$pool" ]; then
      pool="$(pick_reserve "$g" 3 "$cand" "$tmp/corpus.md" | paste -sd ',' - | sed 's/,/, /g')"
      if [ -z "$pool" ]; then
        log "ERROR name scout: reserve pool exhausted — withholding candidates"
        return 1
      fi
    fi
    while IFS= read -r s; do
      printf '%s\t%s\n' "$s" "$pool" >> "$ALIASES"
      added=$((added + 1))
      log "aliases: auto-added '$s'"
    done <<< "$new"
  done < "$resp"

  if [ "$data" -eq 0 ]; then
    log "ERROR name scout output unusable (no data lines, no NONE)"
    return 1
  fi
  [ "$added" -eq 0 ] || log "aliases: $added new name(s) now anonymized, this run and onward"
  return 0
}

# Longitudinal gate stats, one line per candidate — so
# `awk -F'\t' '$2=="REJECTED"' logs/gate.tsv | wc -l` (and its PASS twin)
# answers "is the stitching getting better?" over time.
record_gate() {   # $1 PASS|REJECTED  $2 kind  $3 title  $4 gate summary
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" "$3" "$4" >> "$GATE_TSV"
}

# Exact-string replacement (no regex, so arbitrary filenames are safe).
#   $1 = old string, $2 = new string, $3 = file, edited in place
replace_in_file() {
  local tmpf
  tmpf="$(mktemp "$WORK/.repl.XXXXXX")"
  awk -v old="$1" -v new="$2" '
    {
      line = $0; out = ""
      while ((p = index(line, old)) > 0) {
        out = out substr(line, 1, p - 1) new
        line = substr(line, p + length(old))
      }
      print out line
    }' "$3" > "$tmpf" && mv "$tmpf" "$3" || rm -f "$tmpf"
}

# --- txt normalization --------------------------------------------------------
# Some note apps (and hand-copies) write .txt; the corpus accepts it, but
# Obsidian refuses to open it. Rename to .md on sight — markdown IS plain
# text — propagating the new path into every live reference so no `sources:`
# line dangles, exactly like archive_notes does for its renames. mv preserves
# mtime and inode, so corpus ordering and archive dating are unaffected.
normalize_txt_notes() {
  local f dest old_rel new_rel p renamed=0
  shopt -s nullglob
  for f in "$VAULT"/*.txt "$ARCHIVE"/*.txt; do
    dest="$(dedup_file "${f%.txt}" md)"
    old_rel="${f#"$BLOG_ROOT"/}"
    new_rel="${dest#"$BLOG_ROOT"/}"
    mv "$f" "$dest"
    renamed=$((renamed + 1))
    log "TXT->MD $old_rel -> $new_rel"
    for p in "$POSTS"/*.md "$POSTS"/Keep/*.md "$POSTS"/Discarded/*.md \
             "$POSTS"/Rejected/*.md "$PROVENANCE"/*.md; do
      [ -f "$p" ] || continue
      grep -qF "$old_rel" "$p" || continue
      replace_in_file "$old_rel" "$new_rel" "$p"
      log "TXT->MD updated source ref in $(basename "$p")"
    done
  done
  shopt -u nullglob
}

# --- archive ------------------------------------------------------------------
# Root notes older than ARCHIVE_DAYS move to Obsidian/Archive/<date>-<slug>,
# the date from when the note was created (file_created_epoch — never the
# archival date) and the slug from its first line — the phone's
# note apps name files arbitrarily ("Lorem ipsum dolor sit.txt"), and archiving
# is where a note gets its real, dated title. Names that already lead with a
# date are kept as-is. Every rename is propagated into the `sources:` lines of
# the pool and Keep/ so no reference dangles. Archived notes stay in the
# corpus: archiving organises, it never forgets.
archive_notes() {
  local f base ext date first slug dest old_rel new_rel p moved=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    ext="${base##*.}"
    case "$base" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*)
        dest="$(dedup_file "$ARCHIVE/${base%.*}" "$ext")" ;;
      *)
        date="$(epoch_to_date "$(file_created_epoch "$f")")"
        first="$(head -n 1 "$f" | sed 's/^#\+[[:space:]]*//')"
        slug="$(printf '%s' "$first" | slugify)"
        [ -n "$slug" ] || slug="note"
        dest="$(dedup_file "$ARCHIVE/${date}-${slug}" "$ext")" ;;
    esac
    old_rel="${f#"$BLOG_ROOT"/}"
    new_rel="${dest#"$BLOG_ROOT"/}"
    mv "$f" "$dest"
    moved=$((moved + 1))
    log "ARCHIVE $old_rel -> $new_rel"
    for p in "$POSTS"/*.md "$POSTS"/Keep/*.md; do
      [ -f "$p" ] || continue
      grep -qF "$old_rel" "$p" || continue
      replace_in_file "$old_rel" "$new_rel" "$p"
      log "ARCHIVE updated source ref in $(basename "$p")"
    done
  done < <(find "$VAULT" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' \) \
             -mtime +"$ARCHIVE_DAYS" 2>/dev/null)
  [ "$moved" -eq 0 ] || log "archived $moved note(s) into Obsidian/Archive/"
}

# --- typo pass over typed notes -----------------------------------------------
# A voice memo is proofread the moment it is transcribed: prompts/cleanup.md
# fixes obvious transcription errors, and nothing downstream has to care. A
# TYPED note — thumbed into the phone one-handed, unproofread — had no such
# stage, so its typos travelled verbatim into the corpus and out the other side
# in a stitched post. This is that missing stage, and it lives here for the same
# reason cleanup lives in process.sh: at capture, once, never again.
#
# It rewrites the note IN PLACE — the one place in this pipeline where raw input
# is edited. That is deliberate: the note reads correctly on the phone too, the
# corpus and the verbatim gate keep seeing exactly one version of the text, and
# a post stitched next month inherits the fix for free. What keeps it honest is
# that the model is never trusted with the result:
#
#   - one call per note, EVER (logs/typofix.tsv, keyed by content hash — both
#     the pre- and post-fix hash are recorded, so a fixed note is not re-read
#     next run, and a note you edit later gets exactly one fresh pass);
#   - the output is not written anywhere. It is diffed against the note word by
#     word, and the only thing extracted from it is a list of single-word
#     substitutions, which are then applied to the ORIGINAL file. Everything the
#     model did beyond respelling words — a reflowed line, a supplied comma, a
#     tidied sentence — is discarded by construction, because there is no code
#     path that could carry it across;
#   - any substitution that is not typo-shaped fails the WHOLE note (typo_gate):
#     it stays as typed and is never retried at that content hash.
#
# Voice bundles under drafts/ are excluded: they are already cleaned, and their
# cleaned.md must keep matching verbatim.md and changes.diff.
typofix_notes() {
  [ "$TYPO_FIX" = 1 ] || return 0
  if [ ! -f "$TYPO_PROMPT" ]; then
    log "WARN $TYPO_PROMPT missing — typo pass skipped"
    return 0
  fi
  local f rel h h2 rc n reason fixed_notes=0 scanned=0
  local stream="$TMP/typo.in" out="$TMP/typo.out" subs="$TMP/typo.subs"
  local merged="$TMP/typo.merged" ref="$TMP/typo.ref"
  shopt -s nullglob
  for f in "$VAULT"/*.md "$VAULT"/*.txt "$ARCHIVE"/*.md "$ARCHIVE"/*.txt; do
    [ -s "$f" ] || continue
    h="$(sha256 "$f")" || continue
    grep -q "^$h	" "$TYPOFIX_TSV" 2>/dev/null && continue
    rel="${f#"$BLOG_ROOT"/}"
    scanned=$((scanned + 1))

    {
      cat "$TYPO_PROMPT"
      printf '\n\n===== BEGIN INPUT (proofread ONLY the text between the markers; output nothing else) =====\n'
      cat "$f"
      printf '\n===== END INPUT =====\n'
    } > "$stream"

    rc=0
    claude_call "$stream" "$out" "$TYPO_MODEL" || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
      log "WARN typo pass failed on $rel (exit $rc) — left as typed"
      typofix_record "$h" "$rel" "FAILED"
      continue
    fi

    rc=0
    strip_fence "$out" | typo_gate "$f" > "$subs" || rc=$?
    if [ "$rc" -ne 0 ]; then
      reason="$(sed -n 's/^REJECT //p' "$subs" | head -n 1)"
      log "WARN typo pass rejected on $rel: ${reason:-unusable output} — left as typed"
      typofix_record "$h" "$rel" "REJECTED ${reason:-unusable output}"
      continue
    fi

    awk -F'\t' -v f="$(basename "$f")" '$1 == "SKIP" {
      printf "declined on %s: %s -> %s (under TYPO_MIN_LEN)\n", f, $4, $5 }' "$subs" \
      | while IFS= read -r line; do log "TYPO-SKIP $line"; done

    n="$(awk -F'\t' '$1 == "SUB"' "$subs" | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then
      typofix_record "$h" "$rel" "clean"
      continue
    fi

    # Apply to the ORIGINAL, not the model's text: every byte the gate did not
    # explicitly approve — indentation, blank lines, the missing full stop —
    # survives untouched.
    cp -p "$f" "$ref"
    typo_apply "$subs" "$f" > "$merged" && mv "$merged" "$f"
    touch -r "$ref" "$f"     # mtime is corpus recency and the archive clock
    awk -F'\t' '$1 == "SUB" { print $4 "\t" $5 }' "$subs" | while IFS=$'\t' read -r old new; do
      log "TYPO $(basename "$f"): $old -> $new"
    done
    fixed_notes=$((fixed_notes + 1))
    h2="$(sha256 "$f")"
    typofix_record "$h"  "$rel" "fixed $n"
    typofix_record "$h2" "$rel" "fixed $n (post)"
  done
  shopt -u nullglob
  [ "$scanned" -eq 0 ] || log "typo pass: $scanned note(s) read, $fixed_notes corrected"
  [ "$fixed_notes" -eq 0 ] || notify "$fixed_notes typed note(s) proofread" "typos fixed in the vault"
}

typofix_record() {   # $1 hash  $2 rel path  $3 result
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$3" >> "$TYPOFIX_TSV"
}

# Strip a markdown code fence the model may have wrapped its answer in. Nothing
# else about the output is repaired — a stray sentence of commentary is left in
# place so the gate can reject the note, which is the correct outcome.
strip_fence() {
  awk '{ lines[NR] = $0 }
    END {
      first = 1; last = NR
      if (lines[1] ~ /^```/ && lines[NR] ~ /^```[[:space:]]*$/ && NR >= 2) { first = 2; last = NR - 1 }
      for (i = first; i <= last; i++) print lines[i]
    }' "$1"
}

# The gate. Reads the ORIGINAL ($1) and the model's version (stdin) and decides
# whether the difference is nothing but respelled words.
#
# stdout on success: one line per differing word, as
#   SUB  \t <line no> \t <word no> \t <old> \t <new>   approved
#   SKIP \t <line no> \t <word no> \t <old> \t <new>   declined, note still fine
# stdout on failure: a single "REJECT <reason>" line, exit 1. Rejection is
# all-or-nothing per note — a model that got one word wrong does not get to keep
# the others, because the failure mode this guards against (a quietly improved
# sentence) looks exactly like a run of legitimate small edits.
#
# SKIP is the one exception, and only for the short-word rule. That rule is not
# there to catch a misbehaving model; it is there because a three-letter token
# is unknowable from the outside, so declining just that word is exact. Failing
# the note over it would throw away real fixes and — since the note is never
# re-read at that hash — throw them away permanently.
#
# A word may change only if:
#   - it sits at the same line and word position, with identical punctuation
#     around it and inside it (so `dont` -> `don't` is a REJECT: that is
#     punctuation, not spelling);
#   - its core is at least TYPO_MIN_LEN characters — under that lives the whole
#     population of acronyms, initialisms and shorthand (wbe, tbh, iir), which
#     cannot be told from typos by shape, so none of them are ever touched
#     (SKIP, not REJECT);
#   - the change is not case-only (that would be capitalization, not spelling);
#   - both spellings are plain words: no digits, no symbols, and no bytes
#     outside ASCII. The last rule means a word carrying an umlaut is never
#     "corrected" — which is also the German/Denglisch rule, enforced rather
#     than requested;
#   - the two spellings are within a small edit distance (2, or 3 for long
#     words): a typo is a slipped finger, not a different word.
# And the note as a whole may not change more than TYPO_MAX_PCT of its words
# (minimum 3), which is what a proofreader does; more than that is a rewrite.
#
# What this CANNOT catch: a plain-ASCII word swapped for another plain-ASCII
# word one edit away, where the intent was grammar rather than spelling — a
# German declension (ganze -> ganzen) is the realistic case, since umlaut words
# are already immune. Only prompts/typos.md forbids that, and a wrong one shows
# up in logs/typofix.tsv and the TYPO lines in the log, which is why every
# substitution is recorded by name.
typo_gate() {
  awk -v minlen="$TYPO_MIN_LEN" -v maxpct="$TYPO_MAX_PCT" '
    function lev(a, b,   la, lb, i, j, cost, prev, cur) {
      la = length(a); lb = length(b)
      if (la == 0) return lb
      if (lb == 0) return la
      for (j = 0; j <= lb; j++) prev[j] = j
      for (i = 1; i <= la; i++) {
        cur[0] = i
        for (j = 1; j <= lb; j++) {
          cost = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
          cur[j] = prev[j] + 1
          if (cur[j - 1] + 1 < cur[j])      cur[j] = cur[j - 1] + 1
          if (prev[j - 1] + cost < cur[j])  cur[j] = prev[j - 1] + cost
        }
        for (j = 0; j <= lb; j++) prev[j] = cur[j]
      }
      return prev[lb]
    }
    # A word split into its punctuation shell and its core: "(cobsciousness?" ->
    # lead "(", core "cobsciousness", trail "?".
    function lead(t)  { return match(t, /^[^[:alnum:]]+/) ? substr(t, 1, RLENGTH) : "" }
    function trail(t) { return match(t, /[^[:alnum:]]+$/) ? substr(t, RSTART)     : "" }
    function core(t)  { sub(/^[^[:alnum:]]+/, "", t); sub(/[^[:alnum:]]+$/, "", t); return t }
    function reject(msg) { printf "REJECT %s\n", msg; exit 1 }
    # Last line that is not trailing whitespace: the model reliably drops or adds
    # a final blank line, and that is not a difference worth failing a note over.
    function effective_last(arr, n,   i) {
      for (i = n; i >= 1; i--) if (arr[i] ~ /[^[:space:]]/) return i
      return 0
    }
    NR == FNR { o[FNR] = $0; on = FNR; next }
                { m[FNR] = $0; mn = FNR }
    END {
      oe = effective_last(o, on); me = effective_last(m, mn)
      if (oe != me) reject(sprintf("line count %d -> %d", oe, me))
      changed = 0; words = 0
      for (i = 1; i <= oe; i++) {
        na = split(o[i], A); nb = split(m[i], B)
        words += na
        if (na != nb) reject(sprintf("line %d: word count %d -> %d", i, na, nb))
        for (j = 1; j <= na; j++) {
          if (A[j] == B[j]) continue
          ca = core(A[j]); cb = core(B[j])
          if (lead(A[j]) != lead(B[j]) || trail(A[j]) != trail(B[j]))
            reject(sprintf("punctuation changed: %s -> %s", A[j], B[j]))
          if (length(ca) < minlen) {
            skipped++
            skip_old[skipped] = A[j]; skip_new[skipped] = B[j]
            continue
          }
          if (tolower(ca) == tolower(cb))
            reject(sprintf("case-only change: %s -> %s", A[j], B[j]))
          # Internal punctuation must survive too, or a supplied apostrophe
          # (dont -> the contraction) and hyphenation (motherinlaw ->
          # mother-in-law) would pass as respellings. Both are punctuation, and
          # punctuation is not what this pass is for.
          pa = ca; gsub(/[A-Za-z]/, "", pa)
          pb = cb; gsub(/[A-Za-z]/, "", pb)
          if (pa != pb)
            reject(sprintf("punctuation changed: %s -> %s", A[j], B[j]))
          if (ca ~ /[^A-Za-z'"'"'-]/ || cb ~ /[^A-Za-z'"'"'-]/)
            reject(sprintf("not a plain word: %s -> %s", A[j], B[j]))
          # The distance a typo is allowed to travel scales with the word, or a
          # short word drifts into a different one: like -> love is distance 2
          # on four letters, which is a rewrite of the sentence, not a slipped
          # finger — and on this corpus it is exactly the wrong word to get
          # wrong. Long words keep the looser cap: freinds -> friends is a
          # transposition, which Levenshtein charges 2 for.
          maxd = length(ca) >= 10 ? 3 : (length(ca) >= 6 ? 2 : 1)
          if (lev(tolower(ca), tolower(cb)) > maxd)
            reject(sprintf("different word, not a typo: %s -> %s", A[j], B[j]))
          changed++
          sub_line[changed] = i; sub_word[changed] = j
          sub_old[changed] = A[j]; sub_new[changed] = B[j]
        }
      }
      allow = int(words * maxpct / 100); if (allow < 3) allow = 3
      if (changed > allow)
        reject(sprintf("%d words changed in a %d-word note (cap %d)", changed, words, allow))
      for (k = 1; k <= changed; k++)
        printf "SUB\t%d\t%d\t%s\t%s\n", sub_line[k], sub_word[k], sub_old[k], sub_new[k]
      for (k = 1; k <= skipped; k++)
        printf "SKIP\t0\t0\t%s\t%s\n", skip_old[k], skip_new[k]
    }' "$1" -
}

# Apply approved substitutions ($1) to a note ($2); result on stdout. Walks each
# line token by token so the original spacing is reproduced byte for byte, and
# swaps a word only where the gate approved that exact word at that exact
# position.
typo_apply() {
  awk -F'\t' '
    NR == FNR { if ($1 == "SUB") { key = $2 SUBSEP $3; old[key] = $4; new[key] = $5 } next }
    {
      rest = $0; out = ""; idx = 0
      while (length(rest) > 0) {
        if (match(rest, /^[[:space:]]+/)) {
          out = out substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1); continue
        }
        match(rest, /^[^[:space:]]+/)
        tok = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
        # ++idx on its own line: "FNR SUBSEP ++idx" is parsed by awk as
        # (SUBSEP++) concatenated with idx, silently keying every lookup wrong.
        idx++
        key = FNR SUBSEP idx
        if (key in old && tok == old[key]) tok = new[key]
        out = out tok
      }
      print out
    }' "$1" "$2"
}

# --- sentence reuse -----------------------------------------------------------
# "One sentence, one post" — enforced softly, and PER KIND. A sentence that
# already carries a post you KEPT is claimed for that post's kind only: a
# sentence spent on a long may still open a short, and vice versa — only
# same-kind repetition is damped. Each claimed sentence is enforced
# REUSE_DROP_PCT% of the time (one die per sentence per run, shared by both
# kinds), so an iconic line still resurfaces now and then. Sentences under
# REUSE_MIN_WORDS words are never claimed ("No!" belongs to every post).
#
# ONLY Keep/ CLAIMS. The pool does not: a candidate is disposable by design —
# it ages out, gets evicted by the curator, or is thrown away unread — and a
# sentence must not be locked up by a post that was never chosen. Reserving
# material for a candidate reserves it for something that probably dies, which
# is the opposite of the rule's purpose. So a line that appears in today's pool
# is still free for tomorrow's better stitching of the same idea; the pool cap
# and the curator's near-duplicate eviction are what keep the pool itself from
# repeating, and they do that by reading the candidates, not by hiding material.
# Discarded/ and Rejected/ claim nothing either, for the same reason.
#
# Enforcement is split because one corpus feeds both kinds in a single call:
#   - claimed by BOTH kinds -> hidden from the corpus as a […] hole (the model
#     usually cannot re-stitch it; if it reproduces one from memory, the gate
#     reads it as NEW and sinks the candidate — no new rule needed there);
#   - claimed by ONE kind -> left visible (it is legal material for the other
#     kind), listed in the RESERVED SENTENCES section of the generation stream
#     (trimmed to sentences present in this run's corpus — see
#     filter_to_corpus), and enforced after the fact by reuse_gate against
#     same-kind candidates.
#
# Matching runs on the pre-alias text recorded in the provenance reports (the
# posts themselves are anonymized, so their text no longer equals the notes').
# The norm() here MUST stay identical to verbatim_gate's.

# Normalized enforced sentences -> three files, one sentence per line:
#   <$1>.long    claimed by a live long post and enforced this run
#   <$1>.short   claimed by a live short post and enforced this run
#   <$1>.hidden  enforced for both kinds -> becomes a corpus hole
build_claimed() {
  local prefix="$1" raw="$1.raw" pv base pool kind
  : > "$raw"; : > "$prefix.long"; : > "$prefix.short"
  shopt -s nullglob
  for pv in "$PROVENANCE"/*.md; do
    base="$(basename "$pv")"
    # Keep/ only — a provenance report whose post is in the pool, Discarded/ or
    # Rejected/ claims nothing (see the note above).
    [ -f "$POSTS/Keep/$base" ] || continue
    pool="$POSTS/Keep/$base"
    kind="$(pool_kind_of "$pool")"
    case "$kind" in long|short) ;; *) continue ;; esac
    awk -v min="$REUSE_MIN_WORDS" -v kind="$kind" '
      function norm(s) {
        gsub(/[\342\200\230\342\200\231]/, "\x27", s)
        gsub(/[\342\200\234\342\200\235]/, "\"", s)
        gsub(/[[:space:]]+/, " ", s)
        sub(/^ +/, "", s); sub(/ +$/, "", s)
        return tolower(s)
      }
      /^- (VERBATIM|TWEAKED) / {
        t = $0
        sub(/^- (VERBATIM|TWEAKED)[[:space:]]+\[[^]]*\][[:space:]]*/, "", t)
        t = norm(t)
        if (split(t, w, " ") >= min) printf "%s\t%s\n", kind, t
      }' "$pv" >> "$raw"
  done
  shopt -u nullglob
  # One die per sentence, shared across kinds, so a sentence claimed by a long
  # AND a short comes and goes as one — never half-hidden.
  awk -F'\t' -v pct="$REUSE_DROP_PCT" -v seed="$((RANDOM * 32768 + RANDOM))" \
      -v longf="$prefix.long" -v shortf="$prefix.short" '
    BEGIN { srand(seed) }
    {
      if (!($2 in roll)) roll[$2] = (rand() * 100 < pct) ? 1 : 0
      if (!roll[$2]) next
      if ($1 == "long") print $2 > longf
      else              print $2 > shortf
    }' "$raw"
  rm -f "$raw"
  sort -u -o "$prefix.long"  "$prefix.long"
  sort -u -o "$prefix.short" "$prefix.short"
  comm -12 "$prefix.long" "$prefix.short" > "$prefix.hidden"
}

# Emit note $1 with corpus-hidden sentences (set in $2 — the .hidden file, dice
# already rolled in build_claimed) replaced by […] — a visible hole, so the
# model stitches around it instead of bridging it with prose of its own.
filter_claimed() {
  local f="$1" claimed="$2"
  if [ ! -s "$claimed" ]; then cat "$f"; return 0; fi
  awk -v claimedf="$claimed" '
    function norm(s) {
      gsub(/[\342\200\230\342\200\231]/, "\x27", s)
      gsub(/[\342\200\234\342\200\235]/, "\"", s)
      gsub(/[[:space:]]+/, " ", s)
      sub(/^ +/, "", s); sub(/ +$/, "", s)
      return tolower(s)
    }
    BEGIN {
      while ((getline l < claimedf) > 0) claimed[l] = 1
      close(claimedf)
    }
    {
      line = $0
      gsub(/[.!?][[:space:]]+/, "&\x01", line)
      n = split(line, units, "\x01")
      out = ""
      for (i = 1; i <= n; i++) {
        u = units[i]
        c = u
        sub(/^[[:space:]]*(#+|[-*>]|[0-9]+\.)[[:space:]]+/, "", c)
        c = norm(c)
        if (c in claimed) out = out "[…] "
        else out = out u
      }
      print out
    }' "$f"
}

# Keep only the sentences (one per line, already norm()ed by build_claimed)
# that actually appear in this run's corpus, $2. A claim whose source notes
# were not sampled this run cannot be stitched verbatim anyway, so listing it
# in the generation stream is pure token waste — and Keep/ only ever grows, so
# without this trim the RESERVED SENTENCES section grows without bound while
# everything else in the stream is budgeted. Prompt-only: reuse_gate still
# enforces the FULL claim lists afterwards.
filter_to_corpus() {
  local list="$1" corpus="$2"
  [ -s "$list" ] || return 0
  awk -v listf="$list" '
    function norm(s) {
      gsub(/[\342\200\230\342\200\231]/, "\x27", s)
      gsub(/[\342\200\234\342\200\235]/, "\"", s)
      gsub(/[[:space:]]+/, " ", s)
      sub(/^ +/, "", s); sub(/ +$/, "", s)
      return tolower(s)
    }
    { text = text " " $0 }
    END {
      text = norm(text)
      while ((getline l < listf) > 0) if (index(text, l)) print l
      close(listf)
    }' "$corpus"
}

# The kind-scoped half of the rule: candidate body $1 must not contain a
# sentence enforced for its own kind (list $2). Runs AFTER verbatim_gate, which
# cannot catch these — a single-kind claim is deliberately left visible in the
# corpus, so it classifies as VERBATIM. Prints REUSED lines plus a "gate:"
# verdict line on failure; prints nothing and exits 0 on pass.
reuse_gate() {
  local body="$1" enforced="$2" kind="$3"
  [ -s "$enforced" ] || return 0
  awk -v listf="$enforced" -v kind="$kind" '
    function norm(s) {
      gsub(/[\342\200\230\342\200\231]/, "\x27", s)
      gsub(/[\342\200\234\342\200\235]/, "\"", s)
      gsub(/[[:space:]]+/, " ", s)
      sub(/^ +/, "", s); sub(/ +$/, "", s)
      return tolower(s)
    }
    BEGIN {
      while ((getline l < listf) > 0) claimed[l] = 1
      close(listf)
    }
    {
      line = $0
      sub(/^[[:space:]]*(#+|[-*>]|[0-9]+\.)[[:space:]]+/, "", line)
      body = body " " line
    }
    END {
      gsub(/[.!?][[:space:]]+/, "&\n", body)
      n = split(body, sents, "\n")
      for (i = 1; i <= n; i++) {
        s = norm(sents[i])
        if (!(s in claimed)) continue
        hits++
        d = sents[i]; gsub(/[[:space:]]+/, " ", d); sub(/^ /, "", d)
        printf "- REUSED   %s\n", d
      }
      if (hits) printf "\ngate: FAIL — %d sentence(s) already carrying a live %s post\n", hits, kind
      exit hits ? 1 : 0
    }' "$body"
}

# --- corpus -----------------------------------------------------------------
# Every cleaned voice memo plus every typed note (vault root and Archive/).
# Ordered by mtime, not filename: the phone's note apps use arbitrary names, so
# filenames cannot be trusted to lead with a date.
#
# When the material exceeds CORPUS_MAX, the newest notes get ~70% of the budget
# and the remainder is filled with a RANDOM SAMPLE of the older ones — old
# material keeps a chance to converge with new instead of aging out of the
# corpus entirely. Together with the reuse holes (filter_claimed) this makes
# the corpus a different lens every run, which is why generation runs even on
# unchanged notes.
#
# Posts/ lives *inside* the vault but is excluded by the non-recursive globs:
# the generator must never read its own output back in as source material.

# Every corpus candidate as "<mtime>\t<path>", unordered.
# .txt as well as .md: the phone's note apps write plain .txt, and a note is a
# note regardless of what extension the editor chose.
corpus_files() {
  local f
  shopt -s nullglob
  for f in "$DRAFTS"/*/cleaned.md \
           "$VAULT"/*.md "$VAULT"/*.txt \
           "$ARCHIVE"/*.md "$ARCHIVE"/*.txt; do
    printf '%s\t%s\n' "$(file_mtime_epoch "$f")" "$f"
  done
  shopt -u nullglob
}

NOTE_COUNT=0
build_corpus() {
  local out="$1" f rel mt fsize size=0 total=0 sampled=0 skipped
  : > "$out"

  local claimed="$TMP/claimed"
  build_claimed "$claimed"
  if [ -s "$claimed.long" ] || [ -s "$claimed.short" ]; then
    log "reuse: enforced this run (${REUSE_DROP_PCT}% of claims): $(wc -l < "$claimed.long" | tr -d ' ') long, $(wc -l < "$claimed.short" | tr -d ' ') short — $(wc -l < "$claimed.hidden" | tr -d ' ') claimed by both kinds, hidden from the corpus"
  fi

  local listing
  listing="$(corpus_files | sort -rn)"
  [ -n "$listing" ] || return 0

  local recent_budget=$((CORPUS_MAX * 70 / 100))
  local selected="$TMP/corpus.selected" rest="$TMP/corpus.rest"
  : > "$selected"; : > "$rest"

  # phase 1: newest first, up to the recency share of the budget
  while IFS=$'\t' read -r mt f; do
    total=$((total + 1))
    fsize="$(wc -c < "$f" | tr -d ' ')"
    if [ "$((size + fsize))" -le "$recent_budget" ]; then
      printf '%s\t%s\n' "$mt" "$f" >> "$selected"
      size=$((size + fsize))
    else
      printf '%s\t%s\n' "$mt" "$f" >> "$rest"
    fi
  done <<< "$listing"

  # phase 2: random sample of the remainder, until the full budget is spent
  if [ -s "$rest" ]; then
    while IFS=$'\t' read -r mt f; do
      fsize="$(wc -c < "$f" | tr -d ' ')"
      if [ "$((size + fsize))" -le "$CORPUS_MAX" ]; then
        printf '%s\t%s\n' "$mt" "$f" >> "$selected"
        size=$((size + fsize))
        sampled=$((sampled + 1))
      fi
    done < <(shuffle_lines < "$rest")
  fi

  # emit newest-first regardless of which phase selected a note
  while IFS=$'\t' read -r mt f; do
    rel="${f#"$BLOG_ROOT"/}"
    {
      printf '\n### NOTE id=%s\n\n' "$rel"
      filter_claimed "$f" "$claimed.hidden"
      printf '\n'
    } >> "$out"
  done < <(sort -rn "$selected")

  NOTE_COUNT="$(wc -l < "$selected" | tr -d ' ')"
  skipped=$((total - NOTE_COUNT))
  [ "$skipped" -eq 0 ] \
    || log "corpus: $skipped note(s) omitted, $sampled older one(s) sampled in — CORPUS_MAX=$CORPUS_MAX chars"
}

# --- provenance backfill ------------------------------------------------------
# A post claims its sentences through its provenance report (build_claimed), so
# a Keep/ post WITHOUT one claims nothing — silently. That is the worst possible
# direction for the rule to fail in: the posts you chose to keep are exactly the
# ones whose lines should not be spent twice. It is a real state, not a
# hypothetical — Keep/2026-08-09-long-the-whole-idea-of-editing-is.md predates
# the provenance step and had been claiming nothing for days.
#
# So: any Keep/ post missing a report gets one rebuilt by re-matching its body
# against the corpus, exactly as verbatim_gate does at generation time. The
# verdict is discarded — a reconstruction is not a gate, and a post already in
# Keep/ passed the real one when it was written.
#
# A reconstruction is APPROXIMATE and says so in the file it writes:
#   - the post is anonymized and the corpus is not, so any sentence carrying a
#     name fails to match and claims nothing;
#   - notes are edited, so a sentence whose source has since been reworded (or
#     proofread by typofix_notes) no longer matches either.
# Both failures are safe in the same direction: a sentence that cannot be found
# is simply not claimed, which is the state the post was already in. On the one
# post this exists for, 33 of 40 sentences come back.
#
# Runs before build_corpus, because build_claimed reads what this writes.
emit_full_corpus() {
  local out="$1" f rel
  : > "$out"
  while IFS=$'\t' read -r _ f; do
    rel="${f#"$BLOG_ROOT"/}"
    {
      printf '\n### NOTE id=%s\n\n' "$rel"
      cat "$f"
      printf '\n'
    } >> "$out"
  done < <(corpus_files | sort -rn)
}

# A post file stripped to the text verbatim_gate wants: no frontmatter, and no
# "# Title" line (the generator adds that after the gate has run, so a
# reconstruction has to take it back off).
post_body() {
  awk 'NR == 1 && $0 == "---" { fm = 1; next }
       fm == 1 && $0 == "---"  { fm = 2; next }
       fm == 1                 { next }
       !h1 && /^# /            { h1 = 1; next }
       { print }' "$1"
}

backfill_provenance() {
  local f base id kind rep body corpus="$TMP/corpus.full"
  local n_claim n_sent rebuilt=0
  local missing=()
  shopt -s nullglob
  for f in "$POSTS"/Keep/*.md; do
    base="$(basename "$f")"
    [ -f "$PROVENANCE/$base" ] && continue
    kind="$(pool_kind_of "$f")"
    case "$kind" in long|short) ;; *) continue ;; esac   # not ours; leave alone
    missing+=("$f")
  done
  shopt -u nullglob
  [ "${#missing[@]}" -gt 0 ] || return 0

  emit_full_corpus "$corpus"
  body="$TMP/backfill.body"; rep="$TMP/backfill.prov"

  for f in "${missing[@]}"; do
    base="$(basename "$f")"; id="${base%.md}"
    post_body "$f" > "$body"
    # Verdict ignored on purpose (see above) — only the classification lines are
    # wanted, and a FAIL line among them is harmless: build_claimed reads only
    # the VERBATIM/TWEAKED ones.
    verbatim_gate "$body" "$corpus" > "$rep" || true
    n_claim="$(grep -cE '^- (VERBATIM|TWEAKED) ' "$rep" || true)"
    n_sent="$(grep -cE '^- ' "$rep" || true)"
    if [ "${n_claim:-0}" -eq 0 ]; then
      log "WARN Keep/$base has no provenance and none could be rebuilt — it claims nothing"
      continue
    fi
    {
      printf '# provenance: %s\n' "$id"
      # A post from before the experiment layer has no variant to report, and
      # saying nothing would let it be counted as whatever runs today. So it
      # says what is true: it came from before any of this.
      printf '# variant: pre-experiment\n'
      printf '# persona: \n'
      printf '# run: %s\n' "$BLOG_RUN_ID"
      printf '#\n'
      printf '# RECONSTRUCTED %s. This post predates the provenance step, so the\n' "$(date '+%Y-%m-%d')"
      printf '# generation-time report is gone for good; these lines were recovered by\n'
      printf '# re-matching the post against the corpus (%s of %s sentences found).\n' \
        "$n_claim" "${n_sent:-0}"
      printf '# It exists so the post can claim its sentences — it is NOT a record of\n'
      printf '# what the model actually did, and the unmatched sentences claim nothing.\n\n'
      cat "$rep"
    } > "$PROVENANCE/$base"
    prov_record backfill "$f" "" "reconstructed:$n_claim/${n_sent:-0}"
    rebuilt=$((rebuilt + 1))
    log "PROVENANCE rebuilt for Keep/$base — $n_claim of ${n_sent:-0} sentence(s) recovered"
  done
  [ "$rebuilt" -eq 0 ] || log "provenance: $rebuilt Keep/ post(s) backfilled"
}

# --- pool inventory ---------------------------------------------------------
# Writes "<id>\t<kind>\t<title>\t<sources>" for every post currently in the
# pool. Keep/ and Discarded/ are subdirectories, so the glob skips them.
pool_inventory() {
  local f id kind
  shopt -s nullglob
  for f in "$POSTS"/*.md; do
    kind="$(pool_kind_of "$f")"
    [ -n "$kind" ] || continue
    id="$(basename "$f" .md)"
    printf '%s\t%s\t%s\t%s\n' \
      "$id" "$kind" "$(fm_field "$f" title)" "$(fm_sources "$f")"
  done
  shopt -u nullglob
}

# --- generate ---------------------------------------------------------------
generate() {
  local tmp="$1" inventory="$2"
  local stream="$tmp/gen.in" out="$tmp/gen.out" n_res_all n_res

  {
    cat "$SUGGEST_PROMPT"
    if [ -f "$ANCHOR" ]; then printf '\n\n'; cat "$ANCHOR"; fi
    printf '\n\nMAX NEW: %s\n' "$MAX_NEW"

    printf '\n===== BEGIN CORPUS =====\n'
    cat "$tmp/corpus.md"
    printf '\n===== END CORPUS =====\n'

    # Single-kind claims stay visible in the corpus (legal for the other
    # kind), so the model has to be TOLD what they are reserved for. Both-kind
    # claims are already […] holes and must not be revealed here. Trimmed to
    # sentences present in this run's corpus: only those can be stitched.
    printf '\n===== BEGIN RESERVED SENTENCES =====\n'
    comm -23 "$tmp/claimed.long" "$tmp/claimed.hidden" > "$tmp/claimed.only_long.all"
    comm -23 "$tmp/claimed.short" "$tmp/claimed.hidden" > "$tmp/claimed.only_short.all"
    filter_to_corpus "$tmp/claimed.only_long.all"  "$tmp/corpus.md" > "$tmp/claimed.only_long"
    filter_to_corpus "$tmp/claimed.only_short.all" "$tmp/corpus.md" > "$tmp/claimed.only_short"
    n_res_all="$(cat "$tmp/claimed.only_long.all" "$tmp/claimed.only_short.all" | wc -l | tr -d ' ')"
    n_res="$(cat "$tmp/claimed.only_long" "$tmp/claimed.only_short" | wc -l | tr -d ' ')"
    [ "$n_res" -eq "$n_res_all" ] \
      || log "reserved: $((n_res_all - n_res)) claim(s) whose sentences are not in this corpus — left out of the stream"
    if [ -s "$tmp/claimed.only_long" ] || [ -s "$tmp/claimed.only_short" ]; then
      if [ -s "$tmp/claimed.only_long" ]; then
        printf 'Already carrying a live LONG post — do not use in a new long; free for a short:\n'
        sed 's/^/- /' "$tmp/claimed.only_long"
      fi
      if [ -s "$tmp/claimed.only_short" ]; then
        printf 'Already carrying a live SHORT post — do not use in a new short; free for a long:\n'
        sed 's/^/- /' "$tmp/claimed.only_short"
      fi
    else
      printf '(none)\n'
    fi
    printf '===== END RESERVED SENTENCES =====\n'

    printf '\n===== BEGIN POOL =====\n'
    if [ -s "$inventory" ]; then
      awk -F'\t' '{ printf "- [%s] %s  (from: %s)\n", $2, $3, $4 }' "$inventory"
    else
      printf '(empty)\n'
    fi
    printf '===== END POOL =====\n'

    printf '\n===== BEGIN HISTORY =====\n'
    if [ -s "$SUGGESTED" ]; then
      tail -n "$HISTORY_LINES" "$SUGGESTED" \
        | awk -F'\t' '{ printf "- [%s] %s  (from: %s)\n", $2, $3, $4 }'
    else
      printf '(nothing yet)\n'
    fi
    printf '===== END HISTORY =====\n'

    # The model's own error log: what the gate killed recently, and why. This
    # is the feedback half of the stitching contract — rejections teach the
    # next run instead of vanishing into a log file.
    printf '\n===== BEGIN GATE FEEDBACK =====\n'
    if [ -s "$GATE_TSV" ] && awk -F'\t' '$2 == "REJECTED" { found = 1 } END { exit !found }' "$GATE_TSV"; then
      awk -F'\t' '$2 == "REJECTED"' "$GATE_TSV" | tail -n 8 \
        | awk -F'\t' '{ printf "- [%s] %s — %s\n", $3, $4, $5 }'
    else
      printf '(none yet)\n'
    fi
    printf '===== END GATE FEEDBACK =====\n'
  } > "$stream"

  if ! claude_call "$stream" "$out" 2>>"$SUGGEST_LOG"; then
    log "ERROR generation call failed"
    return 1
  fi
  if [ ! -s "$out" ]; then
    log "ERROR generation produced no output"
    return 1
  fi
  printf '%s' "$out"
}

# Split the model's output into one file per candidate and write the accepted
# ones into the pool. Echoes the number written.
write_candidates() {
  local tmp="$1" out="$2" written=0 rejected=0
  local today; today="$(date +%Y-%m-%d)"
  # What the model was looking at, by content — the one identity that says two
  # candidates were stitched from the same material. Cheap to record, and the
  # only way a later comparison can tell "different variant" from "different day".
  local corpus_sha
  corpus_sha="$(blog_file_hash "$tmp/corpus.md" | cut -c1-12)"

  if grep -qx 'NO CANDIDATES' "$out"; then
    log "model proposed nothing this run"
    printf '0 0'
    return 0
  fi

  awk -v d="$tmp" '
    /^===== POST =====[[:space:]]*$/  { n++; f = sprintf("%s/cand.%03d", d, n); inp = 1; next }
    /^===== END POST =====[[:space:]]*$/ { inp = 0; next }
    inp && f { print > f }
  ' "$out"

  local c kind title sources dest slug src rel
  shopt -s nullglob
  for c in "$tmp"/cand.*; do
    if [ "$written" -ge "$MAX_NEW" ]; then
      log "WARN model proposed more than MAX_NEW=$MAX_NEW; ignoring the rest"
      break
    fi

    awk '/^----- body -----[[:space:]]*$/ { exit } { print }' "$c" > "$c.head"
    awk 'f { print } /^----- body -----[[:space:]]*$/ { f = 1 }' "$c" > "$c.body"

    kind="$(sed -n 's/^kind:[[:space:]]*//p' "$c.head" | head -1 | tr -d '[:space:]')"
    title="$(sed -n 's/^title:[[:space:]]*//p' "$c.head" | head -1)"
    sources="$(sed -n 's/^sources:[[:space:]]*//p' "$c.head" | head -1)"

    case "$kind" in
      long|short) ;;
      *) log "WARN candidate rejected: unknown kind '$kind'"; continue ;;
    esac
    if [ -z "$title" ] || ! grep -q '[^[:space:]]' "$c.body"; then
      log "WARN candidate rejected: missing title or empty body"
      continue
    fi

    # Grounding check: a source the model made up is the tell that the post is
    # made up too. Keep only paths that exist, and require at least two.
    local valid=() n_valid=0
    while IFS= read -r src; do
      src="$(printf '%s' "$src" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$src" ] || continue
      if [ -f "$BLOG_ROOT/$src" ]; then
        valid+=("$src"); n_valid=$((n_valid + 1))
      else
        log "WARN candidate '$title': unknown source '$src' dropped"
      fi
    done <<< "$(printf '%s' "$sources" | tr ',' '\n')"

    if [ "$n_valid" -lt 2 ]; then
      log "WARN candidate rejected: '$title' cites $n_valid real source(s), needs 2+"
      continue
    fi

    # This post's alias draw — one map for the accepted post or the kept
    # reject alike, so either way nothing synced carries a real name.
    make_alias_map "$c.aliases"

    # Stitching gate: the model was told to assemble the author's own
    # sentences; this measures whether it did, and rejects the whole candidate
    # if not. The classification is kept as the post's provenance report.
    # Then the reuse gate: no sentence already carrying a live post of the
    # SAME kind (the other kind's claims don't apply — see build_claimed).
    local gate_ok=1
    verbatim_gate "$c.body" "$tmp/corpus.md" > "$c.prov" || gate_ok=0
    if [ "$gate_ok" -eq 1 ]; then
      reuse_gate "$c.body" "$tmp/claimed.$kind" "$kind" >> "$c.prov" || gate_ok=0
    fi
    if [ "$gate_ok" -eq 0 ]; then
      local gate_line
      gate_line="$(tail -n 1 "$c.prov" | sed 's/^gate: //')"
      log "WARN candidate rejected by gate: '$title' — $gate_line"
      record_gate REJECTED "$kind" "$title" "$gate_line"
      rejected=$((rejected + 1))

      # Keep the near-miss where you can read it: rejects go to Posts/Rejected/
      # (synced, aged out after REJECT_DAYS) with the gate report appended, so
      # you can compare what the gate kills against what it lets through — if
      # you keep liking them, lower VERBATIM_MIN.
      local rtitle rslug rdest
      rtitle="$(printf '%s' "$title" | apply_aliases "$c.aliases")"
      rslug="$(printf '%s' "$rtitle" | slugify)"
      [ -n "$rslug" ] || rslug="untitled"
      rdest="$(dedup_md "$REJECTED/${today}-${kind}-${rslug}")"
      {
        printf -- '---\n'
        printf 'kind: %s\n' "$kind"
        printf 'title: %s\n' "$rtitle"
        printf 'created: %s\n' "$today"
        prov_frontmatter "$PERSONA"
        printf 'rejected: %s\n' "$gate_line"
        printf 'sources:\n'
        for src in "${valid[@]}"; do printf '  - %s\n' "$src"; done
        printf -- '---\n\n'
        printf '# %s\n\n' "$rtitle"
        apply_aliases "$c.aliases" < "$c.body"
        printf '\n---\n\n## gate report\n\n'
        apply_aliases "$c.aliases" < "$c.prov"
      } > "$rdest"
      # A rejection is a result too: a variant that gets everything rejected is
      # a variant that failed, and that only shows up if the losses are counted.
      prov_record rejected "$rdest" "$PERSONA" "corpus:$corpus_sha"
      log "REJECTED kept: $(basename "$rdest" .md)"
      continue
    fi
    record_gate PASS "$kind" "$title" "$(tail -n 1 "$c.prov" | sed 's/^gate: //')"

    # Aliases apply after the gate (which must see the text as written) and
    # before anything reaches the synced pool. Slug from the anonymized title,
    # so real names don't survive in filenames either.
    title="$(printf '%s' "$title" | apply_aliases "$c.aliases")"
    apply_aliases "$c.aliases" < "$c.body" > "$c.body.anon"

    slug="$(printf '%s' "$title" | slugify)"
    [ -n "$slug" ] || slug="untitled"
    dest="$(dedup_md "$POSTS/${today}-${kind}-${slug}")"

    # variant/persona/run go in the FRONTMATTER, not in a side file, because
    # frontmatter is what survives the trip to the phone and the move into
    # Keep/ — and that move is the datum the online scorer reads. The filename
    # and the body stay unbranded, so reading the pool stays blind.
    {
      printf -- '---\n'
      printf 'kind: %s\n' "$kind"
      printf 'title: %s\n' "$title"
      printf 'created: %s\n' "$today"
      prov_frontmatter "$PERSONA"
      printf 'sources:\n'
      for src in "${valid[@]}"; do printf '  - %s\n' "$src"; done
      printf -- '---\n\n'
      printf '# %s\n\n' "$title"
      cat "$c.body.anon"
    } > "$dest"

    # Provenance: which note every sentence came from, and what little glue the
    # model added — the posts' equivalent of the drafts' changes.diff. Quotes
    # are pre-alias, matching the (private) corpus, which is why .provenance/
    # is in sync/.stignore: laptop-only, never carried to the phone.
    {
      printf '# provenance: %s\n' "$(basename "$dest" .md)"
      prov_report_header "$PERSONA"
      printf '\n'
      cat "$c.prov"
    } > "$PROVENANCE/$(basename "$dest" .md).md"
    prov_record candidate "$dest" "$PERSONA" "corpus:$corpus_sha"

    rel="$(basename "$dest" .md)"
    # Join by hand: "${valid[*]}" plus tr would turn the spaces *inside* a
    # filename into separators, and the phone's note apps name files things like
    # "Lorem ipsum dolor sit.txt".
    local srclist=""
    for src in "${valid[@]}"; do srclist="${srclist:+$srclist, }$src"; done
    printf '%s\t%s\t%s\t%s\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$kind" "$title" "$srclist" >> "$SUGGESTED"
    log "NEW [$kind] $rel"
    written=$((written + 1))
  done
  shopt -u nullglob

  printf '%s %s' "$written" "$rejected"
}

# --- curate -----------------------------------------------------------------
# Move a post out of the pool. The mtime is reset on the way in so Discarded/
# retention is measured from eviction, not from when the post was written.
evict() {
  local f="$1" dest
  dest="$(dedup_md "$TRASH/$(basename "$f" .md)")"
  mv "$f" "$dest"
  touch "$dest"
  log "EVICT $(basename "$f")"
}

curate_kind() {
  local kind="$1" cap="$2" tmp="$3"
  local files=() f
  shopt -s nullglob
  for f in "$POSTS"/*.md; do
    if [ "$(pool_kind_of "$f")" = "$kind" ]; then files+=("$f"); fi
  done
  shopt -u nullglob

  local n="${#files[@]}"
  if [ "$n" -le "$cap" ]; then
    log "pool[$kind]: $n/$cap — nothing to evict"
    return 0
  fi
  log "pool[$kind]: $n/$cap — curating"

  # A short is judgeable from its first 500 chars; a long post's excerpt was
  # cutting off mid-argument, so longs are judged on the (capped) full body.
  local exlen=500
  [ "$kind" = "long" ] && exlen=6000

  local stream="$tmp/curate.$kind.in" out="$tmp/curate.$kind.out"
  {
    cat "$CURATE_PROMPT"
    printf '\n\n===== BEGIN POOL =====\n'
    for f in "${files[@]}"; do
      printf '\nid: %s\n'      "$(basename "$f" .md)"
      printf 'title: %s\n'     "$(fm_field "$f" title)"
      printf 'sources: %s\n'   "$(fm_sources "$f")"
      printf 'excerpt: %s\n'   "$(post_body "$f" | tr '\n' ' ' | tr -s ' ' | head -c "$exlen")"
    done
    printf '\n===== END POOL =====\n'
    printf '\nKEEP COUNT: %s\n' "$cap"
  } > "$stream"

  local keep_ids=""
  if claude_call "$stream" "$out" 2>>"$SUGGEST_LOG" && [ -s "$out" ]; then
    keep_ids="$(grep -m1 '^KEEP:' "$out" 2>/dev/null \
                | sed 's/^KEEP:[[:space:]]*//' \
                | tr ',' '\n' \
                | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                | grep -v '^$' || true)"
    local why
    why="$(grep -m1 '^WHY:' "$out" 2>/dev/null | sed 's/^WHY:[[:space:]]*//' || true)"
    [ -z "$why" ] || log "curator[$kind]: $why"
  else
    log "WARN curation call failed for $kind"
  fi

  # Validate the decision against the pool that actually exists. Anything
  # unexpected — wrong count, unknown id, duplicate — and we do not trust it.
  local ok=1 id
  if [ "$(printf '%s\n' "$keep_ids" | grep -c '[^[:space:]]' || true)" -ne "$cap" ]; then
    ok=0
  else
    while IFS= read -r id; do
      [ -f "$POSTS/$id.md" ] || { ok=0; break; }
    done <<< "$keep_ids"
    [ "$(printf '%s\n' "$keep_ids" | sort -u | wc -l)" -eq "$cap" ] || ok=0
  fi

  if [ "$ok" -ne 1 ]; then
    # Deterministic fallback: keep the newest `cap` by name (names lead with the
    # date), evict the rest. The cap is honoured either way — a bad model
    # response must never leave the pool unbounded.
    log "WARN curator[$kind] response unusable; falling back to newest-$cap"
    keep_ids="$(printf '%s\n' "${files[@]}" | sed 's#.*/##; s#\.md$##' | sort -r | head -n "$cap")"
  fi

  for f in "${files[@]}"; do
    id="$(basename "$f" .md)"
    if ! printf '%s\n' "$keep_ids" | grep -qxF "$id"; then
      evict "$f"
    fi
  done
}

# --- main -------------------------------------------------------------------
# The scratch dir is global: the EXIT trap runs outside any function, so a
# `local` here would be unbound by the time it fires (set -u).
TMP=""
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  [ -z "$LOCK_CREATED_DIR" ] || rmdir "$LOCK_CREATED_DIR" 2>/dev/null || true
}

main() {
  acquire_lock

  # Retry-slot guard: the timer fires several slots a day so a 03:00 failure
  # (laptop off, no network) gets retried, but only the first SUCCESS of a
  # calendar day does work — later slots are no-ops. A failed run writes no
  # stamp, so the next slot picks it up. Manual runs ignore the stamp.
  if [ "${SUGGEST_SCHEDULED:-0}" = 1 ] && [ -f "$STAMP" ] \
     && [ "$(cat "$STAMP")" = "$(date +%Y-%m-%d)" ]; then
    log "already completed today — retry slot skipped"
    return 0
  fi

  # A crashed run (SIGKILL, power loss) never fires the EXIT trap; sweep any
  # scratch dir old enough that it can't belong to a live run.
  find "$WORK" -maxdepth 1 \( -name 'sugg.*' -o -name '.repl.*' \) -mmin +1440 \
    -exec rm -rf {} + 2>/dev/null || true

  TMP="$(mktemp -d "$WORK/sugg.XXXXXX")"
  trap cleanup EXIT
  local tmp="$TMP"

  normalize_txt_notes
  archive_notes
  alias_sweep

  if [ "${1:-}" = "--sweep-only" ]; then
    log "sweep-only run done"
    return 0
  fi

  # Before the corpus is read, so a typo is fixed once at the source rather than
  # in every post stitched out of it.
  typofix_notes

  if [ "${1:-}" = "--typos-only" ]; then
    log "typos-only run done"
    return 0
  fi

  # Before build_corpus: build_claimed runs inside it and reads what this writes.
  backfill_provenance

  build_corpus "$tmp/corpus.md"
  if [ "$NOTE_COUNT" -lt 2 ]; then
    log "corpus has $NOTE_COUNT note(s); need at least 2 to stitch anything — nothing to do"
    return 0
  fi

  local inventory="$tmp/pool.tsv"
  pool_inventory > "$inventory"
  local n_long n_short
  n_long="$(awk -F'\t' '$2 == "long"' "$inventory" | wc -l | tr -d ' ')"
  n_short="$(awk -F'\t' '$2 == "short"' "$inventory" | wc -l | tr -d ' ')"

  log "corpus: $NOTE_COUNT notes; pool: ${n_long}/${MAX_LONG} long, ${n_short}/${MAX_SHORT} short"

  # Generation runs EVERY run, even with no new notes — deliberately. The
  # corpus is a different lens each day (reuse holes fall differently, the
  # over-budget sample rotates), so identical notes can still yield a stitching
  # yesterday's run couldn't see; the pool cap, HISTORY and the curator absorb
  # any churn. One Claude call a day is the price of serendipity.
  local out counts written=0 rejected=0 gen_failed=0
  if out="$(generate "$tmp" "$inventory")"; then
    # Name scout before anything is written: a new person in the notes gets an
    # alias row NOW, so the very post that introduces them is already covered.
    # Failure withholds all candidates (fail closed) and the timer retries.
    if extend_aliases "$tmp" "$out"; then
      counts="$(write_candidates "$tmp" "$out")"
      written="${counts%% *}"
      rejected="${counts##* }"
    else
      gen_failed=1
      log "WARN name scout failed; candidates withheld, curating the pool anyway"
    fi
  else
    gen_failed=1
    log "WARN generation failed; curating the existing pool anyway"
  fi

  curate_kind long  "$MAX_LONG"  "$tmp"
  curate_kind short "$MAX_SHORT" "$tmp"

  # Age out the undo buffer and the kept rejects.
  find "$TRASH" -maxdepth 1 -type f -name '*.md' -mtime +"$TRASH_DAYS" -delete 2>/dev/null || true
  find "$REJECTED" -maxdepth 1 -type f -name '*.md' -mtime +"$REJECT_DAYS" -delete 2>/dev/null || true

  # Drop provenance only once its post is gone from the pool, Keep/ AND
  # Discarded/ — an eviction is reversible for TRASH_DAYS, and a restored post
  # should still have its report.
  local pv base
  shopt -s nullglob
  for pv in "$PROVENANCE"/*.md; do
    base="$(basename "$pv")"
    [ -f "$POSTS/$base" ] || [ -f "$POSTS/Keep/$base" ] || [ -f "$TRASH/$base" ] \
      || rm -f "$pv"
  done
  shopt -u nullglob

  log "run done: $written new suggestion(s), $rejected gate-rejected"
  if [ "$written" -gt 0 ]; then
    notify "$written new post suggestion(s)" "in sync/Obsidian/Posts/"
  fi
  # Rejections must be as visible as acceptances, or the gate silently starves
  # the pool and nobody learns anything.
  if [ "$rejected" -gt 0 ]; then
    notify "$rejected candidate(s) rejected by the stitching gate" "kept in Posts/Rejected/ for $REJECT_DAYS days"
  fi

  # The day stamp is written only when generation actually went through; a
  # transport failure exits non-zero, stamps nothing, and the timer's next
  # retry slot tries again — until midnight rolls the day over.
  if [ "$gen_failed" -eq 1 ]; then
    log "run incomplete: generation failed — next timer slot will retry"
    return 1
  fi
  date +%Y-%m-%d > "$STAMP"

  # Daily stats snapshot: one page per day in logs/stats/ (gitignored with the
  # rest of logs/, never synced to the phone), latest.txt always the newest.
  # A year of dailies is kept — they're a few hundred bytes each.
  local statsdir="$LOGS/stats" snap
  mkdir -p "$statsdir"
  snap="$statsdir/$(date +%Y-%m-%d).txt"
  if "$SCRIPT_DIR/stats.sh" > "$snap" 2>/dev/null; then
    ln -sf "$(basename "$snap")" "$statsdir/latest.txt"
  else
    log "WARN stats snapshot failed"
  fi
  find "$statsdir" -maxdepth 1 -name '[0-9]*.txt' -mtime +365 -delete 2>/dev/null || true

  # STATS.md in the repo root: the same numbers, but the one copy that is NOT
  # gitignored — so the state of the pipeline is visible in the repo without
  # digging through logs/. Public view (no titles): it gets committed.
  "$SCRIPT_DIR/stats.sh" --write 2>/dev/null || log "WARN STATS.md refresh failed"
}

main "$@"
