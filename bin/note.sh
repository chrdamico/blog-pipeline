#!/usr/bin/env bash
#
# note.sh — no-frills text-note capture, the laptop half of the notes vault.
#
# The phone half is a plain markdown editor (Obsidian / Zettel Notes) writing
# into a Syncthing folder; this is the same thing from a terminal. Notes are
# plain .md files named <date>-<slug>.md — no database, no frontmatter, no
# index. Whatever writes the file is interchangeable.
#
#   note.sh                     open $EDITOR on a new note; slug from line 1
#   note.sh buy milk on friday  capture immediately, no editor
#   echo hi | note.sh           capture stdin
#   note.sh -l                  list recent notes
#   note.sh -e <pattern>        open the newest note whose *filename* matches
#
# Invariants (mirroring bin/process.sh):
#   - an existing note is never overwritten; collisions get -2, -3, ...
#   - an editor session left empty writes nothing
#
# Optional environment:
#   NOTES_DIR   where notes live   (default: <repo>/sync/Obsidian)
#   EDITOR      editor to open     (default: first of nvim, vim, nano)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# The vault inside the shared Syncthing folder. Notes are its top-level .md
# files; Posts/ (generated suggestions) is a subdirectory, so the non-recursive
# globs below list and search notes only.
NOTES_DIR="${NOTES_DIR:-$REPO_DIR/sync/Obsidian}"

die() { printf '\033[1;31m[note]\033[0m %s\n' "$*" >&2; exit 1; }

pick_editor() {
  if [ -n "${EDITOR:-}" ]; then printf '%s' "$EDITOR"; return; fi
  for e in nvim vim nano; do
    command -v "$e" >/dev/null 2>&1 && { printf '%s' "$e"; return; }
  done
  die "no editor found — set \$EDITOR"
}

# Read text on stdin, emit a filesystem-safe slug from the first ~6 words.
# Umlauts are transliterated in both cases *before* the ASCII lowercase, which
# only maps a-z — otherwise a leading "Ö" survives to the tr -c and is dropped.
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

# Given a desired base path (no extension), return the first non-existing
# variant, adding -2, -3, ... so an existing note is never overwritten.
dedup_dest() {
  local base="$1" dest="$1.md" n=2
  while [ -e "$dest" ]; do
    dest="${base}-${n}.md"
    n=$((n + 1))
  done
  printf '%s' "$dest"
}

# Name a note from its own first line; fall back to the timestamp alone.
name_for() {
  local first slug
  first="$(head -n 1 "$1" | sed 's/^#\+[[:space:]]*//')"
  slug="$(printf '%s' "$first" | slugify)"
  dedup_dest "$NOTES_DIR/$(date +%Y-%m-%d)${slug:+-$slug}"
}

mkdir -p "$NOTES_DIR"

# --- list / edit modes ------------------------------------------------------
if [ "${1:-}" = "-l" ]; then
  # ls fails on an empty vault and pipefail would abort the script, so the
  # listing is collected first and the empty case handled explicitly.
  # .txt too — the phone's note apps write plain .txt (see bin/suggest.sh).
  # Archive/ as well: suggest.sh moves old notes there (dated, titled).
  listing="$(ls -t "$NOTES_DIR"/*.md "$NOTES_DIR"/*.txt \
                   "$NOTES_DIR"/Archive/*.md "$NOTES_DIR"/Archive/*.txt 2>/dev/null \
             | head -n "${2:-20}" || true)"
  [ -n "$listing" ] || { printf '[note] no notes yet in %s\n' "$NOTES_DIR" >&2; exit 0; }
  printf '%s\n' "$listing" | while read -r f; do
    printf '%s  %s\n' "$(basename "$f")" "$(head -n 1 "$f")"
  done
  exit 0
fi

if [ "${1:-}" = "-e" ]; then
  [ $# -ge 2 ] || die "usage: note.sh -e <pattern>"
  # ls exits non-zero for every unmatched glob (kept literal — no nullglob), and
  # pipefail would turn that into a false "no match"; the emptiness check below
  # is the real verdict.
  target="$(ls -t "$NOTES_DIR"/*"$2"*.md "$NOTES_DIR"/*"$2"*.txt \
                  "$NOTES_DIR"/Archive/*"$2"*.md "$NOTES_DIR"/Archive/*"$2"*.txt 2>/dev/null \
            | head -n 1 || true)"
  [ -n "$target" ] || die "no note matching: $2"
  exec "$(pick_editor)" "$target"
fi

# --- capture ----------------------------------------------------------------
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [ $# -gt 0 ]; then
  printf '%s\n' "$*" > "$tmp"          # args are the note
elif [ ! -t 0 ]; then
  cat > "$tmp"                          # stdin is the note
else
  "$(pick_editor)" "$tmp"               # type it
fi

# An empty capture is a cancelled capture.
if ! grep -q '[^[:space:]]' "$tmp" 2>/dev/null; then
  printf '[note] empty — nothing written\n' >&2
  exit 0
fi

dest="$(name_for "$tmp")"
cp "$tmp" "$dest"
printf '%s\n' "$dest"
