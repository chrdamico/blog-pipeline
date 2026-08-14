# arms/ — live A/B arms

One `<name>.env` per arm: the deltas from the base, nothing else. Created by
`bin/arm.sh new`, applied by `lib/config.sh` when `BLOG_ARM=<name>`, and folded
into `profiles/base.env` by `bin/arm.sh promote`.

**Everything in here is running.** An arm's file is deleted the moment the arm
stops — `promote` folds its deltas into `profiles/base.env` and removes it,
`retire` removes it and takes any directive or overlay nothing else points at
with it. So the answer to "what is live?" is `ls arms/`, with no dates to read
and no status to look up.

The history lives in two other places, which is why it does not need to live
here. `logs/arms.tsv` keeps a row per arm forever — created, status, and the
question it was asking — so `bin/arm.sh list` still shows what you tried. And
git keeps the file, so `git log -- arms/<name>.env` says what was in it.
