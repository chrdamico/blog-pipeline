#!/usr/bin/env bash
# tests/run_all.sh — every check in this directory, in one command.
#
# It exists because the list was written out by hand in CLAUDE.md, and a hand
# list drifts: check_sweep.sh was added and never added to it, so the notes said
# "run all five" while there were six, and the one guarding the privacy backstop
# was the one nobody was told to run. This globs, so a new tests/check_*.sh joins
# the suite by existing.
#
# None of these call a model. They are free and they are fast; there is no reason
# to run a subset.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0; failed=""
for t in check_*.sh; do
  # The description each test gives itself on its second line, after the em dash.
  what="$(sed -n '2s/^# [^—]*— *//p' "$t")"
  printf '\n\033[1m== %s\033[0m %s\n' "$t" "${what:+— $what}"
  if bash "$t"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed="${failed:+$failed }$t"
  fi
done

printf '\n=====================================================\n'
if [ "$fail" -eq 0 ]; then
  printf '%d test file(s), all passing.\n' "$pass"
else
  printf '%d passing, %d FAILING: %s\n' "$pass" "$fail" "$failed"
fi
[ "$fail" -eq 0 ]
