#!/bin/bash
set -euo pipefail
SRC_DIR=~/Downloads/apache-thetis/"Project Files"/lib/NR_Algorithms_x64/src/rnnoise
OUT_DIR=~/Downloads/"Kenwood control"/ThirdParty/NR/build
mkdir -p "$OUT_DIR"
pushd "$SRC_DIR"
# Configure and build static library for macOS without x86 rtcd
CC=clang CFLAGS="-O3 -fPIC" ./configure --disable-x86-rtcd --disable-examples --enable-static --enable-shared=no || true
make clean || true
# Build static lib
make -j$(sysctl -n hw.ncpu) || true
# Copy produced static library or .la to OUT_DIR
if [ -f src/.libs/librnnoise.a ]; then
  cp src/.libs/librnnoise.a "$OUT_DIR/rnnoise.a"
elif [ -f librnnoise.a ]; then
  cp librnnoise.a "$OUT_DIR/rnnoise.a"
fi
# Copy model weights if present
cp -v models/* "$OUT_DIR/" 2>/dev/null || true
popd
