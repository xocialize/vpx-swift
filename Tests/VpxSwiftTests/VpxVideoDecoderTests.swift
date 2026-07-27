import XCTest
import AVFoundation
import CoreVideo
@testable import VpxSwift
import MediaBridge
import MediaImport

/// End-to-end proof that the REAL libvpx-backed `VpxVideoDecoder` rescues VP9 through media-bridge's
/// external-decoder seam (mirrors media-bridge's ExternalDecoderTests, which used a fake), plus a direct
/// pixel spot-check that decoded frames carry real image data (not gray/garbage). Both fixtures are
/// generated at runtime with ffmpeg (a dev-time tool, never shipped) and XCTSkip when it's absent.
final class VpxVideoDecoderTests: XCTestCase {

    // MARK: ffmpeg helpers (mirrors media-bridge's test harness)

    private func tool(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let p = dir + name; if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
    @discardableResult private func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: 1) the seam, with the real decoder

    func testRealDecoderRescuesDeferredVP9() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).webm")
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst)
            MediaBridge.unregisterAllExternalDecoders()
        }
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8",
                         "-pix_fmt", "yuv420p", src.path])

        // Unregistered → VP9 defers, exactly as media-bridge behaves alone.
        do {
            _ = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
            XCTFail("VP9 should defer before the decoder is registered")
        } catch MediaBridge.NormalizeError.deferredCodec(let id) {
            XCTAssertEqual(id, "V_VP9")
        }

        // Registered → the real libvpx decoder carries VP9 through the full HEVC pipeline.
        MediaBridge.register(externalDecoder: VpxVideoDecoder())
        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertEqual(result.sourceCodecID, "V_VP9")
        XCTAssertGreaterThan(result.frameCount, 0, "libvpx produced frames")
        let types = try await AVURLAsset(url: dst).load(.tracks).map(\.mediaType)
        XCTAssertEqual(types.filter { $0 == .video }.count, 1, "decoded frames → one native HEVC track")

        // Removable: after unregister VP9 defers again.
        MediaBridge.unregisterAllExternalDecoders()
        do {
            _ = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
            XCTFail("VP9 should defer again after unregister")
        } catch MediaBridge.NormalizeError.deferredCodec(let id) {
            XCTAssertEqual(id, "V_VP9")
        }
    }

    // MARK: 2) pixel spot-check — decoded frames are real, not gray/garbage

    func testDecodedPixelsLookRight() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let ivf = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ivf")
        defer { try? FileManager.default.removeItem(at: ivf) }
        // testsrc = vivid SMPTE-style bars + a moving element → high color/brightness variance.
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.3",
                         "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8",
                         "-pix_fmt", "yuv420p", "-f", "ivf", ivf.path])

        let packets = try Self.parseIVF(Data(contentsOf: ivf))
        XCTAssertGreaterThan(packets.count, 0, "IVF yielded VP9 frames")

        var frames: [CVPixelBuffer] = []
        try await VpxVideoDecoder().decodeStreaming(
            codecID: "V_VP9", codecPrivate: nil,
            packets: packets.map { ExternalVideoPacket(data: $0.data, ptsNanos: $0.ptsNanos) }) { frame in
            frames.append(frame.image)
        }
        XCTAssertEqual(frames.count, packets.count, "one visible frame per packet")

        let stats = Self.bgraStats(frames[0])
        XCTAssertEqual(stats.width, 320); XCTAssertEqual(stats.height, 240)
        // A gray/garbage frame is flat (near-zero spread) or has a dead alpha. testsrc bars span the
        // luma range, so demand a wide spread AND a non-trivial mean — this fails loudly on a broken
        // I420→BGRA path (all-gray, single-plane smear, wrong strides).
        XCTAssertGreaterThan(stats.maxLuma - stats.minLuma, 120,
                             "decoded frame should span a wide brightness range (bars), not be flat gray")
        XCTAssertGreaterThan(stats.maxSaturation, 80,
                             "some pixels should be strongly colored (saturated bars), not a gray smear")
        XCTAssertEqual(stats.meanAlpha, 255, "opaque alpha")
    }

    // MARK: helpers

    /// Minimal IVF (DKIF) reader: 32-byte file header, then per-frame 12-byte header + payload. Enough to
    /// feed raw VP9 frames to the decoder without any container library.
    private static func parseIVF(_ data: Data) throws -> [(data: Data, ptsNanos: Int64)] {
        let b = [UInt8](data)
        guard b.count > 32, b[0] == 0x44, b[1] == 0x4B, b[2] == 0x49, b[3] == 0x46 else {
            throw NSError(domain: "IVF", code: 1, userInfo: [NSLocalizedDescriptionKey: "not an IVF file"])
        }
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o+1])<<8 | Int(b[o+2])<<16 | Int(b[o+3])<<24 }
        var out: [(data: Data, ptsNanos: Int64)] = []
        var off = 32, idx: Int64 = 0
        while off + 12 <= b.count {
            let size = u32(off)
            let start = off + 12
            guard start + size <= b.count else { break }
            out.append((data: Data(b[start..<start+size]), ptsNanos: idx * 41_666_666))  // ~24fps
            off = start + size; idx += 1
        }
        return out
    }

    private struct BGRAStats {
        let width: Int, height: Int
        let minLuma: Int, maxLuma: Int
        let maxSaturation: Int   // max over pixels of max(|B-G|,|G-R|,|B-R|) — colorfulness, not a global mean
        let meanAlpha: Int
    }

    /// Sample a BGRA CVPixelBuffer: luma range + per-channel means + alpha, to distinguish a real image
    /// from a flat gray/garbage frame. Subsamples for speed.
    private static func bgraStats(_ pb: CVPixelBuffer) -> BGRAStats {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var minL = 255, maxL = 0, maxSat = 0
        var sumA = 0, n = 0
        var y = 0
        while y < h {
            var x = 0
            let row = base + y * rb
            while x < w {
                let px = row + x * 4
                let bch = Int(px[0]), gch = Int(px[1]), rch = Int(px[2]), ach = Int(px[3])
                let luma = (bch + 2*gch + rch) / 4
                minL = min(minL, luma); maxL = max(maxL, luma)
                let sat = max(abs(bch-gch), max(abs(gch-rch), abs(bch-rch)))
                maxSat = max(maxSat, sat)
                sumA += ach; n += 1
                x += 4   // subsample columns
            }
            y += 4       // subsample rows
        }
        return BGRAStats(width: w, height: h, minLuma: minL, maxLuma: maxL,
                         maxSaturation: maxSat, meanAlpha: sumA/n)
    }
}
