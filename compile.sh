#!/bin/bash
# KTPHLTVRecorder compile script (WSL)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AMXX_DIR="/mnt/n/Nein_/KTP Git Projects/KTPAMXX"
INCLUDE_DIR="$AMXX_DIR/plugins/include"
COMPILER="$AMXX_DIR/obj-linux/packages/base/addons/ktpamx/scripting/amxxpc"
COMPILER_LIB="$AMXX_DIR/obj-linux/packages/base/addons/ktpamx/scripting/amxxpc32.so"
OUTPUT_DIR="$SCRIPT_DIR/compiled"
STAGING_DIR="/mnt/n/Nein_/KTP Git Projects/KTP DoD Server/serverfiles/dod/addons/ktpamx/plugins"

echo "========================================"
echo "KTPHLTVRecorder Plugin Compiler (WSL)"
echo "========================================"
echo ""

# Create temp build directory
BUILD_DIR=$(mktemp -d)
trap "rm -rf $BUILD_DIR" EXIT

# Copy compiler and library
cp "$COMPILER" "$BUILD_DIR/"
cp "$COMPILER_LIB" "$BUILD_DIR/"
cp -r "$INCLUDE_DIR" "$BUILD_DIR/include"

# Generate build_info.inc for ktp_version_reporter — git SHA + build time
# get baked into the .amxx so `amx_ktp_versions` rcon can report what's
# actually deployed. Falls back to "unknown" off-toolchain.
GIT_SHA=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_DIRTY=""
if [ "$GIT_SHA" != "unknown" ]; then
    if ! git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null || \
       ! git -C "$SCRIPT_DIR" diff --cached --quiet 2>/dev/null; then
        GIT_DIRTY="-dirty"
    fi
fi
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%MZ)
cat > "$BUILD_DIR/include/build_info.inc" <<EOF
#define KTP_BUILD_SHA "${GIT_SHA}${GIT_DIRTY}"
#define KTP_BUILD_TIME "$BUILD_TIME"
EOF
echo "[INFO] build_info: SHA=${GIT_SHA}${GIT_DIRTY} BUILD_TIME=$BUILD_TIME"

# Convert line endings and copy source
sed 's/\r$//' "$SCRIPT_DIR/KTPHLTVRecorder.sma" > "$BUILD_DIR/KTPHLTVRecorder.sma"

# Compile
echo "[INFO] Compiling KTPHLTVRecorder.sma..."
cd "$BUILD_DIR"
./amxxpc KTPHLTVRecorder.sma -i./include -oKTPHLTVRecorder.amxx

if [ -f "KTPHLTVRecorder.amxx" ]; then
    mkdir -p "$OUTPUT_DIR"
    cp KTPHLTVRecorder.amxx "$OUTPUT_DIR/"
    echo ""
    echo "========================================"
    echo "[SUCCESS] Compilation successful!"
    echo "========================================"
    echo "Output: $OUTPUT_DIR/KTPHLTVRecorder.amxx"

    # Stage to server
    if [ -d "$STAGING_DIR" ]; then
        echo ""
        echo "[INFO] Staging to server..."
        cp "$OUTPUT_DIR/KTPHLTVRecorder.amxx" "$STAGING_DIR/"
        echo "[OK] Staged: $STAGING_DIR/KTPHLTVRecorder.amxx"
    fi
else
    echo ""
    echo "========================================"
    echo "[ERROR] Compilation failed!"
    echo "========================================"
    exit 1
fi

echo ""
echo "Done!"
