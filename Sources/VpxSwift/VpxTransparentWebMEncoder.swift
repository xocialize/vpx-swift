//
// VpxTransparentWebMEncoder.swift — VpxSwift
//
// The public seam conformance: a libvpx-backed `ExternalAlphaVideoEncoder` for media-bridge's
// transparent-export path. Register it once and `.webm` + VP9-with-alpha becomes available
// alongside the `.mov` + HEVC-with-alpha that media-bridge writes natively:
//
//     import MediaBridge
//     import VpxSwift
//     MediaBridge.register(externalAlphaEncoder: VpxTransparentWebMEncoder())
//
// The libvpx binary lives entirely in THIS package — media-bridge stays pure-Swift and binary-free,
// exactly as it does for `VpxVideoDecoder` on the read side. This type is a thin adapter; the work
// is in `TransparentWebMEncoder`, which is also usable directly by a consumer that doesn't want
// media-bridge in the picture at all.
//

import CoreVideo
import Foundation
import MediaImport

public struct VpxTransparentWebMEncoder: ExternalAlphaVideoEncoder {

    private let configuration: TransparentWebMEncoder.Configuration

    public init(configuration: TransparentWebMEncoder.Configuration = .init()) {
        self.configuration = configuration
    }

    /// Only the format that needs us. `.movHEVCAlpha` and `.movProRes4444` are media-bridge's own
    /// AVFoundation writers — claiming them here would substitute libvpx for a better native path.
    public func canWrite(_ format: TransparentVideoFormat) -> Bool {
        format == .webmVP9Alpha
    }

    @discardableResult
    public func write(to output: URL,
                      format: TransparentVideoFormat,
                      width: Int,
                      height: Int,
                      frameRate: Double,
                      nextFrame: () async throws -> (buffer: CVPixelBuffer, ptsNanos: Int64?)?) async throws -> Int {
        guard canWrite(format) else {
            throw VpxError.encoderInit("VpxTransparentWebMEncoder does not write \(format.rawValue)")
        }

        let nominalFrameDurationNanos = frameRate > 0
            ? Int64((1_000_000_000.0 / frameRate).rounded())
            : 33_333_333
        let encoder = try TransparentWebMEncoder(width: width,
                                                 height: height,
                                                 nominalFrameDurationNanos: nominalFrameDurationNanos,
                                                 configuration: configuration)

        var index = 0
        while let frame = try await nextFrame() {
            // Prefer the source's real PTS. Falling back to `index × step` is a last resort, not a
            // default: it silently retimes variable-frame-rate sources, and screen and browser
            // capture — exactly the sources that carry alpha — are commonly VFR.
            let ptsNanos = frame.ptsNanos ?? Int64(index) * nominalFrameDurationNanos
            try encoder.append(frame.buffer, ptsNanos: ptsNanos)
            index += 1
        }

        try encoder.finish(writingTo: output)
        return index
    }
}
