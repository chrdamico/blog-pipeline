#!/usr/bin/env bash
# tests/check_claims.sh — the guard on "one sentence, one post".
#
# A kept post spends its sentences. The ledger for that is the provenance report,
# and the key is the sentence's normalized TEXT — which means the rule fails the
# moment the text on the post's side stops matching the text on the corpus side.
# It fails silently, it fails open, and what it lets through is the one outcome
# the pipeline exists to prevent: publishing a line the author already published.
#
# It had been failing that way. verbatim_gate records the CANDIDATE's wording on
# a TWEAKED line, and a tweak is by definition a sentence that does NOT occur in
# the corpus — trimming its ends is what made it a tweak. So every TWEAKED claim
# was inert: no corpus hole, nothing in the RESERVED SENTENCES section, and no
# reuse FAIL unless a later candidate reproduced the identical trim. Measured on
# the live tree on 2026-08-14: 10 of 87 claims from Keep/ posts, and the daily log
# reported them as a corpus-sampling artifact while the corpus sat at 44% of its
# budget and omitted nothing.
#
# The fix is that a tweak claims TWICE — the post's wording and the note sentence
# it was cut down from (lib/gate.awk's `= source` line, read by lib/claims.awk).
# So this asserts the property that was missing rather than the mechanism:
#
#   a sentence a kept post TRIMMED cannot be republished untrimmed.
#
# No model call: every stage under test here is awk over fixtures.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SB="$(mktemp -d)"
LIB="$(mktemp "bin/.libtest.XXXXXX")"
trap 'rm -rf "$SB" "$LIB"' EXIT
sed 's/^main "\$@"$/:/' bin/suggest.sh > "$LIB"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; shift; [ $# -eq 0 ] || printf '     %s\n' "$@"; }

# BLOG_BASE_ENV points at nothing: these assertions are about what the CODE does
# with its shipped defaults, and a promotion must not move them (same reason
# tests/check_gate.sh does it).
lib() {   # lib <function> [args...] — call into suggest.sh's innards
  env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-such-base.env" \
      bash -c 'source "$0" >/dev/null 2>&1; "$@"' "$LIB" "$@"
}

cat > "$SB/corpus.md" <<'EOF'

### NOTE id=sync/Obsidian/a.md

Honestly I think the whole idea of estimating hardware is a polite fiction we all agree to keep, you know.

### NOTE id=sync/Obsidian/b.md

The connector arrived three weeks late and the plan never recovered from it.
EOF

# What a kept post did: took that first sentence and trimmed the spoken run-up
# ("Honestly I think") and the trailing tag ("you know") off it.
cat > "$SB/kept.body.md" <<'EOF'
The whole idea of estimating hardware is a polite fiction we all agree to keep.
The connector arrived three weeks late and the plan never recovered from it.
EOF

lib verbatim_gate "$SB/kept.body.md" "$SB/corpus.md" > "$SB/kept.prov.md"

# --- 1. the gate names the sentence it matched -----------------------------------
if grep -q '^  = source ' "$SB/kept.prov.md"; then
  ok "a TWEAKED sentence records the note sentence it came from"
else
  bad "a TWEAKED sentence records the note sentence it came from" "$(cat "$SB/kept.prov.md")"
fi
# The whole point of the second key: unlike the post's wording, it is findable.
src="$(sed -n 's/^  = source[[:space:]]*\[[^]]*\][[:space:]]*//p' "$SB/kept.prov.md" | head -1)"
if [ -n "$src" ] && awk -f lib/text.awk -v s="$src" '
      { t = t " " $0 } END { exit index(blog_norm(t), s) ? 0 : 1 }' "$SB/corpus.md"; then
  ok "the recorded source sentence is present in the corpus"
else
  bad "the recorded source sentence is present in the corpus" "$src"
fi
# And a VERBATIM line needs no such companion — it IS the corpus text.
if [ "$(grep -c '^  = source ' "$SB/kept.prov.md")" -eq 1 ]; then
  ok "only the tweak gets a source line"
else
  bad "only the tweak gets a source line" "$(cat "$SB/kept.prov.md")"
fi

# --- 2. the report stays machine-readable ---------------------------------------
# Same requirement tests/check_gate.sh §4 puts on the trace annotation: an
# indented line must never be mistaken for a classification line, or it would
# claim a sentence the author never kept.
if grep -E '^- (VERBATIM|TWEAKED) ' "$SB/kept.prov.md" | grep -q '= source'; then
  bad "a source line cannot be read as a classification line"
else
  ok "a source line cannot be read as a classification line"
fi
case "$(tail -1 "$SB/kept.prov.md")" in
  gate:*) ok "the verdict is still the last line" ;;
  *)      bad "the verdict is still the last line" "$(tail -1 "$SB/kept.prov.md")" ;;
esac

# --- 3. both keys are claimed ----------------------------------------------------
awk -f lib/text.awk -f lib/claims.awk -v min=6 -v kind=long "$SB/kept.prov.md" \
  | cut -f2 > "$SB/claims"
n="$(wc -l < "$SB/claims" | tr -d ' ')"
[ "$n" -eq 3 ] && ok "the tweak claims two keys, the verbatim one" \
               || bad "the tweak claims two keys, the verbatim one" "$n claim(s): $(cat "$SB/claims")"
if grep -qi 'honestly i think' "$SB/claims"; then
  ok "the note's own wording is among the claims"
else
  bad "the note's own wording is among the claims" "$(cat "$SB/claims")"
fi
# Short sentences are never claimed, whichever side they come from.
awk -f lib/text.awk -f lib/claims.awk -v min=99 -v kind=long "$SB/kept.prov.md" > "$SB/none"
[ ! -s "$SB/none" ] && ok "REUSE_MIN_WORDS still applies to both keys" \
                    || bad "REUSE_MIN_WORDS still applies to both keys" "$(cat "$SB/none")"

# --- 4. THE PROPERTY: the untrimmed sentence can no longer be republished --------
# A new candidate of the same kind quotes the note sentence in full — exactly what
# the trimmed keeper made legal before, because the claim key was the trim.
cat > "$SB/new.body.md" <<'EOF'
Honestly I think the whole idea of estimating hardware is a polite fiction we all agree to keep, you know.
Something else entirely that no post has ever used before now.
EOF
out="$(lib reuse_gate "$SB/new.body.md" "$SB/claims" long)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^- REUSED'; then
  ok "republishing the untrimmed sentence now FAILS the reuse gate"
else
  bad "republishing the untrimmed sentence now FAILS the reuse gate" "exit $rc" "$out"
fi
# The trimmed wording is still caught too — that half was never broken.
out="$(lib reuse_gate "$SB/kept.body.md" "$SB/claims" long)"; rc=$?
[ "$rc" -ne 0 ] && ok "republishing the trimmed wording still FAILS" \
               || bad "republishing the trimmed wording still FAILS" "exit $rc"
# And an unrelated candidate still passes: this must damp repetition, not
# everything.
cat > "$SB/fresh.md" <<'EOF'
A sentence about something completely different that appears in no note at all.
EOF
out="$(lib reuse_gate "$SB/fresh.md" "$SB/claims" long)"; rc=$?
[ "$rc" -eq 0 ] && ok "an unrelated candidate still passes the reuse gate" \
               || bad "an unrelated candidate still passes the reuse gate" "$out"

# --- 5. the corpus hole can now be punched --------------------------------------
# When both kinds have claimed a sentence it is hidden from the corpus outright.
# With only the trim as a key that was impossible: the key was not in the corpus,
# so there was nothing to match and the material stayed on offer.
#
# Only the tweak's source key is put on the hide list here, so the second note is
# the control: hiding has to be per SENTENCE, or a single spent line would take a
# whole note out of the corpus with it.
grep -i 'honestly i think' "$SB/claims" > "$SB/one.claim"
hole="$(lib filter_claimed "$SB/corpus.md" "$SB/one.claim")"
case "$hole" in
  *'[…]'*) ok "a claimed sentence can be hidden from the corpus" ;;
  *)       bad "a claimed sentence can be hidden from the corpus" "$hole" ;;
esac
case "$hole" in
  *'Honestly I think'*) bad "the spent sentence is gone from the corpus" "$hole" ;;
  *)                    ok "the spent sentence is gone from the corpus" ;;
esac
case "$hole" in
  *'connector arrived three weeks late'*) ok "hiding is per sentence, not per note" ;;
  *) bad "hiding is per sentence, not per note" "$hole" ;;
esac

# --- 6. and the model is told about it -------------------------------------------
# filter_to_corpus trims the RESERVED SENTENCES section to claims that are
# actually in this run's corpus. The trim-shaped key never survived that filter,
# which is the log line that read as housekeeping while it was really a leak.
kept="$(lib filter_to_corpus "$SB/claims" "$SB/corpus.md")"
if printf '%s' "$kept" | grep -qi 'honestly i think'; then
  ok "the claim survives the corpus trim, so the model is told"
else
  bad "the claim survives the corpus trim, so the model is told" "$kept"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
