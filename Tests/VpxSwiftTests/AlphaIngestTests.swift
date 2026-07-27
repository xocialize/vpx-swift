import XCTest
import CoreVideo
import Accelerate
import MatroskaDemux
import MediaImport
@testable import VpxSwift

/// The **ingest** half of transparent WebM: `VpxVideoDecoder` claims `decodesAlpha = true`, and this is
/// what backs the claim.
///
/// The failure this guards against is invisible by construction. A decoder that ignores the alpha stream
/// returns a complete, plausible, fully opaque frame — no error, no dropped frame, nothing that looks
/// wrong. Only measuring the alpha channel distinguishes "kept it" from "silently threw it away".
///
/// The round trip is entirely in-package (encode → mux → demux → decode), so it also proves the two
/// halves agree with each other, not merely with ffmpeg.
final class AlphaIngestTests: XCTestCase {

    private let width = 160
    private let height = 96
    private let frameCount = 6

    // MARK: - Sources

    private func makeFrame(alpha: (Int, Int) -> UInt8,
                           color: (Int, Int) -> (blue: UInt8, green: UInt8, red: UInt8)) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &optional)
        let buffer = try XCTUnwrap(optional, "CVPixelBufferCreate failed (\(status))")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y), i = y * rowBytes + x * 4
                base[i] = c.blue; base[i + 1] = c.green; base[i + 2] = c.red; base[i + 3] = alpha(x, y)
            }
        }
        return buffer
    }

    /// Horizontal alpha ramp over colour that varies independently of it, so a flattened channel is
    /// measurable rather than merely suspected.
    private func rampFrame(shift: Int) throws -> CVPixelBuffer {
        try makeFrame { x, _ in UInt8(x * 255 / (self.width - 1)) } color: { x, y in
            (blue: UInt8((x &+ shift) % 256), green: UInt8(y % 256), red: 128)
        }
    }

    private func opaqueFrame() throws -> CVPixelBuffer {
        try makeFrame { _, _ in 255 } color: { x, y in
            (blue: UInt8(x % 256), green: UInt8(y % 256), red: 200)
        }
    }

    private func encode(_ frame: (Int) throws -> CVPixelBuffer) throws -> Data {
        var configuration = TransparentWebMEncoder.Configuration()
        configuration.bitrateKbps = 1_500
        configuration.keyframeIntervalFrames = 5
        let encoder = try TransparentWebMEncoder(width: width, height: height, configuration: configuration)
        for i in 0..<frameCount {
            try encoder.append(try frame(i), ptsNanos: Int64(i) * 33_333_333)
        }
        return try encoder.finish()
    }

    /// Demux, then decode through the public seam exactly as media-bridge drives it.
    private func decodeFirstFrame(_ document: Data) async throws -> CVPixelBuffer {
        let demuxer = MatroskaDemuxer(data: document)
        try demuxer.parseHeaders()
        let track = try XCTUnwrap(demuxer.tracks.first { $0.type == .video })
        XCTAssertTrue(track.video?.hasAlpha ?? false, "encoder must set AlphaMode")

        let packets = try demuxer.readAllPackets()
            .filter { $0.trackNumber == track.number }
            .map { ExternalVideoPacket(data: $0.data, ptsNanos: $0.ptsNanos, alpha: $0.blockAdditional) }
        XCTAssertNotNil(packets.first?.alpha, "demuxer must surface BlockAdditional")

        var first: CVPixelBuffer?
        try await VpxVideoDecoder().decodeStreaming(codecID: track.codecID,
                                                    codecPrivate: track.codecPrivate,
                                                    packets: packets) { frame in
            if first == nil { first = frame.image }
        }
        return try XCTUnwrap(first, "no frame decoded")
    }

    private func alphaRow(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let y = height / 2
        return (0..<width).map { base[y * rowBytes + $0 * 4 + 3] }
    }

    // MARK: - Tests

    func testAlphaRampSurvivesIngest() async throws {
        let row = alphaRow(try await decodeFirstFrame(try encode { try rampFrame(shift: $0 * 3) }))

        XCTAssertLessThan(row[2], 32, "left edge should decode near-transparent")
        XCTAssertGreaterThan(row[width - 3], 223, "right edge should decode near-opaque")
        XCTAssertNotEqual(row.min(), row.max(), "a decoder that ignored alpha returns a constant")

        let meanError = Double(row.enumerated()
            .map { abs(Int($1) - $0 * 255 / (width - 1)) }
            .reduce(0, +)) / Double(row.count)
        XCTAssertLessThan(meanError, 12.0, "mean alpha error \(meanError) — the ramp did not survive ingest")
    }

    /// The discriminating case: an opaque source must come back opaque. Without it, a bug that wrote a
    /// ramp unconditionally would pass the test above.
    func testOpaqueSourceIngestsOpaque() async throws {
        let row = alphaRow(try await decodeFirstFrame(try encode { _ in try opaqueFrame() }))
        XCTAssertEqual(row.min(), 255, "an opaque source must stay fully opaque through ingest")
    }

    /// Colour is premultiplied on the way out, matching the contract media-bridge's alpha writers
    /// document and the `kVTAlphaChannelMode_PremultipliedAlpha` the HEVC path is configured with.
    /// Straight alpha handed to that writer renders soft edges too bright.
    func testColourIsPremultiplied() async throws {
        let buffer = try await decodeFirstFrame(try encode { try rampFrame(shift: $0 * 3) })
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let y = height / 2

        // At the fully transparent edge premultiplied colour must collapse to ~0 regardless of what
        // the colour stream carried there; straight alpha would leave the original colour intact.
        for x in 0..<3 {
            let i = y * rowBytes + x * 4
            XCTAssertLessThan(Int(base[i]) + Int(base[i + 1]) + Int(base[i + 2]), 24,
                              "colour at a transparent pixel should be premultiplied to ~0")
        }
    }

    /// A decoder must not claim alpha support it doesn't have — media-bridge routes on this flag and
    /// refuses alpha-preserving work when it is false.
    func testDecoderDeclaresAlphaSupport() {
        XCTAssertTrue(VpxVideoDecoder().decodesAlpha)
    }
}
