#!/usr/bin/env bash
# tests/check_gate.sh — the guard on the stitching gate's experiment seams.
#
# verbatim_gate is the pillar the whole pipeline stands on: posts are stitched
# from the author's sentences, and this is what refuses to take the model's word
# for it. The experiment layer added two knobs to it, and the requirement for
# both is the same — they may add information, they may not change the verdict
# arithmetic. So this asserts, with no model in the loop:
#
#   - the classification and the verdict are exactly what they were (a
#     regression here is a silently weakened gate);
#   - GATE_MODE=report never rejects, and says so in the summary line rather
#     than quietly passing;
#   - GATE_TRACE annotates only what it should, and only when asked;
#   - the annotation lines cannot be mistaken for classification lines by
#     build_claimed, which is what decides whether a sentence is spent.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SB="$(mktemp -d)"
LIB="$(mktemp "bin/.libtest.XXXXXX")"
trap 'rm -rf "$SB" "$LIB"' EXIT
sed 's/^main "\$@"$/:/' bin/suggest.sh > "$LIB"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; shift; [ $# -eq 0 ] || printf '     %s\n' "$@"; }

cat > "$SB/corpus.md" <<'EOF'

### NOTE id=sync/Obsidian/a.md

Estimation is hard when hardware is involved and nobody says so out loud. So I keep padding the numbers and hoping for the best.

### NOTE id=sync/Obsidian/b.md

The connector arrived three weeks late and the plan never recovered from it. Nobody wrote that down anywhere.
EOF

# One verbatim sentence, one near-rewrite of a corpus sentence, one invention.
cat > "$SB/body.md" <<'EOF'
Estimation is hard when hardware is involved and nobody says so out loud.
So I keep padding the estimates and hoping for the very best outcome here.
This is a sentence that exists nowhere in the corpus at all, invented wholesale by a model.
EOF

# A candidate that passes: two verbatim sentences and nothing else.
cat > "$SB/clean.md" <<'EOF'
Estimation is hard when hardware is involved and nobody says so out loud.
The connector arrived three weeks late and the plan never recovered from it.
EOF

# Run verbatim_gate under a given environment: the report on stdout, the
# verdict as the exit status — so a caller reads it as `rep="$(gate …)"; RC=$?`
# (the assignment has to happen outside, or the subshell swallows it).
RC=0
# BLOG_BASE_ENV points at nothing on purpose: profiles/base.env is a recorded
# change to what the base IS (written by `arm.sh promote`), and these assertions
# are about what the CODE does with its shipped defaults. Letting a promotion in
# would rewrite the expected thresholds under the test — which is the moment you
# most want the gate's arithmetic still being watched.
gate() {
  local body="$1"; shift
  env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-such-base.env" "$@" \
      bash -c 'source "$0" >/dev/null 2>&1; verbatim_gate "$1" "$2"' \
      "$LIB" "$body" "$SB/corpus.md"
}

# --- 1. the verdict arithmetic is untouched ------------------------------------
rep="$(gate "$SB/body.md")"; RC=$?
[ "$RC" -eq 1 ] && ok "enforce still rejects a rewritten candidate" \
                || bad "enforce still rejects a rewritten candidate" "exit $RC"
case "$rep" in
  *"gate: FAIL — 1 verbatim, 0 tweaked, 0 glue (max 1), 2 new (max 0) of 3 sentences"*)
    ok "the summary line is unchanged" ;;
  *) bad "the summary line is unchanged" "$(printf '%s' "$rep" | tail -1)" ;;
esac
rep="$(gate "$SB/clean.md")"; RC=$?
[ "$RC" -eq 0 ] && ok "enforce still passes a stitched candidate" \
                || bad "enforce still passes a stitched candidate" "exit $RC"

# Nothing is annotated unless annotation was asked for.
rep="$(gate "$SB/body.md")"; RC=$?
case "$rep" in
  *'~ nearest'*) bad "no annotation without GATE_TRACE" ;;
  *)             ok "no annotation without GATE_TRACE" ;;
esac

# --- 2. report mode classifies but never rejects --------------------------------
rep="$(gate "$SB/body.md" GATE_MODE=report)"; RC=$?
[ "$RC" -eq 0 ] && ok "report mode never rejects" || bad "report mode never rejects" "exit $RC"
case "$rep" in
  *'would have FAILED'*) ok "report mode says the verdict it withheld" ;;
  *) bad "report mode says the verdict it withheld" "$(printf '%s' "$rep" | tail -1)" ;;
esac
rep="$(gate "$SB/clean.md" GATE_MODE=report)"; RC=$?
case "$rep" in
  *'would have FAILED'*) bad "report mode does not cry wolf on a passing post" ;;
  *'[report mode: enforcement off]'*) ok "report mode does not cry wolf on a passing post" ;;
  *) bad "report mode does not cry wolf on a passing post" "$(printf '%s' "$rep" | tail -1)" ;;
esac
# Report mode implies tracing: the classification IS the result of the run.
rep="$(gate "$SB/body.md" GATE_MODE=report)"; RC=$?
case "$rep" in
  *'~ nearest'*) ok "report mode turns tracing on by itself" ;;
  *) bad "report mode turns tracing on by itself" ;;
esac

# --- 3. what tracing says -------------------------------------------------------
rep="$(gate "$SB/body.md" GATE_TRACE=1)"; RC=$?
[ "$RC" -eq 1 ] && ok "tracing does not change the verdict" || bad "tracing does not change the verdict" "exit $RC"
case "$rep" in
  *'[sync/Obsidian/a.md]'*'{+estimates+}'*)
    ok "a rewritten sentence names its source and shows the diff" ;;
  *) bad "a rewritten sentence names its source and shows the diff" "$rep" ;;
esac
case "$rep" in
  *"nothing in the corpus above 30%"*)
    ok "an invented sentence is reported as having no source" ;;
  *) bad "an invented sentence is reported as having no source" "$rep" ;;
esac
# A verbatim sentence is its own source: annotating it would be noise.
if [ "$(printf '%s\n' "$rep" | grep -c '~ nearest')" -eq 2 ]; then
  ok "verbatim sentences are not annotated"
else
  bad "verbatim sentences are not annotated" "$rep"
fi

# --- 4. the report stays machine-readable ---------------------------------------
# build_claimed decides which sentences are spent by reading VERBATIM/TWEAKED
# lines out of these reports. An annotation line that could be read as one would
# claim a sentence the author never kept.
if printf '%s\n' "$rep" | grep -E '^- (VERBATIM|TWEAKED) ' | grep -q 'nearest'; then
  bad "annotations cannot be read as classification lines"
else
  ok "annotations cannot be read as classification lines"
fi
# And the last line is still the verdict, which is what the caller logs.
case "$(printf '%s\n' "$rep" | tail -1)" in
  gate:*) ok "the verdict is still the last line" ;;
  *)      bad "the verdict is still the last line" "$(printf '%s\n' "$rep" | tail -1)" ;;
esac

# --- 4b. the dictation licence (VOICE_TWEAK_GAP) --------------------------------
# The one place the gate is allowed to treat the corpus's two mouths
# differently. A false start cut out of the MIDDLE of a sentence leaves a hole
# no end-trim can close, so without this the sentence grades NEW; with it, and
# only when the sentence is found in a dictated bundle, it grades TWEAKED.
#
# The asymmetry is the whole point, so it is asserted from both sides: the same
# edit, the same number of words, applied once to a spoken note and once to a
# typed one. If the typed case ever starts passing, the licence has leaked into
# material the author composed by hand and the arm is no longer testing what it
# says it tests.
#
# The hole has to sit in the REAL middle for these to test anything. Put a false
# start three words in and the existing end-trim path matches the sentence on
# its own — the licence is never consulted, and the test passes while asserting
# nothing. So both fixtures keep eight words in front of the hole and seven
# behind it, where no trim of three words from either end can reach.
cat > "$SB/mouths.md" <<'EOF'

### NOTE id=drafts/2026-08-13-spoken/cleaned.md

The whole delivery plan depends on one connector, well no I mean, arriving on time before the winter freeze.

### NOTE id=sync/Obsidian/typed.md

The whole budget forecast depends on one supplier, well no I mean, holding its price until the spring review.
EOF

# Each candidate is its note's sentence with the same four-word false start
# ("well no I mean,") cut out of the middle.
cat > "$SB/spoken-cut.md" <<'EOF'
The whole delivery plan depends on one connector, arriving on time before the winter freeze.
EOF
cat > "$SB/typed-cut.md" <<'EOF'
The whole budget forecast depends on one supplier, holding its price until the spring review.
EOF

mouth_gate() {
  local body="$1"; shift
  env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-such-base.env" "$@" \
      bash -c 'source "$0" >/dev/null 2>&1; verbatim_gate "$1" "$2"' \
      "$LIB" "$body" "$SB/mouths.md"
}

# Off by default: the excision is prose as far as the shipped gate is concerned.
rep="$(mouth_gate "$SB/spoken-cut.md")"
case "$rep" in
  *"- NEW "*) ok "an excision is NEW while the licence is off" ;;
  *)          bad "an excision is NEW while the licence is off" "$rep" ;;
esac
case "$rep" in
  *"middle of a dictated"*) bad "the default summary line gains no suffix" "$rep" ;;
  *)                        ok "the default summary line gains no suffix" ;;
esac

# On, and the spoken sentence is his again — attributed to the bundle it came
# out of, counted in the summary, and countable afterwards.
rep="$(mouth_gate "$SB/spoken-cut.md" VOICE_TWEAK_GAP=8)"
case "$rep" in
  *"- TWEAKED  [drafts/2026-08-13-spoken/cleaned.md]"*)
    ok "a cut inside a dictated sentence grades TWEAKED" ;;
  *) bad "a cut inside a dictated sentence grades TWEAKED" "$rep" ;;
esac
case "$rep" in
  *"[1 cut from the middle of a dictated sentence]"*)
    ok "the summary line counts what the licence bought" ;;
  *) bad "the summary line counts what the licence bought" "$(printf '%s' "$rep" | tail -1)" ;;
esac

# The same edit over a typed note gets nothing, at any gap.
rep="$(mouth_gate "$SB/typed-cut.md" VOICE_TWEAK_GAP=8)"
case "$rep" in
  *"- NEW "*) ok "the licence does not reach a typed note" ;;
  *)          bad "the licence does not reach a typed note" "$rep" ;;
esac
rep="$(mouth_gate "$SB/typed-cut.md" VOICE_TWEAK_GAP=99)"
case "$rep" in
  *"- NEW "*) ok "the licence does not reach a typed note at any gap" ;;
  *)          bad "the licence does not reach a typed note at any gap" "$rep" ;;
esac

# The cap is a cap: a hole wider than the budget is two thoughts welded
# together, not a false start, and it must still fail.
rep="$(mouth_gate "$SB/spoken-cut.md" VOICE_TWEAK_GAP=2)"
case "$rep" in
  *"- NEW "*) ok "a hole wider than the budget still fails" ;;
  *)          bad "a hole wider than the budget still fails" "$rep" ;;
esac

# A licensed sentence is a SPENT sentence: build_claimed reads TWEAKED lines to
# decide what a kept post has used up, and it must be able to read this one.
rep="$(mouth_gate "$SB/spoken-cut.md" VOICE_TWEAK_GAP=8)"
if printf '%s\n' "$rep" | grep -qE '^- TWEAKED[[:space:]]+\[[^]]*\][[:space:]]*The whole delivery'; then
  ok "an excised sentence is claimable by build_claimed"
else
  bad "an excised sentence is claimable by build_claimed" "$rep"
fi

# --- 5. report mode cannot reach the live tree ----------------------------------
# The knob that switches enforcement off is the one thing in this repo that can
# put model prose into the pool wearing the author's voice. It is refused
# outright against the live tree, and the refusal has to happen before anything
# is written — so this runs the real script and checks that nothing moved.
#
# No model in the loop either way: the live-tree run stops at the guard, and the
# sandbox run has an empty corpus (and CLAUDE_BIN=/bin/false, which turns any
# call that did happen into a failure rather than a charge).
out="$(env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-base.env" GATE_MODE=report bash bin/suggest.sh 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSING'; then
  ok "GATE_MODE=report is refused against the live tree"
else
  bad "GATE_MODE=report is refused against the live tree" "exit $rc" "$out"
fi
# It must refuse before the lock and before the scratch dir the run works in.
if [ -z "$(find work -maxdepth 1 -name 'sugg.*' -newermt '-20 seconds' 2>/dev/null)" ]; then
  ok "the refusal happens before any work is started"
else
  bad "the refusal happens before any work is started"
fi

mkdir -p "$SB/root/sync/Obsidian" "$SB/root/drafts" "$SB/root/logs" \
         "$SB/root/work" "$SB/root/private"
out="$(env -u BLOG_ARM BLOG_BASE_ENV="$SB/no-base.env" BLOG_ROOT="$SB/root" GATE_MODE=report CLAUDE_BIN=/bin/false NOTIFY=/bin/true \
       bash bin/suggest.sh 2>&1)"; rc=$?
if printf '%s' "$out" | grep -q 'REFUSING'; then
  bad "a sandboxed run may still use report mode" "$out"
else
  ok "a sandboxed run may still use report mode"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
