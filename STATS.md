# Pipeline statistics

Generated 2026-08-12 10:01 CEST by `bin/stats.sh --write`, which runs at the end of every
suggest run. Post titles are omitted here on purpose — see `bin/stats.sh`
for the full local view, and `logs/stats/` for one snapshot per day.

```
== pool ==
suggestions : 2 long, 3 short
Keep/       : 8
Discarded/  : 24
Rejected/   : 1

== material ==
draft bundles : 13
notes (root)  : 17
notes (archive): 0

== stitching gate ==
candidates  : 37  (34 passed, 3 rejected — 91% pass rate)
last rejections:
  - [long] FAIL — 43 verbatim, 1 tweaked, 0 glue (max 6), 2 new of 46 sentences
  - [long] FAIL — 36 verbatim, 1 tweaked, 0 glue (max 5), 1 new of 38 sentences
  - [long] FAIL — 1 sentence(s) already carrying a live long post

== claude usage (estimates: chars/4 ≈ tokens; CLI overhead not included) ==
suggest           :   41 call(s)  in ~249k tok   out ~24k tok
process:cleanup   :    7 call(s)  in ~6k tok   out ~2k tok
reclean:cleanup   :   42 call(s)  in ~82k tok   out ~15k tok
TOTAL             :   90 call(s)  in ~339k tok   out ~41k tok
last active day   : 2026-08-12 — 5 call(s), ~40k tokens in
```
