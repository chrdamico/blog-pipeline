# lib/reuse_gate.awk — the kind-scoped half of "one sentence, one post".
#
#   awk -f lib/text.awk -f lib/reuse_gate.awk -v listf=<claims> -v kind=long body.md
#
# The candidate body must not contain a sentence already carrying a live post of
# its OWN kind. Runs after the stitching gate, which cannot catch these: a claim
# held by only one kind is deliberately left VISIBLE in the corpus (it is legal
# material for the other kind), so it classifies as VERBATIM and passes.
#
# Prints REUSED lines and a "gate:" verdict on failure; prints nothing and exits
# 0 on a pass.
BEGIN {
  while ((getline l < listf) > 0) claimed[l] = 1
  close(listf)
}
{
  line = $0
  sub(/^[[:space:]]*(#+|[-*>]|[0-9]+\.)[[:space:]]+/, "", line)
  body = body " " line
}
END {
  n = blog_split_sentences(body, sents)
  for (i = 1; i <= n; i++) {
    s = blog_norm(sents[i])
    if (!(s in claimed)) continue
    hits++
    d = sents[i]; gsub(/[[:space:]]+/, " ", d); sub(/^ /, "", d)
    printf "- REUSED   %s\n", d
  }
  if (hits) printf "\ngate: FAIL — %d sentence(s) already carrying a live %s post\n", hits, kind
  exit hits ? 1 : 0
}
