#!/usr/bin/env bash
# tests/check_sweep.sh — the guard on the alias sweep.
#
# alias_sweep is the backstop of the anonymization: candidates are aliased as
# they are written, but a person who enters the notes AFTER a post was written
# would still be sitting in the pool under their real name, and the sweep is
# what catches that on the next run.
#
# It is therefore a piece of safety code that does its work silently and, when
# it works, changes nothing — which means it can stop working entirely and look
# exactly the same from outside. It did: the arm refactor turned its loop into a
# `while read` without a redirect, so it took the script's stdin, found EOF and
# swept nothing, run after run, with no error and no log line.
#
# So this test does not check that the sweep CAN work. It plants a name that
# must be rewritten and fails if it is still there, which is the only claim
# worth making about it.
#
# No model call: --sweep-only stops before generation. Runs entirely in a
# sandbox root, so the live tree is never touched.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; shift; [ $# -eq 0 ] || printf '     %s\n' "$@"; }

R="$SB/root"
mkdir -p "$R/sync/Obsidian/Posts/Keep" "$R/sync/Obsidian/Posts/Discarded" \
         "$R/sync/Obsidian/Posts/Rejected" "$R/sync/Obsidian/Posts/armX" \
         "$R/drafts" "$R/logs" "$R/work" "$R/private"

# Invented names, and they must stay invented: tests/check_privacy.sh blocks any
# commit containing a name from the real map, so an example here can never be a
# real one.
printf 'Testperson Alpha\tZeta, Yara\n' > "$R/private/aliases.tsv"

post() {   # $1 path, $2 body
  { printf -- '---\nkind: short\ntitle: A test post\ncreated: 2026-01-15\n'
    printf 'arm: %s\nsources:\n  - sync/Obsidian/note.md\n---\n\n# A test post\n\n%s\n' "$2" "$3"
  } > "$1"
}
post "$R/sync/Obsidian/Posts/2026-01-15-short-in-the-base.md" base \
     'Testperson Alpha said the thing, and I wrote it down.'
post "$R/sync/Obsidian/Posts/armX/2026-01-15-armX-short-in-an-arm.md" armX \
     'Later that week Testperson Alpha said it again.'
post "$R/sync/Obsidian/Posts/Keep/2026-01-15-short-kept.md" base \
     'A kept post also mentions Testperson Alpha once.'
printf 'a note\n' > "$R/sync/Obsidian/note.md"

out="$(env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-base.env" BLOG_ROOT="$R" NOTIFY=/bin/true NAME_SCAN=0 TYPO_FIX=0 \
       bash bin/suggest.sh --sweep-only </dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || bad "the sweep run exits cleanly" "exit $rc" "$out"

# The claim: after a sweep, the real name is gone from every post that syncs —
# the base's pool, an ARM's pool, and Keep/ alike.
for f in "$R/sync/Obsidian/Posts/2026-01-15-short-in-the-base.md" \
         "$R/sync/Obsidian/Posts/armX/2026-01-15-armX-short-in-an-arm.md" \
         "$R/sync/Obsidian/Posts/Keep/2026-01-15-short-kept.md"; do
  where="$(basename "$(dirname "$f")")/$(basename "$f")"
  if grep -q 'Testperson Alpha' "$f" 2>/dev/null; then
    bad "the real name is swept from $where"
  else
    ok "the real name is swept from $where"
  fi
  if grep -qE 'Zeta|Yara' "$f" 2>/dev/null; then
    ok "an alias replaced it in $where"
  else
    bad "an alias replaced it in $where" "$(sed -n '/^# /,$p' "$f")"
  fi
done

# And it said so: a sweep that rewrites a post and logs nothing is a sweep whose
# next silent failure nobody notices.
case "$out" in
  *SWEEP*) ok "the sweep reports what it changed" ;;
  *)       bad "the sweep reports what it changed" "$out" ;;
esac

# The `sources:` block keeps real paths on purpose — they must resolve — so a
# sweep that rewrote them would break every post's provenance.
if grep -q 'sync/Obsidian/note.md' "$R/sync/Obsidian/Posts/2026-01-15-short-in-the-base.md"; then
  ok "the sources block is left alone"
else
  bad "the sources block is left alone"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
