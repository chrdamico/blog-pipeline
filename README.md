# blog-pipeline

Dictation-first blog writing pipeline: voice memos recorded on the go (Android →
Syncthing) are transcribed locally (whisper.cpp), minimally cleaned by Claude
(`claude -p`, voice-preserving), and land as reviewable draft bundles in
`drafts/` — verbatim transcript, cleaned text, and a word-diff showing every
change the LLM made.

A second, slower job (`bin/suggest.sh`, daily) reads everything captured — voice
drafts *and* typed notes — looks for places where two or more notes converge, and
**stitches** them into candidate posts built from your own sentences, into a
**capped**, rotating pool you read on your phone. Anything you like, you move to
`Posts/Keep/`; the rest is allowed to age out, so a month away leaves you a dozen
suggestions, not a backlog.

Design pillars: raw audio is the permanent source of truth · verbatim transcript
is always kept and diffable · cleanup never rewrites voice · suggestions are
capped and disposable, your `Keep/` folder is not · zero marginal cost (local
Whisper + Claude subscription, **no API key**) · portable Linux → macOS · all
personal data stays in this gitignored tree.

## Quick start

```sh
./install.sh                 # deps (ffmpeg, whisper.cpp, model) + both timers
# optional: copy prompts/style-anchor.example.md -> style-anchor.md and fill it in (SETUP.md §2)
# drop an audio file into sync/  (or let Syncthing do it)
bin/process.sh               # process now; the timer also runs it every 15 min
bin/suggest.sh               # propose posts now; the timer also runs it daily
```

Each processed memo becomes `drafts/<recording-date>-<slug>/`:

| File            | What it is                                                        |
|-----------------|------------------------------------------------------------------|
| *original audio*| the source recording, **copied** here permanently; the `sync/` original lingers `SYNC_KEEP_DAYS` then is reaped |
| `verbatim.md`   | raw whisper.cpp transcript — the sacred, re-diffable intermediate |
| `cleaned.md`    | voice-preserving cleanup: filler gone, **nothing rephrased**      |
| `changes.diff`  | word-level diff of verbatim → cleaned; every change made visible  |
| `structure.md`  | optional outline suggestion (only when run with `STRUCTURE=1`)    |

## How it works

`bin/process.sh` runs on a timer and, for each **unprocessed** audio file at the
root of `sync/` (`*.m4a *.mp3 *.opus *.ogg *.wav`, case-insensitive):

1. **skip** it if its SHA-256 is already in `logs/processed.tsv` (content hash, so
   Syncthing renames don't cause reprocessing);
2. **transcribe** verbatim via `bin/transcribe.sh` (ffmpeg → 16 kHz WAV → whisper.cpp);
3. **clean** the transcript through `claude -p` with `prompts/cleanup.md`
   (subscription auth; FS/exec tools denied; run from `work/`);
4. **diff** verbatim vs cleaned with `git diff --word-diff`;
5. **bundle** everything into `drafts/<date>-<slug>/` (date = recording mtime,
   slug = first meaningful words), never overwriting an existing bundle — the
   audio is **copied**, so the original stays in `sync/`;
6. **leave a transcript** next to that original (`<recording>.md`), so a memo is
   readable on the phone minutes after you record it;
7. **record** the hash and fire a desktop notification;
8. **reap** recordings whose grace period has expired — see below.

It's idempotent and crash-safe: a failure at any point leaves the audio in
`sync/` for the next run, already-bundled audio is skipped by content hash, and
one bad file never aborts the batch.

### Retention: `drafts/` is the archive, `sync/` is a conveyor belt

A processed recording and its transcript stay in `sync/` — and therefore on your
phone — for `SYNC_KEEP_DAYS` (default **14**), then both are removed together.
The copy in `drafts/<date>-<slug>/` is permanent and never touched.

The reaper only ever deletes a `sync/` file whose content hash is already in
`logs/processed.tsv`, so an **unprocessed** recording is never removed no matter
how old it is. The clock runs from processing, not recording, so a memo that
syncs in late still gets its full window.

The scan is **non-recursive** on purpose — `sync/Obsidian/` is the notes vault,
and neither the audio scan nor anything else in `process.sh` ever walks into it.

## Layout

```
blog-pipeline/
├── README.md          # this file
├── SETUP.md           # install, phone pairing, notes app, notifications, macOS
├── install.sh         # idempotent OS-aware setup (deps, model, schedulers)
├── bin/
│   ├── process.sh     # the transcription driver (every 15 min)
│   ├── suggest.sh     # the post-suggestion job (daily)
│   ├── transcribe.sh  # whisper.cpp wrapper (swappable STT backend)
│   ├── note.sh        # text-note capture from the terminal (writes the vault)
│   ├── reclean.sh     # re-run cleanup over existing bundles (prompt upgrades)
│   ├── stats.sh       # the pipeline at a glance; writes STATS.md
│   └── notify.sh      # notify-send / osascript wrapper
├── lib/
│   └── config.sh      # every path, prompt, model and knob, resolved in one place
├── profiles/
│   └── default.env    # the full inventory of knobs, at their defaults
├── prompts/
│   ├── cleanup.md      # voice-preserving cleanup prompt
│   ├── structure.md    # optional outline-suggestion prompt
│   ├── suggest.md      # find convergences, write candidate posts
│   ├── curate.md       # choose the best N-subset of an overflowing pool
│   ├── names.md        # the name scout: list person names to anonymize
│   ├── typos.md        # proofread a typed note: spelling only, nothing else
│   └── style-anchor.example.md # template: copy to style-anchor.md (gitignored) + add your writing
├── tests/             # check_privacy.sh: nothing personal is ever committed
│                      # check_typo_gate.sh: the typo pass only respells words
│                      # check_defaults.sh: the config layer changes nothing
├── .githooks/         # pre-commit hook running that check (wired by install.sh)
├── watcher/           # systemd user units + (untested) macOS launchd plists
├── sync/              # THE Syncthing folder (the phone calls it /blog)
│   ├── *.m4a          #   recordings land here, at the root
│   └── Obsidian/      #   the vault: notes at the root, Archive/ + Posts/ below
├── private/           # gitignored: aliases.tsv (real name -> alias, optional)
└── drafts/  models/  logs/  work/    # gitignored, like sync/ (personal / large)
```

Everything that touches the phone lives under the single `sync/` folder — one
Syncthing pairing carries recordings, notes, and suggestions alike.

## Text notes (`sync/Obsidian/`)

A separate space from the voice pipeline: typed notes are plain `.md` / `.txt`
files at the root of the vault, never cleaned, restructured, or rewritten — the
one thing that does touch their text is the typo pass below. Same Syncthing
folder as the recordings, one level down — write on the phone (Obsidian, or any
editor that saves into a folder) or on the laptop:

```sh
bin/note.sh                      # opens $EDITOR; filename comes from line 1
bin/note.sh cancel the domain renewal
bin/note.sh -l                   # list recent notes
bin/note.sh -e domain            # reopen the newest note matching "domain"
```

Notes written here are `<date>-<slug>.md`, the same naming as draft bundles;
nothing is ever overwritten. No database and no index — the folder *is* the app,
so the editor on either end is swappable. See `SETUP.md` §4 for the phone side.

Phone note apps name files whatever they like ("Lorem ipsum dolor sit.txt");
that's fine. Once a root note is older than `ARCHIVE_DAYS` (14), the daily job
moves it to `Obsidian/Archive/<date>-<slug>.<ext>` — date from when the note was
*created* (the earlier of file birth time and mtime, never the archival date),
slug from its first line — so the archive is dated and titled even when the
capture wasn't. Renames are propagated into the `sources:` of every pool and
`Keep/` post, archived notes stay part of the corpus, and `note.sh -l` / `-e`
see the archive too. Archiving only ever changes the name, never the text.

### The typo pass: proofread once, at capture

A voice memo is proofread the moment it is transcribed — `prompts/cleanup.md`
fixes obvious transcription errors and nothing downstream has to care. A note
thumbed into the phone one-handed had no such stage, so its typos travelled
verbatim into the corpus and came out the other side inside a stitched post.

The daily job now proofreads each typed note **once**, before it reads the
corpus, and rewrites it in place — so the note reads correctly on the phone too,
the verbatim gate keeps seeing exactly one version of the text, and a post
stitched next month inherits the fix. This is the only place in the pipeline
where raw input is edited, so the model is never trusted with the result:

- **one call per note, ever** — `logs/typofix.tsv` is keyed by content hash, and
  records both the before and after hash, so a fixed note is not re-read next
  run and a note *you* edit later gets exactly one fresh pass;
- **the model's text is never written anywhere.** It is diffed against the note
  word by word, and all that is extracted is a list of single-word
  substitutions, which are applied to the *original* file. A reflowed line, a
  supplied comma, a tidied sentence cannot survive that trip — there is no code
  path that would carry them across;
- **anything not typo-shaped fails the whole note**, which is then left as typed
  and never retried at that hash: a changed word count, moved punctuation, a
  supplied apostrophe (`dont` → `don't` is punctuation, not spelling), a
  case-only change, a word carrying a non-ASCII letter (so German and Denglisch
  are immune), an edit too large to be a slipped finger, or more than
  `TYPO_MAX_PCT` of the note's words at once;
- **short words are declined, not failed.** Nothing under `TYPO_MIN_LEN` (4) is
  ever "corrected": `wbe`, `tbh`, `iir` are acronyms and shorthand, and no rule
  can tell those from typos by shape. That one word is skipped and the note's
  real fixes still land.

Every substitution is logged by name (`TYPO <note>: cobsciousness ->
consciousness`), and every declined one too, so the pass is auditable after the
fact. What it cannot catch mechanically is a plain-ASCII word swapped for
another one edit away when the intent was grammar — a German declension
(`ganze` → `ganzen`) is the realistic case; only the prompt forbids that.
`TYPO_FIX=0` turns the whole stage off, and `bin/suggest.sh --typos-only` runs
just this and exits.

## Post suggestions (`sync/Obsidian/Posts/`)

`bin/suggest.sh` runs daily — scheduled at 03:00, with catch-up after a night
the laptop was off (`Persistent=true`) and retry slots every 4 hours: only the
first *successful* run of a day does work (per-day stamp in
`logs/suggest.lastdone`), and a run whose Claude call failed writes no stamp,
so the next slot retries until midnight rolls the day over. Manual runs ignore
the stamp. It reads the whole corpus — every `drafts/*/cleaned.md`
plus every note in the vault (root and `Archive/`) — and looks for places where
**two or more notes converge**. A candidate is **stitched, not written**: the
model may select, reorder and drop your sentences, but not write its own — short
connective glue is the only exception. Each candidate is a markdown file with
frontmatter naming the notes it came from:

```yaml
---
kind: long          # long = 400-900 word post · short = 40-120 word note/tweet
title: Everything is easy until it touches matter
created: 2026-08-13
sources:
  - drafts/2026-08-11-so-the-cable-spec-looked/cleaned.md
  - sync/Obsidian/2026-08-12-estimates-and-matter.md
---
```

The pool is **capped** (4 long, 8 short by default). When it overflows, one
Claude call judges the whole pool *as a set* — quality **and** coverage, so two
near-duplicates lose to two genuinely different ideas — and returns a decision
the script validates and acts on. The model never deletes anything itself, and
losers move to `Posts/Discarded/` for 14 days rather than being removed. That
folder **syncs to your phone**, so an eviction stays visible and reversible —
move a file back out of `Discarded/` and it is yours again.

**Your half of the loop is one gesture:** read the suggestions on your phone and
move the ones you like into `Posts/Keep/`. That folder is invisible to the job —
never re-judged, never evicted, never counted against the cap. Everything you
*don't* rescue is allowed to age out, which is what keeps a month of absence from
turning into a backlog.

Guardrails worth knowing:

- **The stitching contract is enforced, not requested.** Every sentence of a
  candidate is searched for in the corpus (`verbatim_gate`): a candidate with
  any model-written sentence longer than glue (`GLUE_MAX_WORDS`), or with more
  glue than `VERBATIM_MIN` allows, is rejected whole. Accepted posts get a
  per-sentence provenance report in `Posts/.provenance/<id>.md` — which note
  each sentence came from, and what little glue was added — the posts'
  equivalent of the drafts' `changes.diff` (laptop-only: it quotes pre-alias
  text, so it is stignored).
- **A sentence mostly carries one post — per kind, and only once you keep it.**
  Sentences stitched into a post in `Keep/` are claimed for that post's kind
  only: a sentence spent on a long is still fair game for a short, and vice
  versa — only same-kind repetition is damped. Each claim is enforced
  `REUSE_DROP_PCT`% of the time (75; one die per sentence per run), so an
  iconic line still resurfaces now and then. A sentence claimed by *both*
  kinds is hidden from the corpus as a `[…]` hole the model is told not to
  bridge; one claimed by a single kind stays visible but is listed as a
  RESERVED SENTENCE in the prompt, and a candidate that reuses it in a post of
  the same kind is rejected by the gate. Sentences under `REUSE_MIN_WORDS` (6)
  words are never claimed.
  **Only `Keep/` claims.** A candidate sitting in the pool does not: it is
  disposable by design — it ages out, the curator evicts it, or you never read
  it — and a sentence must not be locked away by a post that was never chosen.
  So a line in today's pool stays available for tomorrow's better stitching of
  the same idea; what stops the *pool* repeating itself is the cap and the
  curator's near-duplicate eviction, which read the candidates rather than
  hiding the material. `Discarded/` and `Rejected/` claim nothing either: a
  sentence spent on a post that died returns to circulation.
  A `Keep/` post with no provenance report would claim nothing at all — the
  silent failure in the worst direction — so any that lacks one (posts written
  before provenance existed) has it rebuilt at the start of the run by
  re-matching the post against the corpus. The rebuilt file says so in its
  header: it is approximate, since a sentence carrying an aliased name or a
  since-reworded source will not match, and unmatched sentences claim nothing.
- **Rejections are never silent.** A gate-rejected candidate is kept in
  `Posts/Rejected/` (synced to the phone, aged out after `REJECT_DAYS`) with
  its gate report appended, logged to `logs/gate.tsv`, counted in the desktop
  notification, and fed back to the next generation call as an error log. Read
  the rejects now and then: if you keep liking them, lower `VERBATIM_MIN`.
- **Names are anonymized with per-post random aliases.** If
  `private/aliases.tsv` exists (gitignored; `Real Name<TAB>alias1, alias2,
  alias3`), each candidate draws one alias per person from the pool — the same
  person reads differently from one post to the next, so posts can't be joined
  up. The draw avoids the previous post's pick, stays consistent within a
  post, and is an exact-substring replacement by the script, never a model
  edit. Notes, drafts and the corpus keep the real names; aliases apply at the
  boundary where text leaves the private tree. Give each person 3+ plausible
  aliases; fictional or merged characters are fine — the pipeline neither
  knows nor cares.
- A candidate citing fewer than two **existing** source files is rejected — an
  invented source is the tell that the post is invented too.
- The generator is explicitly allowed to return nothing, and told that forcing a
  connection between unrelated notes is worse than silence.
- `Posts/` sits inside the vault but is excluded from the corpus, so the job can
  never read its own output back in as source material.
- If the curator's answer doesn't validate (wrong count, unknown id), the script
  falls back to keeping the newest N. The cap is honoured either way.
- Generation runs every run, even with no new notes — the corpus is a different
  lens each day (reuse holes fall differently, the over-budget sample rotates),
  so unchanged notes can still yield a stitching yesterday couldn't see.

## Provenance

Every artifact records the configuration that produced it — not only when an
experiment is running. A run with no profile is still a variant; it is just the
one called `default`. Three places carry the stamp, each chosen for how it
survives:

- **`drafts/<bundle>/meta.json`** — the full record beside the artifacts it
  explains: run id, pipeline commit, config fingerprint and every resolved knob,
  the model, each prompt by name *and* content hash (anchor and directive
  included), the input by content hash (audio, verbatim), and what the transform
  cost — chars in/out, wall clock, and **churn %**: the word-level edit distance
  from `verbatim.md` to `cleaned.md`, as a share of their combined length. That
  last number is how "did the looser cleanup prompt actually rewrite more?"
  gets answered without reading a single diff by hand.
- **Frontmatter** on every candidate post: `variant:`, `persona:`, `run:`.
  Frontmatter because it survives the trip to the phone and the move into
  `Keep/` — and that move is the datum the online scorer reads. The filename and
  the body stay unbranded, so reading the pool stays blind.
- **`logs/provenance.tsv`** — one row per artifact (timestamp, run, kind, path,
  variant, persona, input hashes): what exists, and where it came from.
  `logs/usage.tsv` keeps its own job as the per-call token ledger; the two join
  on the run id.

Provenance reports in `Posts/.provenance/` gain the same three keys plus the
prompt hashes as a comment header. `bin/reclean.sh` re-stamps the bundles it
touches (a recleaned `cleaned.md` was produced by *today's* configuration, and
says so, while keeping its original `first_seen`), and a `Keep/` post whose
report has to be reconstructed is honestly labelled `variant: pre-experiment`
rather than being counted as whatever runs today.

## Statistics

`bin/stats.sh` prints the pipeline at a glance: pool/Keep/Discarded/Rejected
counts, material totals, the stitching gate's pass rate over time (from
`logs/gate.tsv`, one row per candidate), and rough Claude usage (from
`logs/usage.tsv`, one row per call with stream sizes). Token figures are
estimates — chars/4, excluding the CLI's own per-call overhead — good for a
gut feeling, not a bill.

Every successful daily run also snapshots this page to
`logs/stats/<date>.txt` (`latest.txt` points at the newest; a year is kept).
Like everything in `logs/`, snapshots are gitignored and never leave the
laptop.

The same run writes **`STATS.md` in the repo root** — the one copy that is not
gitignored, so the state of the pipeline is visible in the repo itself. Because
it gets committed it uses the `--public` view: post titles are omitted, since
`logs/gate.tsv` records them *pre-alias* (the gate runs before anonymization)
and a title can carry a real name. Regenerate it any time with
`bin/stats.sh --write`; it changes on most runs, so expect it in `git status`.

## Configuration (environment)

All optional; sensible defaults are baked in. Every knob below is resolved in
one place — **`lib/config.sh`**, sourced by each script — which also adds three
things no single script could:

- **A re-rootable tree.** Every data path hangs off `BLOG_ROOT` (default: the
  repo) and is individually overridable (`BLOG_DRAFTS=…`, `BLOG_LOGS=…`).
  Export one variable and a whole run happens in a sandbox, never touching the
  live `drafts/`, `processed.tsv`, or the phone.
- **A prompt overlay.** `PROMPTS_DIR=<dir>` is searched before `prompts/`, so a
  prompt variant is a directory holding only the file it changes. Individual
  prompts can also be pinned (`SUGGEST_PROMPT=…`, `CLEANUP_PROMPT=…`, `ANCHOR=…`).
- **Profiles.** `BLOG_PROFILE=<name>` applies `profiles/<name>.env` before the
  defaults, so a profile states only its deltas. `profiles/default.env` is the
  documented inventory of every knob there is. Precedence, highest first: the
  environment, the profile, the defaults.

```sh
lib/config.sh paths                       # where this configuration reads and writes
lib/config.sh dump                        # the resolved configuration, sorted
lib/config.sh fingerprint                 # 12 hex characters identifying it
BLOG_PROFILE=personas lib/config.sh dump  # ... under a profile
```

The **fingerprint** hashes the dump — models, knobs, and prompt *contents*, but
never paths — so two runs with the same fingerprint are the same variant
whatever the profile was called, and a sandbox copy of a variant fingerprints
identically to the live one. It is what provenance stamps on every artifact
(see *Provenance*), and `tests/check_defaults.sh` asserts, value by value, that
a profileless run still resolves to exactly the numbers below.

- `STRUCTURE=1` — also emit a `structure.md` outline per bundle (extra Claude call).
- `WHISPER_MODEL` / `WHISPER_LANG` / `WHISPER_THREADS` / `WHISPER_BIN` — tune STT
  (default language is `auto`, for the author's EN/DE/Denglisch mix).
- `SYNC_KEEP_DAYS` (14) — days a processed recording and its transcript linger
  in `sync/` (i.e. on the phone) before the reaper removes them.
- `TRANSCRIBE` / `CLAUDE_BIN` / `NOTIFY` — swap the backend commands (used by the
  test harness, and if you ever replace whisper.cpp).
- `NOTES_DIR` / `EDITOR` — where `bin/note.sh` writes, and what it opens.

`bin/suggest.sh` only:

- `MAX_LONG` (4) / `MAX_SHORT` (8) — how many suggestions of each kind survive.
- `MAX_NEW` (8) — how many candidates one run may propose. This is a ceiling,
  but `prompts/suggest.md` also tells the curator to keep looking until it hits
  the ceiling or runs out of genuine convergences — so lowering it is the way to
  ask for less, and the prompt bullet is the way to change how hard it reaches.
- `TRASH_DAYS` (14) — how long an evicted suggestion stays in `Posts/Discarded/`.
- `CORPUS_MAX` (150000) — char budget for the notes fed to Claude. When over
  budget, the newest notes get ~70% and the rest is filled with a random sample
  of the older ones, so old material still gets a chance to converge with new;
  the run logs how many were omitted.
- `ARCHIVE_DAYS` (14) — root notes older than this move to `Obsidian/Archive/`
  with a dated, titled name.
- `VERBATIM_MIN` (85) / `GLUE_MAX_WORDS` (12) — the stitching gate: minimum
  share of verbatim sentences per candidate, and the longest a non-verbatim
  (glue) sentence may be.
- `NEW_SLACK_EVERY` (25) — proportional mercy: one model-written sentence is
  tolerated per this many sentences of post, so a single slip can't sink a
  long post while shorts stay at zero.
- `REJECT_DAYS` (30) — how long gate-rejected candidates stay in `Posts/Rejected/`.
- `REUSE_MIN_WORDS` (6) / `REUSE_DROP_PCT` (75) — sentence-reuse damping: shorter
  sentences are always free; longer ones already in a live post are enforced
  against new posts *of the same kind* this often.
- `ALIASES` (`private/aliases.tsv`) — real-name → alias-pool map; one alias is
  drawn per person per post.
- `TYPO_FIX` (1) — proofread each typed note once, in place, before the corpus
  is read; `0` turns the stage off entirely.
- `TYPO_MODEL` (`claude-sonnet-5`) — the typo pass is the most mechanical call
  in the pipeline, so it does not run on the curator's model.
- `TYPO_MIN_LEN` (4) — words shorter than this are never "corrected": that is
  where acronyms and shorthand live (`wbe`, `tbh`).
- `TYPO_MAX_PCT` (5) — most of a note a single pass may change, minimum 3 words.
  Above it the whole note is rejected: that is a rewrite, not proofreading.

## Status

**Live** (phases 1–4). Running on the ThinkPad: `install.sh` done (ffmpeg +
whisper.cpp + large-v3-q5_0 model, `-mc 0` anti-repetition), the systemd user timer fires every
15 min, and Syncthing runs as a `--user` service feeding `sync/` from the phone
(Fossify Voice Recorder). First real memos processed 2026-07-28; see `SETUP.md`
for the operating commands, benchmark, and the macOS migration.

Privacy is enforced, not just promised: `tests/check_privacy.sh` — run as a
pre-commit hook — fails any commit that would track a file under the personal
paths (`sync/`, `drafts/`, `private/`, …), any audio file, a weakened
`.gitignore`, or staged text containing a private marker.
