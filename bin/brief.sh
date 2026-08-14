#!/usr/bin/env bash
#
# brief.sh — one page saying what the pipeline is currently doing, and what each
# arm changes about it.
#
#   bin/brief.sh            print it
#   bin/brief.sh --write    …and drop it in the vault, where the phone can read it
#   bin/brief.sh --files    just the file inventory: what is LIVE, opt-in, ORPHAN
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
FILES=0
for a in "$@"; do
  case "$a" in
    --write) WRITE=1 ;;
    # The inventory alone, as `status <TAB> path <TAB> why` — the form
    # tests/check_layout.sh reads. The page below renders the same rows.
    --files) FILES=1 ;;
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
CLEANUP_MODEL
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
# is instructions + directive, and for a curator arm the directive is usually
# the entire difference.
prompt_lines() {   # $1 = a `config.sh paths` dump
  printf 'cleanup|%s + %s\n' \
    "$(basename "$(val "$1" CLEANUP_PROMPT)")" "$(basename "$(val "$1" CLEANUP_DIRECTIVE)")"
  printf 'propose|%s + %s\n' \
    "$(basename "$(val "$1" SUGGEST_PROMPT)")" "$(basename "$(val "$1" CURATE_DIRECTIVE)")"
}

BASE_SENT="$(sentences_for "$BASE_DUMP"; prompt_lines "$BASE_PATHS")"

# --- what is on disk, and whether it is running ----------------------------------
# The layout is supposed to answer "is this file live?" by which directory it
# sits in (profiles/README.md). This is the part that checks the answer is TRUE,
# by resolving the configuration instead of trusting the directory:
#
#   LIVE    a path the base or a running arm actually resolves to
#   opt-in  under profiles/offline/, or a prompt only bin/ab.sh reaches
#   docs    profiles/default.env — an inventory to read, a no-op to run
#   ORPHAN  in a live directory, and nothing points at it
#
# An ORPHAN is the failure the layout exists to prevent: a file that reads as
# running and is not — a retired arm's directive, an overlay whose arm was
# promoted. tests/check_layout.sh parses these rows and fails if one appears, so
# the tidying is enforced rather than remembered.
#
# Rows are `status <TAB> repo-relative path <TAB> why`.
rel() { printf '%s' "${1#"$BLOG_REPO_DIR"/}"; }

# Every prose path the live configuration reaches, as `path <TAB> who`.
live_paths() {
  local who paths k p
  for who in '' $(blog_active_arms); do
    paths="$(paths_for "$who")"
    for k in PROMPTS_DIR PERSONAS \
             CLEANUP_PROMPT SUGGEST_PROMPT CURATE_PROMPT \
             TYPO_PROMPT NAMES_PROMPT CLEANUP_DIRECTIVE CURATE_DIRECTIVE; do
      p="$(val "$paths" "$k")"
      [ -n "$p" ] || continue
      case "$k" in
        CLEANUP_DIRECTIVE) printf '%s\t%s, cleanup slot\n' "$p" "${who:-base}" ;;
        CURATE_DIRECTIVE)  printf '%s\t%s, curate slot\n'  "$p" "${who:-base}" ;;
        PROMPTS_DIR)       printf '%s\t%s, prompt overlay\n' "$p" "${who:-base}" ;;
        PERSONAS)          printf '%s\t%s, personas\n' "$p" "${who:-base}" ;;
        *)                 printf '%s\t%s\n' "$p" "every run" ;;
      esac
    done
  done
}

LIVE_PATHS=""            # set by inventory(), read by live_why()
live_why() { printf '%s\n' "$LIVE_PATHS" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'; }
row() { printf '%s\t%s\t%s\n' "$1" "$(rel "$2")" "$3"; }

inventory() {
  local f d name why
  LIVE_PATHS="$(live_paths)"

  row LIVE "$PROMPTS/" 'one standing instruction per stage, always in the stream'
  for f in "$PROMPTS"/*.md; do
    why="$(live_why "$f")"
    # The judge tier lives in prompts/ too, but only bin/ab.sh judge sends it.
    if [ -n "$why" ]; then row LIVE "$f" "$why"; else row opt-in "$f" 'bin/ab.sh judge'; fi
  done

  row LIVE "$BLOG_BASE_ENV" 'the floor under every run, arms included'
  row docs "$BLOG_REPO_DIR/profiles/default.env" 'every knob at its shipped value; a no-op to run'

  # arms/ holds exactly what runs, because promote and retire delete the file. A
  # file here the registry does not call active is therefore a leftover.
  local active; active="$(blog_active_arms)"
  for f in "$ARMS_DIR"/*.env; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .env)"
    if printf '%s\n' "$active" | grep -qxF "$name"; then
      row LIVE "$f" 'runs tonight beside the base'
    else
      row ORPHAN "$f" 'not active in logs/arms.tsv — promote/retire should have removed it'
    fi
  done

  # The live prose directories: everything in them should be reached by something.
  for f in "$BLOG_REPO_DIR"/profiles/directives/*.md; do
    [ -e "$f" ] || continue
    why="$(live_why "$f")"
    if [ -n "$why" ]; then row LIVE "$f" "$why"; else row ORPHAN "$f" 'nothing points at it'; fi
  done
  for d in "$BLOG_REPO_DIR"/profiles/overlays/*/; do
    [ -e "$d" ] || continue
    why="$(live_why "${d%/}")"
    if [ -n "$why" ]; then row LIVE "${d%/}" "$why"
    else row ORPHAN "${d%/}" 'nothing points at it'; fi
  done

  # profiles/offline/: inert until named, and which .exp names it is the useful part.
  for f in "$BLOG_REPO_DIR"/profiles/offline/*.env; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .env)"
    why="$( { grep -rlsE "_PROFILE=${name}\$" "$BLOG_REPO_DIR/eval/experiments" 2>/dev/null || true; } \
            | while IFS= read -r e; do printf 'bin/ab.sh run %s; ' "$(basename "$e" .exp)"; done)"
    row opt-in "$f" "${why:-}BLOG_PROFILE=$name"
  done
  # Prose an offline profile pulls in — directly, or through a personas table,
  # which names its directives relative to itself rather than by repo path.
  for f in "$BLOG_REPO_DIR"/profiles/offline/directives/*.md \
           "$BLOG_REPO_DIR"/profiles/offline/personas/* \
           "$BLOG_REPO_DIR"/profiles/offline/overlays/*; do
    [ -e "$f" ] || continue
    if grep -rqsF -- "$(rel "$f")" "$BLOG_REPO_DIR"/profiles/offline/*.env \
    || grep -rqsF -- "$(basename "$f")" "$BLOG_REPO_DIR"/profiles/offline/personas/*.tsv; then
      row opt-in "$f" 'pulled in by an offline profile'
    else
      row ORPHAN "$f" 'no offline profile points at it'
    fi
  done
}

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

  # --- the inventory ------------------------------------------------------------
  # Which files are in play, resolved rather than assumed. It belongs on this page
  # because the layering that makes the arms above cheap is also what makes a
  # stopped experiment's file indistinguishable from a running one by looking.
  printf '\n## Files in play\n\n```\n'
  inventory | awk -F'\t' '{ printf "%-7s %-44s %s\n", $1, $2, $3 }'
  printf '```\n'
  if inventory | grep -q '^ORPHAN'; then
    printf '\n**Orphans above point at nothing.** They read as live and are not —\n'
    printf 'delete them, or point something at them. `tests/check_layout.sh` fails\n'
    printf 'while any exist.\n'
  fi
  printf '\n'

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

if [ "$FILES" = 1 ]; then
  inventory
elif [ "$WRITE" = 1 ]; then
  # A SUBFOLDER of the vault, never its root: the corpus globs are non-recursive,
  # so this page stays out of the material the curator reads.
  dest="$VAULT/Pipeline"
  mkdir -p "$dest"
  brief > "$dest/RUNNING.md.tmp" && mv "$dest/RUNNING.md.tmp" "$dest/RUNNING.md"
  printf 'brief: %s\n' "${dest#"$BLOG_ROOT"/}/RUNNING.md"
else
  brief
fi
