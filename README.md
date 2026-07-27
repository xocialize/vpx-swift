# vpx-swift

**VP9 with alpha, both directions**: a transparent-WebM *encoder*, and a VP9(+VP8) *decoder* for
[media-bridge](https://github.com/xocialize/media-bridge)'s external-decoder seam. It carries the
[libvpx](https://github.com/webmproject/libvpx) binary so that media-bridge itself stays pure-Swift
and binary-free — the package boundary *is* the quarantine.

## Why this exists

**Writing transparent WebM is the primary reason.** Transparent video on the web has exactly two
delivery formats, split by platform:

| Target | Container + codec | Where it's written |
|---|---|---|
| Apple / Safari | `.mov` + HEVC-with-alpha | media-bridge (`AlphaVideoWriter`) |
| **Chrome / Firefox / Edge** | **`.webm` + VP9-with-alpha** | **here** |

Nothing on macOS writes the second one. `AVAssetWriter` has no VP9 encoder at all, and even for the
Apple format alpha only survives in `.mov` — no mp4 configuration carries it.

Decoding is the secondary capability, and equally unavoidable: VP9 has **no native macOS decoder**
(`VTDecompressionSessionCreate` returns `-12906`, `kVTCouldNotFindVideoDecoderErr`, on Apple
Silicon) and no pure-Swift decoder exists. `libvpx` (BSD-3-Clause + a patent grant) is the only path
for either direction, and media-bridge can't take that binary without becoming un-shippable (the old
FFmpeg approach was ~100 MB), so it lives here.

## Writing transparent WebM

```swift
import VpxSwift

let encoder = try TransparentWebMEncoder(width: 640, height: 360)
for (index, frame) in bgraFrames.enumerated() {          // kCVPixelFormatType_32BGRA
    try encoder.append(frame, ptsNanos: Int64(index) * 33_333_333)
}
try encoder.finish(writingTo: webmURL)
```

Or through media-bridge's export seam, if you're already using it:

```swift
import MediaBridge
import VpxSwift

MediaBridge.register(externalAlphaEncoder: VpxTransparentWebMEncoder())   // once at startup
```

media-bridge writes the Apple half (`.mov` + HEVC-with-alpha) natively and delegates
`.webmVP9Alpha` here — so it never gains a codec binary. With nothing registered,
`MediaBridge.canWriteTransparent(.webmVP9Alpha)` is `false` and the caller says so, rather than
falling back to an opaque write.

**Alpha must be straight, not premultiplied.** Browsers composite `colour × alpha` themselves, so
colour that has already been multiplied down comes out visibly too dark in every semi-transparent
pixel. CoreGraphics and most compositors produce premultiplied BGRA — set
`Configuration.inputIsPremultiplied` and the conversion undoes it.

### How VP9 stores alpha

It doesn't, exactly — VP9 has no alpha plane. A transparent WebM is **two complete VP9 streams**:
the colour image in the Matroska `Block`, and a second stream whose **luma plane is the alpha
channel** in `BlockAdditional` (`BlockAddID` 1), with the track's `AlphaMode` set to 1.

The consequence is worth internalising: a decoder that reads only the base stream produces a
complete, plausible, **fully opaque** image and no indication anything is missing. That is why the
tests assert decoded pixel values through both libvpx and ffmpeg's `libvpx-vp9`, rather than
checking that a flag is present.

## Decoding

```swift
import MediaBridge
import VpxSwift

// Once at startup. Now VP9/VP8 WebM/MKV normalize through media-bridge's HEVC pipeline.
MediaBridge.register(externalDecoder: VpxVideoDecoder())

let result = try await MediaBridge.normalizeVideoToHEVC(input: webmURL, output: mp4URL)
```

Consumers that don't need VP9 depend on media-bridge alone and stay binary-free.

## What's in the box

| Target | Role |
|---|---|
| `Cvpx` | `binaryTarget` — the `libvpx.xcframework`: VP9 encode + VP9/VP8 decode, no VP8 encode, no tools, no libwebm. |
| `VpxSwift` | libvpx C-interop + vImage colour conversion; `TransparentWebMEncoder` (usable standalone), plus `VpxTransparentWebMEncoder: ExternalAlphaVideoEncoder` and `VpxVideoDecoder: ExternalVideoDecoder` for the media-bridge seams. |

Muxing and demuxing are **not** here — `matroska-swift` does both, so this package carries no
libwebm. Scope: 8-bit I420 (VP9 profile 0 / VP8 — the web-ubiquitous case). Other pixel formats
throw a clear `VpxError.unsupportedFormat`; encoder input must be `kCVPixelFormatType_32BGRA` with
even dimensions.

## Rebuilding the binary

`Artifacts/vpx.xcframework` is committed, but fully reproducible:

```sh
Scripts/build-libvpx.sh                        # arm64 (default), macOS 14 floor
ARCHS="arm64 x86_64" Scripts/build-libvpx.sh   # fat build
```

The script clones libvpx v1.16.0 and configures it for VP9 encode + VP9/VP8 decode
(`--disable-vp8-encoder --disable-examples --disable-tools --disable-docs --disable-unit-tests
--disable-webm-io --disable-libyuv`). Measured cost of the encoder, arm64 static lib:

```
decode-only        962,752 bytes
+ VP9 encoder    2,876,728 bytes      → +1,913,976 (2.99x)
```

## License

BSD-3-Clause (matching libvpx). The bundled libvpx `LICENSE` + `PATENTS` are reproduced in
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) and must ship with any binary that links this
package. The patent grant covers encode as well as decode, so enabling the VP9 encoder raised no new
licence question. media-bridge stays MIT-pure; only a consumer that links vpx-swift accepts BSD-3 +
the patent grant.
