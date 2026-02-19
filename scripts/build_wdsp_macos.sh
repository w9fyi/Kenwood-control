#!/bin/bash
# Build WDSP EMNR + ANR into a static library for macOS (arm64 + x86_64).
# Requires: FFTW3 installed via Homebrew at /opt/homebrew
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WDSP_DIR="$SCRIPT_DIR/../ThirdParty/wdsp"
OUT="$WDSP_DIR/libwdsp_nr.a"

FFTW_INC="/opt/homebrew/include"
FFTW_LIB="/opt/homebrew/lib/libfftw3.a"

if [ ! -f "$FFTW_LIB" ]; then
    echo "ERROR: libfftw3.a not found at $FFTW_LIB"
    echo "Install with: brew install fftw"
    exit 1
fi

echo "Building WDSP EMNR+ANR static library..."

SRCS=(
    "$WDSP_DIR/calculus.c"
    "$WDSP_DIR/emnr.c"
    "$WDSP_DIR/anr.c"
    "$WDSP_DIR/WDSPWrapper.c"
)

OBJS=()
for src in "${SRCS[@]}"; do
    obj="${src%.c}.o"
    echo "  Compiling $(basename "$src")..."
    clang -c -O2 \
          -arch arm64 \
          -I"$WDSP_DIR" \
          -I"$FFTW_INC" \
          -Wno-implicit-function-declaration \
          -Wno-int-conversion \
          "$src" -o "$obj"
    OBJS+=("$obj")
done

echo "  Linking $OUT..."
libtool -static -o "$OUT" "${OBJS[@]}" "$FFTW_LIB"

# Clean up object files
for obj in "${OBJS[@]}"; do
    rm -f "$obj"
done

echo "Done: $OUT ($(du -sh "$OUT" | cut -f1))"
