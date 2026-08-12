#!/usr/bin/env bash
# tests/check_defaults.sh — the guard on lib/config.sh.
#
# The config layer sits under every script in the pipeline, so its one
# non-negotiable property is that it changes nothing: with no profile and no
# environment it must resolve to exactly the values the scripts hard-coded
# before it existed. This asserts that value by value, and then checks the four
# mechanisms built on top of it — the re-rootable tree, the prompt overlay,
# profile precedence, and the fingerprint.
#
# No network, no Claude call, no writes outside a scratch dir.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=lib/config.sh

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; shift; [ $# -eq 0 ] || printf '     %s\n' "$@"; }

# $1 name, $2 expected, $3 actual
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want: $2" "got:  $3"; fi
}

# Resolve one variable under a given environment: $1 = variable, rest = env
# assignments. The -u list clears whatever the caller's own shell happens to
# carry, so the test says what it means; an assignment in "$@" puts it back.
resolve() {
  local var="$1"; shift
  env -u BLOG_PROFILE -u BLOG_ROOT -u PROMPTS_DIR -u BLOG_VARIANT "$@" \
    bash -c '. lib/config.sh; printf "%s" "${'"$var"'}"'
}

# The fingerprint under a given environment, same convention.
fp_of() { env -u BLOG_PROFILE -u BLOG_ROOT -u PROMPTS_DIR -u BLOG_VARIANT "$@" bash "$CONFIG" fingerprint; }

# --- 1. a profileless run resolves to today's exact values --------------------
# Every line here was copied out of the scripts as they stood before the config
# layer existed. If one of them changes on purpose, change it here too — the
# point is that it cannot change by accident.
while IFS='=' read -r key want; do
  [ -n "$key" ] || continue
  eq "default $key" "$want" "$(resolve "$key")"
done <<'DEFAULTS'
CLEANUP_MODEL=claude-sonnet-5
CURATE_MODEL=claude-opus-5
TYPO_MODEL=claude-sonnet-5
CLAUDE_BIN=claude
STRUCTURE=0
SYNC_KEEP_DAYS=14
MAX_LONG=4
MAX_SHORT=8
MAX_NEW=8
TRASH_DAYS=14
CORPUS_MAX=150000
HISTORY_LINES=40
ARCHIVE_DAYS=14
VERBATIM_MIN=85
GLUE_MAX_WORDS=12
NEW_SLACK_EVERY=25
REJECT_DAYS=30
REUSE_MIN_WORDS=6
REUSE_DROP_PCT=75
TYPO_FIX=1
TYPO_MIN_LEN=4
TYPO_MAX_PCT=5
NAME_SCAN=1
SELF_NAME=Christian
GATE_MODE=enforce
GATE_TRACE=0
WHISPER_LANG=auto
WHISPER_MARKS=1
WHISPER_CONF_LOW=0.40
WHISPER_CONF_VLOW=0.25
PERSONAS=
CLEANUP_DIRECTIVE=
CURATE_DIRECTIVE=
DEFAULTS

# CLAUDE_MODEL is the blunt override it always was — for cleanup and curation,
# never for the typo pass.
eq "CLAUDE_MODEL overrides cleanup" claude-fable-5 "$(resolve CLEANUP_MODEL CLAUDE_MODEL=claude-fable-5)"
eq "CLAUDE_MODEL overrides curation" claude-fable-5 "$(resolve CURATE_MODEL CLAUDE_MODEL=claude-fable-5)"
eq "CLAUDE_MODEL leaves the typo pass" claude-sonnet-5 "$(resolve TYPO_MODEL CLAUDE_MODEL=claude-fable-5)"

# --- 2. the tree ---------------------------------------------------------------
REPO="$(pwd)"
for pair in "SYNC=$REPO/sync" "VAULT=$REPO/sync/Obsidian" "POSTS=$REPO/sync/Obsidian/Posts" \
            "TRASH=$REPO/sync/Obsidian/Posts/Discarded" "REJECTED=$REPO/sync/Obsidian/Posts/Rejected" \
            "PROVENANCE=$REPO/sync/Obsidian/Posts/.provenance" "ARCHIVE=$REPO/sync/Obsidian/Archive" \
            "DRAFTS=$REPO/drafts" "WORK=$REPO/work" "LOGS=$REPO/logs" \
            "PROCESSED=$REPO/logs/processed.tsv" "USAGE_TSV=$REPO/logs/usage.tsv" \
            "ALIASES=$REPO/private/aliases.tsv" "CLEANUP_PROMPT=$REPO/prompts/cleanup.md" \
            "SUGGEST_PROMPT=$REPO/prompts/suggest.md" "ANCHOR=$REPO/prompts/style-anchor.md"; do
  eq "path ${pair%%=*}" "${pair#*=}" "$(resolve "${pair%%=*}")"
done

# BLOG_ROOT moves the whole data tree and nothing else: the code, the prompts
# and the model stay where they ship.
eq "BLOG_ROOT re-roots sync"   "$SB/r/sync"   "$(resolve SYNC   BLOG_ROOT="$SB/r")"
eq "BLOG_ROOT re-roots drafts" "$SB/r/drafts" "$(resolve DRAFTS BLOG_ROOT="$SB/r")"
eq "BLOG_ROOT re-roots logs"   "$SB/r/logs"   "$(resolve LOGS   BLOG_ROOT="$SB/r")"
eq "BLOG_ROOT re-roots posts"  "$SB/r/sync/Obsidian/Posts" "$(resolve POSTS BLOG_ROOT="$SB/r")"
# A sandbox root has no prompts/ of its own — the shipped ones must still resolve.
eq "prompts fall back to the repo" "$REPO/prompts/cleanup.md" \
   "$(resolve CLEANUP_PROMPT BLOG_ROOT="$SB/r")"
# One path can be pinned without moving the rest.
eq "BLOG_DRAFTS alone" "$SB/d" "$(resolve DRAFTS BLOG_DRAFTS="$SB/d")"
eq "BLOG_DRAFTS leaves sync" "$REPO/sync" "$(resolve SYNC BLOG_DRAFTS="$SB/d")"

# --- 3. the prompt overlay ------------------------------------------------------
mkdir -p "$SB/overlay"
printf 'overlaid\n' > "$SB/overlay/suggest.md"
eq "overlay wins for the file it has" "$SB/overlay/suggest.md" \
   "$(resolve SUGGEST_PROMPT PROMPTS_DIR="$SB/overlay")"
eq "overlay falls through for the rest" "$REPO/prompts/curate.md" \
   "$(resolve CURATE_PROMPT PROMPTS_DIR="$SB/overlay")"
eq "an explicit prompt beats the overlay" "$SB/overlay/suggest.md" \
   "$(resolve CURATE_PROMPT PROMPTS_DIR="$SB/overlay" CURATE_PROMPT="$SB/overlay/suggest.md")"

# --- 4. profiles ----------------------------------------------------------------
cat > "$SB/p.env" <<'PROFILE'
# a comment, and a blank line follow

MAX_NEW=2
CURATE_MODEL=claude-sonnet-5
RESERVE_X="Kim Luca"
PROFILE
eq "profile sets its delta" 2 "$(resolve MAX_NEW BLOG_PROFILE="$SB/p.env")"
eq "profile leaves the rest" 8 "$(resolve MAX_SHORT BLOG_PROFILE="$SB/p.env")"
eq "profile handles quotes" "Kim Luca" "$(resolve RESERVE_X BLOG_PROFILE="$SB/p.env")"
eq "the environment outranks the profile" 5 "$(resolve MAX_NEW BLOG_PROFILE="$SB/p.env" MAX_NEW=5)"
# The shipped inventory repeats the defaults, so running under it must resolve
# to the same variant — that is what makes it safe documentation.
eq "profiles/default.env is a no-op" "$(fp_of)" "$(fp_of BLOG_PROFILE=default)"
if BLOG_PROFILE=nope bash -c '. lib/config.sh' 2>/dev/null; then
  bad "a missing profile is an error"
else
  ok "a missing profile is an error"
fi

# --- 5. the fingerprint ----------------------------------------------------------
fp() { fp_of "$@"; }
base="$(fp)"
eq "fingerprint is stable" "$base" "$(fp)"
eq "fingerprint ignores the root" "$base" "$(fp BLOG_ROOT="$SB/r")"
eq "fingerprint ignores thread count" "$base" "$(fp WHISPER_THREADS=1)"
eq "fingerprint ignores the alias map" "$base" "$(fp ALIASES=/nowhere/aliases.tsv)"
if [ "$(fp MAX_NEW=3)" = "$base" ]; then bad "fingerprint follows a knob"; else ok "fingerprint follows a knob"; fi
if [ "$(fp GATE_MODE=report)" = "$base" ]; then bad "fingerprint follows the gate mode"; else ok "fingerprint follows the gate mode"; fi
if [ "$(fp PROMPTS_DIR="$SB/overlay")" = "$base" ]; then
  bad "fingerprint follows prompt CONTENT"
else
  ok "fingerprint follows prompt CONTENT"
fi
# The same prompt at a different path is the same variant: content, not path.
mkdir -p "$SB/same"
cp prompts/suggest.md "$SB/same/suggest.md"
eq "fingerprint ignores prompt PATH" "$base" "$(fp PROMPTS_DIR="$SB/same")"
# The dump must never print anything personal.
if bash "$CONFIG" dump | grep -qE '^(SELF_NAME|ALIASES|RESERVE_)'; then
  bad "the dump leaks privacy configuration"
else
  ok "the dump keeps privacy configuration out"
fi
# And the variant string is <name>:<fingerprint>: the profile's name so a
# report reads, the fingerprint so two profiles that resolve alike are visibly
# one variant.
eq "variant of a profileless run" "default:$base" \
   "$(env -u BLOG_PROFILE -u BLOG_ROOT bash "$CONFIG" variant)"
eq "variant names the profile" "p:$(env -u BLOG_ROOT BLOG_PROFILE="$SB/p.env" bash "$CONFIG" fingerprint)" \
   "$(env -u BLOG_ROOT BLOG_PROFILE="$SB/p.env" bash "$CONFIG" variant)"
eq "BLOG_VARIANT wins outright" "loose-a:$base" \
   "$(env -u BLOG_PROFILE -u BLOG_ROOT BLOG_VARIANT=loose-a bash "$CONFIG" variant)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
