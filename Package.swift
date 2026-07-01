// swift-tools-version: 6.2
import PackageDescription

// vpx-swift — a VP9(+VP8) decoder for the media-bridge external-decoder seam.
//
// This package is the QUARANTINE for libvpx: it carries ALL of the binary encumbrance (a decode-only
// libvpx built by Scripts/build-libvpx.sh, ~1 MB/arch) so that media-bridge itself stays pure-Swift and
// binary-free. VP9 has no native macOS decoder (VTDecompressionSessionCreate → -12906 on Apple Silicon)
// and no pure-Swift decoder exists, so libvpx (BSD-3 + PATENTS grant) is the only path. A consumer that
// wants transparent WebM depends on BOTH media-bridge and vpx-swift and registers the decoder once:
//
//     MediaBridge.register(externalDecoder: VpxVideoDecoder())
//
// Consumers that don't need VP9 depend on media-bridge alone and stay binary-free. See
// media-bridge/DEFERRED-CODEC-PLAN.md §9.
//
//   Cvpx       binaryTarget — the decode-only libvpx.xcframework (VP9+VP8 decoders, no encoder/tools).
//   VpxSwift   thin C-interop + vImage I420→BGRA; `VpxVideoDecoder: ExternalVideoDecoder`.
//
// License: this package is BSD-3-Clause (matching libvpx + its PATENTS grant). media-bridge stays MIT.
let package = Package(
    name: "vpx-swift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VpxSwift", targets: ["VpxSwift"]),
    ],
    dependencies: [
        // media-bridge v0.3.0 is the first tag that exposes the `MediaImport` product + a public
        // `DecodedVideoFrame.init` — the two enablers this package needs to conform to the seam.
        .package(url: "https://github.com/xocialize/media-bridge.git", from: "0.3.0"),
    ],
    targets: [
        .binaryTarget(name: "Cvpx", path: "Artifacts/vpx.xcframework"),
        .target(
            name: "VpxSwift",
            dependencies: [
                "Cvpx",
                .product(name: "MediaImport", package: "media-bridge"),
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
