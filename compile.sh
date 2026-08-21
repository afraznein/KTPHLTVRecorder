#!/bin/bash
# KTPHLTVRecorder compile script (WSL)

set -e

# A failed build must be VISIBLE, not merely non-zero. Callers pipe this script
# (`| tail`, `| tee`), and the shell then reports the PIPE's status -- so a failed
# build reads as exit 0 unless the log itself says so. Gate on the banners below,
# never on the exit code.
_ktp_build_exit() {
    local rc=$?
    # Folded in from the old `trap "rm -rf $BUILD_DIR" EXIT` -- a second EXIT trap
    # would have silently replaced it.
    if [ -n "${BUILD_DIR:-}" ]; then rm -rf "$BUILD_DIR"; fi
    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "========================================"
        echo "[KTP-BUILD] FAILED: KTPHLTVRecorder compile.sh exited $rc"
        echo "========================================"
        echo "Nothing has been staged."
    fi
    exit "$rc"
}
trap _ktp_build_exit EXIT


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve KTPAMXX. Order: explicit override -> sibling checkout -> the path this
# script used to hardcode. A contributor who clones the repos side by side gets
# the sibling case for free; nobody has to edit this file to build, which they
# previously did.
if [ -n "${KTPAMXX_ROOT:-}" ]; then
    AMXX_DIR="$KTPAMXX_ROOT"
elif [ -d "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../KTPAMXX" ]; then
    AMXX_DIR="$(cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../KTPAMXX" && pwd)"
else
    AMXX_DIR="/mnt/n/Nein_/KTP Git Projects/KTPAMXX"
fi
INCLUDE_DIR="$AMXX_DIR/plugins/include"
COMPILER="$AMXX_DIR/obj-linux/packages/base/addons/ktpamx/scripting/amxxpc"
COMPILER_LIB="$AMXX_DIR/obj-linux/packages/base/addons/ktpamx/scripting/amxxpc32.so"
OUTPUT_DIR="$SCRIPT_DIR/compiled"
# Staging is the maintainer's local test tree; overridable, and every
# call site already skips it when absent, so a contributor just builds.
STAGING_DIR="${KTP_STAGING_DIR:-/mnt/n/Nein_/KTP Git Projects/KTP DoD Server/serverfiles/dod/addons/ktpamx/plugins}"
# Set KTP_NO_STAGE=1 to build WITHOUT touching the staging tree. Verifying a
# change to this script must not overwrite a staged artifact whose md5 is
# pinned to a reviewed build -- doing exactly that churned a wave pin on
# 2026-08-10. Every stage call site already tests -d, so a sentinel disables it.
[ -n "${KTP_NO_STAGE:-}" ] && STAGING_DIR="(staging disabled by KTP_NO_STAGE)"


echo "========================================"
echo "KTPHLTVRecorder Plugin Compiler (WSL)"
echo "========================================"
echo ""

# Create temp build directory
BUILD_DIR=$(mktemp -d)

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
# `set -e` would kill the script here before the verdict below.
set +e
./amxxpc KTPHLTVRecorder.sma -i./include -oKTPHLTVRecorder.amxx
AMXXPC_RC=$?
set -e

if [ "$AMXXPC_RC" -eq 0 ] && [ -f "KTPHLTVRecorder.amxx" ]; then
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
    echo "[ERROR] Compilation failed! (amxxpc exit $AMXXPC_RC)"
    echo "========================================"
    exit 1
fi

echo ""
echo "Done!"

# Success sentinel, last line on the only path that reaches here. A caller checks
# for this rather than for `$?`, which a pipe launders.
echo "[KTP-BUILD] OK: KTPHLTVRecorder compile.sh"
