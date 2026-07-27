//
// VpxBGRAToI420.swift — VpxSwift
//
// The encode-side mirror of `VpxI420ToBGRA`: turns a BGRA `CVPixelBuffer` into the two planar
// images a transparent VP9 stream needs.
//
//   • **Colour** — BGRA → I420, the ordinary Yp'CbCr conversion, straight into libvpx's planes.
//   • **Alpha**  — the A channel extracted into the **luma plane of a second I420 image**, with the
//     chroma planes pinned at neutral 128. That is not a trick: VP9 has no alpha plane, so WebM
//     stores transparency as a whole second VP9 stream whose luma *is* the alpha channel.
//
// The alpha image is encoded **full range** (0–255). Studio range would squeeze alpha into 16–235,
// so a fully opaque pixel would come back as 235 and nothing would ever be quite opaque. The colour
// image keeps the usual video-range BT.709 convention the web expects.
//
// As on the decode side, the conversion info is built once and reused — it is the expensive part.
//

import Accelerate
import CoreVideo
import Cvpx

final class VpxBGRAToI420 {

    private var colorInfo = vImage_ARGBToYpCbCr()
    private var alphaBuffer: UnsafeMutableRawPointer?
    private var alphaBufferSize = 0

    /// vImage wants ARGB; `kCVPixelFormatType_32BGRA` is B,G,R,A in memory. The map selects each
    /// ARGB channel's source index — the same permutation the decode side applies in reverse.
    private static let bgraToARGB: [UInt8] = [3, 2, 1, 0]

    init() throws {
        // Video-range BT.709: the web's default for VP9 colour, and what our decoder assumes when a
        // stream declares nothing.
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128,
                                            YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        let err = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &colorInfo,
            kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { throw VpxError.vImage(err) }
    }

    deinit { alphaBuffer?.deallocate() }

    /// Fill `image`'s I420 planes with the colour content of `pixelBuffer`.
    ///
    /// - Parameter unpremultiply: set when the source carries **premultiplied** alpha (what
    ///   CoreGraphics and most compositors produce). WebM alpha is *straight*: a player composites
    ///   `colour × alpha` itself, so handing it premultiplied colour darkens every semi-transparent
    ///   pixel twice. Undoing it here is the only place that can be fixed without guessing.
    func fillColor(from pixelBuffer: CVPixelBuffer,
                   into image: UnsafeMutablePointer<vpx_image_t>,
                   unpremultiply: Bool) throws {
        try withLockedBGRA(pixelBuffer) { source in
            var src = source
            if unpremultiply {
                var scratch = try scratchBuffer(matching: source)
                // `vImageUnpremultiplyData_BGRA8888` is a C macro aliasing the RGBA entry point, so
                // Swift can't see it — call the real symbol. Only the *alpha* channel's position
                // matters to this operation, and BGRA is alpha-last just like RGBA.
                let err = vImageUnpremultiplyData_RGBA8888(&src, &scratch, vImage_Flags(kvImageNoFlags))
                guard err == kvImageNoError else { throw VpxError.vImage(err) }
                src = scratch
            }

            let img = image.pointee
            let width = Int(img.d_w), height = Int(img.d_h)
            let chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2
            var destY = vImage_Buffer(data: img.planes.0, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: Int(img.stride.0))
            var destCb = vImage_Buffer(data: img.planes.1, height: vImagePixelCount(chromaHeight),
                                       width: vImagePixelCount(chromaWidth), rowBytes: Int(img.stride.1))
            var destCr = vImage_Buffer(data: img.planes.2, height: vImagePixelCount(chromaHeight),
                                       width: vImagePixelCount(chromaWidth), rowBytes: Int(img.stride.2))

            let err = vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(
                &src, &destY, &destCb, &destCr, &colorInfo,
                Self.bgraToARGB, vImage_Flags(kvImageNoFlags))
            guard err == kvImageNoError else { throw VpxError.vImage(err) }
        }
    }

    /// Copy `pixelBuffer`'s alpha channel into `image`'s **luma** plane. Chroma is left at the
    /// neutral 128 that `prepareAlphaChroma` wrote once at allocation.
    func fillAlpha(from pixelBuffer: CVPixelBuffer,
                   into image: UnsafeMutablePointer<vpx_image_t>) throws {
        try withLockedBGRA(pixelBuffer) { source in
            var src = source
            let img = image.pointee
            var destY = vImage_Buffer(data: img.planes.0,
                                      height: vImagePixelCount(Int(img.d_h)),
                                      width: vImagePixelCount(Int(img.d_w)),
                                      rowBytes: Int(img.stride.0))
            // Channel 3 is A in BGRA memory order.
            let err = vImageExtractChannel_ARGB8888(&src, &destY, 3, vImage_Flags(kvImageNoFlags))
            guard err == kvImageNoError else { throw VpxError.vImage(err) }
        }
    }

    /// Pin an alpha image's chroma planes to neutral. Called once per allocation — the alpha stream
    /// carries no colour, and constant chroma costs almost nothing to encode.
    static func prepareAlphaChroma(_ image: UnsafeMutablePointer<vpx_image_t>) {
        let img = image.pointee
        let chromaHeight = (Int(img.d_h) + 1) / 2
        for (plane, stride) in [(img.planes.1, img.stride.1), (img.planes.2, img.stride.2)] {
            guard let plane else { continue }
            plane.update(repeating: 128, count: Int(stride) * chromaHeight)
        }
    }

    // MARK: - Helpers

    private func withLockedBGRA<T>(_ pixelBuffer: CVPixelBuffer,
                                   _ body: (vImage_Buffer) throws -> T) throws -> T {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else {
            throw VpxError.unsupportedInput(format)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VpxError.pixelBuffer(kCVReturnInvalidArgument)
        }
        let buffer = vImage_Buffer(
            data: base,
            height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        return try body(buffer)
    }

    /// A reusable same-geometry scratch buffer for the unpremultiply pass.
    private func scratchBuffer(matching source: vImage_Buffer) throws -> vImage_Buffer {
        let needed = source.rowBytes * Int(source.height)
        if alphaBufferSize < needed {
            alphaBuffer?.deallocate()
            alphaBuffer = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 64)
            alphaBufferSize = needed
        }
        return vImage_Buffer(data: alphaBuffer, height: source.height,
                             width: source.width, rowBytes: source.rowBytes)
    }
}
