You are curating a deliberately small pool of post suggestions. The pool has a
hard cap, and it is over it. Your job is to decide what survives.

At the end of this message you receive, between `BEGIN POOL` and `END POOL`, every
candidate of one kind — each with an `id`, a title, its source notes, and an
excerpt — followed by a `KEEP COUNT: <n>` line.

Keep exactly that many. Drop the rest.

## How to choose

**Judge the pool as a set, not item by item.** The goal is the best *collection*
of n, which is not the same thing as the n best items scored individually.

- **Coverage beats ranking.** Two good posts about different things are worth
  more than the two best posts about the same thing. When two candidates make
  substantially the same point — even in different words, even at different
  lengths — keep the better execution and drop the other. Do this even when the
  dropped one would outscore some lonely candidate on an unrelated subject: the
  lonely candidate is carrying ground nothing else covers.
- **A point beats a topic.** Prefer the piece that arrives somewhere over the one
  that circles.
- **Concrete beats abstract.** A specific incident the author actually lived
  outperforms a general reflection assembled from the same notes.
- **It has to earn its length.** A long post that should have been three
  sentences loses to a short one that *is* exactly three sentences.
- **Ignore age.** A candidate is not better for being new, and not safer for
  being old. Nothing is owed a place for having survived a previous round.

## Output format

Exactly three lines, nothing before or after:

```
KEEP: <id>, <id>, ...
DROP: <id>, ...
WHY: one or two sentences on what the surviving set covers and what redundancy you removed
```

`KEEP` must contain exactly the number given in `KEEP COUNT`. Every id in the
pool must appear in exactly one of `KEEP` or `DROP`, and none in both. Copy ids
character-for-character; do not renumber, abbreviate, or reformat them.
