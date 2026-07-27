//
// VpxError.swift — VpxSwift
//

import Foundation

/// Errors surfaced by the libvpx-backed decode path. All carry enough context to distinguish a codec
/// problem (bitstream) from a host problem (pixel-buffer / vImage).
public enum VpxError: Error, CustomStringConvertible {
    /// `vpx_codec_dec_init` failed, or an unknown CodecID was requested.
    case codecInit(String)
    /// `vpx_codec_decode` rejected a packet (message from libvpx where available).
    case decode(String)
    /// A decoded frame arrived in a pixel format this converter doesn't handle (only 8-bit I420 is
    /// supported — VP9 profile 0 / VP8, the web-ubiquitous case). Raw `vpx_img_fmt_t` value attached.
    case unsupportedFormat(Int32)
    /// `CVPixelBufferCreate` failed.
    case pixelBuffer(Int32)
    /// A vImage call failed (raw `vImage_Error`).
    case vImage(Int)
    /// `vpx_codec_enc_init` / encoder configuration failed, or the frame geometry is unusable.
    /// A libvpx built without the VP9 encoder reports itself here.
    case encoderInit(String)
    /// `vpx_codec_encode` rejected a frame, or the caller misused the encoder.
    case encode(String)
    /// A source pixel buffer arrived in a format the encoder can't read (only
    /// `kCVPixelFormatType_32BGRA`). Raw `OSType` attached.
    case unsupportedInput(OSType)
    /// The colour and alpha VP9 streams stopped producing packets one-for-one. Continuing would
    /// attach one frame's transparency to another frame's colour.
    case layerDesync(color: Int, alpha: Int)
    /// The paired colour and alpha packets disagree on presentation time.
    case layerTimestampMismatch(colorTicks: Int64, alphaTicks: Int64)
    /// The paired colour and alpha packets disagree on keyframe status, so a seek to that point
    /// would resolve colour but not transparency.
    case layerKeyframeMismatch(ptsTicks: Int64)

    public var description: String {
        switch self {
        case .codecInit(let m):       return "vpx codec init failed: \(m)"
        case .decode(let m):          return "vpx decode failed: \(m)"
        case .unsupportedFormat(let f): return "vpx frame has unsupported pixel format \(f) (only 8-bit I420 supported)"
        case .pixelBuffer(let s):     return "CVPixelBufferCreate failed (\(s))"
        case .vImage(let e):          return "vImage conversion failed (\(e))"
        case .encoderInit(let m):     return "vpx encoder init failed: \(m)"
        case .encode(let m):          return "vpx encode failed: \(m)"
        case .unsupportedInput(let f):
            let fourCC = String(bytes: (0..<4).map { UInt8((f >> (8 * (3 - $0))) & 0xFF) }, encoding: .ascii) ?? "?"
            return "source pixel buffer format '\(fourCC)' unsupported (need kCVPixelFormatType_32BGRA)"
        case .layerDesync(let c, let a):
            return "VP9 colour/alpha layers desynchronised: \(c) colour packet(s) vs \(a) alpha packet(s)"
        case .layerTimestampMismatch(let c, let a):
            return "VP9 colour/alpha layers disagree on timestamp (\(c) vs \(a) ticks)"
        case .layerKeyframeMismatch(let pts):
            return "VP9 colour/alpha layers disagree on keyframe status at \(pts) ticks"
        }
    }
}
