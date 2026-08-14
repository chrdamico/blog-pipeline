#!/usr/bin/env bash
# tests/check_privacy.sh — the "nothing personal ever gets committed" gate.
#
# Inspects the git INDEX — i.e. exactly what the next commit would contain,
# including anything force-added past .gitignore — so it works both as a test
# and as the pre-commit hook (.githooks/pre-commit runs exactly this script;
# install.sh wires it up via core.hooksPath).
#
# Layers of defence:
#   1. no file under a private path may be tracked (sync/ drafts/ logs/ work/
#      private/ models/ vendor/, plus PLAN.md)
#   2. no audio file may be tracked, anywhere in the tree
#   3. .gitignore must still contain every guarding pattern — this catches the
#      failure mode where the guard itself is weakened
#   4. no staged text may contain a private marker: a work email address, or a
#      real name listed in private/aliases.tsv (read at run time so no name is
#      ever embedded in this script; silently skipped where the file is absent)
#   5. no staged text may quote a draft bundle's name or a note's title. Both
#      are built from the author's own first words, so a list of them is a list
#      of his phrasing — which is exactly how material once reached a public
#      repo through a file that contained no prose at all
set -u
cd "$(git rev-parse --show-toplevel)"
fail=0
err() { printf 'PRIVACY FAIL: %s\n' "$*" >&2; fail=1; }

# 1. private paths must never be tracked
bad=$(git ls-files -- 'sync/' 'drafts/' 'logs/' 'work/' 'private/' 'models/' \
                      'vendor/' 'PLAN.md')
[ -z "$bad" ] || err "tracked file(s) in a private path:
$bad"

# 1b. eval/ is personal too — fixtures are your memos and your vault, copied,
# and run outputs are posts stitched out of them. Only the experiment
# DEFINITIONS (and this exception) are code.
bad=$(git ls-files -- 'eval/' | grep -v '^eval/experiments/' || true)
[ -z "$bad" ] || err "tracked file(s) under eval/ that are not experiment definitions:
$bad"

# 2. no audio, anywhere
bad=$(git ls-files | grep -iE '\.(wav|m4a|mp3|opus|ogg|flac|aac|wma)$' || true)
[ -z "$bad" ] || err "audio file(s) tracked:
$bad"

# 3. the guard itself must stay intact
for pat in 'sync/' 'drafts/' 'logs/' 'work/' 'private/' 'models/' 'eval/*' \
           'PLAN.md' '*.wav' '*.m4a' '*.mp3' \
           '*.opus' '*.ogg' '*.flac'; do
  grep -qxF "$pat" .gitignore || err ".gitignore no longer contains '$pat'"
done

# 4. private markers in staged content (-I skips binary blobs)
hits=$(git grep -I --cached -l -E '[A-Za-z0-9._%+-]+@smart-steel[a-z-]*\.[a-z]+' -- . 2>/dev/null || true)
[ -z "$hits" ] || err "work email address in staged content: $(echo "$hits" | tr '\n' ' ')"

# -w (word boundary): the map auto-grows via the name scout, and a short name
# matched as a bare substring would block innocent words around it. Printing
# the offending name is fine — it goes to the terminal, never into the commit.
if [ -f private/aliases.tsv ]; then
  while IFS=$'\t' read -r real _; do
    [ -n "$real" ] || continue
    case $real in '#'*) continue ;; esac
    hits=$(git grep -I --cached -l -wF "$real" -- . 2>/dev/null || true)
    [ -z "$hits" ] || err "real name '$real' (private/aliases.tsv) appears in: $(echo "$hits" | tr '\n' ' ')"
  done < private/aliases.tsv
fi

# 5. the author's own words, in any form — including the ones that do not look
# like content. A draft bundle's directory name is built from the first words of
# what he actually said, and a note's filename IS its first line, so a list of
# them is a list of his phrasing and his recording dates. That is how a
# perfectly innocent-looking "which files are the test set" manifest leaked real
# material into a public repo once, which is why this layer exists.
#
# Only distinctive names are checked: some notes are called "a" or "1", and a
# guard that blocks those blocks everything. A bundle slug always carries its
# date, and a note title needs three words and twelve characters before it
# counts as identifying.
if [ -d drafts ] || [ -d sync/Obsidian ]; then
  marker_hit() {   # $1 = the string, $2 = what to call it
    local hits
    hits=$(git grep -I --cached -l -F "$1" -- . 2>/dev/null || true)
    # The example manifest is allowed to describe the format; it must not
    # contain a real one. Nothing else is exempt.
    [ -z "$hits" ] || err "$2 '$1' appears in staged content: $(echo "$hits" | tr '\n' ' ')"
  }
  for d in drafts/*/; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    case "$b" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*) marker_hit "$b" "draft bundle name" ;; esac
  done
  for f in sync/Obsidian/*.md sync/Obsidian/Archive/*.md; do
    [ -f "$f" ] || continue
    t=$(basename "$f" .md)
    [ "${#t}" -ge 12 ] || continue
    words=$(printf '%s\n' "$t" | wc -w)
    [ "$words" -ge 3 ] || continue
    marker_hit "$t" "note title"
  done
fi

if [ "$fail" -ne 0 ]; then
  echo 'Commit blocked: nothing personal may be committed (tests/check_privacy.sh).' >&2
  exit 1
fi
echo 'privacy check: OK'
