#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/SubtitleMediaPlayer.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
MODEL_DIR="$ROOT/models"
APP_SUPPORT_MODEL_DIR="$HOME/Library/Application Support/SubtitleMediaPlayer/models"
MODEL_NAME="${SUBTITLEMEDIAPLAYER_WHISPER_MODEL_NAME:-ggml-base.bin}"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
MODEL_URL="${SUBTITLEMEDIAPLAYER_WHISPER_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing dependency: $1" >&2
    exit 1
  fi
}

need brew
need clang
need pkg-config

if ! pkg-config --exists mpv; then
  brew install mpv
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  brew install ffmpeg
fi

if ! command -v whisper-cli >/dev/null 2>&1; then
  brew install whisper-cpp
fi

mkdir -p "$MODEL_DIR"
if [[ "${SUBTITLEMEDIAPLAYER_SKIP_MODEL_DOWNLOAD:-0}" != "1" && ! -f "$MODEL_PATH" ]]; then
  echo "Downloading whisper model: $MODEL_NAME"
  if curl -L --fail --progress-bar "$MODEL_URL" -o "$MODEL_PATH.tmp"; then
    mv "$MODEL_PATH.tmp" "$MODEL_PATH"
  else
    rm -f "$MODEL_PATH.tmp"
    echo "warning: model download failed; the app still builds, but auto subtitles need a local .bin model" >&2
  fi
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES/models"
cp "$ROOT/src/SubtitleMediaPlayer/Info.plist" "$CONTENTS/Info.plist"

MPV_CFLAGS="$(pkg-config --cflags mpv)"
MPV_LIBS="$(pkg-config --libs mpv)"

clang -fobjc-arc -ObjC -std=gnu11 -Wall -Wextra -Wno-deprecated-declarations \
  -mmacosx-version-min=13.0 \
  $MPV_CFLAGS \
  "$ROOT/src/SubtitleMediaPlayer/main.m" \
  -o "$MACOS/SubtitleMediaPlayer" \
  -framework Cocoa -framework OpenGL \
  $MPV_LIBS

if [[ -f "$MODEL_PATH" ]]; then
  cp "$MODEL_PATH" "$RESOURCES/models/$MODEL_NAME"
  mkdir -p "$APP_SUPPORT_MODEL_DIR"
  cp "$MODEL_PATH" "$APP_SUPPORT_MODEL_DIR/$MODEL_NAME"
fi

SIGN_IDENTITY="${SUBTITLEMEDIAPLAYER_CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'\"' '/Developer ID Application|Apple Development|Mac Developer/ {print $2; exit}')"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

xattr -cr "$APP" 2>/dev/null || true

rm -f "$ROOT/dist/SubtitleMediaPlayer.dmg"
if command -v hdiutil >/dev/null 2>&1; then
  hdiutil create -volname SubtitleMediaPlayer -srcfolder "$APP" -ov -format UDZO "$ROOT/dist/SubtitleMediaPlayer.dmg" >/dev/null
  xattr -c "$ROOT/dist/SubtitleMediaPlayer.dmg" 2>/dev/null || true
fi

echo "Built: $APP"
if [[ -f "$ROOT/dist/SubtitleMediaPlayer.dmg" ]]; then
  echo "Built: $ROOT/dist/SubtitleMediaPlayer.dmg"
fi
