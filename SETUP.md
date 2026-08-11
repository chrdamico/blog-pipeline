# blog-pipeline — setup

One-time setup: install, add a style anchor, pair the phone, test. Everything
here is manual on purpose — the pipeline itself is automated, but pairing and
personalisation are yours to do once.

## 1. Install

```sh
./install.sh
```

This is idempotent (safe to re-run). It:

- checks for `git`, `claude` (Claude Code, signed in with your **subscription** —
  no API key is ever used), and `curl`;
- installs `ffmpeg` via your package manager (needs `sudo` on Linux; `brew` on macOS);
- builds `whisper.cpp` from source into `vendor/` (or `brew install whisper-cpp`
  on macOS) and links it to `bin/whisper-cli`;
- downloads the `large-v3-q5_0` model into `models/` (~1.1 GB, once) and
  records its SHA-256 for future integrity checks;
- installs the schedulers — on Linux two **systemd user timers**
  (`blog-pipeline`, every 15 min; `blog-suggest`, daily at 03:00), on macOS the
  two equivalent **launchd agents**.

Model integrity: the first download records a checksum. To pin a known-good hash,
re-run once with `WHISPER_MODEL_SHA256=<hash> ./install.sh`. Deps only, no
scheduler: `SKIP_SCHEDULER=1 ./install.sh`.

Once installed, the steady state is fully hands-off: any audio Syncthing drops
into `sync/` becomes a draft bundle within 15 minutes, and overnight the
suggestion job turns your accumulated notes into candidate posts. Check on it:

```sh
systemctl --user list-timers 'blog-*'               # when they last/next fire
journalctl --user -u blog-pipeline.service -n 50    # what the last run did
journalctl --user -u blog-suggest.service -n 50
tail -f logs/process.log logs/suggest.log           # live logs
systemctl --user start blog-pipeline.service        # process right now, don't wait
systemctl --user start blog-suggest.service         # suggest right now
```

Re-runs are safe (idempotent): already-processed audio is skipped by content
hash, so an overlapping timer fire while a batch is running is a no-op.

## 2. Style anchor (strongly recommended)

Copy `prompts/style-anchor.example.md` to `prompts/style-anchor.md` and paste
2–3 paragraphs of your own writing into it. The real file is **gitignored** —
your writing sample stays on this machine. **Every** step reads that one file,
so it is the only place you need it.

For cleanup it is a nice-to-have — that step doesn't rephrase anything, so an
empty anchor costs you little. For **post suggestions it is the whole ballgame**:
generation writes new prose, and without a sample to anchor to it will read like
generic LLM blogging. If you do one manual thing before enabling `blog-suggest`,
do this one.

## 3. Pair the phone (one folder for everything)

Goal: **one** Syncthing folder — `/blog` on the phone, `sync/` here — carrying
recordings, notes, and post suggestions alike. Its shape:

```
/blog                    (phone)   ==   sync/            (laptop)
├── 20260811_0814.m4a               ├── 20260811_0814.m4a    recordings, at the root
└── Obsidian/                       └── Obsidian/            the notes vault
    ├── my-note.md                      ├── my-note.md       notes (.md or .txt)
    └── Posts/                          └── Posts/           generated suggestions
        └── Keep/                           └── Keep/        the ones you rescue
```

Recordings sit at the root and the vault is a subdirectory, which is what keeps
the two apart: `bin/process.sh` scans for audio **non-recursively**, so it never
sees the vault, and Obsidian never sees the `.m4a` files.

**On the phone**

1. Install **Fossify Voice Recorder** and **Syncthing-Fork** (Catfriend1) — both
   on F-Droid (Syncthing-Fork is also on the Play Store). Use *Syncthing-Fork*,
   not the old "Syncthing-Android" by Nutomic, which is discontinued.
2. In Fossify → Settings, set the **save folder** to `/blog` (the folder you are
   about to share). Prefer a compressed format (m4a/opus) to keep syncs small.
3. In Syncthing, **Add Folder** and point it at `/blog`. Note its Folder ID.

**On this machine**

4. Install Syncthing on the laptop (`sudo apt install syncthing`; `brew install
   syncthing` on the Mac) and run it **as a background service** so you never
   start it by hand:

   ```sh
   systemctl --user enable --now syncthing.service   # start now + on every login
   loginctl enable-linger "$USER"                     # keep syncing even when logged out
   ```

   It then runs continuously — syncing within a minute or two of a new recording
   and idling (~40 MB RAM, ~0 CPU) otherwise. There is no schedule to set; "always
   on, syncs on change" is the design. Manage it via the web UI
   <http://127.0.0.1:8384> or `systemctl --user status|restart|stop syncthing.service`.
   (If you had a manual `syncthing` running, `pkill syncthing` first so the service
   can take over the ports; it reuses the same config, so your pairing is kept.)
5. **Add Remote Device** → scan/enter the phone's device ID (Syncthing shows a QR
   under *Actions → Show ID*). Approve the pairing on both ends.
6. **Add Folder** with the *same Folder ID* as step 3, and set its path to this
   repo's `sync/` directory. Accept the shared folder when the phone prompts.
7. Leave both sides **Send & Receive**. This is required, not optional: notes and
   post suggestions have to travel laptop→phone, so the folder cannot be
   receive-only.
8. Turn on **file versioning** (Simple, keep 5) on the laptop side. Two-way sync
   means a mis-tap on the phone can delete a note here too; versioning is the
   cheap insurance against that.

**How long things stay on your phone.** Two-way sync means the phone mirrors
`sync/`, so anything deleted here eventually disappears there. The pipeline gives
you a grace period rather than deleting on the spot:

| What | On the phone for | Then |
|------|------------------|------|
| a processed recording | `SYNC_KEEP_DAYS`, default **14 days** | reaped from `sync/`; the copy in `drafts/<date>-<slug>/` is permanent |
| its transcript (`<recording>.md`, written next to the audio) | the same 14 days | reaped with the recording, as a pair |
| an evicted post suggestion | `TRASH_DAYS`, default **14 days** in `Posts/Discarded/` | deleted |
| a note you wrote | forever | only you delete it |

The retention clock starts at **processing**, not at recording, so a memo that
syncs across days later still gets its full window.

This does not weaken the "raw audio is the permanent source of truth" pillar,
because `drafts/` is the archive and `sync/` is only the conveyor belt. What
expires is a transport copy, and only ever after its hash is recorded in
`logs/processed.tsv` — an unprocessed recording is never reaped, however old.

Want a different window? `SYNC_KEEP_DAYS=30 bin/process.sh`, or set it in the
service unit. Want recordings kept on the phone indefinitely? Set **Ignore
Delete** on the *phone-side* folder — at the cost that deletions you make on the
laptop stop reaching the phone at all.

Now a recording on the phone lands in `sync/` within a minute or two of both
devices being online. The pipeline is E2E-encrypted phone↔laptop via Syncthing;
no third party sees the audio. Only cleaned/verbatim **text** leaves the machine,
and only to Anthropic via `claude -p`.

## 4. Text notes (the `Obsidian/` vault)

Voice memos land at the root of `sync/` and become drafts. Typed notes are a
separate space with no pipeline attached: they live at the root of
`sync/Obsidian/` as plain `.md` or `.txt` files and stay exactly as written.
Two-way, so you can write on either end and the other gets it.

**Pick an app on the phone** — any editor that writes plain `.md` into a folder
you choose works; the folder is the interface, so you can swap apps later
without migrating anything. On the Play Store:

| App | Why / why not |
|-----|---------------|
| **Obsidian** *(recommended)* | Free, offline, no account needed. A "vault" is just a folder of `.md`. Best-maintained of the lot and the well-trodden Syncthing path. Ignore every sync/plugin prompt — you need none of it. |
| **Zettel Notes** | Lighter and closer to "no-frills"; one `.md` per note in a folder you pick. Smaller project, busier UI. |
| ~~Markor~~ | The usual recommendation and genuinely the simplest, but F-Droid only — not on the Play Store. |

Obsidian, from install to typing: open it → *Create new vault* → **"Open folder
as vault"** → pick **`/blog/Obsidian`** → start typing. Turn off *Settings →
Files & Links → Use [[Wikilinks]]* if you want the files to stay plain markdown
that any other editor reads identically.

**Wire it up** — nothing to pair. §3 already shares the whole folder, so the
vault comes along with it. On the phone, point the editor at `/blog/Obsidian`;
that is the entire step. Pick `Obsidian` as the vault root, **not** `/blog`
itself: the vault must not contain the recordings.

`sync/.stignore` keeps Obsidian's per-device workspace state from syncing — that
state is rewritten every time either device opens the app, and syncing it is the
main source of `.sync-conflict` files. It deliberately does **not** hide
`Posts/Discarded/`: evicted suggestions sync to the phone so you can still read
them, or move one back out to rescue it. Syncthing picks the file up
automatically.

If a conflict does happen (both devices edited the same note while offline),
Syncthing never loses data: it writes the loser as
`<name>.sync-conflict-<date>-<device>.md` next to the winner. Diff and delete.

**Capturing from the laptop**

`bin/note.sh` is the same idea in a terminal — no app, no daemon, just files:

```sh
bin/note.sh                      # opens $EDITOR; the filename comes from line 1
bin/note.sh remember to cancel the domain renewal
echo "clipboard thought" | bin/note.sh
bin/note.sh -l                   # list recent notes
bin/note.sh -e domain            # reopen the newest note matching "domain"
```

Notes are named `sync/Obsidian/<date>-<slug>.md`, the same convention as draft
bundles. Nothing is ever overwritten (collisions get `-2`, `-3`), and an editor
session left empty writes no file. `-l` and `-e` list `.txt` as well as `.md`, so
notes typed on the phone show up too — whatever extension its editor chose.

**Moving your Keep notes over:** with the folder synced, export or copy/paste
each note into a new note in the phone app — or paste them on the laptop with
`bin/note.sh` and let Syncthing push them to the phone, which is faster for
anything long. Keep's own export (Google Takeout) gives you HTML/JSON rather
than clean markdown, so for a handful of notes manual is genuinely less work.

## 5. Post suggestions (`Posts/` → your phone)

`bin/suggest.sh` reads the whole corpus (voice drafts + typed notes), finds where
two or more notes converge, and writes candidates into `sync/Obsidian/Posts/`,
which Obsidian on the phone shows as a folder alongside your notes. See the
README for the mechanics; this is the part that needs *you*.

**The loop, from your side**

1. Overnight the job writes up to 5 candidates — `long` (a 400–900 word post) and
   `short` (40–120 words, publishable as a tweet or Substack note).
2. Over coffee, read them in Obsidian.
3. Anything you'd actually publish: **long-press → Move → `Posts/Keep/`**. That
   is the whole interaction, and the only signal the system takes from you.
4. Everything you don't rescue stays in the pool and competes. When the pool
   overflows its cap, losers move to `Posts/Discarded/` — which syncs to your
   phone, so you can still read them (or move one back out) — and are gone in
   14 days.

`Keep/` is invisible to the job — never re-judged, never evicted, never counted
against the cap. That asymmetry is the point: the pool is a rotating tray the job
may clear, `Keep/` is the shelf, and moving a file is how you promote one to the
other. Not deciding about a suggestion is a valid outcome; ignoring it *is* the
rejection.

**Before you enable it,** do §2 (the style anchor). Generation writes new prose,
and an unanchored run reads like generic LLM blogging.

**Running it**

```sh
bin/suggest.sh                              # now, with the defaults
MAX_NEW=1 MAX_LONG=2 MAX_SHORT=4 bin/suggest.sh
systemctl --user enable --now blog-suggest.timer    # let it run daily at 03:00
systemctl --user disable --now blog-suggest.timer   # stop it again
tail -f logs/suggest.log
```

`logs/suggested.tsv` records every candidate ever written (kind, title, sources),
and is fed back to the generator so it doesn't restitch the same notes forever.
Deleting a suggestion by hand is always safe: the job re-reads the directory each
run and never assumes a file it wrote is still there.

Sensible first tuning: if the pool feels crowded, lower `MAX_LONG`/`MAX_SHORT`
rather than `MAX_NEW` — a smaller cap means the curator has to make sharper
choices, which is where the quality comes from.

## 6. Test it (no phone needed)

Synthesize a short memo with `espeak` and run the pipeline once:

```sh
espeak -w sync/test-memo.wav \
  "Today I want to talk about, um, the future of dictated writing, \
   and why raw audio should stay the source of truth."
bin/process.sh
tail -n 40 logs/process.log
ls drafts/*/
```

You should get `drafts/<today>-<slug>/` containing the audio, `verbatim.md`,
`cleaned.md`, and `changes.diff`, plus a desktop notification. Re-running
`bin/process.sh` does nothing (idempotent). Delete the test bundle afterward if
you like — nothing else references it.

Optional structure outline (a separate `structure.md`, never merged into the
cleaned text):

```sh
STRUCTURE=1 bin/process.sh
```

## 7. Notifications from the timers

`bin/notify.sh` uses `notify-send` (Linux) / `osascript` (macOS). When run from
the systemd **user** timer, `notify-send` needs the session bus. Most desktops
import it automatically; if a draft is created but no popup appears:

```sh
systemctl --user import-environment DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
systemctl --user restart blog-pipeline.timer
```

Useful checks:

```sh
systemctl --user status blog-pipeline.timer
systemctl --user list-timers blog-pipeline.timer
journalctl --user -u blog-pipeline.service -n 50
systemctl --user start blog-pipeline.service   # run once, now
```

## 8. Benchmark

whisper.cpp, CPU-only, on a real 10-min memo (603 s of audio), measured 2026-07-29:

| Model (this laptop, i7-1260P, 16 thr) | Transcription time | Notes |
|---------------------------------------|--------------------|-------|
| `large-v3-q5_0` **(default)** + `-mc 0` | ~590 s (≈1.0× RT) | robust, best multilingual |
| `large-v3-turbo-q5_0` + `-mc 0`         | ~383 s (≈0.64× RT) | faster, weaker; kept only as a speed fallback |
| (future) M3/M4 Mac (Metal)              | _TODO_             | expect several× faster |

So on this laptop a memo transcribes in roughly its own length — a 20-min memo
is ~20 min of CPU. Fine unattended (the timer runs it in the background); it's
why the pipeline is batch, not live.

**Why `-mc 0` (max-context 0):** without it, Whisper conditions each window on
its previous output and can fall into a runaway repetition loop over a pause or
noise — overwriting real speech (a 10-min memo once produced "She's doing it"
×13 in place of ~1.5 KB of words). `-mc 0` stops that carry-over; the loss is
minor cross-window continuity, well worth the robustness. Raw audio is kept, so
any older memo can be re-transcribed with the current settings at any time.

**Why full `large-v3`, not `turbo`:** turbo is ~1.5× faster but hallucinates
these loops more and is weaker on German/Italian. To switch back per-run:
`WHISPER_MODEL=models/ggml-large-v3-turbo-q5_0.bin bin/process.sh`.

## 9. Migration to macOS (later)

The design goal: **copy the folder, install, delete the old one.**

1. Copy the entire `blog-pipeline/` tree to the Mac (includes `models/`, so no
   re-download; excludes nothing you need — `sync/`, `drafts/`, `logs/` come
   along if you want your history).
2. Install Claude Code on the Mac and sign in (subscription).
3. Run `./install.sh` — it detects macOS, uses `brew` for `ffmpeg`/`whisper-cpp`,
   and loads `watcher/com.christian.blog-pipeline.plist` as a launchd agent.
   (That plist is written but **untested** on Linux; verify it loads with
   `launchctl list | grep blog-pipeline`.)
4. Re-pair Syncthing on the Mac, pointing the shared folder at the new `sync/`.
5. On the old laptop: `systemctl --user disable --now blog-pipeline.timer`,
   remove `~/.config/systemd/user/blog-pipeline.*`, then delete the folder.

Everything personal lived under this one tree, so eviction is clean.
