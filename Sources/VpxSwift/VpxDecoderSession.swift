//
// VpxDecoderSession.swift — VpxSwift
//
// Thin lifecycle wrapper over a single libvpx decoder instance: init the VP9/VP8 decoder, feed it one
// compressed packet at a time, and drain the decoded I420 frames it emits (0..n per packet — VP9
// superframes pack an "invisible" alt-ref with the visible frame; get_frame yields only the visible
// ones, in display order). Mirrors examples/simple_decoder.c. Not thread-safe; use one per decode.
//

import Cvpx
import CoreVideo
import Foundation

final class VpxDecoderSession {

    private var ctx = vpx_codec_ctx_t()
    private let converter = VpxI420ToBGRA()

    init(codecID: String) throws {
        let iface: OpaquePointer?
        switch codecID {
        case "V_VP9": iface = vpx_codec_vp9_dx()
        case "V_VP8": iface = vpx_codec_vp8_dx()
        default:      throw VpxError.codecInit("unsupported CodecID \(codecID)")
        }
        guard iface != nil else { throw VpxError.codecInit("\(codecID) decoder unavailable in libvpx build") }

        var cfg = vpx_codec_dec_cfg_t()          // w/h = 0 → derived from the stream
        cfg.threads = UInt32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))
        let err = vpxs_dec_init(&ctx, iface, &cfg, 0)
        guard err == VPX_CODEC_OK else { throw VpxError.codecInit(message(fallback: "dec_init \(err.rawValue)")) }
    }

    deinit { vpx_codec_destroy(&ctx) }

    /// Decode one compressed packet and hand each resulting BGRA frame to `onImage` in display order.
    func decode(packet: Data, onImage: (CVPixelBuffer) throws -> Void) throws {
        try packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            let err = vpx_codec_decode(&ctx, base, UInt32(raw.count), nil, 0)
            guard err == VPX_CODEC_OK else { throw VpxError.decode(message(fallback: "decode \(err.rawValue)")) }
        }
        var iter: vpx_codec_iter_t? = nil
        while let imgPtr = vpx_codec_get_frame(&ctx, &iter) {
            let pb = try converter.makeBGRA(from: imgPtr)
            try onImage(pb)
        }
    }

    /// libvpx's human-readable error detail for the last failure, else `fallback`.
    private func message(fallback: String) -> String {
        if let detail = vpx_codec_error_detail(&ctx) { return String(cString: detail) }
        if let err = vpx_codec_error(&ctx) { return String(cString: err) }
        return fallback
    }
}
