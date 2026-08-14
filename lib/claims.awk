# lib/claims.awk — what one kept post has spent, read out of its provenance
# report.
#
#   awk -f lib/text.awk -f lib/claims.awk -v min=6 -v kind=long report.md
#
# Emits "<kind>\t<normalized sentence>" per claimed sentence. Called by
# build_claimed() in bin/suggest.sh, once per report, and the rule it serves —
# "one sentence, one post", per kind, per arm — is documented there.
#
# TWO KEYS PER TWEAKED SENTENCE, and that is the point of this file existing:
#
#   the classification line   what the POST says. A future candidate that
#                             reproduces this wording is caught by reuse_gate.
#   the `= source` line       what the NOTE says (lib/gate.awk emits it). This
#                             is the key that can actually be found in the
#                             corpus, so it is the one filter_claimed can punch
#                             a hole for, filter_to_corpus can keep, and
#                             reuse_gate can catch a VERBATIM re-use with.
#
# Before both were claimed, a kept post that trimmed a sentence's ends left the
# original sentence entirely free: no hole, no reuse FAIL, and a line the author
# had already published was legal material for the next post of the same kind.
# Claiming both can only ever spend more, never less — the one direction this
# rule is safe to move in (see bin/reclean.sh's header for why the other
# direction corrupts the ledger).
#
# Only VERBATIM/TWEAKED/REWORDED lines and their `= source` companions are read.
# A GLUE or NEW sentence is the model's and claims nothing; a `~ nearest` trace
# line is a similarity GUESS and must never become a claim (tests/check_gate.sh
# §4).
#
# REWORDED (the VOICE_REWRITE_MIN licence) is in that list on purpose, and it is
# the one case where the classification line's own text is nearly worthless as a
# key — it is the MODEL's wording, so no future candidate will reproduce it and
# no corpus hole can be punched for it. What earns its place here is the
# `= source` line beside it, which carries the spoken sentence it restates. That
# sentence has been spent: the post published that thought, in his voice, under
# his name. Leaving it claimable would let the next post publish it again.

function emit(t,   w) {
  t = blog_norm(t)
  if (t != "" && split(t, w, " ") >= min) printf "%s\t%s\n", kind, t
}

/^- (VERBATIM|TWEAKED|REWORDED) / {
  t = $0
  sub(/^- (VERBATIM|TWEAKED|REWORDED)[[:space:]]+\[[^]]*\][[:space:]]*/, "", t)
  emit(t)
  next
}

/^[[:space:]]+= source[[:space:]]+\[/ {
  t = $0
  sub(/^[[:space:]]+= source[[:space:]]+\[[^]]*\][[:space:]]*/, "", t)
  emit(t)
  next
}
