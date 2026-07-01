#!/usr/bin/env bash
#
# build-libvpx.sh — reproducibly build a VP9(+VP8)-DECODE-ONLY libvpx and package it as an
# .xcframework for SPM binaryTarget consumption. This script is the provenance of Artifacts/vpx.xcframework:
# it carries ALL of vpx-swift's binary encumbrance so media-bridge can stay pure-Swift.
#
# Decode-only config keeps it SMALL (~1-2 MB/arch) — the whole point (the old FFmpeg mess was ~100 MB
# from linking everything). One codec family, no encoder, no tools, no libwebm (we already demux WebM
# via matroska-swift).
#
#   libvpx: BSD-3-Clause + PATENTS grant. License stays contained to this package.
#
# Usage:  Scripts/build-libvpx.sh [VERSION]     (default v1.16.0)
#         ARCHS="arm64 x86_64" Scripts/build-libvpx.sh   # dual-arch (default: arm64 only)
#
set -euo pipefail

VERSION="${1:-v1.16.0}"
ARCHS="${ARCHS:-arm64}"                 # space-separated; add x86_64 for a fat xcframework
MIN_MACOS="14.0"                        # match media-bridge's platform floor
DARWIN_TGT="darwin23"                   # libvpx target suffix ≈ macOS 14 toolchain

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/libvpx"
BUILD="$HERE/.build-libvpx"
OUT="$(cd "$HERE/.." && pwd)/Artifacts"
XCF="$OUT/vpx.xcframework"

# --- 1. source -------------------------------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  echo "==> cloning libvpx $VERSION"
  git clone --quiet --branch "$VERSION" --depth 1 https://github.com/webmproject/libvpx.git "$SRC"
fi
echo "==> libvpx $(git -C "$SRC" describe --tags 2>/dev/null || echo "$VERSION")"

# Decode-only, no encoder / examples / tools / docs / unit-tests / webm-io / libyuv. VP8+VP9 decoders
# are on by default; we only disable the encoders. highbitdepth lets us decode 10/12-bit VP9 streams.
CFG_COMMON=(
  --disable-vp8-encoder --disable-vp9-encoder
  --disable-examples --disable-tools --disable-docs --disable-unit-tests
  --disable-webm-io --disable-libyuv
  --disable-install-bins --disable-install-docs
  --enable-vp9-highbitdepth
  --enable-static --disable-shared
  --enable-pic
)

rm -rf "$BUILD"
LIBS=()
for ARCH in $ARCHS; do
  echo "==> configuring + building $ARCH"
  BDIR="$BUILD/$ARCH"
  mkdir -p "$BDIR"
  ( cd "$BDIR"
    "$SRC/configure" \
      --target="${ARCH}-${DARWIN_TGT}-gcc" \
      --prefix="$BDIR/install" \
      --extra-cflags="-mmacosx-version-min=${MIN_MACOS}" \
      "${CFG_COMMON[@]}"
    make -j"$(sysctl -n hw.ncpu)"
    make install
  )
  LIBS+=("$BDIR/install/lib/libvpx.a")
done

# --- 2. headers ------------------------------------------------------------------------------------
# The public vpx/ API headers are identical across arches; take them from the first build's install.
FIRST_ARCH="$(echo "$ARCHS" | awk '{print $1}')"
HDRROOT="$BUILD/headers"
rm -rf "$HDRROOT"; mkdir -p "$HDRROOT/vpx"
cp "$BUILD/$FIRST_ARCH/install/include/vpx/"*.h "$HDRROOT/vpx/"
# Umbrella + modulemap so SPM can `import Cvpx` (decode-only surface).
cat > "$HDRROOT/vpx_shim.h" <<'EOF'
// Umbrella for the VP9/VP8 decode surface of libvpx (see Scripts/build-libvpx.sh).
#include <vpx/vpx_codec.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_image.h>
#include <vpx/vp8dx.h>

// `vpx_codec_dec_init` is a function-like C macro (and VPX_DECODER_ABI_VERSION a nested macro), so it
// is invisible to Swift. This static-inline wrapper — which Swift DOES import — pins the ABI version
// at the exact value this header set was built against, avoiding any hardcoded constant on the Swift side.
static inline vpx_codec_err_t vpxs_dec_init(vpx_codec_ctx_t *ctx,
                                            vpx_codec_iface_t *iface,
                                            const vpx_codec_dec_cfg_t *cfg,
                                            vpx_codec_flags_t flags) {
    return vpx_codec_dec_init(ctx, iface, cfg, flags);
}
EOF
cat > "$HDRROOT/module.modulemap" <<'EOF'
module Cvpx {
    header "vpx_shim.h"
    export *
}
EOF

# --- 3. xcframework --------------------------------------------------------------------------------
# arm64 + x86_64 macOS both go in ONE macos slot; -create-xcframework refuses to merge same-platform
# slices, so lipo them into a fat static lib first.
echo "==> assembling xcframework"
rm -rf "$XCF"; mkdir -p "$OUT"
FATLIB="$BUILD/libvpx-fat.a"
lipo -create "${LIBS[@]}" -output "$FATLIB"
lipo -info "$FATLIB"
xcodebuild -create-xcframework \
  -library "$FATLIB" -headers "$HDRROOT" \
  -output "$XCF"

echo "==> done: $XCF"
find "$XCF" -maxdepth 2 -type d
du -sh "$XCF"
