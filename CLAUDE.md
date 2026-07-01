# vpx-swift — agent notes

**What:** VP9(+VP8) decoder for media-bridge's external-decoder seam. Quarantines the libvpx binary so
media-bridge stays pure-Swift. Ships OPEN in `MetalToolBox/PROD` (reusable media SPM).

**Architecture:**
- `Cvpx` — binaryTarget, decode-only `libvpx.xcframework`. Built by `Scripts/build-libvpx.sh` (the
  provenance of the binary; committed artifact is reproducible). arm64 by default; `ARCHS="arm64 x86_64"`
  for fat. The umbrella header `vpx_shim.h` adds a `static inline vpxs_dec_init(...)` wrapper because
  `vpx_codec_dec_init` is a C macro invisible to Swift — if you rebuild, that shim must survive (it's in
  the build script heredoc AND the artifact Headers).
- `VpxSwift` — `VpxDecoderSession` (libvpx C-interop, one packet → 0..n visible frames), `VpxI420ToBGRA`
  (vImage, conversion info cached per color-space/range), `VpxVideoDecoder` (the `ExternalVideoDecoder`).

**Scope:** 8-bit I420 only (VP9 profile 0 / VP8). Other formats throw `VpxError.unsupportedFormat`.
Highbitdepth is compiled into libvpx (decodes 10/12-bit streams) but the BGRA converter is 8-bit I420.

**Depends on media-bridge** for `ExternalVideoDecoder` + `DecodedVideoFrame` (the `MediaImport` product).
Two small enablers were added to media-bridge for this: (1) `MediaImport` exposed as a library product,
(2) a public `DecodedVideoFrame.init`. Currently a `path:` dependency — becomes a URL dependency once
media-bridge ships a tag with those. media-bridge stays MIT; this package is BSD-3 (matches libvpx).

**Tests:** `swift test` needs `ffmpeg` (dev-time, XCTSkip if absent). Two tests: the seam end-to-end with
the REAL decoder (VP9 WebM → HEVC), and a direct pixel spot-check via a tiny IVF reader (luma spread +
per-pixel saturation prove real image, not gray/garbage).

**Next (not done here):** wire into Forge Erase (register at startup → transparent WebM). Bundle Vorbis
(Phase C) into this same package so one binary unlocks the full WebM stack (VP8 + VP9 + Vorbis).
