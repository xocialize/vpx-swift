//
// TransparentWebMEncoder.swift — VpxSwift
//
// Writes **transparent WebM**: VP9 + alpha in a Matroska container. The public reason this package
// exists.
//
// Transparent video on the web has exactly two delivery formats, split by platform. Apple takes
// `.mov` + HEVC-with-alpha, which `AVAssetWriter` handles. Everything else — Chrome, Firefox, Edge —
// takes `.webm` + VP9-with-alpha, which nothing on the system can write. This is that.
//
// ## How VP9 stores alpha
//
// It doesn't, exactly. VP9 has no alpha plane. A transparent WebM is **two complete VP9 streams**:
//
//   - the base stream — the opaque colour image, stored in the Matroska `Block`;
//   - the alpha stream — a second VP9 stream whose **luma plane is the alpha channel**, stored per
//     frame in `BlockAdditional` under `BlockAddID` 1, with the track's `AlphaMode` set to 1.
//
// A decoder that reads only the base stream therefore gets a complete, plausible, *fully opaque*
// image and no indication anything is missing. That is the failure this encoder exists to make
// impossible on the write side — and why the round-trip test asserts decoded alpha values rather
// than the presence of a flag.
//
//     let encoder = try TransparentWebMEncoder(width: 640, height: 360)
//     for (index, frame) in frames.enumerated() {
//         try encoder.append(frame, ptsNanos: Int64(index) * 33_333_333)
//     }
//     try encoder.finish(writingTo: url)
//
// ## Alpha must be straight, not premultiplied
//
// Browsers composite `colour × alpha` themselves, so the colour handed in must NOT already be
// multiplied down. CoreGraphics and most compositors produce premultiplied BGRA — set
// `Configuration.inputIsPremultiplied` and the conversion undoes it. Getting this wrong is not a
// crash; it is semi-transparent pixels that come out visibly too dark.
//

import CoreVideo
import Cvpx
import Foundation
import MatroskaDemux
import MatroskaMux

public final class TransparentWebMEncoder {

    public struct Configuration: Sendable {
        /// Target bitrate for the **colour** stream. The alpha stream gets a fraction of it
        /// (`alphaBitrateFraction`) — a luma-only ramp compresses far harder than real imagery.
        public var bitrateKbps: UInt32 = 2_000
        public var alphaBitrateFraction: Double = 0.25
        /// Frames between forced keyframes. Both layers key together; see `VpxEncoderSession`.
        public var keyframeIntervalFrames: Int = 120
        /// libvpx speed/quality dial, −8…8. Higher is faster and softer.
        public var cpuUsed: Int32 = 1
        /// Threads per encoder. `nil` derives a value from the machine, shared between the two.
        public var threads: UInt32?
        /// Set when the source BGRA carries premultiplied alpha.
        public var inputIsPremultiplied: Bool = false
        /// Recorded in the container's `WritingApp`.
        public var writingApp: String = "vpx-swift"

        public init() {}
    }

    private let width: Int
    private let height: Int
    private let nominalFrameDurationNanos: Int64
    private let configuration: Configuration
    private let converter: VpxBGRAToI420
    private let colorEncoder: VpxEncoderSession
    private let alphaEncoder: VpxEncoderSession
    private let writer: MatroskaWriter

    private var colorImage: UnsafeMutablePointer<vpx_image_t>
    private var alphaImage: UnsafeMutablePointer<vpx_image_t>

    private var frameIndex = 0
    private var lastPtsNanos: Int64?
    private var finished = false

    /// - Parameters:
    ///   - width/height: frame size. Must be **even** — I420 chroma is half-resolution in each
    ///     axis, and an odd edge would need a cropping convention this encoder does not invent.
    ///   - nominalFrameDurationNanos: written as `DefaultDuration` so players can derive a frame
    ///     rate, and used for rate control. Defaults to 30 fps.
    public init(width: Int,
                height: Int,
                nominalFrameDurationNanos: Int64 = 33_333_333,
                configuration: Configuration = Configuration()) throws {
        guard width > 0, height > 0 else {
            throw VpxError.encoderInit("zero-sized frame (\(width)x\(height))")
        }
        guard width % 2 == 0, height % 2 == 0 else {
            throw VpxError.encoderInit("frame size \(width)x\(height) must be even in both axes "
                                       + "(I420 chroma is half-resolution)")
        }

        self.width = width
        self.height = height
        self.configuration = configuration
        self.nominalFrameDurationNanos = max(1, nominalFrameDurationNanos)

        let threads = configuration.threads
            ?? UInt32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))

        var colorOptions = VpxEncoderSession.Options()
        colorOptions.bitrateKbps = configuration.bitrateKbps
        colorOptions.cpuUsed = configuration.cpuUsed
        colorOptions.threads = threads
        colorOptions.fullRange = false

        var alphaOptions = colorOptions
        alphaOptions.bitrateKbps = max(64, UInt32(Double(configuration.bitrateKbps)
                                                  * max(0.05, configuration.alphaBitrateFraction)))
        // Full range so an opaque pixel encodes as 255, not studio-range 235.
        alphaOptions.fullRange = true

        converter = try VpxBGRAToI420()
        colorEncoder = try VpxEncoderSession(width: width, height: height, options: colorOptions)
        alphaEncoder = try VpxEncoderSession(width: width, height: height, options: alphaOptions)

        guard let color = vpx_img_alloc(nil, VPX_IMG_FMT_I420, UInt32(width), UInt32(height), 32),
              let alpha = vpx_img_alloc(nil, VPX_IMG_FMT_I420, UInt32(width), UInt32(height), 32) else {
            throw VpxError.encoderInit("vpx_img_alloc failed for \(width)x\(height)")
        }
        colorImage = color
        alphaImage = alpha
        // The alpha stream carries no colour; neutral chroma once is all it ever needs.
        VpxBGRAToI420.prepareAlphaChroma(alphaImage)

        let track = MuxTrack(number: 1,
                             codecID: "V_VP9",
                             pixelWidth: width,
                             pixelHeight: height,
                             hasAlpha: true,
                             defaultDurationNanos: self.nominalFrameDurationNanos)
        writer = try MatroskaWriter(tracks: [track], writingApp: configuration.writingApp)
    }

    deinit {
        vpx_img_free(colorImage)
        vpx_img_free(alphaImage)
    }

    /// Encode and store one frame. `image` must be `kCVPixelFormatType_32BGRA`; its alpha channel
    /// becomes the transparency. Frames must arrive in presentation order.
    public func append(_ image: CVPixelBuffer, ptsNanos: Int64) throws {
        guard !finished else { throw VpxError.encode("append after finish()") }
        guard CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height else {
            throw VpxError.encode("frame is \(CVPixelBufferGetWidth(image))x"
                                  + "\(CVPixelBufferGetHeight(image)), encoder is \(width)x\(height)")
        }
        if let last = lastPtsNanos, ptsNanos < last {
            throw VpxError.encode("timestamps went backwards (\(last) ns → \(ptsNanos) ns)")
        }

        try converter.fillColor(from: image, into: colorImage,
                                unpremultiply: configuration.inputIsPremultiplied)
        try converter.fillAlpha(from: image, into: alphaImage)

        let ticks = Int64((Double(ptsNanos) / 1_000_000.0).rounded())
        let durationTicks = UInt(max(1, nominalFrameDurationNanos / 1_000_000))
        let forceKeyframe = frameIndex % max(1, configuration.keyframeIntervalFrames) == 0

        let colorPackets = try colorEncoder.encode(image: colorImage, ptsTicks: ticks,
                                                   durationTicks: durationTicks,
                                                   forceKeyframe: forceKeyframe)
        let alphaPackets = try alphaEncoder.encode(image: alphaImage, ptsTicks: ticks,
                                                   durationTicks: durationTicks,
                                                   forceKeyframe: forceKeyframe)
        try store(colorPackets: colorPackets, alphaPackets: alphaPackets, ptsNanos: ptsNanos)

        frameIndex += 1
        lastPtsNanos = ptsNanos
    }

    /// Flush both encoders and assemble the document.
    public func finish() throws -> Data {
        guard !finished else { throw VpxError.encode("finish() called twice") }
        finished = true
        try store(colorPackets: try colorEncoder.finish(),
                  alphaPackets: try alphaEncoder.finish(),
                  ptsNanos: lastPtsNanos ?? 0)
        return writer.finish()
    }

    /// Flush and write to `url`.
    public func finish(writingTo url: URL) throws {
        try finish().write(to: url, options: .atomic)
    }

    // MARK: - Pairing

    /// Pair the two layers frame by frame. A mismatch here means the streams have desynchronised,
    /// and the resulting file would attach one frame's transparency to another's colour — so it is
    /// an error rather than a best-effort zip.
    private func store(colorPackets: [VpxEncoderSession.EncodedPacket],
                       alphaPackets: [VpxEncoderSession.EncodedPacket],
                       ptsNanos: Int64) throws {
        guard colorPackets.count == alphaPackets.count else {
            throw VpxError.layerDesync(color: colorPackets.count, alpha: alphaPackets.count)
        }
        for (color, alpha) in zip(colorPackets, alphaPackets) {
            guard color.ptsTicks == alpha.ptsTicks else {
                throw VpxError.layerTimestampMismatch(colorTicks: color.ptsTicks,
                                                      alphaTicks: alpha.ptsTicks)
            }
            // Both layers must key together, or seeking to a random-access point would land on an
            // alpha frame that still references one before it.
            guard color.isKeyframe == alpha.isKeyframe else {
                throw VpxError.layerKeyframeMismatch(ptsTicks: color.ptsTicks)
            }
            try writer.add(MuxFrame(trackNumber: 1,
                                    data: color.data,
                                    ptsNanos: color.ptsTicks * 1_000_000,
                                    isKeyframe: color.isKeyframe,
                                    durationNanos: nominalFrameDurationNanos,
                                    alpha: alpha.data))
        }
    }
}
