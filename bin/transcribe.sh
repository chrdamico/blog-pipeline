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
# Configurable via environment (install.sh sets sensible defaults on disk):
#   WHISPER_BIN      path to the whisper.cpp CLI (auto-detected if unset)
#   WHISPER_MODEL    path to the ggml model file
#   WHISPER_LANG     language code or "auto" (default: auto — EN/DE/mixed)
#   WHISPER_THREADS  thread count (default: all cores)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

die() { echo "transcribe: $*" >&2; exit 1; }

[ $# -eq 1 ] || { echo "usage: transcribe.sh <audiofile>" >&2; exit 2; }
audio="$1"
[ -f "$audio" ] || die "no such file: $audio"

# --- configuration (env overrides win) --------------------------------------
WHISPER_MODEL="${WHISPER_MODEL:-$REPO_DIR/models/ggml-large-v3-q5_0.bin}"
WHISPER_LANG="${WHISPER_LANG:-auto}"
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
"$WHISPER_BIN" \
  -m "$WHISPER_MODEL" \
  -f "$wav" \
  -l "$WHISPER_LANG" \
  -t "$WHISPER_THREADS" \
  -mc 0 \
  -nt -otxt -of "$out_prefix" 1>&2 \
  || die "whisper.cpp failed on: $audio"

[ -f "$out_prefix.txt" ] || die "whisper produced no transcript"

# 3. Emit the transcript verbatim, only stripping the leading space whisper
#    puts on each segment line. No other rewriting happens here — cleanup is
#    the cleaner's job, and this file is the sacred verbatim record.
sed -e 's/^[[:space:]]\{1,\}//' "$out_prefix.txt"
