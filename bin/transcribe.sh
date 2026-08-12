#!/usr/bin/env bash
#
# transcribe.sh — verbatim speech-to-text via whisper.cpp.
#
#   usage: transcribe.sh <audiofile>
#
# Prints the plain-text transcript to stdout and nothing else; all progress,
# ffmpeg and whisper chatter go to stderr. This narrow contract is deliberate:
# process.sh captures stdout as verbatim.md, so the backend can be swapped
# (faster-whisper, a cloud STT, a mock) without touching the driver as long as
# the replacement honours "<audiofile> in, transcript text on stdout".
#
# CONFIDENCE MARKS: spans the recognizer itself was unsure about are wrapped
# in ⟦unsure⟧ … ⟦/unsure⟧ (from whisper's per-token probabilities: runs of
# low-p words — 2+ of them, or a single very-low one; punctuation neither
# starts nor breaks a run). The words inside a mark are still whisper's best
# guess, verbatim — the mark only tells the cleaner where "fix obvious
# transcription errors" most likely applies (cleanup.md knows the marks and
# never echoes them). Thresholds are calibrated on real memos: good speech
# averages p≈0.7–1.0, mishearings and garbled spots land under ≈0.4.
#
# Configurable via environment (install.sh sets sensible defaults on disk):
#   WHISPER_BIN      path to the whisper.cpp CLI (auto-detected if unset)
#   WHISPER_MODEL    path to the ggml model file
#   WHISPER_LANG     language code or "auto" (default: auto — EN/DE/mixed)
#   WHISPER_THREADS  thread count (default: all cores)
#   WHISPER_MARKS    0 disables confidence marks (default: 1; also off when
#                    jq is not installed — output is then identical to before)
#   WHISPER_CONF_LOW   a word below this p is "low" (default 0.40)
#   WHISPER_CONF_VLOW  a single low word only marks below this p (default 0.25)
#
# All of these are resolved in lib/config.sh, so a profile (BLOG_PROFILE) can
# set them for a whole run — see profiles/default.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/config.sh
. "$REPO_DIR/lib/config.sh"

die() { echo "transcribe: $*" >&2; exit 1; }

[ $# -eq 1 ] || { echo "usage: transcribe.sh <audiofile>" >&2; exit 2; }
audio="$1"
[ -f "$audio" ] || die "no such file: $audio"

# --- configuration (env overrides win) --------------------------------------
# Thread count is the one knob config.sh leaves empty: it is a property of the
# machine, not of the variant, so it is filled in here and stays out of the
# config fingerprint.
if [ -z "${WHISPER_THREADS:-}" ]; then
  if command -v nproc >/dev/null 2>&1; then
    WHISPER_THREADS="$(nproc)"
  else
    WHISPER_THREADS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  fi
fi

# Locate the whisper.cpp CLI. Modern builds ship "whisper-cli"; older ones
# called it "main". Prefer a copy vendored into this repo by install.sh.
find_whisper() {
  if [ -n "${WHISPER_BIN:-}" ]; then printf '%s' "$WHISPER_BIN"; return 0; fi
  local c
  for c in \
    "$REPO_DIR/bin/whisper-cli" \
    "$REPO_DIR/vendor/whisper.cpp/build/bin/whisper-cli" \
    "$REPO_DIR/vendor/whisper.cpp/main"; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  for c in whisper-cli whisper main; do
    command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
  done
  return 1
}

WHISPER_BIN="$(find_whisper)" \
  || die "whisper.cpp binary not found — run install.sh or set WHISPER_BIN"
[ -f "$WHISPER_MODEL" ] \
  || die "model not found: $WHISPER_MODEL — run install.sh or set WHISPER_MODEL"
command -v ffmpeg >/dev/null 2>&1 \
  || die "ffmpeg not found — run install.sh"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/transcribe.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
wav="$tmpdir/audio.wav"
out_prefix="$tmpdir/out"   # whisper writes "$out_prefix.txt"

# 1. Normalise to what whisper.cpp expects: 16 kHz, mono, signed 16-bit PCM.
ffmpeg -nostdin -hide_banner -loglevel error -y \
  -i "$audio" -ar 16000 -ac 1 -c:a pcm_s16le "$wav" 1>&2 \
  || die "ffmpeg failed to decode: $audio"

# 2. Transcribe. -nt drops timestamps (we want prose), -otxt writes a clean
#    text file. whisper's own stdout is noisy, so send it to stderr and read
#    the file instead.
# -mc 0 (max-context 0) disables conditioning on previously decoded text. Without
# it, Whisper can fall into runaway repetition loops during pauses/low-info
# moments and overwrite real speech (verified: a 10-min memo produced "She's
# doing it" ×13 in place of ~1.5 KB of actual words; -mc 0 recovered them).
# -ojf additionally writes full JSON with per-token probabilities — the raw
# material for the confidence marks. The .txt stays the fallback output.
"$WHISPER_BIN" \
  -m "$WHISPER_MODEL" \
  -f "$wav" \
  -l "$WHISPER_LANG" \
  -t "$WHISPER_THREADS" \
  -mc 0 \
  -nt -otxt -ojf -of "$out_prefix" 1>&2 \
  || die "whisper.cpp failed on: $audio"

[ -f "$out_prefix.txt" ] || die "whisper produced no transcript"

# 3. Emit the transcript verbatim. The text is rebuilt from the JSON's tokens
#    (concatenating token texts reproduces the .txt exactly), inserting
#    ⟦unsure⟧ marks around low-confidence runs on the way: a run collects
#    consecutive low-p words, punctuation-only tokens bridge it without
#    counting, and it is marked only when it has 2+ low words or dips below
#    the very-low threshold. No other rewriting happens here — cleanup is the
#    cleaner's job, and this file is the sacred verbatim record (the marks
#    annotate the recognizer's own certainty, not the speech).
emit_marked() {
  jq -r --argjson low "$WHISPER_CONF_LOW" --argjson vlow "$WHISPER_CONF_VLOW" '
    .transcription[]
    | if (.tokens // []) == [] then (.text | sub("^[[:space:]]+"; ""))
      else
        ( [ .tokens[]
            | select(.text | startswith("[_") | not)
            | { txt: .text, p: .p, word: (.text | test("[[:alnum:]]")) }
            | . + { low: (.word and .p < $low) } ]
          + [ { txt: "", p: 1, word: true, low: false } ]   # sentinel: flush
        ) as $t
        | reduce range(0; $t | length) as $i (
            { out: "", run: "", minp: 1, words: 0 };
            $t[$i] as $c
            | if $c.low
              then .run += $c.txt | .words += 1
                   | .minp = ([.minp, $c.p] | min)
              elif .run != "" and ($c.word | not)
                   and ($i + 1 < ($t | length)) and $t[$i + 1].low
              then .run += $c.txt
              else
                ( if .run == "" then .
                  elif .words >= 2 or .minp < $vlow
                  then .out +=
                    ( if (.run | startswith(" "))
                      then " ⟦unsure⟧" + (.run | ltrimstr(" "))
                      else "⟦unsure⟧" + .run
                      end ) + "⟦/unsure⟧"
                  else .out += .run
                  end )
                | .run = "" | .minp = 1 | .words = 0
                | .out += $c.txt
              end )
        | .out | sub("^[[:space:]]+"; "")
      end
  ' "$1"
}

if [ "$WHISPER_MARKS" != 0 ] && command -v jq >/dev/null 2>&1 \
   && [ -s "$out_prefix.json" ]; then
  if marked="$(emit_marked "$out_prefix.json")" && [ -n "$marked" ]; then
    printf '%s\n' "$marked"
    exit 0
  fi
  echo "transcribe: WARN confidence marking failed; emitting plain text" >&2
fi
sed -e 's/^[[:space:]]\{1,\}//' "$out_prefix.txt"
