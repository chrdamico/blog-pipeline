# Pipeline statistics

Generated 2026-08-13 14:12 CEST by `bin/stats.sh --write`, which runs at the end of every
suggest run. Post titles are omitted here on purpose — see `bin/stats.sh`
for the full local view, and `logs/stats/` for one snapshot per day.

```
== pool ==
suggestions : 0 long, 0 short
Keep/       : 8
Discarded/  : 31
Rejected/   : 4

== material ==
draft bundles : 14
notes (root)  : 17
notes (archive): 0

== stitching gate ==
candidates  : 42  (39 passed, 3 rejected — 92% pass rate)
last rejections:
  - [long] FAIL — 43 verbatim, 1 tweaked, 0 glue (max 6), 2 new of 46 sentences
  - [long] FAIL — 36 verbatim, 1 tweaked, 0 glue (max 5), 1 new of 38 sentences
  - [long] FAIL — 1 sentence(s) already carrying a live long post

== claude usage (estimates: chars/4 ≈ tokens; CLI overhead not included) ==
suggest           :   43 call(s)  in ~271k tok   out ~26k tok
process:cleanup   :    8 call(s)  in ~10k tok   out ~3k tok
reclean:cleanup   :   42 call(s)  in ~82k tok   out ~15k tok
TOTAL             :   93 call(s)  in ~365k tok   out ~45k tok
last active day   : 2026-08-13 — 2 call(s), ~21k tokens in
```
