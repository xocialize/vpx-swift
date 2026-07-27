// swift-tools-version: 6.2
import PackageDescription

// vpx-swift — transparent-WebM (VP9 + alpha) WRITING, plus a VP9(+VP8) decoder for the media-bridge
// external-decoder seam.
//
// This package is the QUARANTINE for libvpx: it carries ALL of the binary encumbrance (built by
// Scripts/build-libvpx.sh, ~2.9 MB/arch with the VP9 encoder) so that media-bridge itself stays
// pure-Swift and binary-free. libvpx (BSD-3 + PATENTS grant) is the only path in either direction —
// nothing on macOS encodes VP9, and VP9 has no native decoder either (VTDecompressionSessionCreate →
// -12906 on Apple Silicon).
//
// Writing transparent WebM is the PRIMARY purpose: it is the only transparent-video format non-Apple
// browsers accept. (Apple's half — .mov + HEVC-with-alpha — is media-bridge's AlphaVideoWriter.)
//
//     let encoder = try TransparentWebMEncoder(width: 640, height: 360)
//     try encoder.append(bgraFrame, ptsNanos: pts)
//     try encoder.finish(writingTo: url)
//
// Decoding plugs into media-bridge instead, registered once:
//
//     MediaBridge.register(externalDecoder: VpxVideoDecoder())
//
// Consumers that don't need VP9 depend on media-bridge alone and stay binary-free. See
// media-bridge/DEFERRED-CODEC-PLAN.md §9.
//
//   Cvpx       binaryTarget — libvpx.xcframework: VP9 encode + VP9/VP8 decode, no VP8 encode, no tools.
//   VpxSwift   C-interop + vImage colour conversion; `TransparentWebMEncoder`, `VpxVideoDecoder`.
//
// License: this package is BSD-3-Clause (matching libvpx + its PATENTS grant). media-bridge stays MIT.
let package = Package(
    name: "vpx-swift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VpxSwift", targets: ["VpxSwift"]),
    ],
    dependencies: [
        // Both seams live in media-bridge. v0.3.0 exposed the `MediaImport` product and a public
        // `DecodedVideoFrame.init` (the decode side); v0.6.0 added `ExternalAlphaVideoEncoder`
        // (the write side), so that is the floor.
        .package(url: "https://github.com/xocialize/media-bridge.git", from: "0.7.0"),
        // The WebM write side. matroska-swift is pure-Swift and MIT, so it adds no binary or
        // licence weight — and it is what keeps the muxer OUT of media-bridge, which deliberately
        // carries no codec binary and must not gain one transitively.
        // v0.2.0 is the first tag carrying `MatroskaMux`.
        .package(url: "https://github.com/xocialize/matroska-swift.git", from: "0.2.0"),
    ],
    targets: [
        .binaryTarget(name: "Cvpx", path: "Artifacts/vpx.xcframework"),
        .target(
            name: "VpxSwift",
            dependencies: [
                "Cvpx",
                .product(name: "MediaImport", package: "media-bridge"),
                .product(name: "MatroskaMux", package: "matroska-swift"),
                .product(name: "MatroskaDemux", package: "matroska-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]   // CVPixelBuffer isn't Sendable
        ),
        .testTarget(
            name: "VpxSwiftTests",
            dependencies: [
                "VpxSwift",
                .product(name: "MediaBridge", package: "media-bridge"),
                .product(name: "MediaImport", package: "media-bridge"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
