# Pipeline statistics

Generated 2026-08-14 10:54 CEST by `bin/stats.sh --write`, which runs at the end of every
suggest run. Post titles are omitted here on purpose — see `bin/stats.sh`
for the full local view, and `logs/stats/` for one snapshot per day.

```
== pool ==
suggestions : 4 long, 8 short
Keep/       : 8
Discarded/  : 165
Rejected/   : 10

== live A/B arms ==
D            promoted  since 2026-08-13  propose 60 into 4+8 slots: the curator chooses under real competition
massive      active    since 2026-08-13  20% verbatim; rewrite freely, keep the thinking and the voice
middle       active    since 2026-08-13  half verbatim; freer joinery, no restyling
mosaic       retired   since 2026-08-13  sentence-level interleaving; survey first; editing to make seams cohere
nofiller     promoted  since 2026-08-13  cut contentless sentence-openers at cleanup — "I think" above all

arm                                proposed rejected  gate%   pool   Keep   Disc   gone   kept% survival
base                                     70        5     7%     11      8     85      0      9%     0.1d
D                                        12        0     0%      1      0     11      0      0%     0.5d
massive                                  58        0     0%     12      0     46      0      0%     0.1d
middle                                   18        1     5%     10      0      8      0      0%     0.2d
mosaic                                   15        0     0%      0      0     15      0      0%     0.1d


(bin/arm.sh list · bin/arm.sh status · bin/arm.sh promote <name>)

== material ==
draft bundles : 17
notes (root)  : 17
notes (archive): 0

== origin (dictated vs typed) ==
Keep           8 posts     98 sentences  voice    5 ( 5%)  typed   93 (95%)  glue/new 7
Discarded    165 posts   3165 sentences  voice 1408 (44%)  typed 1757 (56%)  glue/new 245  [2 without a report]
pool          12 posts    157 sentences  voice   42 (26%)  typed  115 (74%)  glue/new 3
voice is 43% of what was offered and 5% of what was kept — typing over-performs
(Keep/ is still small — 98 sentences; treat the lift as provisional)

== stitching gate ==
candidates  : 216  (207 passed, 9 rejected — 95% pass rate)
last rejections:
  - [short] FAIL — 2 sentence(s) already carrying a live short post
  - [short] FAIL — 1 sentence(s) already carrying a live short post
  - [short] FAIL — 1 sentence(s) already carrying a live short post
  - [long] FAIL — 1 sentence(s) already carrying a live long post
  - [short] FAIL — 3 verbatim, 0 tweaked, 0 glue (max 1), 1 new (max 0) of 4 sentences

== claude usage (estimates: chars/4 ≈ tokens; CLI overhead not included) ==
suggest           :   70 call(s)  in ~622k tok   out ~97k tok
process:cleanup   :   11 call(s)  in ~19k tok   out ~6k tok
reclean:cleanup   :   42 call(s)  in ~82k tok   out ~15k tok
TOTAL             :  123 call(s)  in ~725k tok   out ~119k tok
last active day   : 2026-08-14 — 14 call(s), ~207k tokens in
```
