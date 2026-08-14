#!/usr/bin/env bash
#
# install.sh — one-shot, idempotent setup for blog-pipeline.
#
# Installs/checks dependencies (ffmpeg, whisper.cpp, the STT model, and the
# presence of the `claude` CLI + git), then installs the OS-appropriate
# scheduler (systemd user timer on Linux, launchd agent on macOS).
#
# Safe to re-run: every step checks before it acts. Prefers user-local
# installs; only system package installation (ffmpeg) needs sudo on Linux.
#
#   ./install.sh
#
# Optional environment:
#   WHISPER_MODEL_SHA256=<hash>   enforce a known-good model checksum
#   SKIP_SCHEDULER=1              install deps only, don't touch the scheduler
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"

# --- what we install --------------------------------------------------------
# Full large-v3 (q5_0), not turbo: turbo is faster but hallucinates repetition
# loops more and is weaker on non-English. large-v3 runs at ~1x realtime here,
# fine for the unattended batch. Override with WHISPER_MODEL to use another.
MODEL_NAME="large-v3-q5_0"
MODEL_FILE="ggml-${MODEL_NAME}.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_FILE}"
WHISPER_GIT="https://github.com/ggerganov/whisper.cpp.git"

# --- pretty output ----------------------------------------------------------
log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# --- platform ---------------------------------------------------------------
case "$(uname -s)" in
  Linux)  PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *)      die "unsupported OS: $(uname -s)" ;;
esac

log "blog-pipeline installer — platform: $PLATFORM, repo: $REPO_DIR"
# sync/ is the one Syncthing folder shared with the phone: recordings at the
# root, the Obsidian vault (notes + generated post suggestions) below it.
mkdir -p "$REPO_DIR"/sync/Obsidian/Posts/Keep "$REPO_DIR"/sync/Obsidian/Posts/Discarded \
         "$REPO_DIR"/drafts "$REPO_DIR"/models "$REPO_DIR"/logs "$REPO_DIR"/work

# Privacy gate: run tests/check_privacy.sh on every commit, so nothing under
# the personal paths (sync/, drafts/, private/, ...) can ever be committed —
# even force-added. hooksPath is per-clone config, hence set here.
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" config core.hooksPath .githooks
  log "git pre-commit privacy gate enabled (core.hooksPath = .githooks)."
fi

# Keep device-local editor state out of the shared folder so it doesn't generate
# a steady drip of .sync-conflict files (see SETUP.md §4).
if [ ! -f "$REPO_DIR/sync/.stignore" ]; then
  cat > "$REPO_DIR/sync/.stignore" <<'STIGNORE'
// Syncthing ignores for the shared blog folder (phone /blog <-> laptop sync/).
//
// Everything listed here is device-local state: syncing it either produces a
// steady drip of .sync-conflict files, or is simply pointless to carry to the
// phone. The content always syncs — recordings at the root, notes and post
// suggestions under Obsidian/.

// Obsidian's per-device workspace state. Both devices rewrite these every time
// the app opens, which is the single biggest source of sync conflicts.
Obsidian/.obsidian/workspace.json
Obsidian/.obsidian/workspace-mobile.json
Obsidian/.obsidian/cache
Obsidian/.trash

// NOTE: Obsidian/Posts/Discarded/ is deliberately NOT ignored. Evicted
// suggestions sync to the phone and stay visible (and rescuable — move one back
// into Posts/ or Keep/) for TRASH_DAYS before suggest.sh ages them out.

(?d).DS_Store
STIGNORE
fi

# --- hard prerequisites -----------------------------------------------------
have git || die "git is required but not installed."
have claude || die "the 'claude' CLI (Claude Code) is required but was not found.
    Install it from https://docs.claude.com/claude-code and sign in with your
    subscription (this pipeline never uses an API key), then re-run install.sh."
have curl || die "curl is required for the model download."

# --- ffmpeg -----------------------------------------------------------------
install_ffmpeg() {
  if have ffmpeg; then log "ffmpeg: present"; return; fi
  log "ffmpeg: installing..."
  if [ "$PLATFORM" = macos ]; then
    have brew || die "Homebrew is required to install ffmpeg on macOS: https://brew.sh"
    brew install ffmpeg
  elif have apt-get; then sudo apt-get update && sudo apt-get install -y ffmpeg
  elif have dnf;     then sudo dnf install -y ffmpeg
  elif have pacman;  then sudo pacman -S --noconfirm ffmpeg
  elif have zypper;  then sudo zypper install -y ffmpeg
  else die "no supported package manager found; please install ffmpeg manually."
  fi
}

# --- whisper.cpp ------------------------------------------------------------
install_whisper() {
  if [ -x "$REPO_DIR/bin/whisper-cli" ] || have whisper-cli; then
    log "whisper.cpp: present"; return
  fi
  if [ "$PLATFORM" = macos ] && have brew; then
    log "whisper.cpp: installing via Homebrew..."
    brew install whisper-cpp && return
  fi

  log "whisper.cpp: building from source (a few minutes on first run)..."
  have cmake || die "cmake is required to build whisper.cpp."
  have make  || have ninja || die "make or ninja is required to build whisper.cpp."

  local vd="$REPO_DIR/vendor/whisper.cpp"
  if [ -d "$vd/.git" ]; then
    ( cd "$vd" && git pull --ff-only ) || warn "could not update whisper.cpp; building existing checkout."
  else
    git clone --depth 1 "$WHISPER_GIT" "$vd"
  fi
  ( cd "$vd" && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j --config Release )

  local built
  built="$(find "$vd/build" -type f -name whisper-cli 2>/dev/null | head -1)"
  [ -n "$built" ] || built="$(find "$vd/build" -type f -name main 2>/dev/null | head -1)"
  [ -n "$built" ] || die "whisper.cpp build produced no usable binary."
  ln -sf "$built" "$REPO_DIR/bin/whisper-cli"
  log "whisper.cpp: bin/whisper-cli -> $built"
}

# --- STT model + integrity --------------------------------------------------
verify_or_record_checksum() {
  local f="$1" sumfile="$1.sha256" cur
  cur="$(sha256_of "$f")"
  if [ -n "${WHISPER_MODEL_SHA256:-}" ]; then
    [ "$cur" = "$WHISPER_MODEL_SHA256" ] \
      || die "model checksum mismatch (expected $WHISPER_MODEL_SHA256, got $cur)."
    printf '%s\n' "$cur" > "$sumfile"
    log "model: checksum verified against WHISPER_MODEL_SHA256"
  elif [ -f "$sumfile" ]; then
    [ "$cur" = "$(cat "$sumfile")" ] \
      || die "model checksum changed since last install (now $cur); delete models/$MODEL_FILE to redownload."
    log "model: checksum matches recorded value"
  else
    printf '%s\n' "$cur" > "$sumfile"
    warn "no reference checksum supplied; recorded current value ($cur).
      For first-download authenticity, re-run once with WHISPER_MODEL_SHA256=$cur after you trust it."
  fi
}

download_model() {
  local dest="$REPO_DIR/models/$MODEL_FILE"
  if [ -f "$dest" ]; then
    log "model: present (models/$MODEL_FILE)"
  else
    log "model: downloading $MODEL_FILE (~1 GB, one time)..."
    local dl="$REPO_DIR/vendor/whisper.cpp/models/download-ggml-model.sh"
    if [ -f "$dl" ]; then
      ( cd "$REPO_DIR/vendor/whisper.cpp" && bash models/download-ggml-model.sh "$MODEL_NAME" ) || true
      local src="$REPO_DIR/vendor/whisper.cpp/models/$MODEL_FILE"
      [ -f "$src" ] && mv "$src" "$dest"
    fi
    if [ ! -f "$dest" ]; then
      curl -L --fail --progress-bar -o "$dest.part" "$MODEL_URL" \
        && mv "$dest.part" "$dest" \
        || die "model download failed from $MODEL_URL"
    fi
  fi
  verify_or_record_checksum "$dest"
}

# --- scheduler --------------------------------------------------------------
install_scheduler_linux() {
  if ! have systemctl; then
    warn "systemd not found; skipping timer. Run bin/process.sh from cron instead."
    return
  fi
  local ud="$HOME/.config/systemd/user" u
  mkdir -p "$ud"
  for u in blog-pipeline blog-suggest; do
    sed "s#__REPO_DIR__#$REPO_DIR#g" \
      "$REPO_DIR/watcher/$u.service" > "$ud/$u.service"
    cp "$REPO_DIR/watcher/$u.timer" "$ud/$u.timer"
  done
  systemctl --user daemon-reload
  systemctl --user enable --now blog-pipeline.timer
  systemctl --user enable --now blog-suggest.timer
  loginctl enable-linger "$USER" >/dev/null 2>&1 \
    || warn "could not enable linger; the timers only run while you are logged in."
  log "scheduler: systemd user timers enabled —"
  log "  blog-pipeline.timer  transcribe new recordings, every 15 min"
  log "  blog-suggest.timer   propose posts from your notes, daily at 03:00"
  log "                       (later slots the same day only retry a failed run)"
  log "  check with: systemctl --user list-timers 'blog-*'"
  log "  and with:   bash tests/check_units.sh   (installed units vs the repo)"
}

install_scheduler_macos() {
  local la="$HOME/Library/LaunchAgents" plist
  mkdir -p "$la"
  for plist in com.christian.blog-pipeline.plist com.christian.blog-suggest.plist; do
    sed "s#__REPO_DIR__#$REPO_DIR#g" "$REPO_DIR/watcher/$plist" > "$la/$plist"
    launchctl unload "$la/$plist" 2>/dev/null || true
    launchctl load "$la/$plist"
  done
  log "scheduler: launchd agents loaded (com.christian.blog-pipeline, .blog-suggest)."
}

# --- run --------------------------------------------------------------------
install_ffmpeg
install_whisper
download_model
chmod +x "$REPO_DIR"/bin/*.sh

if [ "${SKIP_SCHEDULER:-0}" = 1 ]; then
  log "SKIP_SCHEDULER=1 set; not touching the scheduler."
elif [ "$PLATFORM" = linux ]; then
  install_scheduler_linux
else
  install_scheduler_macos
fi

log "done."
log "Test now: drop an audio file in sync/ and run  bin/process.sh"
log "Then watch: tail -f logs/process.log"
log "Post suggestions: bin/suggest.sh  (needs 2+ notes; writes sync/Obsidian/Posts/)"
