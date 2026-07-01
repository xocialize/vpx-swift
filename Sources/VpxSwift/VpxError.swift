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

    public var description: String {
        switch self {
        case .codecInit(let m):       return "vpx codec init failed: \(m)"
        case .decode(let m):          return "vpx decode failed: \(m)"
        case .unsupportedFormat(let f): return "vpx frame has unsupported pixel format \(f) (only 8-bit I420 supported)"
        case .pixelBuffer(let s):     return "CVPixelBufferCreate failed (\(s))"
        case .vImage(let e):          return "vImage conversion failed (\(e))"
        }
    }
}
