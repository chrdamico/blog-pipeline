#!/usr/bin/env bash
#
# lib/provenance.sh — what produced this artifact, recorded at the moment it
# was produced.
#
# The rule the experiment layer rests on: every draft bundle and every
# candidate post records the exact configuration that made it. Without that,
# two variants running in the same pool cannot be told apart afterwards, and
# every comparison is a guess. So this is deliberately written BEFORE any
# experiment runs, and it stamps the default configuration too — a run with no
# profile is still a variant, it is just the one called `default`.
#
# Three places carry the stamp, each chosen for how it survives:
#
#   drafts/<bundle>/meta.json   the full record — knobs, prompt hashes, input
#                               hashes, what the transform cost, how much it
#                               changed. Lives beside the artifacts it explains.
#   frontmatter keys            variant/persona/run on every candidate post,
#                               because frontmatter survives the trip to the
#                               phone and the move into Keep/ — and that move
#                               is the datum the online scorer reads.
#   logs/provenance.tsv         one row per artifact: what exists, and where it
#                               came from. logs/usage.tsv keeps its own job
#                               (the per-call token ledger); the two join on
#                               the run id.
#
# Sourced after lib/config.sh, whose resolved values it reads.

if [ -z "${BLOG_PROVENANCE_LOADED:-}" ]; then
BLOG_PROVENANCE_LOADED=1

prov_now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# Minimal JSON string escaping: quotes, backslashes, control characters. Values
# here are paths, hashes and numbers, but a note filename is whatever the
# phone's note app decided to call it, so this is not optional.
prov_json_escape() {
  printf '%s' "${1:-}" | awk '
    BEGIN { RS = "\x01" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      gsub(/\r/, "\\r")
      gsub(/\n/, "\\n")
      printf "%s", $0
    }'
}

prov_kv()  { printf '"%s": "%s"' "$(prov_json_escape "$1")" "$(prov_json_escape "$2")"; }
prov_num() { printf '"%s": %s' "$(prov_json_escape "$1")" "${2:-0}"; }

# Words in a file (whitespace-separated, blank lines ignored).
#
# The count goes through a variable rather than straight to stdout because
# `grep -c` prints its 0 AND exits 1 when nothing matches: a bare `|| printf 0`
# emits a SECOND zero, and "0\n0" reaches meta.json as invalid JSON and
# prov_churn as an arithmetic syntax error. An empty or whitespace-only file is
# not an error here — it is a legitimate answer, and it is zero.
prov_words() {
  [ -f "${1:-}" ] || { printf 0; return 0; }
  local n
  n="$(tr -s '[:space:]' '\n' < "$1" | grep -c '[^[:space:]]' || true)"
  case "${n:-0}" in
    ''|*[!0-9]*) printf 0 ;;
    *)           printf '%s' "$n" ;;
  esac
}

# How much of the text the transform actually moved: the word-level edit
# distance between two files, as a percentage of their combined length.
# Identical files are 0; a complete rewrite approaches 100. This is the number
# that says what a looser cleanup prompt did, per bundle, without reading a
# single diff by hand.
prov_churn() {
  local before="$1" after="$2" wa wb ch total
  wa="$(prov_words "$before")"; wb="$(prov_words "$after")"
  total=$((wa + wb))
  [ "$total" -gt 0 ] || { printf 0; return 0; }
  ch="$(diff <(tr -s '[:space:]' '\n' < "$before") \
             <(tr -s '[:space:]' '\n' < "$after") 2>/dev/null \
       | grep -c '^[<>]' || true)"
  printf '%s' $(( ${ch:-0} * 100 / total ))
}

# The resolved configuration as a JSON object body (no braces), from the same
# dump the fingerprint is computed over — so what a bundle claims and what it
# fingerprints as can never drift apart.
prov_config_json() {
  blog_config_dump | awk -F= '
    {
      k = $1; v = substr($0, length($1) + 2)
      gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v)
      printf "%s      \"%s\": \"%s\"", sep, k, v; sep = ",\n"
    }
    END { printf "\n" }'
}

# "file": <path relative to the code root>, "sha256": <hash or ->
prov_prompt_json() {
  local name="$1" file="${2:-}" rel="${2:-}"
  rel="${rel#"$BLOG_REPO_DIR"/}"
  printf '      "%s": { %s, %s }' "$name" \
    "$(prov_kv file "$rel")" "$(prov_kv sha256 "$(blog_file_hash "$file")")"
}

# --- the central index ---------------------------------------------------------
# prov_record <kind> <path> [persona] [inputs]
#   kind    draft | reclean | candidate | rejected | backfill
#   path    root-relative, so a row still means something after a move
#   inputs  free-form "audio:abc123,verbatim:def456" — identity of what went in
prov_record() {
  local kind="$1" path="$2" persona="${3:-}" inputs="${4:-}"
  mkdir -p "$(dirname "$PROVENANCE_TSV")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(prov_now)" "$BLOG_RUN_ID" "$kind" "${path#"$BLOG_ROOT"/}" \
    "$(blog_variant)" "$persona" "$inputs" >> "$PROVENANCE_TSV"
}

# --- the draft bundle's record ---------------------------------------------------
# prov_write_meta <bundle-dir> <stage> <audio-file|""> <audio-sha|""> \
#                 <verbatim> <cleaned> <in_chars> <out_chars> <seconds>
#
# Everything a later comparison could want about one bundle: which pipeline
# commit and configuration produced it, which prompts (by content, not name),
# what went in (by content hash), what the call cost, and how much of the text
# it moved.
prov_write_meta() {
  local dir="$1" stage="$2" audio="$3" audio_sha="$4" verbatim="$5" cleaned="$6"
  local in_chars="${7:-0}" out_chars="${8:-0}" seconds="${9:-0}"
  local model="$CLEANUP_MODEL" first_seen="" previous=""

  # A recleaned bundle keeps the timestamp it first appeared with: the archive
  # date is a fact about the recording, not about the last time a prompt changed.
  # Two more things are inherited rather than overwritten, for the same reason:
  #
  #   the audio's identity — a fact about the recording, and the only join key
  #   back to logs/processed.tsv. A caller that does not have the file at hand
  #   (reclean.sh works from the bundle, not from sync/) must not erase it by
  #   passing nothing;
  #   the variant that came before — because rewriting cleaned.md means this
  #   record now describes today's configuration, and the one it replaced would
  #   otherwise vanish without trace, even though cleaned.orig.md still holds
  #   the text it produced.
  if [ -f "$dir/meta.json" ]; then
    first_seen="$(sed -n 's/.*"first_seen": "\([^"]*\)".*/\1/p' "$dir/meta.json" | head -1)"
    previous="$(sed -n 's/.*"variant": "\([^"]*\)".*/\1/p'    "$dir/meta.json" | head -1)"
    [ -n "$audio" ]     || audio="$(sed -n 's/.*"audio": "\([^"]*\)".*/\1/p' "$dir/meta.json" | head -1)"
    [ -n "$audio_sha" ] || audio_sha="$(sed -n 's/.*"audio_sha256": "\([^"]*\)".*/\1/p' "$dir/meta.json" | head -1)"
  fi
  [ -n "$first_seen" ] || first_seen="$(prov_now)"

  {
    printf '{\n'
    printf '  %s,\n' "$(prov_kv run "$BLOG_RUN_ID")"
    printf '  %s,\n' "$(prov_kv timestamp "$(prov_now)")"
    printf '  %s,\n' "$(prov_kv first_seen "$first_seen")"
    printf '  %s,\n' "$(prov_kv stage "$stage")"
    printf '  %s,\n' "$(prov_kv commit "$(blog_git_commit)")"
    printf '  %s,\n' "$(prov_kv variant "$(blog_variant)")"
    printf '  %s,\n' "$(prov_kv fingerprint "$(blog_fingerprint)")"
    [ -z "$previous" ] || [ "$previous" = "$(blog_variant)" ] \
      || printf '  %s,\n' "$(prov_kv replaced_variant "$previous")"
    printf '  %s,\n' "$(prov_kv model "$model")"
    printf '  "prompts": {\n'
    prov_prompt_json cleanup   "$CLEANUP_PROMPT";   printf ',\n'
    prov_prompt_json directive "$CLEANUP_DIRECTIVE"; printf '\n'
    printf '  },\n'
    printf '  "input": {\n'
    printf '    %s,\n' "$(prov_kv audio "$(basename "${audio:-}")")"
    printf '    %s,\n' "$(prov_kv audio_sha256 "${audio_sha:--}")"
    printf '    %s,\n' "$(prov_kv verbatim_sha256 "$(blog_file_hash "$verbatim")")"
    printf '    %s\n'  "$(prov_num verbatim_words "$(prov_words "$verbatim")")"
    printf '  },\n'
    printf '  "transform": {\n'
    printf '    %s,\n' "$(prov_num in_chars "$in_chars")"
    printf '    %s,\n' "$(prov_num out_chars "$out_chars")"
    printf '    %s,\n' "$(prov_num in_tokens_est "$((in_chars / 4))")"
    printf '    %s,\n' "$(prov_num out_tokens_est "$((out_chars / 4))")"
    printf '    %s,\n' "$(prov_num seconds "$seconds")"
    printf '    %s,\n' "$(prov_num cleaned_words "$(prov_words "$cleaned")")"
    printf '    %s\n'  "$(prov_num churn_pct "$(prov_churn "$verbatim" "$cleaned")")"
    printf '  },\n'
    printf '  "config": {\n'
    prov_config_json
    printf '  }\n'
    printf '}\n'
  } > "$dir/meta.json.tmp" && mv "$dir/meta.json.tmp" "$dir/meta.json"
}

# --- the post's record -----------------------------------------------------------
# The three frontmatter keys, emitted into a candidate's header. Written for
# every post, experiment or not: a pool that is only sometimes labelled is a
# pool that cannot be scored.
prov_frontmatter() {
  # The arm is its own key, not just part of `variant:`. build_claimed scopes
  # sentence reuse by it, and the daily statistics group by it, so it has to
  # survive a post being moved into Keep/ by hand — which frontmatter does.
  printf 'arm: %s\n' "${BLOG_ARM:-base}"
  printf 'variant: %s\n' "$(blog_variant)"
  printf 'persona: %s\n' "${1:-}"
  printf 'run: %s\n'     "$BLOG_RUN_ID"
}

# The same three facts plus the prompt hashes, as a comment header for a
# provenance report. `#` comments, because the rest of the file is a
# machine-read classification list (build_claimed) that must not gain a
# meaning-bearing line.
prov_report_header() {
  local persona="${1:-}"
  printf '# variant: %s\n' "$(blog_variant)"
  printf '# persona: %s\n' "$persona"
  printf '# run: %s\n' "$BLOG_RUN_ID"
  printf '# commit: %s\n' "$(blog_git_commit)"
  printf '# model: %s\n' "$CURATE_MODEL"
  printf '# prompt.suggest: %s\n' "$(blog_file_hash "$SUGGEST_PROMPT")"
  printf '# directive: %s\n'      "$(blog_file_hash "${CURATE_DIRECTIVE:-}")"
  printf '# gate: %s\n' "$GATE_MODE"
}

fi   # BLOG_PROVENANCE_LOADED
