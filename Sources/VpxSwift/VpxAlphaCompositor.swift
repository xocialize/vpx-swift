//
// VpxAlphaCompositor.swift — VpxSwift
//
// Writes a decoded alpha stream into an already-decoded colour frame.
//
// VP9-in-WebM carries alpha as a SECOND complete VP9 stream (Matroska `BlockAdditional`, BlockAddID 1)
// whose **luma plane is the alpha channel**; its chroma is ignored. So "decode alpha" means: run a
// second, independent decoder over the second stream and copy its Y plane into byte 3 of the BGRA
// buffer the first decoder produced.
//

import Accelerate
import Cvpx
import CoreVideo
import Foundation

enum VpxAlphaCompositor {

    /// Copy `alpha`'s luma plane into the A byte of `pixelBuffer`, then premultiply.
    ///
    /// **Premultiplication is not optional.** VP9 stores *straight* alpha, while media-bridge's
    /// alpha writers document a premultiplied-BGRA contract and configure the HEVC encoder with
    /// `kVTAlphaChannelMode_PremultipliedAlpha`. Handing straight alpha to that writer renders every
    /// semi-transparent pixel too bright — a soft edge glows instead of fading.
    static func apply(alpha: UnsafeMutablePointer<vpx_image_t>,
                      to pixelBuffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // The alpha stream is encoded at the same resolution as the colour stream. A mismatch means a
        // malformed file; refuse rather than smear a wrong-sized matte across the frame.
        guard Int(alpha.pointee.d_w) == width, Int(alpha.pointee.d_h) == height else {
            throw VpxError.alphaGeometryMismatch(
                color: "\(width)x\(height)",
                alpha: "\(alpha.pointee.d_w)x\(alpha.pointee.d_h)")
        }
        guard let alphaPlane = alpha.pointee.planes.0 else {
            throw VpxError.decode("alpha stream produced no luma plane")
        }
        let alphaStride = Int(alpha.pointee.stride.0)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw VpxError.decode("colour pixel buffer has no base address")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Y → A, row by row. Taken at full range, matching what ffmpeg's libvpx-vp9 path does with the
        // alpha stream; if a producer ever tags it limited-range this is where the 16–235 expansion
        // would go, and a matte's blacks and whites would clip without it.
        for y in 0 ..< height {
            let src = alphaPlane + y * alphaStride
            let dst = base + y * rowBytes
            for x in 0 ..< width { dst[x * 4 + 3] = src[x] }
        }

        var buffer = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: rowBytes)
        // `_RGBA8888` despite the buffer being BGRA: vImage's own header notes the routine "does not
        // have to be RGBA" — it multiplies the first three bytes by the fourth, and alpha is byte 3 in
        // both layouts. `vImagePremultiplyData_BGRA8888` is only a C macro aliasing this, so it does
        // not import into Swift.
        let err = vImagePremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { throw VpxError.vImage(err) }
    }
}
