#!/usr/bin/env bash
set -euo pipefail

# Downloads and installs the Xiph RNNoise (BSD-3) C sources into:
#   ThirdParty/rnnoise/src
#
# This enables the in-process RNNoise backend (not the AU plugin).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT_DIR/ThirdParty/rnnoise/src"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

URL="https://github.com/xiph/rnnoise/archive/refs/heads/master.zip"
ZIP="$TMP_DIR/rnnoise.zip"

echo "Downloading RNNoise source..."
curl -L --fail --silent --show-error "$URL" -o "$ZIP"

echo "Unpacking..."
unzip -q "$ZIP" -d "$TMP_DIR"

SRC_ROOT="$(find "$TMP_DIR" -maxdepth 1 -type d -name 'rnnoise-*' | head -n 1)"
if [[ -z "${SRC_ROOT:-}" ]]; then
  echo "Error: could not find rnnoise-* folder after unzip"
  exit 1
fi

# RNNoise repo layout has historically used:
# - src/*.c and a few internal headers
# - include/rnnoise.h (public header)
# Some forks/branches may also have src/rnnoise.h.
HDR=""
if [[ -f "$SRC_ROOT/src/rnnoise.h" ]]; then
  HDR="$SRC_ROOT/src/rnnoise.h"
elif [[ -f "$SRC_ROOT/include/rnnoise.h" ]]; then
  HDR="$SRC_ROOT/include/rnnoise.h"
else
  HDR="$(find "$SRC_ROOT" -maxdepth 3 -type f -name 'rnnoise.h' | head -n 1 || true)"
fi

if [[ -z "${HDR:-}" || ! -f "$HDR" ]]; then
  echo "Error: rnnoise.h not found after unzip under:"
  echo "  $SRC_ROOT"
  echo "Debug: top-level:"
  (cd "$SRC_ROOT" && ls -la | head -n 60) || true
  exit 1
fi

if [[ ! -d "$SRC_ROOT/src" ]]; then
  echo "Error: expected C sources in:"
  echo "  $SRC_ROOT/src"
  exit 1
fi

mkdir -p "$DEST_DIR"
rsync -a --delete "$SRC_ROOT/src/" "$DEST_DIR/"
cp -f "$HDR" "$DEST_DIR/rnnoise.h"

if [[ -f "$SRC_ROOT/COPYING" ]]; then
  cp -f "$SRC_ROOT/COPYING" "$ROOT_DIR/ThirdParty/rnnoise/LICENSE"
fi

echo "Installed RNNoise sources into:"
echo "  $DEST_DIR"
echo
echo "Files:"
ls -1 "$DEST_DIR" | head -n 50
echo
echo "Next: rebuild the app (xcodebuild) and verify backend shows:"
echo "  RNNoise (in-process C, frame=480)"
