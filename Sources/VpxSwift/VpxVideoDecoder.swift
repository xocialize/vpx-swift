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

    /// Stream-decode VP9/VP8 packets to BGRA frames, emitting each via `onFrame` in PTS order. Memory
    /// stays bounded: exactly one decoded pixel buffer is live at a time (decode packet → emit → release),
    /// and `onFrame` is awaited so the downstream encoder back-pressures the decode.
    public func decodeStreaming(codecID: String,
                                codecPrivate: Data?,
                                packets: [(data: Data, ptsNanos: Int64)],
                                onFrame: (DecodedVideoFrame) async throws -> Void) async throws {
        // VP9/VP8 CodecPrivate carries no init data the decoder needs (unlike AVCC/HEVC) — each packet is
        // a self-contained frame. codecPrivate is intentionally unused.
        let session = try VpxDecoderSession(codecID: codecID)

        for pkt in packets {
            // libvpx's decode/get_frame is synchronous; collect this packet's frames, then await emit.
            // A packet almost always yields exactly one visible frame (0 for a pure alt-ref superframe).
            var produced: [CVPixelBuffer] = []
            try session.decode(packet: pkt.data) { produced.append($0) }
            for image in produced {
                try await onFrame(DecodedVideoFrame(image: image, ptsNanos: pkt.ptsNanos))
            }
        }
    }
}
