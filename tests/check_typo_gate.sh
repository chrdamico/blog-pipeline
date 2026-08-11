#!/usr/bin/env bash
# tests/check_typo_gate.sh — the guard on the one stage that edits raw input.
#
# bin/suggest.sh proofreads typed notes IN PLACE (typofix_notes). What keeps
# that safe is not the prompt — it is typo_gate, which reads the model's version
# of a note and refuses to pass anything that is not a respelled word, and
# typo_apply, which puts approved words back into the ORIGINAL file so nothing
# else can ride along. This exercises both with no model in the loop.
#
# No network and no Claude call: every case here is a hand-written "model
# output". Run it after touching typo_gate, typo_apply, or strip_fence.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

# Load the script's functions without running it: neutralise the final call.
sed 's/^main "\$@"$/:/' bin/suggest.sh > "$SB/lib.sh"
# shellcheck disable=SC1090,SC1091
source "$SB/lib.sh" 2>/dev/null || { echo "TYPO GATE FAIL: could not load bin/suggest.sh"; exit 1; }

pass=0; fail=0
# $1 name, $2 expected (OK:<subs> | OK:<subs>/skip:<n> | REJECT), $3 note, $4 model output
check() {
  local name="$1" want="$2" got out rc=0 n s
  printf '%s' "$3" > "$SB/o"; printf '%s' "$4" > "$SB/m"
  out="$(typo_gate "$SB/o" < "$SB/m")" || rc=$?
  if [ $rc -ne 0 ]; then
    got="REJECT"
  else
    n=$(printf '%s\n' "$out" | grep -c '^SUB'  || true)
    s=$(printf '%s\n' "$out" | grep -c '^SKIP' || true)
    got="OK:$n"; [ "$s" -gt 0 ] && got="OK:$n/skip:$s"
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf 'ok   %-46s %s\n' "$name" "$got"
  else
    fail=$((fail + 1)); printf 'FAIL %-46s want %s got %s\n' "$name" "$want" "$got"
    printf '     %s\n' "$out"
  fi
}

N="Do I really like reading wbe cause it's a stream of cobsciousness?
I think so. It feels honest and dont ask me why.
"

# --- what must get through ----------------------------------------------------
check "real typo fixed" "OK:1" "$N" \
"Do I really like reading wbe cause it's a stream of consciousness?
I think so. It feels honest and dont ask me why.
"
check "clean note, nothing to do" "OK:0" "$N" "$N"
check "trailing blank line differs" "OK:1" "$N" \
"Do I really like reading wbe cause it's a stream of consciousness?
I think so. It feels honest and dont ask me why."
check "live-run fixes (short note, cap 3)" "OK:3" \
"I saw my freinds and the stram of different voicea
" "I saw my friends and the stream of different voices
"
check "long-word fixes under the scaled cap" "OK:2" \
"it went Trough the whole stream of cobsciousness again
" "it went Through the whole stream of consciousness again
"
check "two real typos under the volume cap" "OK:2" \
"I saw my freinds and it was recieved well because everyone there was genuinely happy about the whole thing and nobody complained at all about anything really
" \
"I saw my friends and it was received well because everyone there was genuinely happy about the whole thing and nobody complained at all about anything really
"

# --- short words: declined, but the note still gets its real fixes ------------
check "acronym declined, note still fixed" "OK:1/skip:1" "$N" \
"Do I really like reading web cause it's a stream of consciousness?
I think so. It feels honest and dont ask me why.
"
check "short typo declined, nothing else to do" "OK:0/skip:1" \
"the version of me that I lke being
" "the version of me that I like being
"
check "deliberate lowercase i left alone" "OK:0/skip:1" \
"i went to the shop
" "I went to the shop
"

# --- what must never get through ----------------------------------------------
check "apostrophe supplied" "REJECT" "$N" \
"Do I really like reading wbe cause it's a stream of consciousness?
I think so. It feels honest and don't ask me why.
"
check "comma added" "REJECT" \
"I went to the shop and I left
" "I went to the shop, and I left
"
check "capitalization of a long word" "REJECT" \
"i think the internet is fine
" "i think the Internet is fine
"
check "line reflowed" "REJECT" "$N" \
"Do I really like reading wbe cause it's a stream of consciousness? I think so.
It feels honest and dont ask me why.
"
check "word inserted" "REJECT" "$N" \
"Do I really like reading wbe cause it is a stream of consciousness?
I think so. It feels honest and dont ask me why.
"
check "sentence improved (synonym)" "REJECT" "$N" \
"Do I really like reading wbe cause it's a stream of consciousness?
I believe so. It feels honest and dont ask me why.
"
check "different word entirely" "REJECT" \
"I felt like the king of the volleyball
" "I felt like the queen of the volleyball
"
# The pair this corpus can least afford to have drift: 4 letters, distance 2.
check "short word drift (like -> love)" "REJECT" \
"there is affection and I like her
" "there is affection and I love her
"
check "umlaut word is immune" "REJECT" \
"It was a schöne Wetter and I was tired
" "It was a schönes Wetter and I was tired
"
check "many fixes in a short note hit the volume cap" "REJECT" \
"teh freinds wnet ot the shopp and thne we lefft agian
" "the friends went to the shop and then we left again
"
check "commentary instead of a note" "REJECT" "$N" \
"Here is the corrected note:
Do I really like reading wbe cause it's a stream of consciousness?
"

# KNOWN LIMITATION, asserted so it stays visible: an ASCII German word declined
# differently is a distance-1 change between two plain words, indistinguishable
# from a typo without a dictionary. Only prompts/typos.md forbids it.
check "denglisch declension (prompt-only guard)" "OK:1" \
"the ganze Sache was strange
" "the ganzen Sache was strange
"

# --- typo_apply writes into the ORIGINAL, byte for byte -----------------------
printf '  indented cobsciousness here\ttab\n\nlast line\n\n\n' > "$SB/orig"
printf '  indented consciousness here\ttab\n\nlast line\n'     > "$SB/mod"
if typo_gate "$SB/orig" < "$SB/mod" > "$SB/subs"; then
  typo_apply "$SB/subs" "$SB/orig" > "$SB/final"
  printf '  indented consciousness here\ttab\n\nlast line\n\n\n' > "$SB/want"
  if cmp -s "$SB/final" "$SB/want"; then
    pass=$((pass + 1)); echo "ok   indentation, tabs and trailing blanks preserved"
  else
    fail=$((fail + 1)); echo "FAIL typo_apply changed more than the word:"
    diff <(cat -A "$SB/want") <(cat -A "$SB/final")
  fi
else
  fail=$((fail + 1)); echo "FAIL gate rejected the indented case: $(cat "$SB/subs")"
fi

# Same word twice on a line: only the approved position may change.
printf 'the stram and the stram again\n' > "$SB/orig2"
printf 'SUB\t1\t2\tstram\tstream\n'      > "$SB/subs2"
if [ "$(typo_apply "$SB/subs2" "$SB/orig2")" = "the stream and the stram again" ]; then
  pass=$((pass + 1)); echo "ok   substitution is position-exact"
else
  fail=$((fail + 1)); echo "FAIL substitution hit the wrong occurrence: $(typo_apply "$SB/subs2" "$SB/orig2")"
fi

# --- strip_fence --------------------------------------------------------------
printf '```\nhello there\n```\n' > "$SB/f"
if [ "$(strip_fence "$SB/f")" = "hello there" ]; then
  pass=$((pass + 1)); echo "ok   code fence unwrapped"
else
  fail=$((fail + 1)); echo "FAIL code fence not unwrapped"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
