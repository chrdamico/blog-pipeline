#!/usr/bin/env bash
#
# brief.sh — one page saying what the pipeline is currently doing, and what each
# arm changes about it.
#
#   bin/brief.sh            print it
#   bin/brief.sh --write    …and drop it in the vault, where the phone can read it
#
# WHY THIS EXISTS. The configuration is spread across the shipped defaults, a
# promoted base, an arm's deltas and a directive file, resolved in that order by
# lib/config.sh. That layering is what makes an experiment cheap, and it is also
# why nobody can answer "what is running tonight, and how is the middle arm
# different" without reading four files. This answers it in one screen, from the
# same resolution every run uses — so it cannot describe a configuration that
# isn't the live one.
#
# Two rules keep it honest:
#
#   Every VALUE is read from `lib/config.sh dump`, never written down here. Only
#   the English is local. A knob that changes value changes this page.
#
#   Every knob in BLOG_FINGERPRINT_KEYS must have a sentence (say_knob's case
#   below). tests/check_brief.sh fails when one does not, so a new knob cannot be
#   added and quietly go unexplained.
#
# It lands in $VAULT/Pipeline/ and NOT at the vault root, which matters: the
# corpus globs are non-recursive ($VAULT/*.md), so a subfolder is invisible to
# the generator, the typo pass and the archiver. A page about the pipeline must
# never become material the pipeline stitches posts out of.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"

WRITE=0
for a in "$@"; do
  case "$a" in
    --write) WRITE=1 ;;
    -h|--help) sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'brief: unknown option: %s\n' "$a" >&2; exit 2 ;;
  esac
done

# A child process must not inherit the keys base.env exported into this shell, or
# every arm would resolve to the base's values and this page would report that
# nothing differs. Same reason bin/arm.sh and the arm fan-out do it.
CLEAN=()
for k in $BLOG_APPLIED_KEYS; do CLEAN+=(-u "$k"); done

dump_for()  { env "${CLEAN[@]+${CLEAN[@]}}" ${1:+BLOG_ARM="$1"} bash "$BLOG_LIB_DIR/config.sh" dump; }
paths_for() { env "${CLEAN[@]+${CLEAN[@]}}" ${1:+BLOG_ARM="$1"} bash "$BLOG_LIB_DIR/config.sh" paths; }
val()       { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# --- the English ----------------------------------------------------------------
# say_knob <key> <value> -> "<stage>|<sentence>", or nothing for a knob not worth
# a line of its own. The stage is what groups the base page below.
#
# Phrased as what it PERMITS or COSTS, not as what it is set to: "glue may be at
# most 30% of a post" is readable on a phone at breakfast, "VERBATIM_MIN=70" is
# not — and the second is a trap besides, because that number is a glue ceiling
# and requires no verbatim minimum at all.
say_knob() {
  local k="$1" v="$2"
  case "$k" in
    WHISPER_LANG)      printf 'capture|language %s\n' "$v" ;;
    WHISPER_MARKS)     [ "$v" = 1 ] && printf 'capture|spans whisper was unsure of are marked for the cleaner\n' \
                                    || printf 'capture|confidence marks off\n' ;;
    WHISPER_CONF_LOW)  printf 'capture|"unsure" starts below p=%s\n' "$v" ;;
    WHISPER_CONF_VLOW) printf 'capture|a single word marks itself below p=%s\n' "$v" ;;
    CLEANUP_MODEL)     printf 'cleanup|%s\n' "$v" ;;
    STRUCTURE)         [ "$v" = 1 ] && printf 'cleanup|a structure suggestion is written alongside\n' || true ;;
    CORPUS_MAX)        printf 'corpus|%s chars per run: newest 70%%, the rest sampled at random\n' \
                         "$(printf '%s' "$v" | sed -e :a -e 's/\([0-9]\)\([0-9]\{3\}\)\($\|,\)/\1,\2\3/;ta')" ;;
    ARCHIVE_DAYS)      printf 'corpus|root notes older than %s days move into Archive/ (still in the corpus)\n' "$v" ;;
    TYPO_FIX)          [ "$v" = 1 ] && printf 'proofread|typed notes only, one pass each, ever\n' \
                                    || printf 'proofread|off\n' ;;
    TYPO_MODEL)        printf 'proofread|%s\n' "$v" ;;
    TYPO_MIN_LEN)      printf 'proofread|words shorter than %s letters are never corrected\n' "$v" ;;
    TYPO_MAX_PCT)      printf 'proofread|at most %s%% of a note may change, or the whole note is refused\n' "$v" ;;
    CURATE_MODEL)      printf 'propose|%s\n' "$v" ;;
    MAX_NEW)           printf 'propose|%s candidates a night\n' "$v" ;;
    HISTORY_LINES)     printf 'propose|the last %s suggestions are shown so it does not repeat itself\n' "$v" ;;
    VERBATIM_MIN)      printf 'gate|glue may be at most %s%% of a post'"'"'s sentences\n' "$((100 - v))" ;;
    GLUE_MAX_WORDS)    printf 'gate|…and at most %s words each\n' "$v" ;;
    NEW_SLACK_EVERY)   printf 'gate|one invented sentence tolerated per %s sentences of post\n' "$v" ;;
    VOICE_TWEAK_GAP)   [ "$v" -gt 0 ] 2>/dev/null \
                         && printf 'gate|a DICTATED sentence may have up to %s words cut from its middle\n' "$v" \
                         || printf 'gate|no sentence may be cut in the middle (its ends are always free)\n' ;;
    VOICE_REWRITE_MIN) [ "$v" -gt 0 ] 2>/dev/null \
                         && printf 'gate|a DICTATED sentence may be REWORDED if %s%% of the words it restates survive\n' "$v" \
                         || printf 'gate|nothing may be reworded — a post is his sentences or it is refused\n' ;;
    GATE_MODE)         [ "$v" = enforce ] && printf 'gate|failing candidates are refused\n' \
                                          || printf 'gate|*** %s: classifying but NOT refusing — sandboxes only ***\n' "$v" ;;
    GATE_TRACE)        [ "$v" = 1 ] && printf 'gate|each non-verbatim sentence is annotated with its nearest source and a word diff\n' || true ;;
    REUSE_MIN_WORDS)   printf 'reuse|sentences under %s words are never spent\n' "$v" ;;
    REUSE_DROP_PCT)    printf 'reuse|a kept post'"'"'s sentences are spent %s%% of the time, per kind\n' "$v" ;;
    MAX_LONG)          printf 'pool|%s long\n' "$v" ;;
    MAX_SHORT)         printf 'pool|%s short\n' "$v" ;;
    TRASH_DAYS)        printf 'pool|evicted posts stay readable in Discarded/ for %s days\n' "$v" ;;
    REJECT_DAYS)       printf 'pool|gate-refused ones in Rejected/ for %s days\n' "$v" ;;
    SYNC_KEEP_DAYS)    printf 'capture|a recording stays on the phone %s days after processing\n' "$v" ;;
    NAME_SCAN)         [ "$v" = 1 ] && printf 'privacy|every new person name is given a pseudonym before any post is written\n' \
                                    || printf 'privacy|*** name scout OFF ***\n' ;;
    *) return 0 ;;
  esac
}

# The order knobs are PRINTED in. Separate from BLOG_FINGERPRINT_KEYS, which is
# ordered for hashing and puts SYNC_KEEP_DAYS above the pool caps. Every
# fingerprint key must appear here — tests/check_brief.sh asserts it, so a knob
# added tomorrow cannot go unexplained.
BRIEF_ORDER="
WHISPER_LANG WHISPER_MARKS WHISPER_CONF_LOW WHISPER_CONF_VLOW SYNC_KEEP_DAYS
CLEANUP_MODEL STRUCTURE
CORPUS_MAX ARCHIVE_DAYS
TYPO_FIX TYPO_MODEL TYPO_MIN_LEN TYPO_MAX_PCT
CURATE_MODEL MAX_NEW HISTORY_LINES
VERBATIM_MIN GLUE_MAX_WORDS NEW_SLACK_EVERY VOICE_TWEAK_GAP VOICE_REWRITE_MIN
GATE_MODE GATE_TRACE
REUSE_MIN_WORDS REUSE_DROP_PCT
MAX_LONG MAX_SHORT TRASH_DAYS REJECT_DAYS
NAME_SCAN
"

STAGES="capture cleanup corpus proofread propose gate reuse pool privacy"
stage_title() {
  case "$1" in
    capture)   printf 'capture      ' ;; cleanup)  printf 'cleanup      ' ;;
    corpus)    printf 'corpus       ' ;; proofread) printf 'proofread    ' ;;
    propose)   printf 'propose      ' ;; gate)     printf 'the gate     ' ;;
    reuse)     printf 'reuse        ' ;; pool)     printf 'the pool     ' ;;
    privacy)   printf 'privacy      ' ;;
  esac
}

# Every knob's sentence for one configuration, as "<stage>|<sentence>" lines.
sentences_for() {
  local dump="$1" k v
  for k in $BRIEF_ORDER; do
    v="$(val "$dump" "$k")"
    [ -n "$v" ] || continue
    say_knob "$k" "$v"
  done
}

# --- the page -------------------------------------------------------------------
BASE_DUMP="$(dump_for '')"
BASE_PATHS="$(paths_for '')"
# The prompt files are part of a stage's description, not a footnote: the stream
# is instructions + anchor + directive, and for a curator arm the directive is
# usually the entire difference.
prompt_lines() {   # $1 = a `config.sh paths` dump
  printf 'cleanup|%s + %s\n' \
    "$(basename "$(val "$1" CLEANUP_PROMPT)")" "$(basename "$(val "$1" CLEANUP_DIRECTIVE)")"
  printf 'propose|%s + %s\n' \
    "$(basename "$(val "$1" SUGGEST_PROMPT)")" "$(basename "$(val "$1" CURATE_DIRECTIVE)")"
}

BASE_SENT="$(sentences_for "$BASE_DUMP"; prompt_lines "$BASE_PATHS")"

brief() {
  printf '# What the pipeline is doing\n\n'
  printf '_%s. Generated by `bin/brief.sh`; every number is read from the live\n' "$(date '+%Y-%m-%d %H:%M')"
  printf 'configuration, so this page cannot describe a run that is not happening._\n\n'

  printf 'You dictate. Every 15 minutes new recordings are transcribed and cleaned into\n'
  printf 'a draft; your typed notes join them as one corpus. Once a night the curator\n'
  printf 'reads the whole corpus, proposes posts **stitched out of sentences you already\n'
  printf 'said**, a mechanical gate refuses the ones that are not, and the survivors are\n'
  printf 'judged down to a small pool on your phone. Each arm below is that same run with\n'
  printf 'one thing changed.\n\n'

  printf '## The base\n\n```\n'
  local s line
  for s in $STAGES; do
    printf '%s' "$(stage_title "$s")"
    local first=1
    while IFS= read -r line; do
      case "$line" in "$s|"*) ;; *) continue ;; esac
      [ "$first" = 1 ] || printf '             '
      printf '%s\n' "${line#*|}"
      first=0
    done <<< "$BASE_SENT"
    [ "$first" = 0 ] || printf '\n'
  done
  printf '```\n'

  # --- the arms -----------------------------------------------------------------
  local any=0 arm note
  printf '\n## Running tonight\n\n'
  while IFS= read -r arm; do
    [ -n "$arm" ] || continue
    any=1
    note="$( { [ -f "$ARMS_TSV" ] && awk -F'\t' -v n="$arm" '$1 == n { print $4; exit }' "$ARMS_TSV"; } || true)"
    printf '### %s\n\n' "$arm"
    [ -z "$note" ] || printf '**The question:** %s\n\n' "$note"

    local adump apaths
    adump="$(dump_for "$arm")"; apaths="$(paths_for "$arm")"

    printf '```\n'
    # The prompt delta first: for a curator arm it is usually the whole point,
    # and it is the one difference a list of numbers cannot show.
    local bd ad
    bd="$(basename "$(val "$BASE_PATHS" CURATE_DIRECTIVE)")"
    ad="$(basename "$(val "$apaths" CURATE_DIRECTIVE)")"
    if [ "$bd" != "$ad" ]; then
      printf 'prompt   %s   instead of %s\n' "$ad" "$bd"
      # Its section headings, which is the cheapest honest summary of prose.
      local f
      f="$(val "$apaths" CURATE_DIRECTIVE)"
      if [ -f "$f" ]; then
        grep '^#\{1,3\} ' "$f" | sed 's/^#* *//; s/^THIS RUN: //' | sed 's/^/         · /'
      fi
    fi
    # Then every knob whose sentence differs from the base's.
    local k bv av bs as changed=0
    for k in $BRIEF_ORDER; do
      bv="$(val "$BASE_DUMP" "$k")"; av="$(val "$adump" "$k")"
      [ "$bv" = "$av" ] && continue
      bs="$(say_knob "$k" "$bv")"; as="$(say_knob "$k" "$av")"
      [ -n "$as" ] || continue
      changed=1
      printf 'now      %s\n' "${as#*|}"
      printf 'base     %s\n' "${bs#*|}"
    done
    [ "$changed" = 1 ] || [ "$bd" != "$ad" ] || printf 'nothing — this arm resolves to the base\n'
    printf '```\n\n'
  done < <(blog_active_arms)
  [ "$any" = 1 ] || printf '_No arms active. Everything you see is the base._\n\n'

  # --- history ------------------------------------------------------------------
  if [ -f "$ARMS_TSV" ]; then
    printf '## Already decided\n\n```\n'
    awk -F'\t' '$3 == "promoted" { printf "folded into the base  %-12s %s\n", $1, $4 }
                $3 == "retired"  { printf "stopped               %-12s %s\n", $1, $4 }' "$ARMS_TSV"
    printf '```\n'
  fi

  printf '\n---\n\n'
  printf '_The full knob list is `lib/config.sh dump`; what the pool did with each arm is\n'
  printf '`bin/arm.sh status`; the numbers are in STATS.md._\n'
}

if [ "$WRITE" = 1 ]; then
  # A SUBFOLDER of the vault, never its root: the corpus globs are non-recursive,
  # so this page stays out of the material the curator reads.
  dest="$VAULT/Pipeline"
  mkdir -p "$dest"
  brief > "$dest/RUNNING.md.tmp" && mv "$dest/RUNNING.md.tmp" "$dest/RUNNING.md"
  printf 'brief: %s\n' "${dest#"$BLOG_ROOT"/}/RUNNING.md"
else
  brief
fi
