# lib/gate.awk — the stitching gate: every sentence of a candidate post, judged
# against the corpus it was supposed to be assembled from.
#
#   awk -f lib/text.awk -f lib/gate.awk \
#       -v min_pct=… -v glue_max=… -v new_every=… -v mode=… -v trace=… -v v_gap=… \
#       corpus.md body.md
#
# corpus.md carries "### NOTE id=<path>" markers; body.md is the candidate's
# body. The per-sentence report goes to stdout and the exit status IS the
# verdict. Called by verbatim_gate() in bin/suggest.sh, which is where the
# policy behind every knob is written down; this file is the mechanism.
#
# The classification:
#
#   VERBATIM  found character-for-character in one of the notes
#   TWEAKED   found after trimming up to 3 words off either end (a seam trim),
#             or — with v_gap > 0 and only in a DICTATED note — after cutting one
#             short hole out of the middle
#   GLUE      not found, but short enough to be a connective the prompt allows
#   NEW       not found and too long to be glue — the model wrote prose
#
# Two lines can appear indented under a classification line, and neither may
# ever be mistaken for one (tests/check_gate.sh §4 asserts this, because
# lib/claims.awk decides what a kept post has spent by reading these lines):
#
#   ~ nearest   the trace annotation: the most similar corpus sentence and a
#               word diff, when trace is on. A GUESS, by word overlap.
#   = source    the sentence this one was actually cut down FROM. Not a guess —
#               the gate matched it, so it is exact. See below.
#
# WHY `= source` EXISTS. A TWEAKED line records the CANDIDATE's text, which by
# construction does not appear in the corpus: trimming its ends (or cutting its
# middle) is what made it TWEAKED rather than VERBATIM. lib/claims.awk used to
# key the claim on that text alone, so every TWEAKED claim was unmatchable
# forever: filter_to_corpus dropped it as "not in this corpus", filter_claimed
# could never punch a hole for it, and reuse_gate caught it only if a later
# candidate happened to reproduce the identical trim. Measured on the live tree
# on 2026-08-14: 10 of 87 claims from Keep/ posts were inert this way, and the
# daily log reported them as a corpus-sampling artifact while the corpus sat at
# 44% of its budget and omitted nothing.
#
# So the gate now also names the note sentence it matched, and lib/claims.awk
# claims BOTH. Additive: a claim can only ever cover more than it did, never
# less, which is the only direction this rule is allowed to move (see the
# reclean warning in bin/reclean.sh).

# --- matching ------------------------------------------------------------------
# The note sentence the last successful match came out of. Set by the two
# tweaked_* functions below, read once, at the point of printing.
# (An awk global, deliberately: returning a pair means splitting a string, and
# this is read on the line after it is written.)

# Which note contains s verbatim? Empty if none.
#
# NOTE that this is a substring search over the whole note, which is why cutting
# a sentence's ENDS is already free for every source: drop the run-up off a
# spoken sentence and what is left is still literally present in the note. The
# hole in the middle is the only edit no substring search can see as the
# author's, and v_gap is the knob for it.
function source_of(s,   i) {
  for (i = 1; i <= nids; i++) if (index(ntext[ids[i]], s)) return ids[i]
  return ""
}

# Seam trims: drop up to 3 words from either end; accept if what remains is
# still most of the sentence and is verbatim somewhere.
function tweaked_source_of(s,   w, n, a, b, core, i, src) {
  n = split(s, w, " ")
  for (a = 0; a <= 3; a++) for (b = 0; b <= 3; b++) {
    if (a + b == 0 || n - a - b < 3) continue
    core = w[a + 1]
    for (i = a + 2; i <= n - b; i++) core = core " " w[i]
    if (length(core) >= 0.6 * length(s)) {
      src = source_of(core)
      if (src != "") {
        src_text = blog_enclosing_sentence(ntext[src], core)
        return src
      }
    }
  }
  return ""
}

# --- the dictation licence (v_gap / VOICE_TWEAK_GAP) ----------------------------
# A dictated bundle is the only thing in the tree named cleaned.md, so the id
# alone says which mouth a sentence came out of — no extra plumbing, and it
# holds in a re-rooted tree because ids are relative to BLOG_ROOT.
function is_voice(id) { return id ~ /\/cleaned\.md$/ }

# How many words sit between head and tail in note text t, where tail is taken
# after head ends. -1 when they do not both occur in that order. Also leaves the
# matched span — head, the hole, and tail — in gap_span, for the source key.
function gap_words(t, head, tail,   ph, rest, pt, mid, tmp) {
  gap_span = ""
  ph = index(t, head); if (!ph) return -1
  rest = substr(t, ph + length(head))
  pt = index(rest, tail); if (!pt) return -1
  mid = substr(rest, 1, pt - 1)
  gap_span = substr(t, ph, length(head) + (pt - 1) + length(tail))
  sub(/^[[:space:]]+/, "", mid); sub(/[[:space:]]+$/, "", mid)
  return (mid == "") ? 0 : split(mid, tmp, " ")
}

# Is s two runs of one dictated sentence with a short hole between them? Split s
# at every word boundary that leaves at least three words on each side, and look
# for a voice note carrying both halves, in order, separated by no more than
# v_gap words. One hole only: a sentence needing two is a sentence being
# rewritten, and it should fail.
#
# Only reached after source_of and tweaked_source_of have both failed, so this
# can never change how an already-matching sentence is classified — and with
# v_gap at its default of 0 it returns before doing any work at all.
function voice_gap_source_of(s,   n, w, k, i, head, tail, id, g) {
  if (v_gap <= 0) return ""
  n = split(s, w, " ")
  if (n < 6) return ""
  for (k = 3; k <= n - 3; k++) {
    head = w[1]; for (i = 2; i <= k; i++) head = head " " w[i]
    tail = w[k + 1]; for (i = k + 2; i <= n; i++) tail = tail " " w[i]
    for (id = 1; id <= nids; id++) {
      if (!is_voice(ids[id])) continue
      g = gap_words(ntext[ids[id]], head, tail)
      if (g >= 1 && g <= v_gap) {
        src_text = blog_enclosing_sentence(ntext[ids[id]], gap_span)
        return ids[id]
      }
    }
  }
  return ""
}

# --- tracing: which corpus sentence is this one a rewrite OF? -------------------
# Split every note into sentences once, then score a candidate sentence against
# all of them by shared words (intersection over union). Only built when tracing
# is on: it is the expensive half of this gate.
function build_index(   i, k, m, parts, n) {
  for (i = 1; i <= nids; i++) {
    m = blog_split_sentences(ntext[ids[i]], parts)
    for (k = 1; k <= m; k++) {
      if (length(parts[k]) < 16) continue
      csent[++nsent] = parts[k]; csrc[nsent] = ids[i]
    }
  }
}

function similarity(a, b,   wa, wb, na, nb, i, seen, common, union) {
  na = split(a, wa, " "); nb = split(b, wb, " ")
  delete seen
  for (i = 1; i <= na; i++) seen[wa[i]] = 1
  common = 0
  delete seen2
  for (i = 1; i <= nb; i++) {
    if (wb[i] in seen2) continue
    seen2[wb[i]] = 1
    if (wb[i] in seen) common++
  }
  union = 0
  for (i in seen) union++
  for (i in seen2) if (!(i in seen)) union++
  return union ? common / union : 0
}

# A word-level diff of two sentences, in the same shape git word-diff uses:
# [-dropped-] {+added+}. LCS over two ~20-word sequences, which is nothing.
function word_diff(a, b,   wa, wb, na, nb, i, j, L, out) {
  na = split(a, wa, " "); nb = split(b, wb, " ")
  for (i = 0; i <= na; i++) L[i, 0] = 0
  for (j = 0; j <= nb; j++) L[0, j] = 0
  for (i = 1; i <= na; i++) for (j = 1; j <= nb; j++)
    L[i, j] = (wa[i] == wb[j]) ? L[i - 1, j - 1] + 1 \
              : (L[i - 1, j] >= L[i, j - 1] ? L[i - 1, j] : L[i, j - 1])
  i = na; j = nb; out = ""
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && wa[i] == wb[j])            { out = wa[i] " " out; i--; j-- }
    else if (j > 0 && (i == 0 || L[i, j - 1] >= L[i - 1, j])) { out = "{+" wb[j] "+} " out; j-- }
    else                                             { out = "[-" wa[i] "-] " out; i-- }
  }
  sub(/ $/, "", out)
  return out
}

# The annotation line under a non-verbatim sentence.
function annotate(s,   i, sim, best, bi) {
  if (!trace) return
  if (!indexed) { build_index(); indexed = 1 }
  best = 0; bi = 0
  for (i = 1; i <= nsent; i++) {
    sim = similarity(s, csent[i])
    if (sim > best) { best = sim; bi = i }
  }
  if (bi == 0 || best < 0.3) {
    printf "  ~ nearest   (nothing in the corpus above 30%% — this sentence is the model's)\n"
    return
  }
  printf "  ~ nearest   [%s] %d%%: %s\n", csrc[bi], best * 100 + 0.5, word_diff(csent[bi], s)
}

# The exact source line, under a TWEAKED sentence. Suppressed when the match is
# the candidate's own text (nothing to say) — which cannot happen for a tweak,
# but keeps this honest if the branch is ever reused.
function say_source(src,   t) {
  t = src_text
  if (t == "" || t == last_norm) return
  printf "  = source    [%s] %s\n", src, t
}

# --- the two inputs -------------------------------------------------------------
NR == FNR {   # first file: the corpus, keyed by note id
  if ($0 ~ /^### NOTE id=/) { id = substr($0, 13); ids[++nids] = id; next }
  if (id != "") raw[id] = raw[id] " " $0
  next
}
FNR == 1 { for (i = 1; i <= nids; i++) ntext[ids[i]] = blog_norm(raw[ids[i]]) }
{         # second file: the candidate body, markdown decorations stripped.
  # Lines are joined with \n, NOT a space: a line break is a sentence boundary
  # too, or an unpunctuated line ending (the author writes those) fuses with the
  # next sentence into a phantom "sentence" that exists nowhere in the corpus and
  # falsely reads as NEW. A real sentence wrapped across lines just splits into
  # fragments, and a fragment of a verbatim sentence still matches as a substring.
  line = $0
  sub(/^[[:space:]]*(#+|[-*>]|[0-9]+\.)[[:space:]]+/, "", line)
  body = body "\n" line
}

END {
  n = blog_split_sentences(body, sents)
  for (i = 1; i <= n; i++) {
    s = blog_norm(sents[i])
    if (length(s) < 16) continue    # too short to judge; free either way
    counted++
    d = sents[i]; gsub(/[[:space:]]+/, " ", d); sub(/^ /, "", d)
    last_norm = s
    src_text = ""
    src = source_of(s)
    if (src != "") {
      verbatim++; printf "- VERBATIM [%s] %s\n", src, d
    } else if ((src = tweaked_source_of(s)) != "") {
      tweaked++;  printf "- TWEAKED  [%s] %s\n", src, d
      say_source(src); annotate(s)
    } else if ((src = voice_gap_source_of(s)) != "") {
      # Still TWEAKED — his sentence, edited — so lib/claims.awk spends it like
      # any other and the report keeps the shape everything reads it by. Counted
      # separately because that count IS the measurement: a run where it stays
      # at zero is a run where the licence bought nothing, whatever the posts
      # read like.
      tweaked++; excised++
      printf "- TWEAKED  [%s] %s\n", src, d
      say_source(src); annotate(s)
    } else if (split(s, wtmp, " ") <= glue_max) {
      glue++;     printf "- GLUE     %s\n", d; annotate(s)
    } else {
      new_++;     printf "- NEW      %s\n", d; annotate(s)
    }
  }
  allowed_glue = int(counted * (100 - min_pct) / 100)
  if (allowed_glue < 1) allowed_glue = 1
  # Proportional mercy for NEW: one model-written sentence tolerated per
  # new_every sentences of post. Short posts (< new_every sentences) stay at
  # zero — in 8 sentences, 1 invented one is an eighth of the post; in 46 it is
  # noise the author will delete on review.
  allowed_new = int(counted / new_every)
  pass = (counted > 0 && new_ <= allowed_new && glue <= allowed_glue)
  # Report mode never rejects — but it never lies about it either: the verdict
  # word stays PASS (that is what the script acts on) and the line says out loud
  # that enforcement was off and what would have happened. logs/gate.tsv keeps
  # the whole line, so a report-mode run is still countable afterwards.
  note = excised ? sprintf("  [%d cut from the middle of a dictated sentence]", excised) : ""
  if (mode == "report") {
    note = note (pass ? "  [report mode: enforcement off]" \
                      : "  [report mode: enforcement off — would have FAILED]")
    pass = 1
  }
  printf "\ngate: %s — %d verbatim, %d tweaked, %d glue (max %d), %d new (max %d) of %d sentences%s\n",
         pass ? "PASS" : "FAIL", verbatim, tweaked, glue, allowed_glue, new_, allowed_new, counted, note
  exit pass ? 0 : 1
}
