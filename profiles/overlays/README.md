# Prompt overlays

An overlay is a directory that contains **only the prompt files it changes**.
`PROMPTS_DIR=<dir>` puts it in front of `prompts/`, so everything it does not
contain keeps coming from there:

```sh
mkdir -p profiles/overlays/<arm>
cp prompts/suggest.md profiles/overlays/<arm>/suggest.md
$EDITOR profiles/overlays/<arm>/suggest.md
bin/arm.sh new <arm> PROMPTS_DIR='$BLOG_REPO_DIR/profiles/overlays/<arm>' …
```

Any of the five prompt files can be overlaid: `cleanup.md`, `suggest.md`,
`curate.md`, `typos.md`, `names.md`.

The config fingerprint follows prompt **content**, not path — so two overlays
holding the same bytes are one variant, and editing an overlay makes a new one
the moment you save. That is why every post stamped with a fingerprint can be
traced back to the exact prompt that produced it, and why an overlay is worth
keeping in git once an experiment says it won.

This directory is for a **live arm's** overlay, and it is empty until an arm
needs one — which is the point at which an arm has to make the base prompt say
something different, rather than adding a directive that cancels it (CLAUDE.md
spells out why that distinction matters). An overlay belonging to an offline
experiment lives in `profiles/offline/overlays/` instead, next to the profile
that names it.

Whatever is here is therefore live, and `tests/check_layout.sh` fails if it is
not: an overlay directory nothing points at is exactly the file that reads as
running and is not.
