import XCTest
import AVFoundation
import CoreVideo
import MediaBridge
import MediaImport
@testable import VpxSwift

/// The whole point, end to end: a transparent WebM goes in and a transparent `.mov` comes out, through
/// `MediaBridge.normalizeVideoPreservingAlpha` — the real entry point, not a test harness.
///
/// This lives in vpx-swift because media-bridge deliberately cannot depend on it: media-bridge carries no
/// codec binary, so the only place the two halves meet is a consumer that links both.
///
/// The input is produced by **ffmpeg**, not by this package's encoder. A round trip through our own
/// writer proves the writer and reader agree with each other; it does not prove either agrees with the
/// rest of the world.
final class AlphaRoundTripTests: XCTestCase {

    private func tool(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let p = dir + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// ffmpeg-authored alpha VP9: a horizontal alpha ramp over test content.
    private func makeAlphaWebM(at url: URL, ffmpeg: String) throws {
        try run(ffmpeg, ["-y",
                         "-f", "lavfi", "-i", "testsrc2=s=160x96:r=25:d=1",
                         "-f", "lavfi", "-i", "gradients=s=160x96:c0=black:c1=white:x0=0:y0=48:x1=160:y1=48:r=25:d=1",
                         "-filter_complex",
                         "[0:v]format=gbrp[b];[1:v]format=gray[a];[b][a]alphamerge,format=yuva420p[o]",
                         "-map", "[o]", "-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p",
                         "-auto-alt-ref", "0", "-b:v", "500k", url.path])
    }

    private func firstFrameAlphaRow(_ url: URL) async throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); reader.startReading()
        let sample = try XCTUnwrap(output.copyNextSampleBuffer(), "no frame read back")
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let w = CVPixelBufferGetWidth(buffer), y = CVPixelBufferGetHeight(buffer) / 2
        return (0..<w).map { base[y * rowBytes + $0 * 4 + 3] }
    }

    override func setUp() { super.setUp(); MediaBridge.unregisterAllExternalDecoders() }
    override func tearDown() { MediaBridge.unregisterAllExternalDecoders(); super.tearDown() }

    func testTransparentWebMSurvivesNormalizeIntoAlphaMOV() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).webm")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try makeAlphaWebM(at: src, ffmpeg: ffmpeg)

        MediaBridge.register(externalDecoder: VpxVideoDecoder())
        let result = try await MediaBridge.normalizeVideoPreservingAlpha(input: src, output: dst)

        XCTAssertTrue(result.sourceHadAlpha, "the source declares AlphaMode")
        XCTAssertEqual(result.outputFormat, .movHEVCAlpha)
        XCTAssertGreaterThan(result.frameCount, 0)

        let row = try await firstFrameAlphaRow(dst)
        XCTAssertLessThan(Int(row[2]), 48, "left edge should still be near-transparent after the round trip")
        XCTAssertGreaterThan(Int(row[row.count - 3]), 207, "right edge should still be near-opaque")
        XCTAssertNotEqual(row.min(), row.max(),
                          "a flattened result would be constant — this is the failure being guarded")
    }

    /// The refusal. With no alpha-capable decoder registered, an alpha source must **throw** rather than
    /// produce a valid-looking, silently opaque file — the outcome that is indistinguishable from success.
    func testAlphaSourceWithNoAlphaCapableDecoderIsRefused() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).webm")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try makeAlphaWebM(at: src, ffmpeg: ffmpeg)

        struct OpaqueOnlyDecoder: ExternalVideoDecoder {
            func canDecode(codecID: String) -> Bool { codecID == "V_VP9" }
            // decodesAlpha deliberately left at its `false` default.
            func decodeStreaming(codecID: String, codecPrivate: Data?, packets: [ExternalVideoPacket],
                                 onFrame: (DecodedVideoFrame) async throws -> Void) async throws {}
        }
        MediaBridge.register(externalDecoder: OpaqueOnlyDecoder())

        do {
            _ = try await MediaBridge.normalizeVideoPreservingAlpha(input: src, output: dst)
            XCTFail("must refuse rather than write a silently-flattened file")
        } catch let error as MediaBridge.AlphaNormalizeError {
            XCTAssertEqual(error, .decoderCannotReadAlpha(codecID: "V_VP9"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path),
                       "nothing should have been written")
    }
}
