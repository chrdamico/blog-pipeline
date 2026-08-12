#!/usr/bin/env bash
#
# score.sh — what the live pool says. (`bin/ab.sh score` is the same command.)
#
# The offline runner measures what is measurable: how much a variant rewrote,
# what the gate said, what it cost. None of that answers the question a curator
# experiment is actually about — is this a better post? — because no judge in a
# sandbox knows your taste.
#
# The thing that does know is you, every morning, on the phone. A candidate that
# earns its keep gets moved into Posts/Keep/; one that doesn't gets evicted by
# the curator into Discarded/, or ages out of the pool unread. That decision is
# free, it is already happening, and since M2 every candidate carries the
# variant and persona that produced it in its frontmatter — so the decisions can
# be counted per variant without changing one thing about how you read.
#
# This joins three sources:
#
#   the tree           where each post is NOW (pool, Keep/, Discarded/, Rejected/)
#                      and, from its frontmatter, which variant and persona made it
#   logs/provenance.tsv what was ever proposed, when, and by which variant —
#                      including the posts that have since aged out entirely
#   logs/suggested.tsv  the running record of accepted suggestions
#
# Usage:
#   score.sh              per variant
#   score.sh --personas   per persona instead (for a persona experiment)
#   score.sh --since 2026-08-01
#   score.sh --posts      one line per post, for reading by hand or by awk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"

GROUP=variant
SINCE=""
MODE=summary
while [ "$#" -gt 0 ]; do
  case "$1" in
    --personas) GROUP=persona; shift ;;
    --variants) GROUP=variant; shift ;;
    --since)    SINCE="$2"; shift 2 ;;
    --posts)    MODE=posts; shift ;;
    -h|--help)
      sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'score: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

fm() {   # $1 file, $2 key — frontmatter only
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1  && $0 == "---" { exit }
    NR > 1 { if (index($0, k ": ") == 1) { print substr($0, length(k) + 3); exit } }' "$1"
}

file_date() { date -d "@$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1")" '+%Y-%m-%d' 2>/dev/null \
                || date -r "$(stat -f %m "$1")" '+%Y-%m-%d'; }

# --- one row per post that still exists --------------------------------------
# state  variant  persona  created  state_date  id
#
# A post's identity is its basename: the pipeline never renames one, it only
# moves it between Posts/, Keep/ and Discarded/ — which is exactly what makes
# the move readable as a verdict.
posts_tsv() {
  local f state dir variant persona created sdate id
  shopt -s nullglob
  for dir in "$POSTS" "$POSTS/Keep" "$TRASH" "$REJECTED"; do
    case "$dir" in
      "$POSTS")    state=pool ;;
      "$POSTS/Keep") state=kept ;;
      "$TRASH")    state=evicted ;;
      "$REJECTED") state=rejected ;;
    esac
    for f in "$dir"/*.md; do
      id="$(basename "$f" .md)"
      variant="$(fm "$f" variant)"; [ -n "$variant" ] || variant=pre-experiment
      persona="$(fm "$f" persona)"; [ -n "$persona" ] || persona='(none)'
      created="$(fm "$f" created)"; [ -n "$created" ] || created="$(file_date "$f")"
      # mtime means different things by directory, and both are the ones we
      # want: eviction resets it in Discarded/, so it dates the eviction.
      sdate="$(file_date "$f")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$variant" "$persona" "$created" "$sdate" "$id"
    done
  done
  shopt -u nullglob
}

# --- one row per post that no longer exists ----------------------------------
# Aged out of Discarded/ after TRASH_DAYS, or deleted by hand. A loss, and one
# that would otherwise quietly improve every variant's numbers by disappearing.
# Only candidates: a gate-rejected proposal ageing out of Rejected/ is not a
# judgement you made, and it is already counted in the rejected column.
#
# All of it in awk, because `read -r` with IFS=$'\t' silently collapses two
# adjacent tabs into one — and the empty field between them is the persona.
gone_tsv() {
  [ -s "$PROVENANCE_TSV" ] || return 0
  { ls "$POSTS"/*.md "$POSTS"/Keep/*.md "$TRASH"/*.md "$REJECTED"/*.md 2>/dev/null || true; } \
    | sed 's#.*/##; s#\.md$##' | sort -u > "$tmp/live_ids"
  awk -F'\t' '
    NR == FNR { live[$0] = 1; next }
    $3 != "candidate" { next }
    {
      id = $4; sub(/.*\//, "", id); sub(/\.md$/, "", id)
      if (id in live) next
      d = substr($1, 1, 10)
      printf "gone\t%s\t%s\t%s\t%s\t%s\n", $5, ($6 == "" ? "(none)" : $6), d, d, id
    }' "$tmp/live_ids" "$PROVENANCE_TSV"
}

# What was ever proposed, per group — the denominator the tree cannot supply,
# because a rejected candidate that has aged out left nothing behind but this.
proposed_tsv() {
  [ -s "$PROVENANCE_TSV" ] || return 0
  awk -F'\t' -v g="$GROUP" -v since="$SINCE" '
    $3 != "candidate" && $3 != "rejected" { next }
    since != "" && substr($1, 1, 10) < since { next }
    { key = (g == "persona") ? ($6 == "" ? "(none)" : $6) : $5
      if ($3 == "candidate") acc[key]++; else rej[key]++
      seen[key] = 1 }
    END { for (k in seen) printf "%s\t%d\t%d\n", k, acc[k], rej[k] }' "$PROVENANCE_TSV"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

all_posts() { { posts_tsv; gone_tsv; } | { [ -z "$SINCE" ] && cat || awk -F'\t' -v s="$SINCE" '$4 >= s'; }; }

if [ "$MODE" = posts ]; then
  printf 'state\tvariant\tpersona\tcreated\tstate_date\tid\n'
  all_posts | sort -t$'\t' -k4,4
  exit 0
fi

# --- the summary ---------------------------------------------------------------
all_posts > "$tmp/posts"
proposed_tsv > "$tmp/proposed"

printf '== what the pool did with each %s ==\n' "$GROUP"
[ -z "$SINCE" ] || printf '(since %s)\n' "$SINCE"
printf '\n'

# LC_ALL=C so a mean prints as 7.0d and not 7,0d.
LC_ALL=C awk -F'\t' -v g="$GROUP" '
  FILENAME == ARGV[1] {
    key = (g == "persona") ? $3 : $2
    state = $1
    n[key]++; s[key, state]++
    if (state == "evicted" && $4 != "" && $5 != "") {
      # Days from the day it was written to the day the curator threw it out —
      # how long a candidate of this kind tends to survive being re-read.
      cmd = "date -d \"" $5 "\" +%s 2>/dev/null; date -d \"" $4 "\" +%s 2>/dev/null"
      cmd | getline b; cmd | getline a; close(cmd)
      if (b != "" && a != "" && b >= a) { surv[key] += (b - a) / 86400; survn[key]++ }
    }
    keys[key] = 1
    next
  }
  { prop[$1] = $2; prej[$1] = $3; keys[$1] = 1 }
  END {
    printf "%-34s %8s %8s %6s %6s %6s %6s %6s %7s %8s\n",
           g, "proposed", "rejected", "gate%", "pool", "Keep", "Disc", "gone", "kept%", "survival"
    for (k in keys) {
      p = prop[k] + 0; r = prej[k] + 0
      gatepct = (p + r) ? int(r * 100 / (p + r) + 0.5) : 0
      decided = s[k, "kept"] + s[k, "evicted"] + s[k, "gone"]
      keptpct = decided ? int(s[k, "kept"] * 100 / decided + 0.5) : 0
      sv = survn[k] ? sprintf("%.1fd", surv[k] / survn[k]) : "—"
      printf "%-34s %8d %8d %5d%% %6d %6d %6d %6d %6d%% %8s\n",
             k, p, r, gatepct, s[k, "pool"], s[k, "kept"], s[k, "evicted"], s[k, "gone"], keptpct, sv
    }
  }' "$tmp/posts" "$tmp/proposed" > "$tmp/summary"
# Through a file, not a pipe: `head -1` on a pipe reads a whole buffer and the
# rest of the rows vanish with it.
head -1 "$tmp/summary"
tail -n +2 "$tmp/summary" | sort

cat <<'NOTE'

  proposed/rejected  what the stitching gate saw, from logs/provenance.tsv —
                     the only record of a candidate that has since aged out
  gate%              share of proposals the gate rejected
  pool/Keep/Disc     where the surviving posts are NOW
  kept%              of the posts you have DECIDED about (kept + evicted +
                     aged out), the share you kept. Posts still sitting in the
                     pool are undecided and are not counted either way.
  survival           mean days from writing to eviction, for the evicted ones

Read this the way you would read any small sample: a variant with four decided
posts has told you nothing yet. It is meant to be checked after weeks, not after
a run — and it costs nothing to wait, because the pipeline is recording either
way. `pre-experiment` is everything from before provenance stamping existed.
NOTE
