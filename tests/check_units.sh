#!/usr/bin/env bash
# tests/check_units.sh — the repo and the machine have to agree.
#
# CLAUDE.md opens by saying that two live timers run bin/process.sh and
# bin/suggest.sh, so a change to those scripts "goes live within minutes". True
# of the scripts, and false of the SCHEDULE: the units in watcher/ are templates
# that install.sh copies into ~/.config/systemd/user/, and once copied the two
# drift apart in silence. Editing a template changes nothing that runs; the
# repo then documents a schedule the machine is not keeping.
#
# It had drifted. On 2026-08-14 the installed blog-suggest.timer was the old
# single 03:00 fire while the template had six retry slots, and the installed
# service was missing the line that told suggest.sh a slot was a slot. The pair
# happened to be harmless — one slot needs no guard — but the opposite pairing
# (new timer, old service) is six full runs a day, base and every arm.
#
# So this compares what is installed against what is committed, and it is a
# WARNING, not a hard failure, for the two cases where the machine is allowed to
# disagree with the repo: nothing installed at all (a fresh clone, or CI), and a
# platform without systemd (macOS uses the launchd plists next door).
#
# No model call, no writes: it reads two directories.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0; warn=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; shift; [ $# -eq 0 ] || printf '     %s\n' "$@"; }
note() { warn=$((warn + 1)); printf 'warn %s\n' "$1"; shift; [ $# -eq 0 ] || printf '     %s\n' "$@"; }

UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
REPO_DIR="$(pwd)"

if ! command -v systemctl >/dev/null 2>&1; then
  note "no systemd on this machine — nothing to compare (macOS: watcher/*.plist)"
  printf '\n%d passed, %d failed, %d warning(s)\n' "$pass" "$fail" "$warn"
  exit 0
fi

installed_any=0
for u in blog-pipeline.service blog-pipeline.timer blog-suggest.service blog-suggest.timer; do
  [ -f "$UD/$u" ] && installed_any=1
done
if [ "$installed_any" -eq 0 ]; then
  note "no units installed under $UD — run install.sh to schedule the pipeline"
  printf '\n%d passed, %d failed, %d warning(s)\n' "$pass" "$fail" "$warn"
  exit 0
fi

for u in blog-pipeline.service blog-pipeline.timer blog-suggest.service blog-suggest.timer; do
  if [ ! -f "$UD/$u" ]; then
    bad "$u is installed" "missing from $UD while its siblings are there — run install.sh"
    continue
  fi
  # install.sh substitutes __REPO_DIR__ when it copies; do the same to compare.
  # Comments are stripped from both sides: a reworded comment is not drift worth
  # failing over, and the whole point is to catch a changed OnCalendar, ExecStart
  # or Environment.
  strip() { sed "s|__REPO_DIR__|$REPO_DIR|g" "$1" | grep -vE '^[[:space:]]*(#|;|$)'; }
  if d="$(diff <(strip "watcher/$u") <(strip "$UD/$u"))"; then
    ok "$u matches watcher/$u"
  else
    bad "$u matches watcher/$u" \
        "the installed unit differs from the committed template:" \
        "$(printf '%s' "$d" | sed 's/^/       /')" \
        "'< ' is the repo, '> ' is what actually runs. Reinstall with install.sh."
  fi
done

# The one behavioural claim that used to live in a unit file and no longer does:
# a timer slot must be recognisable without any help from the unit.
if grep -q 'INVOCATION_ID' bin/suggest.sh; then
  ok "suggest.sh detects a timer slot on its own, not from Environment="
else
  bad "suggest.sh detects a timer slot on its own, not from Environment=" \
      "if this moved back into the unit, a stale installed copy silently disables the retry-slot guard"
fi

printf '\n%d passed, %d failed, %d warning(s)\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
