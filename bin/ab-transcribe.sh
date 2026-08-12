#!/usr/bin/env bash
#
# ab-transcribe.sh — the TRANSCRIBE seam, for experiments.
#
#   usage: ab-transcribe.sh <audiofile>          (same contract as transcribe.sh:
#                                                 transcript on stdout, nothing else)
#
# Whisper is the slowest and least interesting part of an LLM-stage experiment:
# the same recording transcribes to the same text every time, and running it
# again for every variant × repetition would cost minutes per run to learn
# nothing. So this stands in for bin/transcribe.sh and answers from, in order:
#
#   1. the fixture's frozen verbatim.md ($AB_FIXTURE), if there is one — that is
#      what "frozen" means: every variant sees byte-identical input, so a
#      difference downstream is the variant and not the recognizer;
#   2. the cache, keyed by the audio's content hash AND the whisper settings, so
#      a transcription experiment (a different model or language) is a different
#      key and is never served a stale answer;
#   3. bin/transcribe.sh itself, whose output is then cached.
#
# Set AB_TRANSCRIBE_FRESH=1 to bypass 1 and 2 — for the one experiment where
# whisper IS the thing under test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"

[ $# -eq 1 ] || { echo "usage: ab-transcribe.sh <audiofile>" >&2; exit 2; }
audio="$1"
[ -f "$audio" ] || { echo "ab-transcribe: no such file: $audio" >&2; exit 1; }

CACHE="${AB_CACHE:-$BLOG_REPO_DIR/eval/cache/transcripts}"
fresh="${AB_TRANSCRIBE_FRESH:-0}"

if [ "$fresh" != 1 ] && [ -n "${AB_FIXTURE:-}" ] && [ -s "$AB_FIXTURE/verbatim.md" ]; then
  cat "$AB_FIXTURE/verbatim.md"
  exit 0
fi

# The key is the recording plus everything about whisper that could change the
# answer. Threads are excluded for the same reason they are excluded from the
# config fingerprint: they are a property of the machine, not of the run.
key="$(printf '%s|%s|%s|%s|%s|%s' \
        "$(blog_sha256 "$audio")" "$(basename "$WHISPER_MODEL")" "$WHISPER_LANG" \
        "$WHISPER_MARKS" "$WHISPER_CONF_LOW" "$WHISPER_CONF_VLOW" \
      | blog_sha256_stdin)"
hit="$CACHE/$key.txt"

if [ "$fresh" != 1 ] && [ -s "$hit" ]; then
  cat "$hit"
  exit 0
fi

mkdir -p "$CACHE"
tmp="$(mktemp "$CACHE/.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
if ! "$REPO_DIR/bin/transcribe.sh" "$audio" > "$tmp"; then
  echo "ab-transcribe: transcription failed for $audio" >&2
  exit 1
fi
[ -s "$tmp" ] || { echo "ab-transcribe: empty transcript for $audio" >&2; exit 1; }
cp "$tmp" "$hit"
cat "$hit"
