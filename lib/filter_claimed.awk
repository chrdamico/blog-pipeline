# lib/filter_claimed.awk — a note, with its spent sentences replaced by […].
#
#   awk -f lib/text.awk -f lib/filter_claimed.awk -v claimedf=<file> note.md
#
# claimedf holds one normalized sentence per line (the .hidden list built by
# build_claimed: claimed by BOTH kinds, dice already rolled). A hole is visible
# on purpose — the model stitches around it instead of bridging it with prose of
# its own, and if it reproduces one from memory the gate reads that as NEW and
# sinks the candidate, so no extra rule is needed here.
#
# Markdown decorations are stripped before the comparison but kept in the output:
# the corpus keeps looking like the note, minus the sentences that are spent.
BEGIN {
  while ((getline l < claimedf) > 0) claimed[l] = 1
  close(claimedf)
}
{
  n = blog_split_sentences($0, units)
  out = ""
  for (i = 1; i <= n; i++) {
    u = units[i]
    c = u
    sub(/^[[:space:]]*(#+|[-*>]|[0-9]+\.)[[:space:]]+/, "", c)
    c = blog_norm(c)
    if (c in claimed) out = out "[…] "
    else out = out u
  }
  print out
}
