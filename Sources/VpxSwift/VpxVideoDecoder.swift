//
// VpxVideoDecoder.swift — VpxSwift
//
// The public entry point: a libvpx-backed `ExternalVideoDecoder` for media-bridge's deferred-codec seam.
// Register it once and VP9/VP8 WebM/MKV normalize transparently through media-bridge's usual HEVC path:
//
//     import MediaBridge
//     import VpxSwift
//     MediaBridge.register(externalDecoder: VpxVideoDecoder())
//
// media-bridge already demuxes WebM (matroska-swift), so this is DECODER-ONLY — no libwebm. The libvpx
// binary lives entirely in THIS package; media-bridge stays pure-Swift. See DEFERRED-CODEC-PLAN.md §9.
//

import CoreVideo
import Foundation
import MediaImport

public struct VpxVideoDecoder: ExternalVideoDecoder {

    public init() {}

    /// The Matroska CodecIDs this decoder handles.
    private static let supported: Set<String> = ["V_VP9", "V_VP8"]

    public func canDecode(codecID: String) -> Bool { Self.supported.contains(codecID) }

    /// This decoder reads the alpha stream, so media-bridge may route alpha-preserving work to it.
    ///
    /// The protocol defaults this to `false` because a decoder that ignores alpha still returns
    /// complete, plausible, fully opaque frames — there is nothing to notice. Saying `true` here is a
    /// claim, and `testAlphaRampSurvivesIngest` is what backs it.
    public var decodesAlpha: Bool { true }

    /// Stream-decode VP9/VP8 packets to BGRA frames, emitting each via `onFrame` in PTS order. Memory
    /// stays bounded: exactly one decoded pixel buffer is live at a time (decode packet → emit → release),
    /// and `onFrame` is awaited so the downstream encoder back-pressures the decode.
    public func decodeStreaming(codecID: String,
                                codecPrivate: Data?,
                                packets: [ExternalVideoPacket],
                                onFrame: (DecodedVideoFrame) async throws -> Void) async throws {
        // VP9/VP8 CodecPrivate carries no init data the decoder needs (unlike AVCC/HEVC) — each packet is
        // a self-contained frame. codecPrivate is intentionally unused.
        let session = try VpxDecoderSession(codecID: codecID)

        // A SECOND, independent decoder for the alpha stream. Two libvpx contexts, each with its own
        // reference frames — the alpha stream has its own keyframes and inter-frame prediction, so it
        // cannot share state with the colour stream. Created lazily: the overwhelmingly common source
        // is opaque and should pay nothing for this.
        var alphaSession: VpxDecoderSession?

        for pkt in packets {
            // libvpx's decode/get_frame is synchronous; collect this packet's frames, then await emit.
            // A packet almost always yields exactly one visible frame (0 for a pure alt-ref superframe).
            var produced: [CVPixelBuffer] = []
            try session.decode(packet: pkt.data) { produced.append($0) }

            if let alphaData = pkt.alpha, !produced.isEmpty {
                let alphaDecoder = try alphaSession ?? VpxDecoderSession(codecID: codecID)
                alphaSession = alphaDecoder
                // Composite in place: the alpha stream's luma becomes the colour frame's A channel.
                // Kept inside `decodeRaw` because libvpx owns the image memory only until the next
                // decode call on that session.
                var index = 0
                try alphaDecoder.decodeRaw(packet: alphaData) { alphaImage in
                    guard index < produced.count else { return }
                    try VpxAlphaCompositor.apply(alpha: alphaImage, to: produced[index])
                    index += 1
                }
            }

            for image in produced {
                try await onFrame(DecodedVideoFrame(image: image, ptsNanos: pkt.ptsNanos))
            }
        }
    }
}
