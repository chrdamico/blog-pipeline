#!/usr/bin/env bash
#
# stats.sh — the pipeline at a glance: what's in the pool, how the stitching
# gate is doing over time, and a rough idea of Claude usage.
#
# Reads only the ledgers the other scripts already write:
#   logs/gate.tsv    one row per candidate  (ts, PASS|REJECTED, kind, title, why)
#   logs/usage.tsv   one row per Claude call (ts, job, model, in_chars, out_chars)
#   logs/suggested.tsv, the pool directories, drafts/, the vault
#
# Token numbers are ESTIMATES: chars/4. Each `claude -p` call also carries CLI
# system-prompt overhead on top of what the stream sizes show — treat every
# figure here as a gut feeling, not a bill.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"

# At the root of whatever tree is being reported on — the repo for a live run,
# the sandbox for an experiment.
STATS_MD="$BLOG_ROOT/STATS.md"

# --public omits post titles. logs/gate.tsv stores them PRE-alias (the gate runs
# before anonymization), so a title can carry a real name — fine for the local
# view, never for anything that gets committed. --write is the committed view:
# STATS.md in the repo root, regenerated at the end of every suggest run.
PUBLIC=0
WRITE=0
for arg in "$@"; do
  case "$arg" in
    --public) PUBLIC=1 ;;
    --write)  WRITE=1 ;;
    -h|--help)
      printf 'usage: stats.sh [--public] [--write]\n'
      printf '  --public  omit post titles (they are pre-alias; may contain real names)\n'
      printf '  --write   write the public view to STATS.md in the repo root\n'
      exit 0 ;;
    *) printf 'stats.sh: unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ "$WRITE" -eq 1 ]; then
  tmp="$STATS_MD.tmp.$$"
  {
    printf '# Pipeline statistics\n\n'
    printf 'Generated %s by `bin/stats.sh --write`, which runs at the end of every\n' "$(date '+%Y-%m-%d %H:%M %Z')"
    printf 'suggest run. Post titles are omitted here on purpose — see `bin/stats.sh`\n'
    printf 'for the full local view, and `logs/stats/` for one snapshot per day.\n\n'
    printf '```\n'
    "$0" --public
    printf '```\n'
  } > "$tmp"
  mv "$tmp" "$STATS_MD"
  exit 0
fi

count() { find "$1" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' \) 2>/dev/null | wc -l | tr -d ' '; }

kind_count() {
  local k="$1" f n=0
  shopt -s nullglob
  for f in "$POSTS"/*.md; do
    grep -q "^kind: $k$" "$f" 2>/dev/null && n=$((n + 1))
  done
  shopt -u nullglob
  printf '%s' "$n"
}

printf '== pool ==\n'
printf 'suggestions : %s long, %s short\n' "$(kind_count long)" "$(kind_count short)"
printf 'Keep/       : %s\n' "$(count "$POSTS/Keep")"
printf 'Discarded/  : %s\n' "$(count "$POSTS/Discarded")"
printf 'Rejected/   : %s\n' "$(count "$POSTS/Rejected")"

# --- live A/B arms ------------------------------------------------------------
# The section that answers "which of these is working", every day, without
# asking for it. Silent when nothing is being tested, so the normal report does
# not grow a heading about an experiment that is not running.
if [ -n "$(blog_active_arms)" ] || { [ -f "$ARMS_TSV" ] && [ -s "$ARMS_TSV" ]; }; then
  printf '\n== live A/B arms ==\n'
  while IFS=$'\t' read -r aname acreated astatus anote; do
    [ -n "${aname:-}" ] || continue
    printf '%-12s %-9s since %s  %s\n' "$aname" "$astatus" "$acreated" "${anote:-}"
  done < "$ARMS_TSV"
  printf '\n'
  # The accept rates themselves, from the same place bin/arm.sh status reads.
  "$SCRIPT_DIR/score.sh" --arms 2>/dev/null | sed -n '3,20p' | sed '/^$/q'
  printf '\n(bin/arm.sh list · bin/arm.sh status · bin/arm.sh promote <name>)\n'
fi

printf '\n== material ==\n'
printf 'draft bundles : %s\n' "$(find "$DRAFTS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
printf 'notes (root)  : %s\n' "$(count "$VAULT")"
printf 'notes (archive): %s\n' "$(count "$VAULT/Archive")"

# --- origin: dictated vs typed ------------------------------------------------
# The corpus has two mouths. A voice memo arrives through process.sh (whisper,
# then prompts/cleanup.md) and lands as drafts/<bundle>/cleaned.md; a typed note
# is thumbed into the phone and lands as sync/Obsidian/<name>.md, proofread only
# by the typo pass. Both go into the same generation stream, and until now
# nothing counted which one the posts actually came out of.
#
# The count is per SENTENCE, not per post, because a stitched post routinely
# draws on both — asking "is this post voice or typed" of a post with 26 typed
# sentences and 5 dictated ones has no honest answer. Every sourced line of a
# provenance report carries the note it matched:
#
#   - VERBATIM [drafts/2026-08-13-x/cleaned.md] ...      <- dictated
#   - TWEAKED  [sync/Obsidian/Lorem ipsum dolor sit.md]  <- typed
#
# GLUE and NEW lines carry no source (they are the model's own words) and are
# counted separately rather than being silently assigned to either mouth.
#
# The number worth reading is not Keep/'s split on its own — it is Keep/'s split
# NEXT TO Discarded/'s. Keep/ being mostly typed proves nothing if the corpus
# offered mostly typed material that day; what says something is the same share
# moving between what was offered and what was chosen. So both are printed, and
# the lift between them is the verdict line.
#
# Rejected/ is deliberately absent: those posts never reached the phone, so they
# were never accepted or refused by anyone, and a gate rejection is not a taste
# signal. (Their gate report also lives inline in the body, not in .provenance/.)
origin_split() {   # $1 = directory of posts; emits "voice typed glue posts noreport"
  local dir="$1" f rep
  shopt -s nullglob
  for f in "$dir"/*.md; do
    rep="$PROVENANCE/$(basename "$f")"
    if [ -f "$rep" ]; then printf '%s\n' "$rep"; else printf '\n'; fi
  done | awk '
    # A voice bundle is the only thing in the tree named cleaned.md, so the
    # suffix classifies without hard-coding $DRAFTS — which BLOG_DRAFTS can move.
    function is_voice(id) { return id ~ /\/cleaned\.md$/ }
    $0 == "" { posts++; noreport++; next }
    {
      posts++
      while ((getline line < $0) > 0) {
        if (line ~ /^- (VERBATIM|TWEAKED) \[/) {
          id = line; sub(/^[^[]*\[/, "", id); sub(/\].*/, "", id)
          if (is_voice(id)) v++; else t++
        } else if (line ~ /^- (GLUE|NEW) /) g++
      }
      close($0)
    }
    END { printf "%d %d %d %d %d\n", v+0, t+0, g+0, posts+0, noreport+0 }'
  shopt -u nullglob
}

# One line per pool, plus the share that makes the pools comparable.
origin_row() {   # $1 = label  $2 = directory
  local label="$1" v t g posts noreport tot
  read -r v t g posts noreport < <(origin_split "$2")
  tot=$((v + t))
  if [ "$tot" -eq 0 ]; then
    printf '%-12s %3s posts  (no sourced sentences yet)\n' "$label" "$posts"
    return
  fi
  printf '%-12s %3d posts  %5d sentences  voice %4d (%2d%%)  typed %4d (%2d%%)  glue/new %d%s\n' \
    "$label" "$posts" "$tot" "$v" "$((v * 100 / tot))" "$t" "$((100 - v * 100 / tot))" "$g" \
    "$([ "$noreport" -gt 0 ] && printf '  [%d without a report]' "$noreport")"
  # Stashed for the verdict line below.
  printf '%s %s\n' "$v" "$tot" > "$ORIGIN_TMP/$label"
}

printf '\n== origin (dictated vs typed) ==\n'
ORIGIN_TMP="$(mktemp -d)"
trap 'rm -rf "$ORIGIN_TMP"' EXIT
origin_row Keep      "$POSTS/Keep"
origin_row Discarded "$POSTS/Discarded"
origin_row pool      "$POSTS"
if [ -s "$ORIGIN_TMP/Keep" ] && [ -s "$ORIGIN_TMP/Discarded" ]; then
  read -r kv kt < "$ORIGIN_TMP/Keep"
  read -r dv dt < "$ORIGIN_TMP/Discarded"
  # Offered = everything that reached the phone and got a verdict, kept or not.
  ov=$((kv + dv)); ot=$((kt + dt))
  if [ "$ot" -gt 0 ] && [ "$kt" -gt 0 ]; then
    printf 'voice is %d%% of what was offered and %d%% of what was kept' \
      "$((ov * 100 / ot))" "$((kv * 100 / kt))"
    if [ "$((kv * 100 / kt))" -gt "$((ov * 100 / ot))" ]; then printf ' — dictation over-performs\n'
    elif [ "$((kv * 100 / kt))" -lt "$((ov * 100 / ot))" ]; then printf ' — typing over-performs\n'
    else printf ' — no difference\n'; fi
    # Keep/ is small and grows one decision at a time; a share computed from a
    # handful of posts will swing wildly for weeks. Say so instead of letting a
    # confident-looking percentage stand unqualified.
    [ "$kt" -lt 200 ] && printf '(Keep/ is still small — %d sentences; treat the lift as provisional)\n' "$kt"
  fi
fi

printf '\n== stitching gate ==\n'
if [ -s "$LOGS/gate.tsv" ]; then
  awk -F'\t' '
    { total++; if ($2 == "PASS") pass++ }
    END {
      printf "candidates  : %d  (%d passed, %d rejected — %d%% pass rate)\n",
             total, pass, total - pass, total ? pass * 100 / total : 0
    }' "$LOGS/gate.tsv"
  printf 'last rejections:\n'
  if [ "$PUBLIC" -eq 1 ]; then
    # Reason only: the counts carry the useful signal and no name can hide in them.
    awk -F'\t' '$2 == "REJECTED" { print "  - [" $3 "] " $5 }' "$LOGS/gate.tsv" | tail -n 5
  else
    awk -F'\t' '$2 == "REJECTED" { print "  - [" $3 "] " $4 }' "$LOGS/gate.tsv" | tail -n 5
  fi
else
  printf '(no candidates yet)\n'
fi

printf '\n== claude usage (estimates: chars/4 ≈ tokens; CLI overhead not included) ==\n'
if [ -s "$LOGS/usage.tsv" ]; then
  awk -F'\t' '
    {
      calls[$2]++; inc[$2] += $4; outc[$2] += $5
      tcalls++; tin += $4; tout += $5
      day = substr($1, 1, 10)
      if (day > lastday) lastday = day
      din[day] += $4; dcalls[day]++
    }
    END {
      for (j in calls)
        printf "%-18s: %4d call(s)  in ~%dk tok   out ~%dk tok\n",
               j, calls[j], inc[j] / 4000, outc[j] / 4000
      printf "%-18s: %4d call(s)  in ~%dk tok   out ~%dk tok\n",
             "TOTAL", tcalls, tin / 4000, tout / 4000
      if (lastday != "")
        printf "last active day   : %s — %d call(s), ~%dk tokens in\n",
               lastday, dcalls[lastday], din[lastday] / 4000
    }' "$LOGS/usage.tsv"
else
  printf '(no calls logged yet)\n'
fi
