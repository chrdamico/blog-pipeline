#!/usr/bin/env bash
# tests/check_brief.sh — the guard on the one page that explains the rest.
#
# bin/brief.sh is read instead of the code, on a phone, to answer "what is
# running tonight". That makes two things load-bearing, and neither is visible
# from reading its output:
#
#   IT MUST NOT ENTER THE CORPUS. It lives in the vault so the phone can see it,
#   and everything else in the vault is material the curator stitches posts out
#   of. A page describing the pipeline, sampled into the corpus, would come back
#   as a post quoting the pipeline's own documentation in the author's voice. The
#   protection is that it sits in a SUBFOLDER and every corpus glob is
#   non-recursive — which is exactly the kind of invariant someone breaks later by
#   adding one -maxdepth 2. So this asserts it end to end, from a real run.
#
#   IT MUST NOT GO QUIETLY OUT OF DATE. Its values come from lib/config.sh, but
#   the English is local, so a knob added tomorrow appears in the fingerprint,
#   changes what the pipeline does, and is simply absent from the page that claims
#   to describe it. So every fingerprint key has to be listed for printing.
#
# No model call, no writes outside a sandbox.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SB="$(mktemp -d)"
LIB="$(mktemp "bin/.libtest.XXXXXX")"
trap 'rm -rf "$SB" "$LIB"' EXIT
sed 's/^main "\$@"$/:/' bin/suggest.sh > "$LIB"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; shift; [ $# -eq 0 ] || printf '     %s\n' "$@"; }

# --- 1. every knob that defines a variant is explained ---------------------------
missing=""
for k in $(env -u BLOG_ARM bash -c '. lib/config.sh >/dev/null 2>&1; printf "%s\n" $BLOG_FINGERPRINT_KEYS'); do
  grep -qE "(^|[[:space:]])$k([[:space:]]|$)" <(sed -n '/^BRIEF_ORDER="/,/^"/p' bin/brief.sh) \
    || missing="${missing:+$missing }$k"
done
if [ -z "$missing" ]; then
  ok "every fingerprint knob is listed for printing"
else
  bad "every fingerprint knob is listed for printing" \
      "not in BRIEF_ORDER: $missing" \
      "add it there and give it a sentence in say_knob, or the page describes a pipeline it isn't"
fi

# And each one's value actually reaches the page. Commas are stripped from the
# page first: it prints 150,000 where the dump says 150000, which is the page
# being readable rather than the page being wrong.
#
# The knobs skipped here are the ones whose sentence is a WORDING rather than a
# number ("failing candidates are refused" for GATE_MODE=enforce), so grepping
# for the raw value proves nothing about them.
page_flat="$(bin/brief.sh 2>/dev/null | tr -d ,)"
silent=""
for k in $(env -u BLOG_ARM bash -c '. lib/config.sh >/dev/null 2>&1; printf "%s\n" $BLOG_FINGERPRINT_KEYS'); do
  case "$k" in
    STRUCTURE|GATE_TRACE|GATE_MODE|NAME_SCAN|TYPO_FIX|WHISPER_MARKS) continue ;;
    CLEANUP_MODEL|CURATE_MODEL|TYPO_MODEL|WHISPER_LANG) continue ;;
    VOICE_TWEAK_GAP|VOICE_REWRITE_MIN|VERBATIM_MIN) continue ;;
  esac
  v="$(env -u BLOG_ARM bash lib/config.sh dump | sed -n "s/^$k=//p")"
  [ -n "$v" ] || continue
  printf '%s' "$page_flat" | grep -qF "$v" || silent="${silent:+$silent }$k"
done
if [ -z "$silent" ]; then
  ok "every numeric knob's value reaches the page"
else
  bad "every numeric knob's value reaches the page" "not printed: $silent"
fi

# --- 2. the page cannot become corpus material ----------------------------------
R="$SB/root"
mkdir -p "$R/sync/Obsidian" "$R/drafts" "$R/logs" "$R/work" "$R/private"
: > "$R/private/aliases.tsv"
printf 'A note about estimating hardware.\n' > "$R/sync/Obsidian/a.md"
printf 'A note about the two week rule.\n'   > "$R/sync/Obsidian/b.md"

out="$(env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-base.env" BLOG_ROOT="$R" \
       bash bin/brief.sh --write 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$R/sync/Obsidian/Pipeline/RUNNING.md" ]; then
  ok "--write lands the page in the vault"
else
  bad "--write lands the page in the vault" "exit $rc" "$out"
fi
# The root is where the corpus is read from; the page must not be there.
if [ -n "$(find "$R/sync/Obsidian" -maxdepth 1 -name 'RUNNING.md' 2>/dev/null)" ]; then
  bad "the page is not at the vault root" "it would be sampled into the corpus"
else
  ok "the page is not at the vault root"
fi

# The real assertion: ask the pipeline itself what its corpus is.
corpus="$(env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-base.env" BLOG_ROOT="$R" \
          bash -c 'source "$0" >/dev/null 2>&1; corpus_files' "$LIB" | cut -f2)"
if printf '%s\n' "$corpus" | grep -q 'RUNNING.md'; then
  bad "the corpus does not contain the page" \
      "corpus_files picked it up — the pipeline would write posts out of its own documentation" \
      "$corpus"
else
  ok "the corpus does not contain the page"
fi
# Nor may the typo pass rewrite it, or the archiver move it.
if [ -n "$(find "$R/sync/Obsidian" -maxdepth 1 -type f -name '*.md' | grep -c 'RUNNING' | grep -v '^0$')" ]; then
  bad "the archiver cannot reach the page"
else
  ok "the archiver cannot reach the page"
fi

# --- 3. it describes the arms, not just the base --------------------------------
page="$(bin/brief.sh 2>/dev/null)"
for a in $(env -u BLOG_ARM bash -c '. lib/config.sh >/dev/null 2>&1; blog_active_arms'); do
  if printf '%s' "$page" | grep -q "^### $a$"; then
    ok "the page names the active arm '$a'"
  else
    bad "the page names the active arm '$a'"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
