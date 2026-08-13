#!/usr/bin/env bash
# tests/check_provenance.sh — the guard on lib/provenance.sh.
#
# Provenance is the load-bearing half of the experiment layer: an artifact that
# does not say what produced it cannot be compared with anything afterwards, and
# — worse — a MALFORMED record is not a gap you notice. It is a meta.json that
# reads fine until something parses it, months after the run it described.
#
# So this asserts the two properties that matter and are easy to lose:
#
#   1. meta.json is valid JSON for every input the pipeline can actually hand it,
#      including the degenerate ones (an empty transcript, a recording whose
#      filename contains a quote);
#   2. the facts that belong to the RECORDING rather than to the run — its
#      content hash, the day the bundle first appeared — survive a reclean,
#      which rewrites everything else in the file.
#
# No network, no Claude call, no writes outside a scratch dir.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; shift; [ $# -eq 0 ] || printf '     %s\n' "$@"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want: $2" "got:  $3"; fi; }

# Run a snippet with both libraries loaded, in a sandbox root so nothing here
# can append to the live ledgers.
prov() { env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-base.env" BLOG_ROOT="$SB" bash -c '. lib/config.sh; . lib/provenance.sh; '"$1"; }

# meta.json through a real JSON parser. Without python3 the file is only checked
# for balance, which is weaker but still catches the failure this test was
# written for (a bare "0\n0" where a number belongs).
json_ok() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>&1
  else
    grep -q '^}$' "$1" || printf 'no closing brace'
  fi
}
json_get() {   # $1 file, $2 dotted path
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d.get(k, "")
print(d)' "$1" "$2" 2>/dev/null
}

# --- 1. prov_words ---------------------------------------------------------------
# grep -c prints its zero AND exits 1 when nothing matched, so the obvious
# `... | grep -c … || printf 0` emits TWO zeros. That string reached meta.json as
# invalid JSON and prov_churn as an arithmetic syntax error, and an empty
# transcript is not hypothetical: process.sh's own guard is `[ -s ]`, which a
# whitespace-only file passes.
: > "$SB/empty.md"
printf '   \n\t\n  \n' > "$SB/blank.md"
printf 'one two three\nfour\n'  > "$SB/three.md"
eq "no words in an empty file"           0 "$(prov 'prov_words '"$SB"'/empty.md')"
eq "no words in a whitespace-only file"  0 "$(prov 'prov_words '"$SB"'/blank.md')"
eq "no words in a file that isn't there" 0 "$(prov 'prov_words '"$SB"'/nope.md')"
eq "words are counted"                   4 "$(prov 'prov_words '"$SB"'/three.md')"

# --- 2. churn --------------------------------------------------------------------
# The number that answers "did the looser prompt actually rewrite more?".
eq "identical files have no churn" 0 \
   "$(prov 'prov_churn '"$SB"'/three.md '"$SB"'/three.md')"
eq "two empty files have no churn" 0 \
   "$(prov 'prov_churn '"$SB"'/empty.md '"$SB"'/empty.md')"
printf 'one two three\nfive\n' > "$SB/three2.md"
if [ "$(prov 'prov_churn '"$SB"'/three.md '"$SB"'/three2.md')" -gt 0 ]; then
  ok "a changed word shows up as churn"
else
  bad "a changed word shows up as churn"
fi

# --- 3. meta.json is valid JSON, including for degenerate bundles ----------------
mkdir -p "$SB/b1"
: > "$SB/b1/verbatim.md"; : > "$SB/b1/cleaned.md"
printf 'audio' > "$SB/b1/rec.m4a"
prov 'prov_write_meta '"$SB"'/b1 process '"$SB"'/b1/rec.m4a deadbeef \
      '"$SB"'/b1/verbatim.md '"$SB"'/b1/cleaned.md 10 5 1' >/dev/null
out="$(json_ok "$SB/b1/meta.json")"
if [ -z "$out" ]; then ok "an empty transcript still yields valid JSON"
else bad "an empty transcript still yields valid JSON" "$out"; fi

# A recording is named by whatever the phone's recorder decided to call it, and
# nothing downstream sanitises it before it reaches this file.
mkdir -p "$SB/b2"
printf 'x' > "$SB/b2/verbatim.md"; printf 'x' > "$SB/b2/cleaned.md"
odd='say "hi" \ now.m4a'
printf 'audio' > "$SB/b2/$odd"
prov 'prov_write_meta '"$SB"'/b2 process "'"$SB"'/b2/'"$odd"'" deadbeef \
      '"$SB"'/b2/verbatim.md '"$SB"'/b2/cleaned.md 10 5 1' >/dev/null
out="$(json_ok "$SB/b2/meta.json")"
if [ -z "$out" ]; then ok "a quoted, backslashed filename is escaped"
else bad "a quoted, backslashed filename is escaped" "$out"; fi

# --- 4. what a reclean must NOT throw away ---------------------------------------
# bin/reclean.sh rewrites cleaned.md, so the record it leaves describes today's
# configuration — correctly. But the recording's content hash is the only join
# key back to logs/processed.tsv, and first_seen is the bundle's own age; both
# are facts about the recording, not about the last time a prompt changed.
if command -v python3 >/dev/null 2>&1; then
  first="$(json_get "$SB/b1/meta.json" first_seen)"
  sleep 1
  prov 'prov_write_meta '"$SB"'/b1 reclean "" "" \
        '"$SB"'/b1/verbatim.md '"$SB"'/b1/cleaned.md 10 5 1' >/dev/null
  eq "a reclean inherits the audio filename"  rec.m4a  "$(json_get "$SB/b1/meta.json" input.audio)"
  eq "a reclean inherits the audio hash"      deadbeef "$(json_get "$SB/b1/meta.json" input.audio_sha256)"
  eq "a reclean keeps the bundle's first_seen" "$first" "$(json_get "$SB/b1/meta.json" first_seen)"
  eq "a reclean says which stage wrote it"    reclean  "$(json_get "$SB/b1/meta.json" stage)"

  # And when the configuration really did change, the one it replaced is named —
  # cleaned.orig.md still holds the text that variant produced, so the record of
  # it should not vanish.
  env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-base.env" BLOG_ROOT="$SB" BLOG_VARIANT=loosened MAX_NEW=3 bash -c \
    '. lib/config.sh; . lib/provenance.sh
     prov_write_meta '"$SB"'/b1 reclean "" "" '"$SB"'/b1/verbatim.md '"$SB"'/b1/cleaned.md 10 5 1' >/dev/null
  case "$(json_get "$SB/b1/meta.json" replaced_variant)" in
    default:*) ok "a changed variant records the one it replaced" ;;
    *) bad "a changed variant records the one it replaced" \
           "$(json_get "$SB/b1/meta.json" replaced_variant)" ;;
  esac
else
  printf 'skip python3 absent — reclean-inheritance assertions not run\n'
fi

# --- 5. the stamps the scorer reads ------------------------------------------------
# bin/score.sh groups by these three keys; a post that carries only some of them
# is a post that silently leaves its variant's column.
fm="$(prov 'prov_frontmatter spare')"
for k in variant persona run; do
  if printf '%s\n' "$fm" | grep -q "^$k: "; then ok "frontmatter carries $k"
  else bad "frontmatter carries $k" "$fm"; fi
done
eq "the persona is the one passed in" "persona: spare" \
   "$(printf '%s\n' "$fm" | grep '^persona: ')"

# The central index: one row, seven tab-separated columns, path relative to the
# root so it still means something after the tree moves.
prov 'prov_record candidate '"$SB"'/sync/Obsidian/Posts/x.md spare corpus:abc' >/dev/null
row="$(tail -1 "$SB/logs/provenance.tsv" 2>/dev/null)"
eq "the ledger row has seven columns" 7 "$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
eq "the ledger stores a root-relative path" "sync/Obsidian/Posts/x.md" \
   "$(printf '%s' "$row" | cut -f4)"
eq "the ledger stores the persona" "spare" "$(printf '%s' "$row" | cut -f6)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
