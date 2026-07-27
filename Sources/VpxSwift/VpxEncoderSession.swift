//
// VpxEncoderSession.swift — VpxSwift
//
// One libvpx VP9 encoder instance: configure, push an I420 image, drain the compressed packets.
// The mirror of `VpxDecoderSession`, and like it, not thread-safe — use one per stream.
//
// ## The lockstep requirement
//
// A transparent WebM is TWO of these running side by side, and every Matroska BlockGroup pairs
// frame N's colour packet with frame N's alpha packet. That pairing only holds if both encoders
// emit exactly one packet per input frame, at the same times, with keyframes in the same places.
// Two settings make that true, and both are load-bearing:
//
//   • **`g_lag_in_frames = 0`.** With lag, libvpx buffers frames to build alt-refs and packs them
//     into superframes, so packets stop corresponding one-to-one with inputs. This is the same
//     reason ffmpeg requires `-auto-alt-ref 0` to produce VP9 alpha at all.
//   • **`kf_mode = VPX_KF_DISABLED` plus explicit `VPX_EFLAG_FORCE_KF`.** Left to decide for
//     itself, each encoder picks keyframes from *its own* content — and a flat alpha ramp and a
//     busy colour image do not agree on where the scene changes. Driving keyframes from outside is
//     what keeps the two layers aligned, at the cost of scene-change adaptivity.
//
// `TransparentWebMEncoder` verifies the lockstep holds rather than trusting it.
//

import Cvpx
import Foundation

final class VpxEncoderSession {

    /// One compressed VP9 frame.
    struct EncodedPacket {
        let data: Data
        /// Presentation timestamp in the session's timebase units (milliseconds here).
        let ptsTicks: Int64
        let isKeyframe: Bool
    }

    struct Options {
        var bitrateKbps: UInt32 = 2_000
        /// libvpx speed/quality dial, −8…8. Higher is faster and softer; 1 is a good default for
        /// an export path where quality matters more than latency.
        var cpuUsed: Int32 = 1
        var threads: UInt32 = 4
        /// Alpha must be full range so 255 stays 255. Colour uses the web's usual studio range.
        var fullRange: Bool = false
        /// Milliseconds per timestamp tick is the Matroska default too, so the two agree without
        /// rescaling.
        var timebaseDenominator: Int32 = 1_000
    }

    private var ctx = vpx_codec_ctx_t()
    private var destroyed = false

    init(width: Int, height: Int, options: Options) throws {
        guard width > 0, height > 0 else {
            throw VpxError.encoderInit("zero-sized frame (\(width)x\(height))")
        }
        guard let iface = vpx_codec_vp9_cx() else {
            throw VpxError.encoderInit("VP9 encoder unavailable — libvpx was built without it "
                                       + "(see Scripts/build-libvpx.sh)")
        }

        var cfg = vpx_codec_enc_cfg_t()
        let defaults = vpx_codec_enc_config_default(iface, &cfg, 0)
        guard defaults == VPX_CODEC_OK else {
            throw VpxError.encoderInit("enc_config_default \(defaults.rawValue)")
        }

        cfg.g_w = UInt32(width)
        cfg.g_h = UInt32(height)
        cfg.g_timebase.num = 1
        cfg.g_timebase.den = options.timebaseDenominator
        cfg.g_threads = options.threads
        cfg.rc_target_bitrate = options.bitrateKbps
        cfg.rc_end_usage = VPX_VBR
        cfg.g_lag_in_frames = 0            // load-bearing — see the note above
        cfg.kf_mode = VPX_KF_DISABLED      // keyframes are driven from outside
        cfg.g_profile = 0                  // 8-bit 4:2:0, the universally decodable VP9 profile

        let err = vpxs_enc_init(&ctx, iface, &cfg, 0)
        guard err == VPX_CODEC_OK else {
            throw VpxError.encoderInit(message(fallback: "enc_init \(err.rawValue)"))
        }

        try control(VP8E_SET_CPUUSED, options.cpuUsed)
        try control(VP9E_SET_COLOR_RANGE, options.fullRange ? Int32(VPX_CR_FULL_RANGE.rawValue)
                                                           : Int32(VPX_CR_STUDIO_RANGE.rawValue))
        // Row-based multithreading; harmless when g_threads is 1.
        try? control(VP9E_SET_ROW_MT, 1)
    }

    deinit { destroy() }

    private func destroy() {
        guard !destroyed else { return }
        destroyed = true
        vpx_codec_destroy(&ctx)
    }

    /// Encode one image. Returns the packets it produced — with `g_lag_in_frames = 0` that is
    /// exactly one, but the caller checks rather than assuming.
    func encode(image: UnsafePointer<vpx_image_t>,
                ptsTicks: Int64,
                durationTicks: UInt,
                forceKeyframe: Bool) throws -> [EncodedPacket] {
        var flags = vpx_enc_frame_flags_t(0)
        if forceKeyframe { flags |= vpx_enc_frame_flags_t(VPX_EFLAG_FORCE_KF) }
        let err = vpx_codec_encode(&ctx, image, ptsTicks, durationTicks, flags, VPX_DL_GOOD_QUALITY)
        guard err == VPX_CODEC_OK else {
            throw VpxError.encode(message(fallback: "encode \(err.rawValue)"))
        }
        return drain()
    }

    /// Flush: a null image tells libvpx no more frames are coming.
    func finish() throws -> [EncodedPacket] {
        let err = vpx_codec_encode(&ctx, nil, 0, 0, 0, VPX_DL_GOOD_QUALITY)
        guard err == VPX_CODEC_OK else {
            throw VpxError.encode(message(fallback: "flush \(err.rawValue)"))
        }
        return drain()
    }

    private func drain() -> [EncodedPacket] {
        var packets: [EncodedPacket] = []
        var iter: vpx_codec_iter_t? = nil
        while let raw = vpx_codec_get_cx_data(&ctx, &iter) {
            guard raw.pointee.kind == VPX_CODEC_CX_FRAME_PKT else { continue }
            let frame = raw.pointee.data.frame
            guard let buf = frame.buf else { continue }
            packets.append(EncodedPacket(
                data: Data(bytes: buf, count: frame.sz),
                ptsTicks: frame.pts,
                isKeyframe: (frame.flags & UInt32(VPX_FRAME_IS_KEY)) != 0))
        }
        return packets
    }

    private func control(_ id: vp8e_enc_control_id, _ value: Int32) throws {
        let err = vpxs_control_int(&ctx, Int32(id.rawValue), value)
        guard err == VPX_CODEC_OK else {
            throw VpxError.encoderInit(message(fallback: "control \(id.rawValue) = \(value)"))
        }
    }

    private func message(fallback: String) -> String {
        if let detail = vpx_codec_error_detail(&ctx) { return String(cString: detail) }
        if let err = vpx_codec_error(&ctx) { return String(cString: err) }
        return fallback
    }
}
