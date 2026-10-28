//
// ColorMatrixTests.swift — VpxSwiftTests
//
// Which Yp'CbCr→RGB matrix a frame converts with, checked against ffmpeg's own conversion of the same
// bitstream. The matrix is invisible to every structural check: a 601 frame converted as 709 is a
// complete, plausible picture with slightly wrong colours (≈6 levels mean on test bars). So each case
// measures BOTH matrices and asserts the right one is within a level AND the wrong one is clearly
// farther — a test that only checked "close to 601" would pass a converter that returned grey mush.
//
// The rule under test (AB-A-0205):
//   • tagged streams convert as tagged;
//   • VP8 (no colour signalling, RFC 6386) is BT.601;
//   • untagged VP9 is BT.601 up to 576 lines and BT.709 above — ffmpeg's SD conversion and
//     deckcraft's `Matrix::from_code` rule;
//   • our own encoder tags its output BT.709, so an SD export is not read back as 601.
//
// Clips are generated at runtime with ffmpeg (dev-time only) and the suite XCTSkips without it. Set
// `DECKCRAFT_FIXTURES` to deckcraft's `crates/media/tests/fixtures` to also measure its two clips.
//

import XCTest
import CoreVideo
import Cvpx
import MatroskaDemux
import MediaImport
@testable import VpxSwift

final class ColorMatrixTests: XCTestCase {

    private enum Matrix: String { case bt601, bt709 }

    /// Mean |ΔB|,|ΔG|,|ΔR| in 8-bit levels against ffmpeg converting the same frame as each matrix.
    private struct Measurement {
        let colorSpace: vpx_color_space_t
        let vs601: Double
        let vs709: Double
    }

    // MARK: - The cases

    func testVP8ConvertsAsBT601() throws {
        let m = try measure(codec: "libvpx", width: 64, height: 48)
        assertUntagged(m)
        assertMatches(.bt601, m, "VP8 has no colour signalling; RFC 6386 is BT.601")
    }

    func testUntaggedSDVP9ConvertsAsBT601() throws {
        let m = try measure(codec: "libvpx-vp9", width: 64, height: 48)
        assertUntagged(m)
        assertMatches(.bt601, m, "untagged SD VP9 is BT.601")
    }

    /// The top of the SD band: PAL's 576 lines still convert as 601.
    func testUntaggedPALHeightVP9ConvertsAsBT601() throws {
        let m = try measure(codec: "libvpx-vp9", width: 720, height: 576)
        assertUntagged(m)
        assertMatches(.bt601, m, "576 lines is SD")
    }

    func testUntaggedHDVP9ConvertsAsBT709() throws {
        let m = try measure(codec: "libvpx-vp9", width: 1280, height: 720)
        assertUntagged(m)
        assertMatches(.bt709, m, "untagged HD VP9 keeps the web default, BT.709")
    }

    /// A tag always wins over the height guess, in both directions.
    func testTaggedStreamsConvertAsTagged() throws {
        let sd709 = try measure(codec: "libvpx-vp9", width: 64, height: 48, tag: "bt709")
        XCTAssertEqual(sd709.colorSpace, VPX_CS_BT_709)
        assertMatches(.bt709, sd709, "SD tagged BT.709")

        let hd601 = try measure(codec: "libvpx-vp9", width: 1280, height: 720, tag: "smpte170m")
        XCTAssertEqual(hd601.colorSpace, VPX_CS_SMPTE_170)
        assertMatches(.bt601, hd601, "HD tagged SMPTE-170")
    }

    /// `VpxBGRAToI420` converts with BT.709 at every size, so the encoder must say so: an untagged SD
    /// export would now (correctly) be read back as BT.601 by us, ffmpeg and browsers.
    func testTransparentWebMEncoderTagsItsOutputBT709() throws {
        let width = 64, height = 48
        let encoder = try TransparentWebMEncoder(width: width, height: height)
        var optional: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &optional)
        let frame = try XCTUnwrap(optional)
        try encoder.append(frame, ptsNanos: 0)
        let document = try encoder.finish()

        let demuxer = MatroskaDemuxer(data: document)
        try demuxer.parseHeaders()
        let packet = try XCTUnwrap(try demuxer.readAllPackets().first)
        let session = try VpxDecoderSession(codecID: "V_VP9")
        var colorSpace: vpx_color_space_t?
        try session.decodeRaw(packet: packet.data) { colorSpace = $0.pointee.cs }
        XCTAssertEqual(colorSpace, VPX_CS_BT_709)
    }

    /// deckcraft's own fixtures (64×48, untagged) — the clips AB-A-0205 was measured on.
    func testDeckcraftFixtures() throws {
        guard let dir = ProcessInfo.processInfo.environment["DECKCRAFT_FIXTURES"] else {
            throw XCTSkip("set DECKCRAFT_FIXTURES to deckcraft's crates/media/tests/fixtures")
        }
        for (name, codecID) in [("clip-vp8.webm", "V_VP8"), ("clip-vp9.webm", "V_VP9")] {
            let ivf = try temporaryFile("ivf")
            defer { try? FileManager.default.removeItem(at: ivf) }
            try ffmpeg(["-y", "-i", "\(dir)/\(name)", "-an", "-c:v", "copy", "-f", "ivf", ivf.path])
            let m = try measure(ivf: ivf, codecID: codecID)
            assertUntagged(m)
            assertMatches(.bt601, m, name)
        }
    }

    // MARK: - Measuring

    private func measure(codec: String, width: Int, height: Int, tag: String? = nil) throws -> Measurement {
        let ivf = try temporaryFile("ivf")
        defer { try? FileManager.default.removeItem(at: ivf) }
        var args = ["-y", "-f", "lavfi", "-i", "testsrc=size=\(width)x\(height):rate=24:duration=0.1",
                    "-frames:v", "1", "-c:v", codec, "-b:v", "2M", "-pix_fmt", "yuv420p"]
        if let tag { args += ["-colorspace", tag] }
        try ffmpeg(args + ["-f", "ivf", ivf.path])
        return try measure(ivf: ivf, codecID: codec == "libvpx" ? "V_VP8" : "V_VP9")
    }

    private func measure(ivf: URL, codecID: String) throws -> Measurement {
        let packet = try XCTUnwrap(try VpxVideoDecoderTests.parseIVF(Data(contentsOf: ivf)).first)

        let session = try VpxDecoderSession(codecID: codecID)
        var colorSpace = VPX_CS_RESERVED
        var decoded: CVPixelBuffer?
        try session.decode(packet: packet.data) { decoded = $0 }
        try VpxDecoderSession(codecID: codecID).decodeRaw(packet: packet.data) { colorSpace = $0.pointee.cs }
        let ours = try bgraBytes(try XCTUnwrap(decoded, "no frame decoded"))

        func meanDelta(_ matrix: Matrix) throws -> Double {
            let reference = try ffmpegBGRA(ivf, matrix: matrix)
            XCTAssertEqual(reference.count, ours.count, "frame size mismatch")
            var sum = 0, n = 0
            for i in stride(from: 0, to: min(reference.count, ours.count), by: 4) {
                for c in 0..<3 { sum += abs(Int(reference[i + c]) - Int(ours[i + c])) }
                n += 3
            }
            return Double(sum) / Double(max(n, 1))
        }
        let m = Measurement(colorSpace: colorSpace, vs601: try meanDelta(.bt601), vs709: try meanDelta(.bt709))
        print(String(format: "[ColorMatrix] %@ %@ cs=%d  mean|ΔRGB| vs ffmpeg 601 = %.2f, vs 709 = %.2f",
                     codecID, ivf.lastPathComponent, Int(colorSpace.rawValue), m.vs601, m.vs709))
        return m
    }

    private func assertUntagged(_ m: Measurement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(m.colorSpace, VPX_CS_UNKNOWN, "fixture must be untagged to test the fallback",
                       file: file, line: line)
    }

    private func assertMatches(_ matrix: Matrix, _ m: Measurement, _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let (right, wrong) = matrix == .bt601 ? (m.vs601, m.vs709) : (m.vs709, m.vs601)
        XCTAssertLessThanOrEqual(right, 1.0, "\(what): expected \(matrix.rawValue) within 1 level, got \(right)",
                                 file: file, line: line)
        XCTAssertGreaterThan(wrong, right + 2.0, "\(what): the other matrix must be clearly farther "
                             + "(\(wrong) vs \(right)) or this test proves nothing", file: file, line: line)
    }

    // MARK: - ffmpeg + pixels

    /// ffmpeg's decode of the first frame, converted to BGRA with an explicit input matrix.
    ///
    /// `bilinear` (swscale's default) is the reference on purpose: its chroma handling agrees with
    /// vImage's to ~0.15 levels. `full_chroma_int` / `accurate_rnd` interpolate chroma differently and
    /// put ~9 levels of edge disagreement into a 64×48 test card under EITHER matrix, which hides the
    /// very difference being measured.
    private func ffmpegBGRA(_ ivf: URL, matrix: Matrix) throws -> [UInt8] {
        let raw = try temporaryFile("bgra")
        defer { try? FileManager.default.removeItem(at: raw) }
        try ffmpeg(["-y", "-i", ivf.path, "-frames:v", "1",
                    "-vf", "scale=in_color_matrix=\(matrix.rawValue):in_range=tv"
                        + ":flags=bilinear,format=bgra",
                    "-f", "rawvideo", raw.path])
        return [UInt8](try Data(contentsOf: raw))
    }

    /// Tightly packed BGRA, matching ffmpeg's rawvideo output.
    private func bgraBytes(_ pb: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](); out.reserveCapacity(w * h * 4)
        for y in 0..<h { out.append(contentsOf: UnsafeBufferPointer(start: base + y * rowBytes, count: w * 4)) }
        return out
    }

    private func ffmpeg(_ args: [String]) throws {
        guard let exe = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("ffmpeg not installed")
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["-v", "error"] + args
        p.standardOutput = Pipe(); let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "ffmpeg", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func temporaryFile(_ ext: String) throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }
}
