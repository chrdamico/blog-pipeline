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
LOGS="$REPO_DIR/logs"
VAULT="$REPO_DIR/sync/Obsidian"
POSTS="$VAULT/Posts"

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

printf '\n== material ==\n'
printf 'draft bundles : %s\n' "$(find "$REPO_DIR/drafts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
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
  awk -F'\t' '$2 == "REJECTED" { print "  - [" $3 "] " $4 }' "$LOGS/gate.tsv" | tail -n 5
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
