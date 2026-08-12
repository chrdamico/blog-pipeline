# Prompt overlays

An overlay is a directory that contains **only the prompt files it changes**.
`PROMPTS_DIR=<dir>` puts it in front of `prompts/`, so everything it does not
contain keeps coming from there:

```sh
cp prompts/suggest.md profiles/overlays/curator-prompt/suggest.md
$EDITOR profiles/overlays/curator-prompt/suggest.md
BLOG_PROFILE=curator-prompt bin/suggest.sh
```

Any of the seven prompt files can be overlaid: `cleanup.md`, `structure.md`,
`suggest.md`, `curate.md`, `typos.md`, `names.md`, `style-anchor.md`.

The config fingerprint follows prompt **content**, not path — so two overlays
holding the same bytes are one variant, and editing an overlay makes a new one
the moment you save. That is why every post stamped with a fingerprint can be
traced back to the exact prompt that produced it, and why an overlay is worth
keeping in git once an experiment says it won.

`curator-prompt/` is empty on purpose: the prompt it would hold is yours to
write, and an empty overlay resolves to exactly the shipped prompts.
