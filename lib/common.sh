#!/usr/bin/env bash
#
# lib/common.sh — the small things more than one script needs.
#
# Two groups, and nothing else belongs here: if a helper is used by exactly one
# script it should stay in that script, where its reader is.
#
#   PORTABLE PRIMITIVES  hashing, file times, slugs, shuffling. Each one exists
#                        because GNU and BSD/macOS disagree about a flag, and the
#                        disagreement should be settled once. This repo still
#                        means to run on macOS, whose /bin/bash is 3.2 — so no
#                        associative arrays, no mapfile, nothing from bash 4.
#
#   POSTS AND POOLS      reading a post's frontmatter, deciding a pool file's
#                        kind, listing the pools. bin/suggest.sh writes posts and
#                        bin/score.sh counts them, and they had drifted into two
#                        names for the same function (fm_field / fm, all_pools /
#                        pool_dirs) — the sort of duplication that is invisible
#                        until the two answer differently.
#
# Sourced after lib/config.sh, whose POSTS/TRASH/REJECTED it reads.

if [ -z "${BLOG_COMMON_LOADED:-}" ]; then
BLOG_COMMON_LOADED=1

# --- portable primitives --------------------------------------------------------

# GNU stat first, then BSD/macOS stat.
file_mtime_epoch() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# GNU date first, then BSD/macOS date.
epoch_to_date() { date -d "@$1" '+%Y-%m-%d' 2>/dev/null || date -r "$1" '+%Y-%m-%d'; }

# A file's mtime as a date, which is what most callers actually want.
file_date() { epoch_to_date "$(file_mtime_epoch "$1")"; }

# When a note was CREATED, as best the filesystem knows. Both available clocks
# overshoot creation in different ways — birth time (GNU stat %W, 0 = unknown;
# BSD/macOS stat -f %B) is when Syncthing first wrote the LOCAL file, mtime is the
# last edit (Syncthing preserves the phone's) — so the earlier of the two is the
# closest estimate. mv preserves both: never the archival date.
file_created_epoch() {
  local b m
  m="$(file_mtime_epoch "$1")"
  b="$(stat -c %W "$1" 2>/dev/null || stat -f %B "$1" 2>/dev/null || echo 0)"
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if [ "$b" -gt 0 ] && [ "$b" -lt "$m" ]; then printf '%s' "$b"; else printf '%s' "$m"; fi
}

# Read text on stdin, emit a filesystem-safe slug from the first $1 words
# (default 6). Umlauts are transliterated in BOTH cases before the ASCII
# lowercase, which only maps a-z — otherwise a leading "Ö" survives to the tr -c
# and is dropped.
#
# The word count is a parameter because the callers disagreed: a draft bundle
# takes 5 words and a post 6, which was almost certainly accident rather than
# decision, but changing either one renames things on disk, so it is preserved
# and made visible instead.
blog_slugify() {
  local max="${1:-6}" s
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
    [ "$i" -ge "$max" ] && break
  done
  printf '%s' "$out"
}

# First non-existing variant of <base>.<ext>, adding -2, -3, ... on collision, so
# nothing in this pipeline ever overwrites anything.
dedup_file() {
  local base="$1" ext="$2" dest="$1.$2" n=2
  while [ -e "$dest" ]; do dest="${base}-${n}.${ext}"; n=$((n + 1)); done
  printf '%s' "$dest"
}
dedup_md() { dedup_file "$1" md; }

# The same, for a path with no extension (a draft bundle's directory).
dedup_dir() {
  local base="$1" dest="$1" n=2
  while [ -e "$dest" ]; do dest="${base}-${n}"; n=$((n + 1)); done
  printf '%s' "$dest"
}

# Portable line shuffle (shuf is GNU-only): decorate with rand(), sort, strip.
shuffle_lines() {
  awk 'BEGIN { srand() } { printf "%.9f\t%s\n", rand(), $0 }' | sort -n | cut -f2-
}

# --- posts and pools ------------------------------------------------------------

# Value of a single-line YAML frontmatter key, or empty. Header region only, so a
# body line that happens to start with "title:" can't shadow the real one.
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

# A pool file's kind: frontmatter first, filename as a fallback. Empty means "not
# ours" — such a file is left strictly alone by curation.
pool_kind_of() {
  local k
  k="$(fm_field "$1" kind)"
  if [ -z "$k" ]; then
    # Anchored to the date prefix our own names carry, so a slug that happens to
    # contain "-long-" (…-short-a-long-day.md) can't lie about its kind.
    case "$(basename "$1")" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-long-*)  k=long ;;
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-short-*) k=short ;;
    esac
  fi
  printf '%s' "$k"
}

# Every pool folder that exists: the base's (the Posts/ root, where it has always
# been) plus one per live arm (Posts/<arm>/). Keep/, Discarded/ and Rejected/ are
# shared and are NOT pools — a post there has already been judged, and its arm
# rides in its frontmatter.
all_pools() {
  printf '%s\n' "$POSTS"
  local d
  shopt -s nullglob
  for d in "$POSTS"/*/; do
    case "$(basename "${d%/}")" in Keep|Discarded|Rejected) continue ;; esac
    printf '%s\n' "${d%/}"
  done
  shopt -u nullglob
}

# All post files, one path per line. With no argument: the pools only. With
# "judged": the shared Keep/, Discarded/ and Rejected/ as well.
#
# Always consume this with `while IFS= read -r`, never `for f in $(...)`: command
# substitution word-splits, and posts get renamed by hand on the phone. A loop
# that split on spaces skipped those files in silence — which is how two of them
# kept a `sources:` line pointing at a note that had been renamed away.
all_post_files() {
  local want="${1:-}" d f
  shopt -s nullglob
  while IFS= read -r d; do
    for f in "$d"/*.md; do printf '%s\n' "$f"; done
  done < <(all_pools)
  if [ "$want" = judged ]; then
    for f in "$POSTS"/Keep/*.md "$TRASH"/*.md "$REJECTED"/*.md; do printf '%s\n' "$f"; done
  fi
  shopt -u nullglob
}

fi   # BLOG_COMMON_LOADED
