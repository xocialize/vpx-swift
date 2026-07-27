#!/usr/bin/env bash
#
# build-libvpx.sh — reproducibly build libvpx (VP9 encode + VP9/VP8 decode) and package it as an
# .xcframework for SPM binaryTarget consumption. This script is the provenance of Artifacts/vpx.xcframework:
# it carries ALL of vpx-swift's binary encumbrance so media-bridge can stay pure-Swift.
#
# The config stays TIGHT — no tools, no examples, no libwebm (we mux/demux WebM via matroska-swift).
# That's the whole point (the old FFmpeg mess was ~100 MB from linking everything).
#
# The VP9 ENCODER is enabled because transparent-WebM export (VP9 + alpha) is the primary reason this
# package exists: it is the only transparent-video format non-Apple browsers accept. VP8 encode stays
# off — nothing needs it, and it is pure binary weight. Measured cost of adding VP9 encode, arm64:
#
#     decode-only        962,752 bytes
#     + VP9 encoder    2,876,728 bytes      → +1,913,976 (2.99x)
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

# VP9 encode + VP8/VP9 decode; no examples / tools / docs / unit-tests / webm-io / libyuv. All four
# codec halves are on by default, so we disable only VP8 *encode*. highbitdepth lets us decode
# 10/12-bit VP9 streams. Keep --disable-webm-io: libvpx's own muxer would duplicate matroska-swift
# AND drag in libwebm, and it cannot write the BlockAdditional alpha layer we need anyway.
CFG_COMMON=(
  --disable-vp8-encoder
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
# Umbrella + modulemap so SPM can `import Cvpx` (VP9 encode + VP9/VP8 decode surface).
#
# Three pieces of libvpx's public API are C macros, hence invisible to Swift. Each gets a
# static-inline wrapper below — which Swift DOES import — so the Swift side never hardcodes an ABI
# constant: every wrapper resolves the macro against the exact headers the binary was built from.
# If you rebuild, these shims must survive; VpxSwift calls them by name.
cat > "$HDRROOT/vpx_shim.h" <<'EOF'
// Umbrella for the libvpx surface vpx-swift uses (see Scripts/build-libvpx.sh).
#include <vpx/vpx_codec.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_encoder.h>
#include <vpx/vpx_image.h>
#include <vpx/vp8dx.h>
#include <vpx/vp8cx.h>

// `vpx_codec_dec_init` is a function-like macro (VPX_DECODER_ABI_VERSION is itself nested).
static inline vpx_codec_err_t vpxs_dec_init(vpx_codec_ctx_t *ctx,
                                            vpx_codec_iface_t *iface,
                                            const vpx_codec_dec_cfg_t *cfg,
                                            vpx_codec_flags_t flags) {
    return vpx_codec_dec_init(ctx, iface, cfg, flags);
}

// Likewise `vpx_codec_enc_init` (VPX_ENCODER_ABI_VERSION composes three nested macros).
static inline vpx_codec_err_t vpxs_enc_init(vpx_codec_ctx_t *ctx,
                                            vpx_codec_iface_t *iface,
                                            const vpx_codec_enc_cfg_t *cfg,
                                            vpx_codec_flags_t flags) {
    return vpx_codec_enc_init(ctx, iface, cfg, flags);
}

// `vpx_codec_control` is a macro that dispatches to a per-ID typed wrapper, and the underlying
// `vpx_codec_control_` is C-variadic — Swift can call neither. Every control VpxSwift sets takes a
// single int-compatible argument, so one shim covers them all.
static inline vpx_codec_err_t vpxs_control_int(vpx_codec_ctx_t *ctx, int ctrl_id, int value) {
    return vpx_codec_control_(ctx, ctrl_id, value);
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
