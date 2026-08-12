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
gate() {
  local body="$1"; shift
  env "$@" bash -c 'source "$0" >/dev/null 2>&1; verbatim_gate "$1" "$2"' \
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
