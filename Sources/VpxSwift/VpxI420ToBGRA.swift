//
// VpxI420ToBGRA.swift — VpxSwift
//
// Converts a decoded libvpx I420 (planar 8-bit 4:2:0) frame into a BGRA CVPixelBuffer using vImage,
// so the frame can flow straight into media-bridge's HEVC encoder. The Yp'CbCr→ARGB conversion info is
// built once (from the stream's color space + range) and reused across frames — it's the expensive part.
//
// An UNTAGGED stream (libvpx reports `VPX_CS_UNKNOWN`) still needs a matrix, and the choice is the
// reference players' one, not a single web-wide default:
//   • VP8 never signals colour — RFC 6386 is BT.601, and libvpx reports unknown for every VP8 frame.
//   • VP9 that declares nothing is picked by picture height: SD (≤ 576 lines, i.e. up to PAL) is
//     BT.601, HD is BT.709. That is what ffmpeg converts SD as and deckcraft's `Matrix::from_code` rule.
//

import Accelerate
import CoreVideo
import Cvpx

final class VpxI420ToBGRA {

    private var info = vImage_YpCbCrToARGB()
    private var builtKey: UInt64?   // (matrix << 1 | fullRange) — rebuild only when characteristics change

    /// VP9 carries a colour space in its keyframe header; VP8 has none, so `VPX_CS_UNKNOWN` from a VP8
    /// stream means "the codec's own BT.601", not "the producer said nothing".
    private let signalsColorSpace: Bool

    /// The tallest picture an untagged VP9 stream is taken to be SD (BT.601) at: 576 lines, PAL.
    static let untaggedSDMaxHeight = 576

    init(signalsColorSpace: Bool) {
        self.signalsColorSpace = signalsColorSpace
    }

    /// Convert one decoded `vpx_image_t` (8-bit I420) into a freshly-allocated BGRA `CVPixelBuffer`.
    func makeBGRA(from imgPtr: UnsafeMutablePointer<vpx_image_t>) throws -> CVPixelBuffer {
        let img = imgPtr.pointee
        guard img.fmt == VPX_IMG_FMT_I420 else { throw VpxError.unsupportedFormat(Int32(img.fmt.rawValue)) }

        let w = Int(img.d_w), h = Int(img.d_h)
        try ensureConversion(cs: img.cs, range: img.range, height: h)

        // libvpx plane/stride tuples → vImage source buffers. Chroma is half-resolution (4:2:0).
        var srcY = vImage_Buffer(data: img.planes.0,
                                 height: vImagePixelCount(h), width: vImagePixelCount(w),
                                 rowBytes: Int(img.stride.0))
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        var srcCb = vImage_Buffer(data: img.planes.1,
                                  height: vImagePixelCount(ch), width: vImagePixelCount(cw),
                                  rowBytes: Int(img.stride.1))
        var srcCr = vImage_Buffer(data: img.planes.2,
                                  height: vImagePixelCount(ch), width: vImagePixelCount(cw),
                                  rowBytes: Int(img.stride.2))

        // Destination: BGRA CVPixelBuffer with IOSurface backing (required to feed VideoToolbox encode).
        var pbOpt: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        let cvret = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                        kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbOpt)
        guard cvret == kCVReturnSuccess, let pb = pbOpt else { throw VpxError.pixelBuffer(cvret) }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        var dest = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb),
                                 height: vImagePixelCount(h), width: vImagePixelCount(w),
                                 rowBytes: CVPixelBufferGetBytesPerRow(pb))

        // vImage writes ARGB byte order [A,R,G,B]; permute to memory order B,G,R,A for kCVPixelFormatType_32BGRA.
        var permute: [UInt8] = [3, 2, 1, 0]
        let err = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
            &srcY, &srcCb, &srcCr, &dest, &info, &permute, 255, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { throw VpxError.vImage(err) }
        return pb
    }

    /// Build (or rebuild, if the stream's color characteristics changed) the Yp'CbCr→ARGB conversion.
    private func ensureConversion(cs: vpx_color_space_t, range: vpx_color_range_t, height: Int) throws {
        let full = (range == VPX_CR_FULL_RANGE)
        let bt601 = usesBT601(cs: cs, height: height)
        let key = (UInt64(bt601 ? 601 : 709) << 1) | (full ? 1 : 0)
        if builtKey == key { return }

        let matrix: UnsafePointer<vImage_YpCbCrToARGBMatrix> =
            bt601 ? kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 : kvImage_YpCbCrToARGBMatrix_ITU_R_709_2

        // 8-bit pixel ranges (Apple's documented video-/full-range values).
        var pixelRange = full
            ? vImage_YpCbCrPixelRange(Yp_bias: 0,  CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
                                      YpMax: 255, YpMin: 0,  CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                      YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)

        let err = vImageConvert_YpCbCrToARGB_GenerateConversion(
            matrix, &pixelRange, &info,
            kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { throw VpxError.vImage(err) }
        builtKey = key
    }

    /// BT.601 for SD colorimetry, BT.709 for everything else. BT.2020 has no dedicated vImage matrix
    /// here; 709 is the closest shipped approximation.
    func usesBT601(cs: vpx_color_space_t, height: Int) -> Bool {
        switch cs {
        case VPX_CS_BT_601, VPX_CS_SMPTE_170, VPX_CS_SMPTE_240:
            return true
        case VPX_CS_UNKNOWN:
            // Untagged: VP8 is always 601; VP9 by picture height (SD 601, HD 709 — the web default).
            return !signalsColorSpace || height <= Self.untaggedSDMaxHeight
        default:
            return false
        }
    }
}
