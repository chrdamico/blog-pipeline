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

**`bin/brief.sh` is the answer to "what is running tonight, and what does each arm
change".** One page, generated from the same resolution every run uses, so it
cannot describe a configuration that is not live: the base grouped by stage in
plain English, then each active arm's deltas — including its directive, which for
a curator arm is usually the whole difference. `--write` puts it in
`sync/Obsidian/Pipeline/RUNNING.md`, where the phone can read it; the nightly run
refreshes it. Read it before proposing an experiment.

It lives in a SUBFOLDER of the vault on purpose: the corpus globs are
non-recursive, so a page about the pipeline can never become material the
pipeline stitches posts out of. `tests/check_brief.sh` asserts that end to end,
and also that every fingerprint knob has a sentence — so a knob added tomorrow
cannot go unexplained.

**Do not restate what is live in here.** `bin/brief.sh` reads it out of the
resolved configuration, `bin/arm.sh list` names tonight's arms, and its "Already
decided" section is generated from the registry. A roll-call of knob values and
promoted arms typed into this file is a second copy that rots, and the rotted
copy is the one a session reads first. What belongs here is only what nothing
generates: the reasoning below.

Two premises currently under test that the numbers will not tell you. **Speech is
first-draft thinking** — the sentence he happened to say aloud is often not the
one he would have written, which is why the `VOICE_*` knobs treat dictated notes
as more editable than typed ones rather than treating the corpus as uniform. And
**cleanup should cut his sentence-opening hedges** ("I think" opened about one
sentence in five of his transcripts, almost never marking real uncertainty),
which is why the base pins a `CLEANUP_DIRECTIVE` at all — it stays in the
directive slot rather than in `prompts/cleanup.md` for a measured reason spelled
out below.

## Where a file lives says whether it is running

`profiles/README.md` is the one page for this, and it is short. The rule:
`prompts/`, `profiles/directives/`, `profiles/overlays/` and `arms/` contain
**only what is live**; `profiles/offline/` contains what is inert until you name
it (`BLOG_PROFILE=`, or an `.exp` variant). `bin/brief.sh --files` prints the
inventory with each file's status resolved from the live configuration, and
`tests/check_layout.sh` fails if any file in a live directory is pointed at by
nothing, or if the two directions ever cross.

So: **an arm's file is deleted when the arm ends.** `promote` folds the deltas
into `profiles/base.env` and removes `arms/<name>.env`; `retire` removes it and
takes any directive or overlay nothing else uses with it (only if git already
has that content — an uncommitted directive is kept and named). The durable
record is git for the file and `logs/arms.tsv` for the question it asked. Do not
keep a stopped arm's file around "for reference": a file in `arms/` is
indistinguishable by looking from one that runs tonight, and that is the entire
cost.

**And no repo history inside a file that goes into the prompt stream.** A prompt
or a directive is text a model reads tonight; which arm it arrived as, what it
used to be called, and what it measured are facts about the repo, and they
belong in a commit message, in `logs/arms.tsv`, or here. `propose-generously.md`
opened with a paragraph about its own renaming — five lines of provenance
addressed to nobody, sent to Opus every night, ahead of the actual instruction.

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
- **Name the file for what it instructs, never for the arm.** An arm's name is
  a label for a question being asked this week; a directive or overlay it
  introduces can be promoted and then sits in `profiles/base.env` for good,
  where the arm it came from means nothing to anyone. `tournament.md` was named
  after arm **D** and had to be renamed to `propose-generously.md` once it was
  the base's standing instruction. Pick the durable name on day one, and put it
  in `profiles/directives/` — the live directory — because a live arm points at
  it. `profiles/offline/directives/` is for sandbox-only prose.
- **Never write a gate threshold into prose.** `GLUE_MAX_WORDS`, `VERBATIM_MIN`,
  `VOICE_*` and the quotas reach the model through `limits_block()` in
  `bin/suggest.sh`, which prints them from the resolved config at the end of the
  stream. A number typed into a prompt or a directive cannot follow a knob, and
  an arm that moves the knob while the prose still states the old figure widens
  what the GATE accepts and tells the model nothing — half an experiment, and
  the half that measures nothing. `prompts/suggest.md` said "at most 12" for
  months while the base ran at 20 and `massive` at 40.
- **Never touch `profiles/base.env` by hand.** Only `bin/arm.sh promote` writes
  it, and that is how "test B is great, move it to base" is supposed to happen.
- **Show him `bin/arm.sh try <name>` output before it goes live.** It costs one
  call, uses the committed sample notes, and proves the arm produces something.
- Arms run automatically every day after the base, into `Posts/<name>/`. He
  reads both folders on the phone and moves what he likes to `Keep/`.
- "Test C is a failure, remove it" → `bin/arm.sh retire C`: its pool goes to
  `Discarded/` (recoverable), its `.env` and any directive nothing else uses are
  deleted, and the registry keeps the row. Never leave the file behind.
- Statistics land in `STATS.md` at the repo root every run, and in
  `bin/arm.sh status`. The registry is `logs/arms.tsv`.

### Change the instruction; do not overrule it later

An arm may carry its **own full copy** of any prompt file — `PROMPTS_DIR=` puts
an overlay in front of `prompts/`, and only the files it contains are replaced
(`profiles/overlays/README.md`). That is deliberate and it is the flexible route:
inside its own copy an arm can say anything, including the opposite of what the
base says.

**Use it that way.** When an arm needs the base prompt to say something different,
edit the sentence in its own copy. Do NOT leave the base's rule standing and add
a directive that quotes it back and cancels it.

All three live arms were built the wrong way and were converted to overlays on
2026-08-14; the deleted directives are in git if you want to see it. The worst,
`voice-loose.md`, spent its middle third un-saying `prompts/suggest.md` — quoting
three rules and suspending them, and informing the model that a factual claim
made earlier in the same stream "is no longer true" because the checker had been
changed underneath it. Two symptoms worth recognising, because both are what a
retraction rots into rather than accidents:

- **It suspended a rule the prompt had stopped making.** It quoted "paraphrasing
  … reads to the checker as writing" and lifted it. That sentence had already
  been edited out of `prompts/suggest.md`. A retraction is pinned to wording it
  does not own, so it goes stale silently — an overlay cannot, because it *is*
  the wording.
- **It wrote a gate threshold into prose, and lost.** It closed with "roughly
  half of every post should still be his words untouched" while inheriting
  `VERBATIM_MIN=70`, so `limits_block()` printed 30% in the same stream. See the
  rule above about never stating a threshold in prose.

Three reasons that is worse than editing the copy, in order of how much they cost:

1. **The model has to arbitrate, and it does not always pick your side.** Two
   instructions in one stream pointing opposite ways is the one prompt failure
   that is reliably measurable. The base's version is stated first, at greater
   length, with more emphasis, and a late conditional exception is the weaker of
   the two. The directive's own tone gives this away — "you will otherwise obey
   those instead", "a run in which you rewrote nothing is a failed run" is what
   someone writes after watching the model side with the base prompt.
2. **A weak arm becomes unreadable as a result.** If it underperforms you cannot
   tell whether the licence was a bad idea or the model simply did not take it,
   and that is the whole question the arm existed to answer.
3. **It hides in review.** A prompt overlay diffs against `prompts/` and shows
   exactly which sentence changed. A retraction reads as additive.
4. **It costs the arm the base's directive.** There is ONE directive slot per
   stage, and `profiles/base.env` already occupies both. An arm that sets
   `CURATE_DIRECTIVE` does not add to `propose-generously.md`, it REPLACES it —
   so the arm quietly differs from the base by that instruction too, on top of
   whatever it meant to test. All three arms had this: `massive` and `middle`
   simply lost it, and `voice-loose` carried it forward by pasting a copy into
   its own file, which is the same rot one step later. An overlay leaves the slot
   free, so the arm inherits the base's directive like any other run and its diff
   is only what it meant to change. That is the fourth reason and in practice the
   one that silently corrupts a comparison.

So: a delta of degree (a knob, an emphasis, an extra instruction that does not
contradict anything) is a **directive**. A delta that requires the base to stop
saying something is an **overlay with that sentence rewritten**, plus a short
directive for the rest. The base prompt should also be written so this is rarely
needed: state a default and name the knob that widens it, rather than an absolute
a later file has to break.

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
baseline. The slot wins because of POSITION: the stream is instructions +
DIRECTIVE + input, so a directive sits immediately before the transcript,
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

- **Profiles**: `BLOG_PROFILE=<name>` loads `profiles/<name>.env`, or
  `profiles/offline/<name>.env` if that is where the file lives (deltas only;
  real environment always outranks the profile). Live wins on a name collision.
- **Re-rooting**: `BLOG_ROOT=<dir>` moves the whole data tree (sync/, drafts/,
  logs/, private/). This is how sandboxes work; the code root never moves.
- **Prompt overlay**: `PROMPTS_DIR=<dir>` — only the files it contains
  override `prompts/`; per-prompt pins like `SUGGEST_PROMPT=…` also work.
- **Directive slot**: prompt stream is instructions + DIRECTIVE + input.
  `CLEANUP_DIRECTIVE=` / `CURATE_DIRECTIVE=` name a small
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
bin/ab.sh judge <exp>         # optional pairwise LLM judge, STAGE=suggest only — expensive
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
- **No model judges cleanup.** `ab.sh judge` is curator-side only and refuses a
  `STAGE=process` experiment by name. A cleanup A/B asks how much more it
  rewrote, and `churn_pct` plus `changes.diff` answer that exactly and for free;
  whether the result still sounds like him is his call, off the recording he
  remembers making, and he reads the transcripts when they come out wrong. There
  was a `prompts/judge-process.md` — written on 2026-08-12 as the symmetric twin
  of `judge-suggest.md` when `ab.sh` was built, never once run — and it was
  deleted for this reason, not by accident. Do not helpfully restore it.
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
