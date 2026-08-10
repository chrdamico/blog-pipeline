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
#      private/ models/ vendor/, plus style-anchor.md and PLAN.md)
#   2. no audio file may be tracked, anywhere in the tree
#   3. .gitignore must still contain every guarding pattern — this catches the
#      failure mode where the guard itself is weakened
#   4. no staged text may contain a private marker: a work email address, or a
#      real name listed in private/aliases.tsv (read at run time so no name is
#      ever embedded in this script; silently skipped where the file is absent)
set -u
cd "$(git rev-parse --show-toplevel)"
fail=0
err() { printf 'PRIVACY FAIL: %s\n' "$*" >&2; fail=1; }

# 1. private paths must never be tracked
bad=$(git ls-files -- 'sync/' 'drafts/' 'logs/' 'work/' 'private/' 'models/' \
                      'vendor/' 'prompts/style-anchor.md' 'PLAN.md')
[ -z "$bad" ] || err "tracked file(s) in a private path:
$bad"

# 2. no audio, anywhere
bad=$(git ls-files | grep -iE '\.(wav|m4a|mp3|opus|ogg|flac|aac|wma)$' || true)
[ -z "$bad" ] || err "audio file(s) tracked:
$bad"

# 3. the guard itself must stay intact
for pat in 'sync/' 'drafts/' 'logs/' 'work/' 'private/' 'models/' \
           'prompts/style-anchor.md' 'PLAN.md' '*.wav' '*.m4a' '*.mp3' \
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

if [ "$fail" -ne 0 ]; then
  echo 'Commit blocked: nothing personal may be committed (tests/check_privacy.sh).' >&2
  exit 1
fi
echo 'privacy check: OK'
