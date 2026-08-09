#!/usr/bin/env bash
#
# notify.sh — cross-platform desktop notification wrapper.
#
#   usage: notify.sh <title> [body]
#
# Linux uses notify-send; macOS uses osascript. If neither is available
# (e.g. a headless run), the message is written to stderr so nothing is lost.
# Never fails hard: a missing notifier must not break the pipeline.
set -euo pipefail

title="${1:-blog-pipeline}"
body="${2:-}"

if command -v notify-send >/dev/null 2>&1; then
  # -a sets the app name shown by most notification daemons.
  notify-send -a "blog-pipeline" "$title" "$body" || true
elif command -v osascript >/dev/null 2>&1; then
  # AppleScript string literals use double quotes; escape any in the input.
  esc_title=${title//\"/\\\"}
  esc_body=${body//\"/\\\"}
  osascript -e "display notification \"$esc_body\" with title \"$esc_title\"" || true
else
  printf 'NOTIFY: %s — %s\n' "$title" "$body" >&2
fi
