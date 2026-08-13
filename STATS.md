# Pipeline statistics

Generated 2026-08-13 18:28 CEST by `bin/stats.sh --write`, which runs at the end of every
suggest run. Post titles are omitted here on purpose — see `bin/stats.sh`
for the full local view, and `logs/stats/` for one snapshot per day.

```
== pool ==
suggestions : 5 long, 8 short
Keep/       : 8
Discarded/  : 37
Rejected/   : 4

== live A/B arms ==
D            promoted  since 2026-08-13  propose 60 into 4+8 slots: the curator chooses under real competition
massive      active    since 2026-08-13  20% verbatim; rewrite freely, keep the thinking and the voice
middle       active    since 2026-08-13  half verbatim; freer joinery, no restyling
mosaic       active    since 2026-08-13  sentence-level interleaving; survey first; editing to make seams cohere

arm                                proposed rejected  gate%   pool   Keep   Disc   gone   kept% survival
base                                     12        0     0%      7      8     31      0     21%     0.1d
D                                        12        0     0%      6      0      6      0      0%     0.0d
massive                                   6        0     0%      6      0      0      0      0%      —
middle                                    3        0     0%      3      0      0      0      0%      —
mosaic                                    3        0     0%      3      0      0      0      0%      —


(bin/arm.sh list · bin/arm.sh status · bin/arm.sh promote <name>)

== material ==
draft bundles : 14
notes (root)  : 17
notes (archive): 0

== stitching gate ==
candidates  : 73  (70 passed, 3 rejected — 95% pass rate)
last rejections:
  - [long] FAIL — 43 verbatim, 1 tweaked, 0 glue (max 6), 2 new of 46 sentences
  - [long] FAIL — 36 verbatim, 1 tweaked, 0 glue (max 5), 1 new of 38 sentences
  - [long] FAIL — 1 sentence(s) already carrying a live long post

== claude usage (estimates: chars/4 ≈ tokens; CLI overhead not included) ==
suggest           :   56 call(s)  in ~415k tok   out ~40k tok
process:cleanup   :    8 call(s)  in ~10k tok   out ~3k tok
reclean:cleanup   :   42 call(s)  in ~82k tok   out ~15k tok
TOTAL             :  106 call(s)  in ~508k tok   out ~60k tok
last active day   : 2026-08-13 — 15 call(s), ~165k tokens in
```
