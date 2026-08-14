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
#   NOTES_DIR   where notes live   (default: the vault under BLOG_ROOT)
#   EDITOR      editor to open     (default: first of nvim, vim, nano)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"
# shellcheck source=../lib/common.sh
. "$REPO_DIR/lib/common.sh"
# The vault inside the shared Syncthing folder. Notes are its top-level .md
# files; Posts/ (generated suggestions) is a subdirectory, so the non-recursive
# globs below list and search notes only.
#
# Through $VAULT rather than the repo, so a re-rooted tree takes this script
# with it: writing a note under BLOG_ROOT=<sandbox> used to land in the LIVE
# vault, which is the one thing re-rooting is supposed to make impossible.
# NOTES_DIR still wins outright — it predates BLOG_ROOT and people have it in
# their fingers.
NOTES_DIR="${NOTES_DIR:-$VAULT}"

die() { printf '\033[1;31m[note]\033[0m %s\n' "$*" >&2; exit 1; }

pick_editor() {
  if [ -n "${EDITOR:-}" ]; then printf '%s' "$EDITOR"; return; fi
  for e in nvim vim nano; do
    command -v "$e" >/dev/null 2>&1 && { printf '%s' "$e"; return; }
  done
  die "no editor found — set \$EDITOR"
}

# Name a note from its own first line; fall back to the timestamp alone.
name_for() {
  local first slug
  first="$(head -n 1 "$1" | sed 's/^#\+[[:space:]]*//')"
  slug="$(printf '%s' "$first" | blog_slugify)"
  dedup_md "$NOTES_DIR/$(date +%Y-%m-%d)${slug:+-$slug}"
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
