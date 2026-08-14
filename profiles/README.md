# profiles/ — configuration, sorted by whether it is running

Four directories hold text that reaches a model or sets a knob, and the question
that used to be hard to answer by looking — *is this thing live?* — is now
answered by which directory a file is in.

```
prompts/            THE PIPELINE. One standing instruction per stage, always in
                    the stream, live by definition. Editing one changes every
                    run tonight.

profiles/           THE FLOOR AND THE MAP.
  base.env            what the base has been promoted to. LIVE under every run,
                      arms included. Written only by `bin/arm.sh promote`.
  default.env         every knob at its shipped value: an inventory to read, a
                      no-op to run (tests/check_defaults.sh pins that).
  directives/         the second prompt slot. ONLY files that base.env or a
                      running arm points at — so everything here is live.
  overlays/           a live arm's full copy of a prompt file, when it needs the
                      base prompt to say something different.

profiles/offline/   NOT RUNNING UNLESS YOU NAME IT. Profiles you reach by
                    `BLOG_PROFILE=<name>` or by an `.exp` variant, plus the
                    directives, overlays and persona tables only they use. A
                    bare profile name resolves here too, so an experiment
                    definition does not care that the file moved.

arms/               THE LIVE EXPERIMENTS. One <name>.env of deltas per arm that
                    runs tonight beside the base — and nothing else: promoting
                    or retiring an arm deletes its file (see arms/README.md).

eval/experiments/   the `.exp` definitions bin/ab.sh runs offline. The rest of
                    eval/ is your memos and your posts, and is gitignored.
```

Two rules keep it true, and `tests/check_layout.sh` enforces both:

1. **Nothing under `profiles/directives/`, `profiles/overlays/` or `arms/` is
   unreferenced.** A file that nothing points at is the failure this layout
   exists to prevent: it reads as live, it is not, and you cannot tell which by
   looking. When an arm is retired its directive goes with it.
2. **Nothing live points into `profiles/offline/`, and nothing offline points
   out of it.** The moment a sandbox-only directive becomes the base's standing
   instruction, `bin/arm.sh promote` is the thing that moves it.

`bin/brief.sh` prints the same inventory with each file's status resolved from
the configuration a run would actually use, which is the version to trust.
