# lib/filter_to_corpus.awk — the claims worth telling the model about.
#
#   awk -f lib/text.awk -f lib/filter_to_corpus.awk -v listf=<claims> corpus.md
#
# Keeps only the sentences from listf that actually occur in this run's corpus. A
# claim whose source notes were not sampled this run cannot be stitched verbatim
# anyway, so listing it in the generation stream is pure token waste — and Keep/
# only ever grows, so without this trim the RESERVED SENTENCES section grows
# without bound while everything else in the stream is budgeted.
#
# Prompt-only: reuse_gate still enforces the FULL claim lists afterwards, so a
# claim dropped here is still spent.
#
# When this drops a lot, read it as a warning rather than as housekeeping: a
# claim that cannot be found in a corpus which omitted nothing is a claim whose
# key has drifted away from the text it was written from (see lib/gate.awk's
# `= source` note). bin/suggest.sh logs the count for exactly that reason.
{ text = text " " $0 }
END {
  text = blog_norm(text)
  while ((getline l < listf) > 0) if (index(text, l)) print l
  close(listf)
}
