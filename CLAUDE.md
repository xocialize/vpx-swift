# vpx-swift — agent notes

**What:** transparent-WebM (VP9 + alpha) **writing**, plus a VP9(+VP8) decoder for media-bridge's
external-decoder seam. Quarantines the libvpx binary so media-bridge stays pure-Swift. Ships OPEN in
`MetalToolBox/PROD` (reusable media SPM).

**Why the write side is the point.** Transparent video on the web has exactly two delivery formats:
`.mov` + HEVC-with-alpha for Apple (media-bridge's `AlphaVideoWriter`), and `.webm` + VP9-with-alpha
for Chrome/Firefox/Edge — which nothing else on macOS can produce. The package was originally built
decode-only, which inverted its main purpose; that's fixed.

**Architecture:**
- `Cvpx` — binaryTarget, `libvpx.xcframework` (VP9 encode + VP9/VP8 decode; **VP8 encode off**, no
  tools, no libwebm). Built by `Scripts/build-libvpx.sh` (the provenance of the binary; committed
  artifact is reproducible). arm64 by default; `ARCHS="arm64 x86_64"` for fat.
  The umbrella header `vpx_shim.h` adds three `static inline` wrappers because the corresponding
  libvpx APIs are C macros invisible to Swift — **if you rebuild, all three must survive** (they are
  in the build-script heredoc AND the artifact Headers), because VpxSwift calls them by name:
  `vpxs_dec_init`, `vpxs_enc_init`, `vpxs_control_int` (`vpx_codec_control_` is C-variadic).
- `VpxSwift` — encode: `VpxEncoderSession`, `VpxBGRAToI420`, `TransparentWebMEncoder` (public).
  Decode: `VpxDecoderSession`, `VpxI420ToBGRA`, `VpxVideoDecoder` (the `ExternalVideoDecoder`).

**Binary size** (arm64 static lib) — enabling the encoder tripled it, and that was a deliberate,
measured call, not an accident:

```
decode-only        962,752 bytes
+ VP9 encoder    2,876,728 bytes      → +1,913,976 (2.99x)
```

Don't enable anything further (VP8 encode, libyuv, webm-io, tools) without a reason and a
measurement — binary size is a shipped-product concern.

## How VP9 alpha works — the thing to internalise

VP9 has **no alpha plane**. A transparent WebM is TWO complete VP9 streams: colour in the Matroska
`Block`, and a second stream whose **luma plane IS the alpha channel** in `BlockAdditional`
(`BlockAddID` 1), with the track's `AlphaMode` = 1.

So a decoder reading only the base stream gets a complete, plausible, **fully opaque** image and no
hint anything is missing. Never accept "the file has an AlphaMode flag" as evidence — assert decoded
pixel values.

## Invariants — keep these true

- **Lockstep layers.** Every Matroska BlockGroup pairs frame N's colour packet with frame N's alpha
  packet, which only holds because both encoders run with `g_lag_in_frames = 0` (no alt-ref
  superframes — the same reason ffmpeg needs `-auto-alt-ref 0`) and `kf_mode = VPX_KF_DISABLED` with
  keyframes forced from outside. Left to themselves the two encoders pick *different* keyframes,
  because a flat alpha ramp and a busy colour image disagree about where the scene changes.
  `TransparentWebMEncoder.store` verifies the lockstep instead of trusting it.
- **Alpha is encoded FULL RANGE** (`VP9E_SET_COLOR_RANGE`). Studio range would squeeze it into
  16–235, so nothing would ever be quite opaque. Colour stays video-range BT.709.
- **Straight, not premultiplied.** WebM alpha is straight; browsers composite `colour × alpha`.
  `Configuration.inputIsPremultiplied` undoes premultiplication. Getting it wrong isn't a crash —
  it's semi-transparent pixels rendering too dark.
- **Even dimensions only** for the encoder (I420 chroma is half-resolution).
- **No muxer here.** matroska-swift muxes and demuxes; this package carries no libwebm.

**Depends on** media-bridge ≥0.6.0 (`ExternalVideoDecoder` + `DecodedVideoFrame` for read,
`ExternalAlphaVideoEncoder` + `TransparentVideoFormat` for write) and matroska-swift ≥0.2.0
(`MatroskaMux`, `MatroskaDemux`). Both seams are protocols: media-bridge carries no codec binary in
either direction — this package is the demarcation. media-bridge stays MIT; this package is BSD-3
(matches libvpx).

**Tests:** `swift test --build-system swiftbuild` (required in this stack). Some tests need `ffmpeg`
(dev-time, XCTSkip if absent). The transparent-WebM suite checks three independent levels — container
structure, our own libvpx decode of the alpha luma plane, and **ffmpeg's `libvpx-vp9` decode to
RGBA** — each against both a ramp and a fully-opaque source, so a decoder that always returned 255
cannot pass. ⚠️ `-c:v libvpx-vp9` must precede `-i`: ffmpeg's *native* vp9 decoder ignores
`BlockAdditional` and reports a perfectly good alpha file as `yuv420p`.

**Licensing:** BSD-3 + the libvpx PATENTS grant, which covers encode as well as decode. If you change
what the binary contains, `THIRD-PARTY-NOTICES.txt`, `README.md`, and the copy bundled into the ML(X)
Media Forge app must be updated together — they previously all said "decode-only".

**Next (not done here):** wire into Forge Erase/Extract — register
`VpxTransparentWebMEncoder` at startup, then export. Alpha *ingest* is still open: decoding a
transparent WebM back needs two `VpxDecoderSession`s (base + alpha, separate `vpx_codec_ctx_t`, so
serial interleave sidesteps the not-thread-safe note) with the alpha stream's luma written into byte
3 of the BGRA buffer — `VpxI420ToBGRA` passes a literal `255` there today, and `decodeRaw` exists to
make the second session straightforward. Bundling Vorbis (Phase C) into this package would unlock the
full WebM stack (VP8 + VP9 + Vorbis) from one binary.
