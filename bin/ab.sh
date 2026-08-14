#!/usr/bin/env bash
#
# ab.sh — run one stage of the pipeline several ways and compare the results.
#
#   ab.sh freeze [bundle...]     build fixtures from real bundles + the vault
#   ab.sh list                   what fixtures and experiments exist
#   ab.sh run <exp>              variant × fixture × repetition, each in a sandbox
#   ab.sh report <exp>           eval/runs/<exp>/REPORT.md
#   ab.sh judge <exp>            the optional, expensive, pairwise judge tier
#   ab.sh promote <exp> <var>    make a variant the baseline to compare against
#   ab.sh score                  what the LIVE pool says (see the note below)
#
# The offline half of the experiment layer. Every run happens under its own
# BLOG_ROOT, so nothing here can touch drafts/, processed.tsv, the alias map or
# the phone — that is the whole reason lib/config.sh exists.
#
# Two things this cannot do, and does not pretend to:
#
#   Claude is not deterministic. One run of A against one run of B separates
#   "the prompt did it" from "the dice did it" not at all, which is why REPS
#   defaults to 3 and why the report prints spread next to every mean. Read the
#   spread first.
#
#   No judge in a sandbox knows your taste. The mechanical tier below measures
#   what is measurable — how much was rewritten, what the gate said, what it
#   cost — and that is genuinely most of what a curator experiment turns on. For
#   "which of these is a better post", the honest metric is what you move into
#   Keep/ on the phone: `ab.sh score`, weeks later.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The names of the variables already exported when this script started —
# captured BEFORE lib/config.sh runs, because sourcing it applies any profile
# and exports keys of its own, after which the two are indistinguishable.
# check_env_leaks (below) is the whole reason this exists.
AB_INHERITED_ENV="$(env | sed 's/=.*//' | LC_ALL=C sort -u)"

# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"
# shellcheck source=../lib/claude.sh
. "$REPO_DIR/lib/claude.sh"

EVAL="${EVAL_DIR:-$BLOG_REPO_DIR/eval}"
FIXTURES="$EVAL/fixtures"
MEMOS="$FIXTURES/memos"
VAULT_FIX="$FIXTURES/vault"
RUNS="$EVAL/runs"
BASELINE="$EVAL/baseline"
EXPERIMENTS="$EVAL/experiments"

# The one column list, so the writer and every reader agree.
METRIC_COLS="variant fixture rep status seconds calls in_chars out_chars churn_pct in_words out_words unsure_in unsure_leak candidates rejected verbatim tweaked glue new pool_long pool_short"

die() { printf 'ab: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*" >&2; }

# --- freeze -------------------------------------------------------------------
# A fixture is a real memo with its transcript frozen beside it, plus a snapshot
# of the vault as it stood. Frozen, because an experiment about prompts must not
# also be an experiment about what whisper heard that morning; a snapshot,
# because suggest.sh is stateful — the pool, the claims, the eviction clocks —
# and two variants reading different pool histories are not being compared.
#
# Everything written here is personal data and stays gitignored.
freeze_vault() {
  mkdir -p "$VAULT_FIX"
  if [ -d "$VAULT" ]; then
    rm -rf "$VAULT_FIX/Obsidian"
    cp -a "$VAULT" "$VAULT_FIX/Obsidian"
    say "froze the vault: $(find "$VAULT_FIX/Obsidian" -type f | wc -l | tr -d ' ') file(s)"
  fi
  # The history the generation prompt reads, and the gate feedback it learns
  # from: state, like the pool, so it belongs in the snapshot.
  mkdir -p "$VAULT_FIX/logs"
  local f
  for f in suggested.tsv gate.tsv aliases.last; do
    [ -f "$LOGS/$f" ] && cp "$LOGS/$f" "$VAULT_FIX/logs/$f"
  done
  [ -f "$ALIASES" ] && { mkdir -p "$VAULT_FIX/private"; cp "$ALIASES" "$VAULT_FIX/private/aliases.tsv"; }
  return 0
}

freeze_memo() {
  local dir="$1" name dest a
  name="$(basename "${dir%/}")"
  [ -f "$dir/verbatim.md" ] || { say "skip $name: no verbatim.md"; return 0; }
  dest="$MEMOS/$name"
  mkdir -p "$dest"
  cp "$dir/verbatim.md" "$dest/verbatim.md"
  [ -f "$dir/cleaned.md" ] && cp "$dir/cleaned.md" "$dest/cleaned.reference.md"
  [ -f "$dir/meta.json" ] && cp "$dir/meta.json" "$dest/meta.reference.json"
  # The audio too: without it a whisper-side experiment is impossible, and it is
  # the only artifact that cannot be regenerated from anything else here.
  shopt -s nullglob
  for a in "$dir"/*.m4a "$dir"/*.mp3 "$dir"/*.opus "$dir"/*.ogg "$dir"/*.wav; do
    cp "$a" "$dest/$(basename "$a")"
  done
  shopt -u nullglob
  say "froze memo: $name"
}

cmd_freeze() {
  mkdir -p "$MEMOS"
  local d
  if [ "$#" -gt 0 ]; then
    for d in "$@"; do
      [ -d "$d" ] || d="$DRAFTS/$(basename "$d")"
      [ -d "$d" ] || { say "skip $d: no such bundle"; continue; }
      freeze_memo "$d"
    done
  else
    shopt -s nullglob
    for d in "$DRAFTS"/*/; do freeze_memo "$d"; done
    shopt -u nullglob
  fi
  freeze_vault
  say "fixtures live in $FIXTURES (gitignored — they are your notes)"
}

# --- experiments ---------------------------------------------------------------
# An .exp file is KEY=VALUE, sourced:
#
#   STAGE=process|suggest
#   REPS=3
#   FIXTURES="all"                  (process) or ignored (suggest: one corpus)
#   VARIANTS="baseline loose"
#   VARIANT_baseline_PROFILE=default
#   VARIANT_loose_PROFILE=curator-loose
#   VARIANT_loose_ENV="MAX_NEW=4"   extra environment, space-separated K=V
#
# Variant names are used as directory names and as parts of shell variable
# names, so they are restricted to [A-Za-z0-9_].
EXP_NAME=""; EXP_STAGE=""; EXP_REPS=3; EXP_FIXTURES="all"; EXP_VARIANTS=""
load_experiment() {
  local name="$1" f
  case "$name" in
    */*) f="$name" ;;
    *)   f="$EXPERIMENTS/$name"; [ -f "$f" ] || f="$EXPERIMENTS/$name.exp" ;;
  esac
  [ -f "$f" ] || die "no such experiment: $name (looked for $f)"
  STAGE=""; REPS=""; FIXTURES_SET=""; VARIANTS=""
  # shellcheck disable=SC1090
  . "$f"
  EXP_NAME="$(basename "${f%.exp}")"
  EXP_STAGE="${STAGE:-}"
  EXP_REPS="${REPS:-3}"
  EXP_FIXTURES="${FIXTURES_SET:-all}"
  EXP_VARIANTS="${VARIANTS:-}"
  [ -n "$EXP_STAGE" ] || die "$f: STAGE= must be process or suggest"
  case "$EXP_STAGE" in process|suggest) ;; *) die "$f: unknown STAGE=$EXP_STAGE" ;; esac
  [ -n "$EXP_VARIANTS" ] || die "$f: VARIANTS= must name at least one variant"
  local v
  for v in $EXP_VARIANTS; do
    case "$v" in *[!A-Za-z0-9_]*) die "$f: variant '$v' — use [A-Za-z0-9_] only" ;; esac
  done
}

variant_profile() { local n="VARIANT_${1}_PROFILE"; printf '%s' "${!n:-default}"; }
variant_env()     { local n="VARIANT_${1}_ENV";     printf '%s' "${!n:-}"; }

# The fingerprint a variant resolves to — printed in the report so two variants
# that are secretly the same configuration cannot be mistaken for a result.
variant_fingerprint() {
  local v="$1" e
  # shellcheck disable=SC2046
  env -u BLOG_ROOT -u PROMPTS_DIR -u BLOG_VARIANT \
      BLOG_PROFILE="$(variant_profile "$v")" $(variant_env "$v") \
      bash "$BLOG_LIB_DIR/config.sh" fingerprint
}

# --- sandboxes ------------------------------------------------------------------
# Seed a root that looks like the real tree and shares nothing with it.
seed_root() {
  local stage="$1" fixture="$2" root="$3"
  rm -rf "$root"
  mkdir -p "$root/sync/Obsidian" "$root/drafts" "$root/logs" "$root/work" "$root/private"

  if [ -d "$VAULT_FIX/Obsidian" ]; then
    rm -rf "$root/sync/Obsidian"
    cp -a "$VAULT_FIX/Obsidian" "$root/sync/Obsidian"
  fi
  local f
  for f in suggested.tsv gate.tsv aliases.last; do
    [ -f "$VAULT_FIX/logs/$f" ] && cp "$VAULT_FIX/logs/$f" "$root/logs/$f"
  done
  # Its own alias map, so the name scout can extend it all it likes without
  # touching the real one.
  if [ -f "$VAULT_FIX/private/aliases.tsv" ]; then
    cp "$VAULT_FIX/private/aliases.tsv" "$root/private/aliases.tsv"
  else
    : > "$root/private/aliases.tsv"
  fi

  case "$stage" in
    process)
      # One memo, back at the start of the pipeline: its audio in sync/, nothing
      # else. mtime is what the bundle gets named after, so it is preserved.
      local a
      shopt -s nullglob
      for a in "$MEMOS/$fixture"/*.m4a "$MEMOS/$fixture"/*.mp3 "$MEMOS/$fixture"/*.opus \
               "$MEMOS/$fixture"/*.ogg "$MEMOS/$fixture"/*.wav; do
        cp -p "$a" "$root/sync/$(basename "$a")"
      done
      shopt -u nullglob
      # No audio in the fixture? Fabricate the one thing process.sh needs from
      # it — a file to hash and name — and let the frozen transcript stand in.
      if ! ls "$root"/sync/*.* >/dev/null 2>&1; then
        printf '%s' "$fixture" > "$root/sync/${fixture}.m4a"
      fi
      ;;
    suggest)
      # The corpus as drafts/: every frozen memo's cleaned text, at the mtime it
      # had, because mtime is corpus recency and the archive clock.
      local m name
      shopt -s nullglob
      for m in "$MEMOS"/*/; do
        name="$(basename "${m%/}")"
        [ -f "$m/cleaned.reference.md" ] || continue
        mkdir -p "$root/drafts/$name"
        cp -p "$m/cleaned.reference.md" "$root/drafts/$name/cleaned.md"
        cp -p "$m/verbatim.md" "$root/drafts/$name/verbatim.md"
      done
      shopt -u nullglob
      ;;
  esac
}

# Run one (variant, fixture, rep) and append its metrics row.
run_one() {
  local stage="$1" variant="$2" fixture="$3" rep="$4" outdir="$5"
  local root="$outdir/root" log="$outdir/run.log" started ended status=ok
  mkdir -p "$outdir"
  seed_root "$stage" "$fixture" "$root"

  local -a envs=(
    "BLOG_ROOT=$root"
    "BLOG_PROFILE=$(variant_profile "$variant")"
    "BLOG_VARIANT=$variant"
    "NOTIFY=/bin/true"
    "AB_FIXTURE=$MEMOS/$fixture"
  )
  # Variant environment last, so an .exp can override anything above except the
  # tree — which it must not, or the experiment escapes its sandbox.
  #
  # Split with eval rather than word-splitting, so a value may contain spaces:
  # the .exp file is sourced already, its assignments are code either way, and
  # VARIANT_x_ENV='SELF_NAME="Ada Lovelace"' should mean what it looks like.
  local -a extra=()
  local raw; raw="$(variant_env "$variant")"
  if [ -n "$raw" ]; then
    eval "extra=($raw)" 2>/dev/null \
      || die "$variant: VARIANT_${variant}_ENV is not a usable assignment list: $raw"
  fi
  # Every path in the tree hangs off a BLOG_* variable, and ALIASES names the
  # one file outside it a run may WRITE (the name scout extends the alias map).
  # Pinning any of them from an .exp would point a sandboxed run at the live
  # data, which is the single thing this runner exists to make impossible — so
  # the whole prefix is refused rather than a list of the paths thought of today.
  local kv
  for kv in "${extra[@]}"; do
    case "$kv" in
      BLOG_*=*|ALIASES=*)
        die "$variant: an experiment may not repoint the tree ($kv) — use a profile" ;;
    esac
    envs+=("$kv")
  done

  started="$(date +%s)"
  case "$stage" in
    process)
      env -u BLOG_FINGERPRINT -u BLOG_RUN_ID -u PROMPTS_DIR \
          "${envs[@]}" TRANSCRIBE="$SCRIPT_DIR/ab-transcribe.sh" \
          "$SCRIPT_DIR/process.sh" > "$log" 2>&1 || status=failed
      ;;
    suggest)
      env -u BLOG_FINGERPRINT -u BLOG_RUN_ID -u PROMPTS_DIR -u SUGGEST_SCHEDULED \
          "${envs[@]}" \
          "$SCRIPT_DIR/suggest.sh" > "$log" 2>&1 || status=failed
      ;;
  esac
  ended="$(date +%s)"
  [ "$status" = ok ] || say "  ! $variant/$fixture/rep$rep failed — see $log"
  collect_metrics "$stage" "$variant" "$fixture" "$rep" "$root" "$status" "$((ended - started))"
}

# Every gate report this run produced, one path per line. An accepted
# candidate's classification lives beside the pool in Posts/.provenance/<id>.md;
# a rejected one's is appended to the copy kept in Posts/Rejected/. Both are
# found through logs/provenance.tsv, which is the only record that distinguishes
# what the run wrote from what the fixture came with.
report_paths() {
  local root="$1" ptsv="$1/logs/provenance.tsv"
  [ -s "$ptsv" ] || return 0
  awk -F'\t' -v root="$root" '
    $3 == "candidate" { p = $4; sub(/[^\/]*$/, ".provenance/&", p); print root "/" p; next }
    $3 == "rejected"  { print root "/" $4 }' "$ptsv"
}

# One TSV row per run. Everything here is read back out of the sandbox — the
# same artifacts the live pipeline writes, which is the point: the experiment
# measures the pipeline, not a special evaluation mode of it.
collect_metrics() {
  local stage="$1" variant="$2" fixture="$3" rep="$4" root="$5" status="$6" seconds="$7"
  local calls=0 in_chars=0 out_chars=0
  if [ -s "$root/logs/usage.tsv" ]; then
    read -r calls in_chars out_chars < <(awk -F'\t' \
      '{ c++; i += $4; o += $5 } END { printf "%d %d %d\n", c, i, o }' "$root/logs/usage.tsv")
  fi

  local churn=- in_words=- out_words=- unsure_in=- unsure_leak=-
  local candidates=- rejected=- verbatim=- tweaked=- glue=- new=- longs=- shorts=-

  if [ "$stage" = process ]; then
    local b
    b="$(find "$root/drafts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
    if [ -n "$b" ] && [ -f "$b/meta.json" ]; then
      churn="$(sed -n 's/.*"churn_pct": \([0-9]*\).*/\1/p' "$b/meta.json" | head -1)"
      in_words="$(sed -n 's/.*"verbatim_words": \([0-9]*\).*/\1/p' "$b/meta.json" | head -1)"
      out_words="$(sed -n 's/.*"cleaned_words": \([0-9]*\).*/\1/p' "$b/meta.json" | head -1)"
      unsure_in="$( { grep -o '⟦unsure⟧' "$b/verbatim.md" 2>/dev/null || true; } | wc -l | tr -d ' ')"
      unsure_leak="$( { grep -o '⟦unsure⟧' "$b/cleaned.md" 2>/dev/null || true; } | wc -l | tr -d ' ')"
    fi
  else
    # Counted from the sandbox's OWN provenance ledger, not from the tree. The
    # tree also holds the seeded snapshot — the pool, the rejections and the
    # provenance reports as they stood when the fixture was frozen — and counting
    # those would add the fixture's whole history to every variant's totals,
    # burying the handful of posts the run actually produced. The ledger has one
    # row per artifact THIS run wrote, and nothing else.
    local ptsv="$root/logs/provenance.tsv"
    candidates=0; rejected=0
    if [ -s "$ptsv" ]; then
      candidates="$(awk -F'\t' '$3 == "candidate"' "$ptsv" | wc -l | tr -d ' ')"
      rejected="$(awk -F'\t' '$3 == "rejected"'  "$ptsv" | wc -l | tr -d ' ')"
    fi
    # The per-sentence classification over the reports this run produced —
    # accepted and rejected alike, because a variant that gets rejected a lot is
    # telling you something and dropping its sentences would hide it.
    read -r verbatim tweaked glue new < <(
      report_paths "$root" \
      | while IFS= read -r p; do [ -f "$p" ] && cat "$p"; done \
      | awk '/^- VERBATIM /{v++} /^- TWEAKED /{t++} /^- GLUE /{g++} /^- NEW /{n++}
             END { printf "%d %d %d %d\n", v, t, g, n }')
    # Pool composition is the one honest END-STATE number here: the cap applies
    # to the whole pool, seeded posts included, and what survives curation is
    # what the phone would show. Hence pool_*, next to the per-run counts above.
    # `|| true`: pipefail turns "grep found nothing" into a failed pipeline, and
    # an empty pool is a result, not an error.
    longs="$( { grep -l '^kind: long$'  "$root"/sync/Obsidian/Posts/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')"
    shorts="$( { grep -l '^kind: short$' "$root"/sync/Obsidian/Posts/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$variant" "$fixture" "$rep" "$status" "$seconds" "$calls" "$in_chars" "$out_chars" \
    "${churn:--}" "${in_words:--}" "${out_words:--}" "${unsure_in:--}" "${unsure_leak:--}" \
    "${candidates:--}" "${rejected:--}" "${verbatim:-0}" "${tweaked:-0}" "${glue:-0}" "${new:-0}" \
    "${longs:--}" "${shorts:--}" \
    >> "$RUNS/$EXP_NAME/metrics.tsv"
}

# The environment outranks a profile — deliberately, everywhere in this
# pipeline. That makes an exported knob in the shell that launches an experiment
# invisible poison: it overrides EVERY variant's profile at once, so the run
# dutifully compares two configurations that were never different, and the
# report says nothing about it beyond two variants that happen to share a
# fingerprint. An experiment must be launched from a clean shell, and this is
# cheaper to enforce than to notice afterwards.
#
# Checked against the names captured before lib/config.sh was sourced, and
# derived from the fingerprint key list so it cannot drift from what actually
# defines a variant.
check_env_leaks() {
  local k leaks=""
  for k in $BLOG_FINGERPRINT_KEYS CLAUDE_MODEL PROMPTS_DIR \
           CLEANUP_DIRECTIVE CURATE_DIRECTIVE PERSONAS BLOG_PROFILE; do
    printf '%s\n' "$AB_INHERITED_ENV" | grep -qx -- "$k" \
      && leaks="${leaks:+$leaks }$k"
  done
  [ -z "$leaks" ] && return 0
  printf 'ab: these are set in your environment: %s\n' "$leaks" >&2
  printf '    The environment outranks a profile, so each of them would override\n' >&2
  printf '    EVERY variant of this experiment and the comparison would measure\n' >&2
  printf '    nothing. Unset them and run again; anything a variant needs belongs\n' >&2
  printf '    in its profile, or in VARIANT_<name>_ENV in the .exp file.\n' >&2
  exit 1
}

cmd_run() {
  [ "$#" -ge 1 ] || die "usage: ab.sh run <experiment>"
  check_env_leaks
  load_experiment "$1"; shift
  local fixtures="$EXP_FIXTURES" reps="$EXP_REPS"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reps)     reps="$2"; shift 2 ;;
      --fixtures) fixtures="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  local list=""
  if [ "$EXP_STAGE" = process ]; then
    if [ "$fixtures" = all ]; then
      shopt -s nullglob
      local m
      for m in "$MEMOS"/*/; do list="${list:+$list }$(basename "${m%/}")"; done
      shopt -u nullglob
    else
      list="$fixtures"
    fi
    [ -n "$list" ] || die "no fixtures — run 'ab.sh freeze' first"
  else
    # The suggest stage reads the whole corpus at once; the fixture IS the
    # snapshot, so there is exactly one of them.
    list=corpus
    [ -d "$VAULT_FIX/Obsidian" ] || die "no vault snapshot — run 'ab.sh freeze' first"
  fi

  mkdir -p "$RUNS/$EXP_NAME"
  printf '%s\n' "$METRIC_COLS" | tr ' ' '\t' > "$RUNS/$EXP_NAME/metrics.tsv"

  local v f r total=0
  for v in $EXP_VARIANTS; do for f in $list; do for r in $(seq 1 "$reps"); do
    total=$((total + 1))
  done; done; done
  say "$EXP_NAME: $EXP_STAGE, $(printf '%s' "$EXP_VARIANTS" | wc -w) variant(s) × $(printf '%s' "$list" | wc -w) fixture(s) × $reps rep(s) = $total run(s)"
  say "each run is a Claude call or several — this is the expensive command"

  local i=0
  for v in $EXP_VARIANTS; do
    say "variant $v — profile $(variant_profile "$v"), fingerprint $(variant_fingerprint "$v")"
    for f in $list; do
      for r in $(seq 1 "$reps"); do
        i=$((i + 1))
        say "  [$i/$total] $v / $f / rep$r"
        run_one "$EXP_STAGE" "$v" "$f" "$r" "$RUNS/$EXP_NAME/$v/$f/rep$r"
      done
    done
  done
  say "done — $RUNS/$EXP_NAME/metrics.tsv"
  cmd_report "$EXP_NAME"
}

# --- report ---------------------------------------------------------------------
cmd_report() {
  [ "$#" -ge 1 ] || die "usage: ab.sh report <experiment>"
  load_experiment "$1"
  local dir="$RUNS/$EXP_NAME" out
  out="$dir/REPORT.md"
  [ -s "$dir/metrics.tsv" ] || die "no runs yet for $EXP_NAME — ab.sh run $EXP_NAME"

  # The repetition count comes from what actually ran, not from the .exp file:
  # `ab.sh run <exp> --reps 5` is allowed to disagree with it.
  local reps_ran
  reps_ran="$(awk -F'\t' 'NR > 1 && $3 + 0 > m { m = $3 + 0 } END { print m + 0 }' "$dir/metrics.tsv")"
  {
    printf '# %s\n\n' "$EXP_NAME"
    printf '%s stage, %s repetition(s), generated %s.\n\n' \
      "$EXP_STAGE" "$reps_ran" "$(date '+%Y-%m-%d %H:%M')"
    printf 'Read the spread before the mean. Claude is not deterministic, and on\n'
    printf 'a handful of repetitions two variants whose ranges overlap have not\n'
    printf 'been told apart — whatever their averages say.\n\n'

    printf '## variants\n\n'
    printf '| variant | profile | fingerprint | extra environment |\n|---|---|---|---|\n'
    local v
    for v in $EXP_VARIANTS; do
      printf '| %s | %s | `%s` | %s |\n' "$v" "$(variant_profile "$v")" \
        "$(variant_fingerprint "$v")" "$(variant_env "$v" | sed 's/|/\\|/g')"
    done
    printf '\nTwo variants sharing a fingerprint are the same configuration; any\n'
    printf 'difference between them is noise by construction.\n\n'

    printf '## mechanical tier\n\n'
    printf 'Free, deterministic, and computed from the artifacts the pipeline\n'
    printf 'writes anyway. Means with the observed range in brackets.\n\n'
    summarize_metrics "$dir/metrics.tsv"

    printf '\n## every run\n\n```\n'
    column -t -s $'\t' "$dir/metrics.tsv" 2>/dev/null || cat "$dir/metrics.tsv"
    printf '```\n'

    printf '\n## what it burned\n\n'
    awk -F'\t' 'NR > 1 { c[$1] += $6; i[$1] += $7; o[$1] += $8 }
      END {
        printf "| variant | calls | in ~ktok | out ~ktok |\n|---|---|---|---|\n"
        for (v in c) printf "| %s | %d | %d | %d |\n", v, c[v], i[v] / 4000, o[v] / 4000
      }' "$dir/metrics.tsv"
    printf '\nEstimates (chars/4), the same ones `bin/stats.sh` prints, and the same\n'
    printf 'caveat: the CLI adds per-call overhead these numbers do not see.\n'

    printf '\n## side by side\n\n'
    side_by_side "$dir"
  } > "$out"
  say "wrote $out"
}

# Mean and range per (metric, variant), skipping columns that stage never fills.
summarize_metrics() {
  local file="$1"
  # LC_ALL=C: a decimal comma in a markdown table of means is a small horror.
  LC_ALL=C awk -F'\t' '
    NR == 1 { for (i = 1; i <= NF; i++) name[i] = $i; ncol = NF; next }
    {
      variant = $1
      if (!(variant in seen)) { seen[variant] = 1; order[++nv] = variant }
      runs[variant]++
      # A failed run is not a cheap fast one. Its row carries whatever the
      # sandbox managed to produce before it died — usually zeros — and
      # averaging that in makes a variant that crashes look like a variant that
      # is efficient. The counts are reported instead, on their own line.
      if ($4 != "ok") { failed[variant]++; next }
      okruns[variant]++
      for (i = 5; i <= ncol; i++) {
        if ($i == "-" || $i == "") continue
        key = i SUBSEP variant
        sum[key] += $i; cnt[key]++
        if (!(key in lo) || $i + 0 < lo[key]) lo[key] = $i + 0
        if (!(key in hi) || $i + 0 > hi[key]) hi[key] = $i + 0
        used[i] = 1
      }
    }
    END {
      printf "| metric"
      for (v = 1; v <= nv; v++) printf " | %s", order[v]
      printf " |\n|---"
      for (v = 1; v <= nv; v++) printf "|---"
      printf "|\n"
      # First row, before any mean: how much of this variant actually ran. A
      # column averaged over one surviving repetition is not the same claim as
      # one averaged over three, and the reader should see that first.
      printf "| runs ok/total"
      for (v = 1; v <= nv; v++)
        printf " | %d/%d", okruns[order[v]] + 0, runs[order[v]] + 0
      printf " |\n"
      for (i = 5; i <= ncol; i++) {
        if (!(i in used)) continue
        printf "| %s", name[i]
        for (v = 1; v <= nv; v++) {
          key = i SUBSEP order[v]
          if (!cnt[key]) { printf " | —"; continue }
          m = sum[key] / cnt[key]
          if (lo[key] == hi[key]) printf " | %.1f", m
          else printf " | %.1f  [%g–%g]", m, lo[key], hi[key]
        }
        printf " |\n"
      }
    }' "$file"
}

# The literal before/after. For the cleanup stage that is a word diff of one
# variant's output against another's on the same fixture — the thing no metric
# replaces. For the curator stage the outputs are different posts rather than
# two versions of one text, so what is worth putting next to each other is what
# each variant chose to write and what the gate said about it.
side_by_side() {
  local dir="$1" a b v first="" second=""
  for v in $EXP_VARIANTS; do
    if [ -z "$first" ]; then first="$v"; elif [ -z "$second" ]; then second="$v"; fi
  done
  if [ -z "$second" ]; then printf '(only one variant — nothing to put beside it)\n'; return 0; fi

  if [ "$EXP_STAGE" = process ]; then
    printf 'Word diff, `%s` → `%s`, rep 1 of each fixture.\n\n' "$first" "$second"
    local f
    shopt -s nullglob
    for f in "$dir/$first"/*/; do
      local fx; fx="$(basename "${f%/}")"
      a="$(find "$dir/$first/$fx/rep1/root/drafts" -name cleaned.md 2>/dev/null | head -1)"
      b="$(find "$dir/$second/$fx/rep1/root/drafts" -name cleaned.md 2>/dev/null | head -1)"
      [ -n "$a" ] && [ -n "$b" ] || continue
      printf '### %s\n\n```diff\n' "$fx"
      { git diff --word-diff --no-index -- "$a" "$b" 2>/dev/null || true; } | tail -n +5
      printf '```\n\n'
    done
    shopt -u nullglob
  else
    # Listed from the sandbox's provenance ledger, NOT from its pool. The pool
    # also holds the seeded snapshot — every post the fixture was frozen with —
    # and printing those under a variant's heading would credit it with choices
    # it never made. The ledger holds exactly what this run proposed.
    local rep
    shopt -s nullglob
    for v in $EXP_VARIANTS; do
      printf '### %s\n\n' "$v"
      for rep in "$dir/$v/corpus"/rep*/; do
        printf '**%s**\n\n' "$(basename "${rep%/}")"
        local root="$rep/root" kind path p pv n=0
        while IFS=$'\t' read -r kind path; do
          p="$root/$path"
          [ -f "$p" ] || continue
          n=$((n + 1))
          if [ "$kind" = rejected ]; then
            printf -- '- REJECTED [%s] %s\n' "$(sed -n 's/^kind: //p' "$p" | head -1)" \
                                             "$(sed -n 's/^title: //p' "$p" | head -1)"
            printf '      %s\n' "$(sed -n 's/^rejected: //p' "$p" | head -1)"
          else
            printf -- '- [%s] %s\n' "$(sed -n 's/^kind: //p' "$p" | head -1)" \
                                    "$(sed -n 's/^title: //p' "$p" | head -1)"
            pv="$root/$(dirname "$path")/.provenance/$(basename "$p")"
            [ -f "$pv" ] && printf '      %s\n' "$(grep '^gate:' "$pv" | tail -1)"
          fi
        done < <(awk -F'\t' '$3 == "candidate" || $3 == "rejected" { print $3 "\t" $4 }' \
                   "$root/logs/provenance.tsv" 2>/dev/null)
        [ "$n" -gt 0 ] || printf '(this run proposed nothing)\n'
        printf '\n'
      done
    done
    shopt -u nullglob
    printf 'The per-sentence classification for any of these is in that run'"'"'s\n'
    printf '`root/sync/Obsidian/Posts/.provenance/` — with `GATE_TRACE=1`, each\n'
    printf 'non-verbatim sentence also carries its nearest source note and a word\n'
    printf 'diff, which is what "how much did it rewrite" actually looks like.\n'
  fi
}

# --- judge ------------------------------------------------------------------------
# The expensive tier, and the one that is manual on purpose: it burns
# subscription, and its answer is softer than it looks. Pairwise, blinded, each
# pair judged twice with the positions swapped — a judge that prefers whichever
# came first is a judge that measured nothing, and printing both votes makes
# that visible instead of averaging it away.
cmd_judge() {
  [ "$#" -ge 1 ] || die "usage: ab.sh judge <experiment>"
  load_experiment "$1"
  local dir="$RUNS/$EXP_NAME" prompt="$BLOG_REPO_DIR/prompts/judge-$EXP_STAGE.md"
  [ -f "$prompt" ] || die "no judge prompt at $prompt"
  [ -d "$dir" ] || die "no runs yet for $EXP_NAME"

  local a b v
  a=""; b=""
  for v in $EXP_VARIANTS; do
    if [ -z "$a" ]; then a="$v"; elif [ -z "$b" ]; then b="$v"; fi
  done
  [ -n "$b" ] || die "the judge tier compares two variants; $EXP_NAME has one"

  # Pinned, and independent of whatever is under test: a model judging its own
  # output is not a measurement.
  local judge_model="${JUDGE_MODEL:-claude-opus-5}"
  local out="$dir/JUDGE.md" tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  {
    printf '# %s — judge tier\n\n' "$EXP_NAME"
    printf 'Judge: `%s`, pinned and not one of the models under test.\n' "$judge_model"
    printf 'Every pair is judged twice with the labels swapped; a variant that\n'
    printf 'only wins in one order won nothing.\n\n'
    printf '| fixture | A=%s first | A=%s first (swapped) |\n|---|---|---|\n' "$a" "$b"
  } > "$out"

  local fx list=""
  if [ "$EXP_STAGE" = process ]; then
    shopt -s nullglob
    for fx in "$dir/$a"/*/; do list="${list:+$list }$(basename "${fx%/}")"; done
    shopt -u nullglob
  else
    list=corpus
  fi

  for fx in $list; do
    local left right v1 v2
    left="$(judge_material "$dir/$a/$fx/rep1/root" "$EXP_STAGE")"
    right="$(judge_material "$dir/$b/$fx/rep1/root" "$EXP_STAGE")"
    [ -n "$left" ] && [ -n "$right" ] || continue
    v1="$(judge_pair "$prompt" "$judge_model" "$left" "$right" "$tmp/1")"
    v2="$(judge_pair "$prompt" "$judge_model" "$right" "$left" "$tmp/2")"
    # The second call had the variants the other way round, so its answer is
    # flipped back before it is written down.
    case "$v2" in A) v2=B ;; B) v2=A ;; esac
    printf '| %s | %s | %s |\n' "$fx" "${v1:-?}" "${v2:-?}" >> "$out"
    say "judged $fx: $v1 / $v2"
  done
  printf '\nA = %s, B = %s. TIE and ? are both "no answer worth having".\n' "$a" "$b" >> "$out"
  say "wrote $out"
}

# What the judge is shown for one run: the cleaned text, or the pool.
judge_material() {
  local root="$1" stage="$2" f
  if [ "$stage" = process ]; then
    f="$(find "$root/drafts" -name cleaned.md 2>/dev/null | head -1)"
    [ -n "$f" ] && cat "$f"
  else
    shopt -s nullglob
    for f in "$root/sync/Obsidian/Posts"/*.md; do
      printf -- '--- post ---\n'
      sed -n '/^# /,$p' "$f"
      printf '\n'
    done
    shopt -u nullglob
  fi
}

judge_pair() {
  local prompt="$1" model="$2" left="$3" right="$4" work="$5"
  mkdir -p "$work"
  {
    cat "$prompt"
    printf '\n\n===== BEGIN A =====\n%s\n===== END A =====\n' "$left"
    printf '\n===== BEGIN B =====\n%s\n===== END B =====\n' "$right"
  } > "$work/in"
  # The judge is a Claude call like any other, so it goes through lib/claude.sh:
  # no tools, and one row in the usage ledger. A judge that failed is a missing
  # verdict, not a failed experiment, hence the `|| true`.
  blog_claude "$work/in" "$work/out" "$model" "judge:$EXP_NAME" 2>/dev/null || true
  { grep -m1 -oE '^(VERDICT: *)?(A|B|TIE)\b' "$work/out" 2>/dev/null || true; } \
    | sed 's/^VERDICT: *//' | head -1
}

# --- promote ------------------------------------------------------------------------
cmd_promote() {
  [ "$#" -ge 2 ] || die "usage: ab.sh promote <experiment> <variant>"
  load_experiment "$1"
  local v="$2"
  printf '%s\n' "$EXP_VARIANTS" | tr ' ' '\n' | grep -qxF "$v" \
    || die "$EXP_NAME has no variant '$v'"
  local dir="$RUNS/$EXP_NAME" dest="$BASELINE/$EXP_STAGE"
  [ -s "$dir/metrics.tsv" ] || die "no runs to promote"
  mkdir -p "$dest"
  {
    printf '# baseline for the %s stage\n' "$EXP_STAGE"
    printf '# promoted %s from experiment %s, variant %s\n' "$(date '+%Y-%m-%d')" "$EXP_NAME" "$v"
    printf '# profile=%s fingerprint=%s\n' "$(variant_profile "$v")" "$(variant_fingerprint "$v")"
    printf '#\n# Every run of that variant, kept as it was measured — means are for\n'
    printf '# reading, not for storing, and a stored mean hides the spread that\n'
    printf '# says whether the difference was real. A later experiment can be read\n'
    printf '# against these rows instead of re-running the variant it means to beat.\n'
    head -1 "$dir/metrics.tsv"
    awk -F'\t' -v v="$v" 'NR > 1 && $1 == v' "$dir/metrics.tsv"
  } > "$dest/baseline.tsv"
  say "baseline: $dest/baseline.tsv"
}

# --- list -----------------------------------------------------------------------------
cmd_list() {
  printf 'fixtures (%s):\n' "$FIXTURES"
  if [ -d "$MEMOS" ]; then
    local m
    shopt -s nullglob
    local w
    for m in "$MEMOS"/*/; do
      # Through a variable, not `… | grep -c . || echo 0`: grep -c prints its
      # zero AND exits 1, so the fallback would print a SECOND one and the line
      # would wrap mid-table (the same trap lib/provenance.sh documents).
      w="$(tr -s '[:space:]' '\n' < "${m}verbatim.md" 2>/dev/null | grep -c . || true)"
      printf '  %-44s %s words\n' "$(basename "${m%/}")" "${w:-0}"
    done
    shopt -u nullglob
  fi
  [ -d "$VAULT_FIX/Obsidian" ] \
    && printf '  vault snapshot: %s file(s)\n' "$(find "$VAULT_FIX/Obsidian" -type f | wc -l | tr -d ' ')" \
    || printf '  (no vault snapshot — ab.sh freeze)\n'
  printf '\nexperiments (%s):\n' "$EXPERIMENTS"
  local e
  shopt -s nullglob
  for e in "$EXPERIMENTS"/*.exp; do
    printf '  %-24s %s\n' "$(basename "$e" .exp)" \
      "$(sed -n 's/^# *//p' "$e" | head -1)"
  done
  shopt -u nullglob
  printf '\nruns (%s):\n' "$RUNS"
  shopt -s nullglob
  for e in "$RUNS"/*/; do
    printf '  %-24s %s run(s)%s\n' "$(basename "${e%/}")" \
      "$(( $(wc -l < "${e}metrics.tsv" 2>/dev/null || echo 1) - 1 ))" \
      "$([ -f "${e}REPORT.md" ] && printf ', REPORT.md' || true)"
  done
  shopt -u nullglob
}

# --- main -------------------------------------------------------------------------------
usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

main() {
  [ "$#" -ge 1 ] || usage 2
  local cmd="$1"; shift
  case "$cmd" in
    freeze)  cmd_freeze "$@" ;;
    list)    cmd_list "$@" ;;
    run)     cmd_run "$@" ;;
    report)  cmd_report "$@" ;;
    judge)   cmd_judge "$@" ;;
    promote) cmd_promote "$@" ;;
    score)   "$SCRIPT_DIR/score.sh" "$@" ;;
    -h|--help|help) usage 0 ;;
    *) die "unknown command: $cmd (try ab.sh --help)" ;;
  esac
}

main "$@"
