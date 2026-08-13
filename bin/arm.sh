#!/usr/bin/env bash
#
# arm.sh — live A/B arms: create one, let it run daily beside the base, then
# promote the winner into the base or retire it.
#
#   arm.sh new B CURATE_MODEL=claude-sonnet-5   create an arm and activate it
#   arm.sh new B --run  ...                     …and generate for it immediately
#   arm.sh list                                 what exists, and what it is
#   arm.sh run [B ...]                          generate for an arm now
#   arm.sh try B [--full]                       run it against the SAMPLE corpus,
#                                               in a sandbox, reproducibly;
#                                               --full starts from the audio
#   arm.sh samples                              (re)build samples/real from real.list
#   arm.sh status                               accept rates per arm
#   arm.sh promote B                            B's deltas become the base
#   arm.sh retire C                             C stops running; its pool is binned
#
# An arm is a named set of deltas (arms/<name>.env) plus a folder of its own
# (sync/Obsidian/Posts/<name>/). The daily job runs the base first and then
# every active arm against the SAME corpus, so what differs between the folders
# is the configuration and nothing else. Sentence claims are scoped per arm, so
# no arm can spend material out from under another.
#
# What stays shared, deliberately: Keep/, Discarded/ and Rejected/. You judge
# posts by moving them, and a post's arm rides in its frontmatter, so the
# attribution survives the move — and promoting an arm does not require
# reshuffling anything you have already decided about.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"

BASE_ENV="$BLOG_BASE_ENV"
SAMPLES="$BLOG_REPO_DIR/samples"

die() { printf 'arm: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*" >&2; }

mkdir -p "$ARMS_DIR" "$LOGS"

# --- the registry ---------------------------------------------------------------
# name <TAB> created <TAB> status <TAB> note. Promoted and retired arms stay in
# it forever: the point of writing experiments down is being able to read, in
# three months, what you already tried and what came of it.
reg_status() {
  [ -f "$ARMS_TSV" ] || return 0
  awk -F'\t' -v n="$1" '$1 == n { s = $3 } END { print s }' "$ARMS_TSV"
}

reg_set() {   # name status [note]
  local name="$1" status="$2" note="${3:-}" tmp
  tmp="$(mktemp)"
  [ -f "$ARMS_TSV" ] && awk -F'\t' -v n="$1" '$1 != n' "$ARMS_TSV" > "$tmp"
  local created
  created="$( { [ -f "$ARMS_TSV" ] && awk -F'\t' -v n="$1" '$1 == n { print $2; exit }' "$ARMS_TSV"; } || true)"
  [ -n "$created" ] || created="$(date '+%Y-%m-%d')"
  [ -n "$note" ] || note="$( { [ -f "$ARMS_TSV" ] && awk -F'\t' -v n="$1" '$1 == n { print $4; exit }' "$ARMS_TSV"; } || true)"
  printf '%s\t%s\t%s\t%s\n' "$name" "$created" "$status" "$note" >> "$tmp"
  sort -t$'\t' -k2,2 -k1,1 "$tmp" > "$ARMS_TSV"
  rm -f "$tmp"
}

# The -u arguments that give a child a clean slate. This script sources
# lib/config.sh, which EXPORTS whatever profiles/base.env holds; those exports
# would then outrank an arm's own file in any child process — so a promoted base
# would silently pin every arm to its values, and the "differs from the base in"
# report below would understate the arm it just wrote. Same reason suggest.sh
# clears them before a fan-out.
clean_env_args() {
  local k
  for k in $BLOG_APPLIED_KEYS; do printf '%s\n' "-u" "$k"; done
}

arm_file() { printf '%s/%s.env' "$ARMS_DIR" "$1"; }
arm_pool() { printf '%s/%s' "$POSTS" "$1"; }

valid_name() {
  case "$1" in
    ''|base|Keep|Discarded|Rejected) return 1 ;;
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# --- new --------------------------------------------------------------------------
cmd_new() {
  [ "$#" -ge 1 ] || die "usage: arm.sh new <name> [--from <profile>] [--note '…'] KEY=VALUE …"
  local name="$1"; shift
  valid_name "$name" || die "bad arm name '$name' — [A-Za-z0-9_-], and not base/Keep/Discarded/Rejected"
  [ -f "$(arm_file "$name")" ] && die "arm '$name' already exists — edit $(arm_file "$name") or retire it"

  local note="" from="" run=0 kvs=() a
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note) note="$2"; shift 2 ;;
      --from) from="$2"; shift 2 ;;
      --run)  run=1; shift ;;
      *=*)    kvs+=("$1"); shift ;;
      *) die "unexpected argument: $1 (deltas are KEY=VALUE)" ;;
    esac
  done
  [ "${#kvs[@]}" -gt 0 ] || [ -n "$from" ] \
    || die "an arm needs at least one delta: arm.sh new $name CURATE_MODEL=claude-sonnet-5"

  {
    printf '# arm: %s\n' "$name"
    [ -z "$note" ] || printf '# %s\n' "$note"
    printf '# created %s. Deltas from the base; everything unlisted falls through.\n' "$(date '+%Y-%m-%d')"
    printf '#\n# Runs every day beside the base, into sync/Obsidian/Posts/%s/.\n' "$name"
    printf '# bin/arm.sh promote %s folds these into profiles/base.env.\n\n' "$name"
    if [ -n "$from" ]; then
      local f; f="$(blog_resolve_profile "$from")"
      [ -f "$f" ] || die "no such profile: $from"
      printf '# from profile %s:\n' "$from"
      grep -vE '^[[:space:]]*(#|$)' "$f" || true
      printf '\n'
    fi
    local kv
    for kv in ${kvs[@]+"${kvs[@]}"}; do printf '%s\n' "$kv"; done
  } > "$(arm_file "$name")"

  mkdir -p "$(arm_pool "$name")"
  reg_set "$name" active "$note"
  say "created $(arm_file "$name")"
  say "pool:   ${POSTS#"$BLOG_ROOT"/}/$name/"
  local cleanup_args=()
  while IFS= read -r a; do cleanup_args+=("$a"); done < <(clean_env_args)
  say "config: $(env ${cleanup_args[@]+"${cleanup_args[@]}"} BLOG_ARM="$name" \
                   bash "$BLOG_LIB_DIR/config.sh" variant)"
  local before after
  before="$(env ${cleanup_args[@]+"${cleanup_args[@]}"} bash "$BLOG_LIB_DIR/config.sh" dump)"
  after="$(env ${cleanup_args[@]+"${cleanup_args[@]}"} BLOG_ARM="$name" \
             bash "$BLOG_LIB_DIR/config.sh" dump)"
  say "differs from the base in:"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> /  /p' >&2 || true
  [ "$run" = 1 ] && cmd_run "$name"
  return 0
}

# --- run --------------------------------------------------------------------------
# Generation for one arm, now. Skips the shared preprocessing (that belongs to
# the daily base run) and writes only into the arm's own pool.
cmd_run() {
  local arms=("$@")
  if [ "${#arms[@]}" -eq 0 ]; then
    local a2
    while IFS= read -r a2; do [ -n "$a2" ] && arms+=("$a2"); done < <(blog_active_arms)
    [ "${#arms[@]}" -gt 0 ] || die "no active arms — arm.sh new <name> …"
  fi
  local a
  for a in "${arms[@]}"; do
    [ -f "$(arm_file "$a")" ] || die "no such arm: $a"
    say "--- $a ---"
    local unset_args=() k
    while IFS= read -r k; do unset_args+=("$k"); done < <(clean_env_args)
    env ${unset_args[@]+"${unset_args[@]}"} \
        ARM_RUN=1 BLOG_ARM="$a" SUGGEST_SCHEDULED=0 "$SCRIPT_DIR/suggest.sh" \
      || say "WARN arm $a failed"
  done
}

# --- try --------------------------------------------------------------------------
# The reproducible one: the arm against the SAMPLE corpus that ships with the
# repo, in a sandbox, touching nothing real. Same notes every time, so two runs
# differ by the configuration and the model's own variance and nothing else —
# which is what you want when you are still deciding whether an idea is worth
# a fortnight of your pool.
cmd_try() {
  [ "$#" -ge 1 ] || die "usage: arm.sh try <name|base> [--keep]"
  local name="$1"; shift
  local keep=0 full=0 real=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep) keep=1; shift ;;
      # --real swaps the invented corpus for the author's own selection
      # (samples/real, built by `arm.sh samples`); --full additionally starts
      # from the RECORDINGS, so transcription and cleanup are part of the test
      # and an arm that changes them is actually exercised.
      --real) real=1; shift ;;
      --full) real=1; full=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ "$name" = base ] || [ -f "$(arm_file "$name")" ] || die "no such arm: $name"

  local src="$SAMPLES/notes"
  if [ "$real" = 1 ]; then
    src="$SAMPLES/real/notes"
    [ -d "$src" ] || die "no real sample set — run: bin/arm.sh samples"
  fi
  [ -d "$src" ] || die "no sample corpus at $src"

  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/armtry.XXXXXX")"
  mkdir -p "$root/sync/Obsidian" "$root/drafts" "$root/logs" "$root/work" "$root/private"
  cp "$src"/*.md "$root/sync/Obsidian/" 2>/dev/null || true
  : > "$root/private/aliases.tsv"
  # Same mtimes every run, so corpus ordering and the archive clock cannot drift
  # between two tries. The date is the samples' own, not today's.
  touch -t 202601150900 "$root/sync/Obsidian"/*.md 2>/dev/null || true

  say "sandbox: $root"
  local armenv=()
  [ "$name" = base ] || armenv=(BLOG_ARM="$name")

  # The full chain: recordings in, bundles out, and only then the curator. The
  # transcription stage answers from the cache bin/arm.sh samples seeded (keyed
  # by audio hash AND whisper settings), so this costs the cleanup calls and
  # nothing else — unless the arm changes a whisper setting, in which case the
  # key misses and whisper really runs, which is the point.
  if [ "$full" = 1 ]; then
    local a n=0
    shopt -s nullglob
    for a in "$SAMPLES"/real/audio/*; do cp -p "$a" "$root/sync/"; n=$((n + 1)); done
    shopt -u nullglob
    [ "$n" -gt 0 ] || die "no recordings in $SAMPLES/real/audio — run: bin/arm.sh samples"
    say "--- transcribe + clean ($n recording(s)) ---"
    env -u BLOG_PROFILE ${armenv[@]+"${armenv[@]}"} \
        BLOG_ROOT="$root" NOTIFY=/bin/true SYNC_KEEP_DAYS=99999 \
        TRANSCRIBE="$SCRIPT_DIR/ab-transcribe.sh" \
        "$SCRIPT_DIR/process.sh" >&2 || say "WARN the cleanup stage failed"
    say "--- suggest ---"
  fi
  env -u BLOG_PROFILE ${armenv[@]+"${armenv[@]}"} \
      BLOG_ROOT="$root" ARCHIVE_DAYS=99999 TYPO_FIX=0 NAME_SCAN=0 \
      NOTIFY=/bin/true "$SCRIPT_DIR/suggest.sh" >&2 || say "WARN the run failed"

  local pool="$root/sync/Obsidian/Posts"
  [ "$name" = base ] || pool="$pool/$name"
  say ""
  say "=== what $name proposed from the sample corpus ==="
  local p n=0
  shopt -s nullglob
  for p in "$pool"/*.md; do
    n=$((n + 1))
    printf '\n--- %s\n' "$(basename "$p")"
    cat "$p"
  done
  for p in "$root/sync/Obsidian/Posts/Rejected"/*.md; do
    printf '\n--- REJECTED %s\n%s\n' "$(basename "$p")" "$(sed -n 's/^rejected: //p' "$p")"
  done
  shopt -u nullglob
  [ "$n" -gt 0 ] || say "(nothing accepted)"
  if [ "$keep" = 1 ]; then say "kept: $root"; else rm -rf "$root"; fi
}

# --- samples ------------------------------------------------------------------------
# Build samples/real/ from the author's own material, per samples/real.list.
# Gitignored, because it is his recordings and his notes; the LIST is committed,
# so the selection survives even though the material cannot.
#
# The recordings come with the transcript their bundle already holds, which is
# then seeded into bin/ab-transcribe.sh's cache under the key the current
# whisper settings produce. That is what makes `try --full` affordable: the
# transcription stage is real, and answers instantly, until you change a whisper
# setting — at which point the key no longer matches and it genuinely runs.
cmd_samples() {
  local list="$SAMPLES/real.list" dest="$SAMPLES/real"
  # real.list is gitignored, and so is everything it names: a bundle slug is
  # made of the first words the author said, so the LIST is his writing too.
  # The committed template is entirely invented.
  [ -f "$list" ] || die "no selection list at $list
       cp samples/real.list.example samples/real.list  and put your own material in it
       (both the list and samples/real/ stay out of git — see .gitignore)"
  rm -rf "$dest"
  mkdir -p "$dest/audio" "$dest/notes" "$dest/verbatim"
  local kind name n_memo=0 n_note=0 a cache key
  cache="${AB_CACHE:-$BLOG_REPO_DIR/eval/cache/transcripts}"
  mkdir -p "$cache"
  while IFS=$'\t' read -r kind name; do
    case "${kind:-}" in ''|'#'*) continue ;; esac
    case "$kind" in
      memo)
        [ -d "$DRAFTS/$name" ] || { say "skip memo $name: no such bundle"; continue; }
        shopt -s nullglob
        for a in "$DRAFTS/$name"/*.m4a "$DRAFTS/$name"/*.mp3 "$DRAFTS/$name"/*.opus \
                 "$DRAFTS/$name"/*.wav "$DRAFTS/$name"/*.ogg; do
          cp -p "$a" "$dest/audio/$(basename "$a")"
          if [ -f "$DRAFTS/$name/verbatim.md" ]; then
            cp "$DRAFTS/$name/verbatim.md" "$dest/verbatim/$(basename "$a").md"
            key="$(printf '%s|%s|%s|%s|%s|%s' \
                    "$(blog_sha256 "$a")" "$(basename "$WHISPER_MODEL")" "$WHISPER_LANG" \
                    "$WHISPER_MARKS" "$WHISPER_CONF_LOW" "$WHISPER_CONF_VLOW" \
                  | blog_sha256_stdin)"
            [ -s "$cache/$key.txt" ] || cp "$DRAFTS/$name/verbatim.md" "$cache/$key.txt"
          fi
        done
        shopt -u nullglob
        n_memo=$((n_memo + 1)) ;;
      note)
        if [ -f "$VAULT/$name.md" ]; then cp -p "$VAULT/$name.md" "$dest/notes/"; n_note=$((n_note + 1))
        elif [ -f "$ARCHIVE/$name.md" ]; then cp -p "$ARCHIVE/$name.md" "$dest/notes/"; n_note=$((n_note + 1))
        else say "skip note $name: not found"; fi ;;
      *) say "skip unknown kind: $kind" ;;
    esac
  done < "$list"
  say "samples/real: $n_memo recording(s), $n_note note(s)"
  say "transcripts seeded into $cache — try --full will not re-run whisper"
  say "(gitignored: this is your material, not the repo's)"
}

# --- list / status ------------------------------------------------------------------
cmd_list() {
  printf '%-14s %-10s %-9s %-7s %s\n' ARM CREATED STATUS POSTS DELTAS
  local name created status note pool n deltas
  printf '%-14s %-10s %-9s %-7s %s\n' base — base \
    "$( { ls "$POSTS"/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')" \
    "$( [ -f "$BASE_ENV" ] && tr '\n' ' ' < <(grep -vE '^[[:space:]]*(#|$)' "$BASE_ENV" || true) || printf '(none)' )"
  [ -f "$ARMS_TSV" ] || return 0
  while IFS=$'\t' read -r name created status note; do
    [ -n "$name" ] || continue
    pool="$(arm_pool "$name")"
    n="$( { ls "$pool"/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')"
    deltas="$( { grep -vE '^[[:space:]]*(#|$)' "$(arm_file "$name")" 2>/dev/null || true; } | tr '\n' ' ')"
    printf '%-14s %-10s %-9s %-7s %s\n' "$name" "$created" "$status" "$n" "${deltas:-—}"
    [ -z "$note" ] || printf '%-14s %s\n' "" "  $note"
  done < "$ARMS_TSV"
}

cmd_status() { "$SCRIPT_DIR/score.sh" --arms "$@"; }

# --- promote / retire -----------------------------------------------------------------
# Promotion folds the arm's deltas into profiles/base.env, which lib/config.sh
# applies as the floor under every run. The arm's own file is kept and its
# registry row becomes `promoted`, because "what did we change the base to, and
# why" is exactly the question a registry exists to answer.
cmd_promote() {
  [ "$#" -ge 1 ] || die "usage: arm.sh promote <name>"
  local name="$1" f
  f="$(arm_file "$name")"
  [ -f "$f" ] || die "no such arm: $name"

  local tmp; tmp="$(mktemp)"
  [ -f "$BASE_ENV" ] && cat "$BASE_ENV" > "$tmp"
  local line k
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"
    # A later promotion overrides an earlier one for the same key.
    grep -vE "^[[:space:]]*${k}=" "$tmp" > "$tmp.new" 2>/dev/null || true
    mv "$tmp.new" "$tmp"
    printf '%s\n' "$line" >> "$tmp"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$f" || true)

  {
    printf '# profiles/base.env — what the base has been changed to, and when.\n'
    printf '#\n# Written by bin/arm.sh promote. lib/config.sh applies this as the FLOOR:\n'
    printf '# the environment, a profile and an arm all still outrank it. Delete a line\n'
    printf '# to go back to the shipped default (profiles/default.env lists them all).\n'
    printf '#\n'
    grep -E '^[[:space:]]*#[[:space:]]*promoted ' "${BASE_ENV:-/dev/null}" 2>/dev/null || true
    printf '# promoted %s: arm %s\n\n' "$(date '+%Y-%m-%d')" "$name"
    grep -vE '^[[:space:]]*(#|$)' "$tmp" | sort -u
  } > "$BASE_ENV"
  rm -f "$tmp"

  # Its posts join the base's pool: they were made by what the base now is.
  local pool p moved=0
  pool="$(arm_pool "$name")"
  shopt -s nullglob
  for p in "$pool"/*.md; do mv "$p" "$POSTS/$(basename "$p")"; moved=$((moved + 1)); done
  shopt -u nullglob
  rmdir "$pool" 2>/dev/null || true
  reg_set "$name" promoted
  say "base now carries $name's deltas ($BASE_ENV)"
  say "moved $moved post(s) into the base pool; arm stopped"
  say "the base fingerprint is now $(bash "$BLOG_LIB_DIR/config.sh" fingerprint)"
}

cmd_retire() {
  [ "$#" -ge 1 ] || die "usage: arm.sh retire <name>"
  local name="$1"
  [ -f "$(arm_file "$name")" ] || die "no such arm: $name"
  local pool p binned=0
  pool="$(arm_pool "$name")"
  shopt -s nullglob
  for p in "$pool"/*.md; do mv "$p" "$TRASH/$(basename "$p")"; binned=$((binned + 1)); done
  shopt -u nullglob
  rmdir "$pool" 2>/dev/null || true
  reg_set "$name" retired
  say "arm $name retired; $binned post(s) moved to Discarded/ (recoverable for $TRASH_DAYS days)"
  say "its file is kept at $(arm_file "$name") — the registry remembers what you tried"
}

usage() { sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

main() {
  [ "$#" -ge 1 ] || usage 2
  local cmd="$1"; shift
  case "$cmd" in
    new)     cmd_new "$@" ;;
    run)     cmd_run "$@" ;;
    try)     cmd_try "$@" ;;
    samples) cmd_samples "$@" ;;
    list)    cmd_list "$@" ;;
    status)  cmd_status "$@" ;;
    promote) cmd_promote "$@" ;;
    retire)  cmd_retire "$@" ;;
    -h|--help|help) usage 0 ;;
    *) die "unknown command: $cmd (try arm.sh --help)" ;;
  esac
}

main "$@"
