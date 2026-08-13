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
