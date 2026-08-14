# lib/text.awk — the text primitives every stage has to agree on, exactly once.
#
# Included ahead of the program that needs it:
#
#   awk -f lib/text.awk -f lib/gate.awk -v min_pct=85 corpus.md body.md
#
# (Several -f files are concatenated into one program by any POSIX awk, and
# functions from the earlier file are visible in the later one. No gawk
# extension, no temp files, no shell quoting to get wrong.)
#
# WHY THIS IS A FILE. blog_norm below used to exist in five copies, pasted into
# five awk programs inside bin/suggest.sh, under a comment saying the copies
# "MUST stay identical" — an invariant enforced by nothing but the reader's
# attention. It is not a stylistic invariant. A sentence's claim key (see
# lib/claims.awk) is its normalized text, and the corpus side of that comparison
# is normalized by a different copy of the same function: the moment two copies
# disagree about one character, every claim silently stops matching, no error is
# raised, and a sentence already published becomes free to publish twice. The
# sentence splitter had the same problem and had ALREADY drifted — the gate's
# trace index split on /[.!?] / while everything else split on
# /[.!?][[:space:]]+/.
#
# So: one definition, one file, and the drift class is gone rather than
# documented.

# The normalization every comparison in the pipeline happens through. Curly
# quotes are folded (the phone's keyboard produces them, the transcript does
# not), whitespace is collapsed, the ends are trimmed, and the result is
# lowercased. Idempotent, so normalizing an already-normalized string is safe.
function blog_norm(s) {
  gsub(/[\342\200\230\342\200\231]/, "\x27", s)   # curly apostrophes
  gsub(/[\342\200\234\342\200\235]/, "\"", s)     # curly double quotes
  gsub(/[[:space:]]+/, " ", s)
  sub(/^ +/, "", s); sub(/ +$/, "", s)
  return tolower(s)
}

# Split s into sentences, filling parts[1..n] and returning n. A boundary is a
# terminator followed by whitespace, and the terminator stays with the sentence
# it ends.
#
# Callers that need to REBUILD the text from the pieces (lib/filter_claimed.awk
# rewrites a corpus line with holes punched in it) can concatenate parts[] back
# together and get the original bytes, because nothing is dropped here — the
# split is on a zero-width position after the terminator's trailing space.
function blog_split_sentences(s, parts) {
  gsub(/[.!?][[:space:]]+/, "&\n", s)
  return split(s, parts, "\n")
}

# The whole sentence of note text t that contains span, or span itself when it
# cannot be located. t is expected to be blog_norm'ed, so a boundary is a
# terminator followed by a space or by the end of the text.
#
# This is what turns a partial match into a claimable key: the gate matches a
# candidate sentence against a SUBSTRING of a note, and it is the note's whole
# sentence that has now been spent — see lib/gate.awk's `= source` line.
function blog_enclosing_sentence(t, span,   p, before, after) {
  p = index(t, span)
  if (!p) return span
  before = substr(t, 1, p - 1)
  after  = substr(t, p + length(span))
  # Walk back to just past the LAST terminator before the span: each pass drops
  # everything up to and including the first one that is left.
  while (match(before, /[.!?][[:space:]]+/) > 0)
    before = substr(before, RSTART + RLENGTH)
  # Forward to the first terminator after the span, inclusive. The trailing
  # (space|end) keeps a decimal point or an abbreviation from ending it early.
  if (match(after, /[.!?]([[:space:]]|$)/) > 0)
    after = substr(after, 1, RSTART)
  span = before span after
  sub(/^[[:space:]]+/, "", span); sub(/[[:space:]]+$/, "", span)
  return span
}
