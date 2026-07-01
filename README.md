# vpx-swift

A **VP9 (+VP8) decoder** for [media-bridge](https://github.com/xocialize/media-bridge)'s external-decoder
seam. It carries a decode-only [libvpx](https://github.com/webmproject/libvpx) binary so that media-bridge
itself stays pure-Swift and binary-free — the package boundary *is* the quarantine.

## Why this exists

VP9 has **no native macOS decoder** — `VTDecompressionSessionCreate` returns `-12906`
(`kVTCouldNotFindVideoDecoderErr`) on Apple Silicon — and no pure-Swift decoder exists. `libvpx`
(BSD-3-Clause + a patent grant) is the only path. media-bridge can't take that binary without becoming
un-shippable (the old FFmpeg approach was ~100 MB), so the decoder lives here instead and plugs in through
media-bridge's `ExternalVideoDecoder` protocol. A decode-only libvpx is ~1 MB/arch.

## Usage

```swift
import MediaBridge
import VpxSwift

// Once at startup. Now VP9/VP8 WebM/MKV normalize transparently through media-bridge's HEVC pipeline.
MediaBridge.register(externalDecoder: VpxVideoDecoder())

let result = try await MediaBridge.normalizeVideoToHEVC(input: webmURL, output: mp4URL)
```

Consumers that don't need VP9 depend on media-bridge alone and stay binary-free. We already demux WebM
(via matroska-swift), so this is **decoder-only** — no libwebm.

## What's in the box

| Target | Role |
|---|---|
| `Cvpx` | `binaryTarget` — the decode-only `libvpx.xcframework` (VP9+VP8 decoders, no encoder/tools/libwebm). |
| `VpxSwift` | Thin libvpx C-interop + vImage I420→BGRA; `VpxVideoDecoder: ExternalVideoDecoder`. |

Scope: 8-bit I420 (VP9 profile 0 / VP8 — the web-ubiquitous case). Other pixel formats throw a clear
`VpxError.unsupportedFormat`.

## Rebuilding the binary

`Artifacts/vpx.xcframework` is committed, but fully reproducible:

```sh
Scripts/build-libvpx.sh                    # arm64 (default), macOS 14 floor
ARCHS="arm64 x86_64" Scripts/build-libvpx.sh   # fat build
```

The script clones libvpx v1.16.0 and configures it decode-only
(`--disable-vp8-encoder --disable-vp9-encoder --disable-examples --disable-tools --disable-docs
--disable-unit-tests --disable-webm-io --disable-libyuv`).

## License

BSD-3-Clause (matching libvpx). The bundled libvpx `LICENSE` + `PATENTS` are reproduced in
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) and must ship with any binary that links this package.
media-bridge stays MIT-pure; only a consumer that links vpx-swift accepts BSD-3 + the patent grant.
