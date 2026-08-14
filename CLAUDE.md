# CLAUDE.md — working notes for Claude sessions in this repo

Dictation-first blog pipeline (see README.md for the full tour). Two live
systemd timers run `bin/process.sh` (every 15 min) and `bin/suggest.sh`
(daily 03:00) on this machine — **changes to those scripts go live within
minutes**, so run the tests after any edit:

```sh
bash tests/run_all.sh            # every tests/check_*.sh, with what each one guards
```

None of them call a model, so they are free and fast — run the lot, always. Use
the runner rather than a list of filenames: this section used to name five tests
when there were six, and the one it left out was the privacy backstop's.

`check_units.sh` is the one that can fail for a reason outside the repo — it
compares the systemd units installed under `~/.config/systemd/user/` against the
templates in `watcher/`, and they had silently drifted apart. If it fails,
either `bash install.sh` (adopt the repo's schedule) or change the template
(adopt the machine's). It is telling you the two disagree, not which is right.

## The map

Nine files do the work. Read them in this order and the pipeline is legible:

```
lib/config.sh      every knob, resolved in one place. Profiles, arms, BLOG_ROOT
                   re-rooting, the variant fingerprint. Nothing here writes.
lib/common.sh      the small things more than one script needs: file times,
                   slugs, frontmatter, which pools exist.
lib/claude.sh      the ONE way a model is called: stdin in, text out, no tools.
lib/provenance.sh  what produced this artifact, recorded as it is produced.
lib/text.awk       blog_norm() and the sentence splitter — the primitives every
                   comparison in the pipeline must agree on, defined once.
lib/gate.awk       the stitching gate. The pillar: is this really his sentence?
lib/claims.awk     what a kept post has spent, read out of its provenance report.
bin/process.sh     capture: audio -> transcript -> cleaned -> a draft bundle.
bin/suggest.sh     the curator: corpus -> candidates -> gate -> pool -> arms.
```

The rest are entry points over those: `bin/arm.sh` (live A/B arms), `bin/ab.sh`
(offline experiments), `bin/score.sh` (what the pool did), `bin/stats.sh`,
`bin/reclean.sh`, `bin/note.sh`, `bin/transcribe.sh`.

`bin/suggest.sh --help` prints its stage list, which is the shortest true answer
to "what does a run actually do".

Where things stand (2026-08-13). The base is `profiles/base.env`: arm **D**'s
quotas (`MAX_NEW=60` proposed into `MAX_LONG=4` + `MAX_SHORT=8`, `VERBATIM_MIN=55`,
`NEW_SLACK_EVERY=6`, `GLUE_MAX_WORDS=20`, `GATE_TRACE=1`) plus
`CURATE_DIRECTIVE=…/tournament.md`. Active arms: **massive**, **middle** —
both curator-stage rewrite licences, differing in `VERBATIM_MIN` — and
**voice-loose** (2026-08-14), the first arm to treat the corpus's two mouths
differently. Typed notes may still be edited, just sparingly; dictated ones may
be cut into (`VOICE_TWEAK_GAP=8`) and genuinely **reworded**
(`VOICE_REWRITE_MIN=50`), on the premise that speech is first-draft thinking and
the sentence he happened to say is often not the one he would have written.
Promoted:
**D**, **nofiller**. Retired: **mosaic** (2026-08-14). The base also pins
`CLEANUP_DIRECTIVE=…/cleanup-nofiller.md`, from the `nofiller` arm: cleanup cuts
the author's sentence-opening hedges ("I think" opened about one sentence in five
of his transcripts). It stays in the directive slot rather than in
`prompts/cleanup.md` for a measured reason spelled out below.

## When Christian says "do this change as an A/B test"

He means a LIVE ARM, not the offline runner. The recipe, in full:

```sh
bin/arm.sh new <name> KEY=VALUE ... --note "the question it answers"
bin/arm.sh try <name>          # against samples/notes/, sandboxed, reproducible
bin/arm.sh run <name>          # generate into the REAL pool now (costs a call)
```

Rules for doing this well:

- **Express the change as deltas, never by editing the base.** If it needs a new
  prompt, put the file in `profiles/overlays/<name>/` and set `PROMPTS_DIR=` in
  the arm; if it needs new instructions, write a directive file and set
  `CURATE_DIRECTIVE=`. `bin/arm.sh new` prints the resolved diff against the
  base — check it says what you meant.
- **Never touch `profiles/base.env` by hand.** Only `bin/arm.sh promote` writes
  it, and that is how "test B is great, move it to base" is supposed to happen.
- **Show him `bin/arm.sh try <name>` output before it goes live.** It costs one
  call, uses the committed sample notes, and proves the arm produces something.
- Arms run automatically every day after the base, into `Posts/<name>/`. He
  reads both folders on the phone and moves what he likes to `Keep/`.
- "Test C is a failure, remove it" → `bin/arm.sh retire C` (its pool goes to
  `Discarded/`, recoverable; the registry keeps the row).
- Statistics land in `STATS.md` at the repo root every run, and in
  `bin/arm.sh status`. The registry is `logs/arms.tsv`.

### What an arm can and cannot test — check this BEFORE proposing one

An arm repeats only what is **downstream of the corpus**: generation, the gate,
its own pool's curation. Transcription and cleanup happen in `process.sh`, once
per recording, and `process.sh` has **no `BLOG_ARM` handling at all** — the
bundles in `drafts/` are shared by the base and every arm alike.

So an arm whose delta is `CLEANUP_DIRECTIVE`, `PROMPTS_DIR` over `cleanup.md`,
`CLEANUP_MODEL` or any `WHISPER_*` knob is **inert**: it will run every night and
write a pool byte-identical to the base's. Do not offer one as a daily A/B, and
say so plainly if the change he asks for lands at that stage.

Test an upstream change one of these ways instead:

```sh
bin/arm.sh try <name> --full   # from samples/real/audio; whisper answers from
                               # eval/cache/transcripts, so only cleanup costs calls
bin/ab.sh run <exp>            # STAGE=process offline, REPS for variance, churn_pct per bundle
```

Plain `bin/arm.sh try <name>` (no `--full`) starts from **already-cleaned notes**
and will show no difference whatsoever for a cleanup change — it is not evidence.

Landing an upstream change is `bin/arm.sh promote`, same as any other — it pins
the directive in `profiles/base.env`, which is the floor under every run.

**Do not "tidy" a won directive into the prompt file.** It is the obvious move
and it is measurably wrong. Tried on 2026-08-13 with the hedge mandate: the same
words left 5 sentence-initial hedges from the directive slot, 12 as a bullet in
`cleanup.md`'s DO list, and 8 as a dedicated late section — 30 uncut is the
baseline. The slot wins because of POSITION: the stream is instructions + anchor
+ DIRECTIVE + input, so a directive sits immediately before the transcript,
where a mid-prompt rule competes with forty others. Churn stayed flat only in the
slot version. If you think a prompt edit is equivalent to a directive, measure it
before believing it.

The price is that a won directive occupies its slot: the next cleanup experiment
to set `CLEANUP_DIRECTIVE` replaces the file and silently reverts the win, so
such an experiment must carry the existing mandate forward in its own directive.
Applied forward all of this is safe; see the reclean warning below for why
applying it backward is not.

Design invariants not to break: claims are **arm-scoped** (`build_claimed`
filters on the post's `arm:` frontmatter) so no arm starves another; `Keep/`,
`Discarded/` and `Rejected/` stay **shared** so judging and promotion never move
files around; each arm's posts carry the arm in **both** the folder and the
filename, because `.provenance/` is flat and two arms must not collide there.

## The experiment (A/B) layer

Everything is resolved in `lib/config.sh` — paths, prompts, models, knobs.
`profiles/default.env` is the runnable inventory of every knob. Design doc:
PLAN-AB.md (gitignored, local). Full user docs: README.md §Provenance and
§Experiments.

Key mechanics, in one screen:

- **Profiles**: `BLOG_PROFILE=<name>` loads `profiles/<name>.env` (deltas
  only; real environment always outranks the profile).
- **Re-rooting**: `BLOG_ROOT=<dir>` moves the whole data tree (sync/, drafts/,
  logs/, private/). This is how sandboxes work; the code root never moves.
- **Prompt overlay**: `PROMPTS_DIR=<dir>` — only the files it contains
  override `prompts/`; per-prompt pins like `SUGGEST_PROMPT=…` also work.
- **Directive slot**: prompt stream is instructions + style anchor +
  DIRECTIVE + input. `CLEANUP_DIRECTIVE=` / `CURATE_DIRECTIVE=` name a small
  file; empty means byte-identical to the pre-experiment stream.
- **Personas**: `PERSONAS=<tsv>` (`name<TAB>directive-file`, paths relative
  to the TSV) fans generation out into one call per persona, MAX_NEW split
  between them; each candidate gets `persona:` frontmatter.
- **Fingerprint**: `lib/config.sh dump|fingerprint|variant|paths` shows what
  an environment resolves to. Prompts enter the fingerprint by CONTENT hash;
  paths and thread counts are deliberately excluded.
- **Provenance**: every bundle gets `drafts/<b>/meta.json`; every candidate
  post gets `variant:`/`persona:`/`run:` frontmatter; every artifact gets a
  row in `logs/provenance.tsv`. Never strip these — `bin/score.sh` joins on
  them.

Offline experiments:

```sh
bin/ab.sh freeze              # once (and after notable new memos): fixtures from drafts/ + vault snapshot
bin/ab.sh list                # fixtures, experiments, past runs
bin/ab.sh run <exp>           # eval/experiments/<exp>.exp — sandboxed, EXPENSIVE (Claude calls)
bin/ab.sh report <exp>        # rebuild eval/runs/<exp>/REPORT.md
bin/ab.sh judge <exp>         # optional pairwise LLM judge — also expensive
bin/ab.sh promote <exp> <v>   # freeze a variant's rows as eval/baseline/
bin/ab.sh score               # ONLINE metric: what the live pool did per variant/persona
```

## Rules that protect the pipeline's pillars

- `GATE_MODE=report` (gate classifies but never rejects) is SANDBOX-ONLY:
  it would put model-written prose on the phone wearing the author's voice.
  `suggest.sh` main() **refuses to start** in report mode when `BLOG_ROOT`
  equals the repo (pinned by check_gate.sh). Don't weaken that guard; a
  sandbox is one `BLOG_ROOT=` away, and `bin/ab.sh` sets it for you.
- `VOICE_REWRITE_MIN` is the only knob that lets a NON-verbatim sentence into a
  live pool, so treat it as the pillar bending rather than flexing. It is
  narrower than report mode in three ways at once and all three are load-bearing:
  it applies to DICTATED sentences only, each rewrite must clear a word-overlap
  floor against the one spoken sentence it restates (so it can restate him but
  not invent), and every rewrite is named in the report and counted on the gate
  line. Keep it at 0 in the base. If an arm carrying it wins, the argument for
  promoting it has to be made about the pillar, not about the accept rate.
- An `.exp` variant may not set any `BLOG_*` or `ALIASES` (ab.sh rejects the
  whole prefix — those are the only handles that could point a sandboxed run
  at live data); use a profile instead. `VARIANT_x_ENV` is eval-split, so
  quoted values with spaces work.
- `eval/` except `eval/experiments/` is gitignored personal data (fixtures
  are real memos and the real vault). Same for `drafts/`, `sync/`,
  `private/`, `logs/`. Never commit or publish content from them.
- `ab.sh run` truncates `eval/runs/<exp>/metrics.tsv` and reuses the run
  directories — promote (or copy) results you want to keep before re-running.
- Suggest-stage metrics come from the sandbox's own `logs/provenance.tsv`
  (`candidates`/`rejected`/the sentence classes = what THIS run produced),
  never from counting the tree, which also holds the seeded snapshot.
  `pool_long`/`pool_short` are the exception and are end-state by design.
- Re-running `ab.sh freeze` overwrites the vault snapshot — old runs' inputs
  are gone at that point; treat REPORT.md as the durable record.
- Changing any prompt file changes the fingerprint, so live artifacts start
  carrying a new variant id automatically. That is intended — `score.sh`
  groups by it.
- **Never `bin/reclean.sh` after a prompt change that rewrites sentence text.**
  Claims are keyed on the exact normalized SENTENCE TEXT: `build_claimed` lifts
  the keys from `.provenance/*.md`, and `filter_claimed` / `reuse_gate` match
  them against the corpus — which reads `drafts/*/cleaned.md` **directly**
  (`corpus_files`). A reclean moves the corpus side and leaves the reports alone,
  so every claimed sentence whose wording changed loses its key: no corpus hole,
  no reuse FAIL, and a sentence already published becomes free to publish twice.
  `REUSE_MIN_WORDS=6` adds a smaller permanent leak — a two-word cut drops a
  7-word sentence below the threshold and it stops being claimable at all.
  Forward-only is safe (a recording is cleaned once, so its corpus text and any
  key written from it are the same generation). The full reasoning, and the
  additive `build_claimed` fix that would make recleaning safe, is in
  `bin/reclean.sh`'s header. Do not instead relax `norm()` — that would let the
  curator drop words at stitch time and still be graded VERBATIM.
- **The gate already lets any sentence be cut at its ENDS.** `source_of` does an
  `index()` substring search over the whole note, so a sentence with its run-up
  or its trailing "or something like that" removed is still literally present in
  the note and grades VERBATIM — no licence involved, for either mouth. What the
  gate cannot see as the author's is a HOLE: cut a false start out of the middle
  and the two surviving runs no longer form a substring, and no amount of
  end-trimming in `tweaked_source_of` closes that. So an experiment about
  "allowing more editing" that widens the end-trim budget is measuring nothing —
  it is loosening a constraint that was never binding. `VOICE_TWEAK_GAP` is the
  knob that addresses the real one (one hole, capped in words, dictated notes
  only, off by default). Verified both ways in `tests/check_gate.sh` §4b.

## Conventions

- Shell style: bash, `set -euo pipefail`, long prose comments explaining the
  WHY; match it. Comment density here is deliberately high — this is a
  personal repo the owner reads like documentation.
- Commit messages: short lowercase `area: what changed` with a sentence-long
  poetic bent (read `git log --oneline` first).
- Models per stage: cleanup/typos = Sonnet, curator = Opus, all overridable
  (`CLEANUP_MODEL`, `CURATE_MODEL`, `TYPO_MODEL`; blunt `CLAUDE_MODEL` still
  overrides the first two).
