#!/usr/bin/env bash
#
# lib/config.sh — the one place every knob in the pipeline is resolved.
#
# Sourced by bin/process.sh, bin/suggest.sh, bin/transcribe.sh, bin/reclean.sh
# and bin/ab.sh. With no profile and no environment it resolves to exactly the
# values those scripts hard-coded before it existed (tests/check_defaults.sh
# asserts that, value by value), so sourcing it is a no-op for a normal run.
#
# What it adds:
#
#   1. A RE-ROOTABLE TREE. Every data path hangs off BLOG_ROOT (default: the
#      repo), and each one is individually overridable (BLOG_DRAFTS=…). Export
#      one variable and a whole run happens in a sandbox, never touching the
#      live drafts/, processed.tsv, or the phone. This is what makes offline
#      experiments possible (bin/ab.sh).
#
#   2. A PROMPT OVERLAY. Every prompt path is env-overridable, and PROMPTS_DIR
#      names an overlay directory searched first. A prompt experiment is then a
#      directory holding only the file it changes.
#
#   3. PROFILES. BLOG_PROFILE=<name|file> names an env file under profiles/,
#      applied before the defaults, so a profile states only its deltas.
#      profiles/default.env is the documented inventory of every knob.
#      Precedence, highest first: the environment, the profile, the defaults —
#      so `MAX_NEW=3 BLOG_PROFILE=loose bin/suggest.sh` does what it looks like.
#
#   4. A CONFIG FINGERPRINT. blog_config_dump prints the resolved configuration
#      as sorted key=value lines (prompts enter by CONTENT hash, not path);
#      blog_fingerprint hashes that into 12 hex characters. Two runs with the
#      same fingerprint are the same variant, whatever the profile was called.
#      Paths are deliberately NOT in it: a sandbox copy of a variant must
#      fingerprint identically to the live one, or offline and online results
#      cannot be compared.
#
# Run it directly to inspect what a given environment resolves to:
#
#   lib/config.sh dump          # the fingerprinted configuration
#   lib/config.sh fingerprint   # just the hash
#   lib/config.sh paths         # where this configuration would read and write
#   BLOG_PROFILE=personas lib/config.sh dump
#
# Nothing here creates directories or writes files — resolution only. Each
# script keeps its own mkdir.

# Idempotent: sourcing twice (process.sh -> transcribe.sh) must not re-apply a
# profile over values the caller has since changed.
if [ -z "${BLOG_CONFIG_LOADED:-}" ]; then
BLOG_CONFIG_LOADED=1

BLOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The CODE root: where the scripts, prompts and models ship. Distinct from
# BLOG_ROOT (the DATA root) — an experiment re-roots the data, never the code.
BLOG_REPO_DIR="$(cd "$BLOG_LIB_DIR/.." && pwd)"

# --- profile -----------------------------------------------------------------
# A profile is a KEY=VALUE file (`# comments` and blank lines allowed). The
# value is expanded like a shell assignment, so quoting and $BLOG_REPO_DIR work:
#
#   CURATE_MODEL=claude-sonnet-5
#   PROMPTS_DIR=$BLOG_REPO_DIR/eval/overlays/loose-curator
#   RESERVE_X="Kim Luca Toni"
#
# A key already present in the environment is left alone — the environment
# outranks the profile, always.
BLOG_PROFILE_FILE=""
# Keys any profile, arm or base.env has exported into this shell.
BLOG_APPLIED_KEYS=""
blog_resolve_profile() {
  local p="$1"
  case "$p" in
    /*)  printf '%s' "$p" ;;
    */*) if [ -f "$p" ]; then printf '%s' "$p"; else printf '%s' "$BLOG_REPO_DIR/$p"; fi ;;
    *)   if [ -f "$BLOG_REPO_DIR/profiles/$p" ]; then printf '%s' "$BLOG_REPO_DIR/profiles/$p"
         else printf '%s' "$BLOG_REPO_DIR/profiles/$p.env"; fi ;;
  esac
}

blog_apply_profile() {
  local f="$1" line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"          # ltrim
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    k="${line%%=*}"
    v="${line#*=}"
    [ "$k" != "$line" ] || continue                  # no '=' on the line
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    # Already in the environment? The environment wins — but only when it says
    # something. `MAX_NEW= bin/suggest.sh` is an empty variable, not an
    # instruction, and it used to beat the profile and then fall through `:-` to
    # the shipped default, which is neither of the two values in play. Treating
    # set-but-empty as unset makes the profile's answer the one that survives.
    [ -z "${!k:+x}" ] || continue
    # Remembered so a child process can be started WITHOUT them. An arm run is
    # spawned by the base run, and anything the base exported would arrive in
    # the child as environment — which outranks the arm's own file, silently
    # pinning every arm to the base's values. See spawn_arm in bin/suggest.sh.
    case " $BLOG_APPLIED_KEYS " in *" $k "*) ;; *) BLOG_APPLIED_KEYS="$BLOG_APPLIED_KEYS $k" ;; esac
    eval "export $k=$v" 2>/dev/null \
      || { printf 'config: unusable line in %s: %s\n' "$f" "$line" >&2; return 1; }
  done < "$f"
}

# Which model keys arrived from the ENVIRONMENT, taken before a profile can
# export its own and make the two indistinguishable. blog_model below needs the
# difference; nothing else does.
BLOG_ENV_CLEANUP_MODEL="${CLEANUP_MODEL:+set}"
BLOG_ENV_CURATE_MODEL="${CURATE_MODEL:+set}"
BLOG_ENV_CLAUDE_MODEL="${CLAUDE_MODEL:+set}"

if [ -n "${BLOG_PROFILE:-}" ]; then
  BLOG_PROFILE_FILE="$(blog_resolve_profile "$BLOG_PROFILE")"
  if [ ! -f "$BLOG_PROFILE_FILE" ]; then
    printf 'config: no such profile: %s (looked for %s)\n' "$BLOG_PROFILE" "$BLOG_PROFILE_FILE" >&2
    exit 2
  fi
  blog_apply_profile "$BLOG_PROFILE_FILE" || exit 2
fi

# --- arms ----------------------------------------------------------------------
# An ARM is a live experiment: a named set of deltas that runs every day beside
# the base configuration, writing into its own pool folder, until you promote it
# into the base or retire it (bin/arm.sh). BLOG_ARM names the one this run is
# for; empty means the base itself, which is an arm like any other except that
# it owns the pool's root folder and is the one a promotion writes into.
#
# Its deltas are applied AFTER any BLOG_PROFILE, so the arm cannot quietly
# outrank a profile you named on the command line, and after the environment for
# the same reason as everything else here.
ARMS_DIR="${ARMS_DIR:-$BLOG_REPO_DIR/arms}"
BLOG_ARM="${BLOG_ARM:-}"
case "$BLOG_ARM" in
  ''|base) BLOG_ARM="" ;;
  *[!A-Za-z0-9_-]*)
    printf 'config: bad arm name %s — use [A-Za-z0-9_-]\n' "$BLOG_ARM" >&2; exit 2 ;;
  *)
    if [ -f "$ARMS_DIR/$BLOG_ARM.env" ]; then
      blog_apply_profile "$ARMS_DIR/$BLOG_ARM.env" || exit 2
    else
      printf 'config: no such arm: %s (looked for %s)\n' "$BLOG_ARM" "$ARMS_DIR/$BLOG_ARM.env" >&2
      exit 2
    fi ;;
esac

# The base's own deltas. Empty (or absent) until a promotion writes into it, so
# a fresh checkout behaves exactly as the code says. Applied LAST, so it loses to
# the environment, to a profile and to an arm — it is the floor, not an override.
BLOG_BASE_ENV="${BLOG_BASE_ENV:-$BLOG_REPO_DIR/profiles/base.env}"
[ -f "$BLOG_BASE_ENV" ] && { blog_apply_profile "$BLOG_BASE_ENV" || exit 2; }

# --- the tree ----------------------------------------------------------------
# BLOG_ROOT is the data root. Everything below is derived from it and each one
# can be pinned on its own, so a sandbox can share (say) the live drafts/ while
# writing its posts somewhere harmless.
BLOG_ROOT="${BLOG_ROOT:-$BLOG_REPO_DIR}"

SYNC="${BLOG_SYNC:-$BLOG_ROOT/sync}"
DRAFTS="${BLOG_DRAFTS:-$BLOG_ROOT/drafts}"
WORK="${BLOG_WORK:-$BLOG_ROOT/work}"
LOGS="${BLOG_LOGS:-$BLOG_ROOT/logs}"
PROMPTS="${BLOG_PROMPTS:-$BLOG_ROOT/prompts}"
VAULT="${BLOG_VAULT:-$SYNC/Obsidian}"
POSTS="${BLOG_POSTS:-$VAULT/Posts}"
ARCHIVE="${BLOG_ARCHIVE:-$VAULT/Archive}"
TRASH="$POSTS/Discarded"
REJECTED="$POSTS/Rejected"
PROVENANCE="$POSTS/.provenance"

# Where THIS run's suggestions land, and the only pool it curates or evicts
# from. The base keeps the folder it always had, so nothing about reading on the
# phone changes when no experiment is running; an arm gets a folder of its own,
# which is the whole point — you see at a glance which pile a post came from.
# Keep/, Discarded/ and Rejected/ stay shared: a post's arm rides in its
# frontmatter, so moving it out of the pool never loses the attribution, and
# promotion does not have to reshuffle folders you have already judged.
if [ -n "$BLOG_ARM" ]; then POOL="$POSTS/$BLOG_ARM"; else POOL="$POSTS"; fi
ARMS_TSV="${ARMS_TSV:-$LOGS/arms.tsv}"

# The live arms, newest last: name <TAB> created <TAB> status <TAB> note.
# `active` is the only status that runs; promoted and retired arms stay in the
# file because the point of a registry is that you can read it in three months
# and know what you already tried.
blog_active_arms() {
  [ -f "$ARMS_TSV" ] || return 0
  awk -F'\t' '$3 == "active" && $1 !~ /^#/ { print $1 }' "$ARMS_TSV"
}

# Ledgers and stamps.
PROCESSED="$LOGS/processed.tsv"
PROCESS_LOG="$LOGS/process.log"
SUGGEST_LOG="$LOGS/suggest.log"
RECLEAN_LOG="$LOGS/reclean.log"
SUGGESTED="$LOGS/suggested.tsv"
GATE_TSV="$LOGS/gate.tsv"
USAGE_TSV="$LOGS/usage.tsv"
TYPOFIX_TSV="$LOGS/typofix.tsv"
PROVENANCE_TSV="$LOGS/provenance.tsv"
STAMP="$LOGS/suggest.lastdone"
ALIAS_STATE="$LOGS/aliases.last"

# --- prompts -----------------------------------------------------------------
# Resolution order for each prompt: an explicit override (CLEANUP_PROMPT=…),
# then the overlay (PROMPTS_DIR), then $PROMPTS, then the prompts/ that ship
# with the code. The last step is what lets a sandbox root exist without a
# prompts/ directory of its own.
PROMPTS_DIR="${PROMPTS_DIR:-}"

blog_prompt() {
  local n="$1" p
  if [ -n "$PROMPTS_DIR" ] && [ -f "$PROMPTS_DIR/$n" ]; then printf '%s' "$PROMPTS_DIR/$n"; return 0; fi
  if [ -f "$PROMPTS/$n" ]; then printf '%s' "$PROMPTS/$n"; return 0; fi
  if [ -f "$BLOG_REPO_DIR/prompts/$n" ]; then printf '%s' "$BLOG_REPO_DIR/prompts/$n"; return 0; fi
  printf '%s' "$PROMPTS/$n"      # doesn't exist; the caller reports it
}

CLEANUP_PROMPT="${CLEANUP_PROMPT:-$(blog_prompt cleanup.md)}"
STRUCTURE_PROMPT="${STRUCTURE_PROMPT:-$(blog_prompt structure.md)}"
SUGGEST_PROMPT="${SUGGEST_PROMPT:-$(blog_prompt suggest.md)}"
CURATE_PROMPT="${CURATE_PROMPT:-$(blog_prompt curate.md)}"
TYPO_PROMPT="${TYPO_PROMPT:-$(blog_prompt typos.md)}"
NAMES_PROMPT="${NAMES_PROMPT:-$(blog_prompt names.md)}"
ANCHOR="${ANCHOR:-$(blog_prompt style-anchor.md)}"

# --- directives ---------------------------------------------------------------
# The third slot in every prompt assembly: instructions + anchor + DIRECTIVE +
# input. A directive is a small free-text file — one paragraph, usually — that
# says something the shared prompt does not. A persona ("stitch as author X
# would") is a directive, not a prompt fork. Empty by default, and an empty
# directive changes the stream by not one byte.
CLEANUP_DIRECTIVE="${CLEANUP_DIRECTIVE:-}"
CURATE_DIRECTIVE="${CURATE_DIRECTIVE:-}"

# PERSONAS: a TSV of `name <TAB> directive-file`, one generation call each,
# with MAX_NEW split between them (see suggest.sh). Unset = one anonymous
# persona = exactly today's single call.
PERSONAS="${PERSONAS:-}"

# --- commands ------------------------------------------------------------------
TRANSCRIBE="${TRANSCRIBE:-$BLOG_REPO_DIR/bin/transcribe.sh}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
NOTIFY="${NOTIFY:-$BLOG_REPO_DIR/bin/notify.sh}"

# --- models --------------------------------------------------------------------
# Per stage, because the stages are different jobs. Cleanup is a constrained
# voice-preserving transform (Sonnet handles it and burns less subscription);
# curation is the judgment-heavy step, reading the whole corpus (Opus); the typo
# pass is the most mechanical call there is (Sonnet). CLAUDE_MODEL still works
# as the blunt override it always was — process.sh and reclean.sh read
# CLEANUP_MODEL, suggest.sh reads CURATE_MODEL — except for the typo pass,
# which has never followed CLAUDE_MODEL and still doesn't.
#
# Precedence, highest first:
#   1. the stage key from the ENVIRONMENT   CURATE_MODEL=x bin/suggest.sh
#   2. CLAUDE_MODEL from the ENVIRONMENT    the blunt override, as it always was
#   3. the stage key from the PROFILE
#   4. CLAUDE_MODEL from the PROFILE
#   5. the default
# By the time this runs, 1 and 3 are the same variable — a profile exports into
# this shell — which is why the flags above were taken before it was applied.
# Without them a profile naming CURATE_MODEL would silently outrank a
# CLAUDE_MODEL on the command line, and the environment would stop being the
# thing that wins, which is the one rule this file promises everywhere else.
blog_model() {
  local from_env="$1" resolved="$2" default="$3"
  if [ -n "$from_env" ];               then printf '%s' "$resolved"; return 0; fi
  if [ -n "$BLOG_ENV_CLAUDE_MODEL" ];  then printf '%s' "$CLAUDE_MODEL"; return 0; fi
  if [ -n "$resolved" ];               then printf '%s' "$resolved"; return 0; fi
  printf '%s' "${CLAUDE_MODEL:-$default}"
}
CLEANUP_MODEL="$(blog_model "$BLOG_ENV_CLEANUP_MODEL" "${CLEANUP_MODEL:-}" claude-sonnet-5)"
CURATE_MODEL="$(blog_model "$BLOG_ENV_CURATE_MODEL"  "${CURATE_MODEL:-}"  claude-opus-5)"
# The typo pass has never followed CLAUDE_MODEL and still doesn't.
TYPO_MODEL="${TYPO_MODEL:-claude-sonnet-5}"

# --- knobs: process.sh ----------------------------------------------------------
STRUCTURE="${STRUCTURE:-0}"
SYNC_KEEP_DAYS="${SYNC_KEEP_DAYS:-14}"

# --- knobs: transcribe.sh -------------------------------------------------------
WHISPER_MODEL="${WHISPER_MODEL:-$BLOG_REPO_DIR/models/ggml-large-v3-q5_0.bin}"
WHISPER_LANG="${WHISPER_LANG:-auto}"
WHISPER_MARKS="${WHISPER_MARKS:-1}"
WHISPER_CONF_LOW="${WHISPER_CONF_LOW:-0.40}"
WHISPER_CONF_VLOW="${WHISPER_CONF_VLOW:-0.25}"
# Thread count is a performance knob, not a behaviour one: deliberately left out
# of the fingerprint so the same variant fingerprints alike on any machine.
WHISPER_THREADS="${WHISPER_THREADS:-}"

# --- knobs: suggest.sh ----------------------------------------------------------
MAX_LONG="${MAX_LONG:-4}"
MAX_SHORT="${MAX_SHORT:-8}"
MAX_NEW="${MAX_NEW:-8}"
TRASH_DAYS="${TRASH_DAYS:-14}"
CORPUS_MAX="${CORPUS_MAX:-150000}"
HISTORY_LINES="${HISTORY_LINES:-40}"
ARCHIVE_DAYS="${ARCHIVE_DAYS:-14}"
VERBATIM_MIN="${VERBATIM_MIN:-85}"
GLUE_MAX_WORDS="${GLUE_MAX_WORDS:-12}"
NEW_SLACK_EVERY="${NEW_SLACK_EVERY:-25}"

# How many words the gate lets a candidate sentence CUT OUT OF ITS MIDDLE and
# still count as the author's sentence (TWEAKED) rather than as the model's
# prose — and only when the sentence is found in a DICTATED note. 0 disables it,
# which is the shipped default: the gate then behaves exactly as it did before
# this knob existed.
#
# The middle is the part that needed a knob. Cutting a sentence's ENDS is
# already free for every source, because source_of does a substring search over
# the whole note: drop "so I guess what I'm saying is" off the front of a spoken
# sentence and what remains is still literally present in the note, so it grades
# VERBATIM. What no amount of end-trimming can close is a hole — "the plan, no
# wait, the plan depends on one connector" cut down to "the plan depends on one
# connector" is two runs of his words with something removed between them, and
# nothing in the gate could see that as his.
#
# Which is right for typed notes and wrong for dictation. He chose the words in
# a typed note and could see them while he did; the false starts in a voice memo
# are an artefact of speaking, and cutting one is closer to transcription than
# to editing. So the licence is granted per mouth, and the cap keeps it local: a
# hole of a few words is a restart, a hole of thirty is two unrelated thoughts
# welded together and must still fail.
VOICE_TWEAK_GAP="${VOICE_TWEAK_GAP:-0}"

# How similar a REWRITTEN sentence must stay to the spoken sentence it came from
# — word overlap as a percentage — for the gate to still count it as the
# author's material rather than the model's prose. Dictated notes only. 0
# disables it and is the shipped default.
#
# VOICE_TWEAK_GAP above only permits CUTS: what survives is still his words in
# his order. This is the knob that permits genuine rewording, and it exists
# because cutting is not actually the interesting difference between the two
# mouths. A typed note was thought about — he composed it, saw it, and left it
# as it stands. A spoken one is first-draft thinking at speaking speed, and its
# sentences are often not the sentences he would have written for the same
# thought. Restating one of those is not falsifying him; refusing to is what
# keeps dictated material out of the pool.
#
# What stops this from becoming "the model may write whatever it likes about
# him" is that a rewrite must still be ANCHORED: the gate finds the single
# dictated sentence it is nearest to and requires that much word overlap, so the
# sentence can only restate something he actually said, and the report names
# which one. A floor around 50 permits a real rewrite while still demanding most
# of the content words; below about 35 the anchor stops meaning anything and the
# class becomes a licence to invent.
#
# The pillar this bends is the one the whole pipeline stands on, so it bends for
# ONE mouth, under a floor, counted on every gate line, and never in the base.
VOICE_REWRITE_MIN="${VOICE_REWRITE_MIN:-0}"
REJECT_DAYS="${REJECT_DAYS:-30}"
REUSE_MIN_WORDS="${REUSE_MIN_WORDS:-6}"
REUSE_DROP_PCT="${REUSE_DROP_PCT:-75}"
TYPO_FIX="${TYPO_FIX:-1}"
TYPO_MIN_LEN="${TYPO_MIN_LEN:-4}"
TYPO_MAX_PCT="${TYPO_MAX_PCT:-5}"

# The stitching gate's policy:
#   enforce  a failing candidate is rejected     (the pillar; the only setting
#            the live pipeline ever runs)
#   report   the gate classifies but never rejects — for measuring how much a
#            relaxed variant actually rewrites. EXPERIMENTS ONLY.
GATE_MODE="${GATE_MODE:-enforce}"
# Annotate GLUE/NEW sentences with their nearest corpus sentence and a word
# diff. That annotation IS the evaluation data for a loose-gate experiment, so
# report mode turns it on whether you asked for it or not.
GATE_TRACE="${GATE_TRACE:-0}"
[ "$GATE_MODE" = report ] && GATE_TRACE=1

NAME_SCAN="${NAME_SCAN:-1}"
SELF_NAME="${SELF_NAME:-Christian}"
# Under BLOG_ROOT, not the code root: an experiment that re-roots the tree must
# not extend the live alias map through the name scout. A sandbox gets its own
# copy (bin/ab.sh seeds one), and the live run is unaffected because BLOG_ROOT
# is the repo.
ALIASES="${ALIASES:-$BLOG_ROOT/private/aliases.tsv}"
# The reserve alias pools the name scout draws from. Hard assignments, NOT
# overridable: they are on the privacy path, not the experiment path, and they
# are deliberately absent from the fingerprint — so an override would change
# which pseudonym a real person is given while leaving no trace in any artifact.
# There is no experiment that wants this, and a stray exported RESERVE_F in a
# shell should never reach the alias map.
RESERVE_F="Judith Helena Ronja Merle Frida Carla Teresa Bianca Sofia Irene Livia Paola Zoe Selin Aylin Esra Noemi Linnea Greta Elif Sanne Rosa Alma Leonie Tilda Edith Runa Amara"
RESERVE_M="Anton Bruno Dario Fabio Georg Henrik Ivo Kilian Lorenz Matteo Nils Oskar Pavel Quentin Ruben Stefan Tobias Umberto Wim Yannick Aldo Boris Cem Darius Enzo Farid"
RESERVE_X="Kim Luca Toni Micha Rowan Sage Noor Eli"

# --- identity ------------------------------------------------------------------
blog_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

blog_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}

# The knobs that define a variant. Order is irrelevant (the dump is sorted);
# membership is not. Paths, thread counts, and anything carrying a real name
# (SELF_NAME, ALIASES, the reserve pools) stay out: the first two are not
# behaviour, the last must never be printed by a command that ends up in a log.
BLOG_FINGERPRINT_KEYS="
CLEANUP_MODEL CURATE_MODEL TYPO_MODEL
STRUCTURE SYNC_KEEP_DAYS
WHISPER_LANG WHISPER_MARKS WHISPER_CONF_LOW WHISPER_CONF_VLOW
MAX_LONG MAX_SHORT MAX_NEW TRASH_DAYS CORPUS_MAX HISTORY_LINES ARCHIVE_DAYS
VERBATIM_MIN GLUE_MAX_WORDS NEW_SLACK_EVERY GATE_MODE GATE_TRACE REJECT_DAYS
VOICE_TWEAK_GAP VOICE_REWRITE_MIN
REUSE_MIN_WORDS REUSE_DROP_PCT
TYPO_FIX TYPO_MIN_LEN TYPO_MAX_PCT
NAME_SCAN
"

# sha256 of a file's CONTENT, or "-" when there is no such file. A prompt that
# moved is the same prompt; a prompt that changed is a different variant.
blog_file_hash() {
  if [ -n "${1:-}" ] && [ -f "$1" ]; then blog_sha256 "$1"; else printf '%s' -; fi
}

# The resolved configuration, sorted, one key=value per line.
blog_config_dump() {
  local k
  {
    for k in $BLOG_FINGERPRINT_KEYS; do
      printf '%s=%s\n' "$k" "${!k}"
    done
    printf 'prompt.cleanup=%s\n'   "$(blog_file_hash "$CLEANUP_PROMPT")"
    printf 'prompt.structure=%s\n' "$(blog_file_hash "$STRUCTURE_PROMPT")"
    printf 'prompt.suggest=%s\n'   "$(blog_file_hash "$SUGGEST_PROMPT")"
    printf 'prompt.curate=%s\n'    "$(blog_file_hash "$CURATE_PROMPT")"
    printf 'prompt.typos=%s\n'     "$(blog_file_hash "$TYPO_PROMPT")"
    printf 'prompt.names=%s\n'     "$(blog_file_hash "$NAMES_PROMPT")"
    printf 'prompt.anchor=%s\n'    "$(blog_file_hash "$ANCHOR")"
    printf 'directive.cleanup=%s\n' "$(blog_file_hash "$CLEANUP_DIRECTIVE")"
    printf 'directive.curate=%s\n'  "$(blog_file_hash "$CURATE_DIRECTIVE")"
    # Personas enter by name and by the content of what they instruct.
    local name file
    while IFS=$'\t' read -r name file _; do
      [ -n "${name:-}" ] || continue
      case "$name" in '#'*) continue ;; esac
      printf 'persona.%s=%s\n' "$name" "$(blog_file_hash "$(blog_persona_path "$file")")"
    done < <(blog_persona_rows)
  } | LC_ALL=C sort
}

# Persona rows, or nothing. Kept here (rather than in suggest.sh) because the
# fingerprint has to see them too.
blog_persona_rows() {
  [ -n "$PERSONAS" ] && [ -f "$PERSONAS" ] || return 0
  awk -F'\t' 'NF >= 2 && $1 !~ /^#/ && $1 != "" { print $1 "\t" $2 }' "$PERSONAS"
}

# A persona's directive file, resolved relative to the PERSONAS file itself so
# a persona set is one movable directory.
blog_persona_path() {
  local f="${1:-}"
  [ -n "$f" ] || { printf ''; return 0; }
  case "$f" in
    /*) printf '%s' "$f" ;;
    *)  printf '%s' "$(dirname "$PERSONAS")/$f" ;;
  esac
}

BLOG_FINGERPRINT="${BLOG_FINGERPRINT:-}"
blog_fingerprint() {
  [ -n "$BLOG_FINGERPRINT" ] || \
    BLOG_FINGERPRINT="$(blog_config_dump | blog_sha256_stdin | cut -c1-12)"
  printf '%s' "$BLOG_FINGERPRINT"
}

# What gets stamped on artifacts: <name>:<fingerprint>. The name is the profile
# (or BLOG_VARIANT, which an experiment runner sets), so a report is readable;
# the fingerprint is what actually identifies the configuration, so two profiles
# that resolve alike are visibly the same variant.
blog_variant() {
  local name="${BLOG_VARIANT:-}"
  # A live arm names itself: reports and the pool statistics are read by arm,
  # so "B:9fc3" beats "default:9fc3" for something you will be looking at daily.
  if [ -z "$name" ] && [ -n "$BLOG_ARM" ]; then name="$BLOG_ARM"; fi
  if [ -z "$name" ]; then
    if [ -n "$BLOG_PROFILE_FILE" ]; then
      name="$(basename "$BLOG_PROFILE_FILE")"; name="${name%.env}"
    else
      name=default
    fi
  fi
  printf '%s:%s' "$name" "$(blog_fingerprint)"
}

# One id per invocation of a script, shared by every artifact that run writes —
# the join key between logs/provenance.tsv, logs/usage.tsv and the artifacts
# themselves. Stable within a run because it is computed once, at source time.
BLOG_RUN_ID="${BLOG_RUN_ID:-$(date '+%Y%m%dT%H%M%S')-$$}"

# The commit the pipeline itself was on. "unknown" outside a git checkout.
blog_git_commit() {
  git -C "$BLOG_REPO_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown'
}

fi   # BLOG_CONFIG_LOADED

# --- run directly to inspect ----------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-dump}" in
    dump)        blog_config_dump ;;
    fingerprint) blog_fingerprint; printf '\n' ;;
    variant)     blog_variant; printf '\n' ;;
    paths)
      printf 'BLOG_REPO_DIR=%s\n' "$BLOG_REPO_DIR"
      printf 'BLOG_ROOT=%s\n'     "$BLOG_ROOT"
      printf 'BLOG_ARM=%s\n' "${BLOG_ARM:-(base)}"
      for v in SYNC VAULT POSTS POOL ARCHIVE DRAFTS WORK LOGS PROMPTS PROMPTS_DIR ARMS_DIR \
               CLEANUP_PROMPT STRUCTURE_PROMPT SUGGEST_PROMPT CURATE_PROMPT \
               TYPO_PROMPT NAMES_PROMPT ANCHOR CLEANUP_DIRECTIVE CURATE_DIRECTIVE \
               PERSONAS ALIASES; do
        printf '%s=%s\n' "$v" "${!v}"
      done
      printf 'profile=%s\n' "${BLOG_PROFILE_FILE:-(none)}"
      ;;
    *) printf 'usage: config.sh [dump|fingerprint|variant|paths]\n' >&2; exit 2 ;;
  esac
fi
