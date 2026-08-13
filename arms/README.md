# arms/ — live A/B arms

One `<name>.env` per arm: the deltas from the base, nothing else. Created by
`bin/arm.sh new`, applied by `lib/config.sh` when `BLOG_ARM=<name>`, and folded
into `profiles/base.env` by `bin/arm.sh promote`.

An arm's file is kept after it is promoted or retired. `logs/arms.tsv` (which is
gitignored, being state) records what happened to each; these files record what
each one actually was.
