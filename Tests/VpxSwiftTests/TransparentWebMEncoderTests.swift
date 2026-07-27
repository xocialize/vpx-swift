//
// TransparentWebMEncoderTests.swift — VpxSwiftTests
//
// The point of these tests is that **a written file is not evidence**. A WebM that merely carries an
// `AlphaMode` flag and a plausible `BlockAdditional` blob is exactly the failure mode worth fearing —
// it inspects perfectly and plays back opaque. So every assertion here goes through a real VP9
// decode and looks at pixel values.
//
// Three independent levels, deliberately:
//   1. structure — the container says what it should (cheap, catches muxer regressions);
//   2. our own libvpx decode of the alpha stream's luma plane;
//   3. **ffmpeg's** `libvpx-vp9` decode to RGBA — a third-party decoder that shares no code with
//      the writer. If our encoder and our decoder were wrong in the same direction, only (3) notices.
//
// And each level is checked against BOTH a ramp and a fully-opaque source, so a decoder that always
// returned 255 — the actual bug being guarded against — cannot pass.
//
// Trap worth knowing (and why `-c:v libvpx-vp9` is explicit below): ffmpeg's *native* vp9 decoder
// ignores `BlockAdditional` entirely and reports `yuv420p` for a perfectly good alpha file. A tool
// reporting "no alpha here" may simply not be looking.
//

import XCTest
import CoreVideo
import MatroskaDemux
import MediaImport
@testable import VpxSwift

final class TransparentWebMEncoderTests: XCTestCase {

    private let width = 160
    private let height = 96
    private let frameCount = 10

    // MARK: - Sources

    /// A horizontal alpha ramp, 0 on the left to 255 on the right, over a colour image that varies
    /// independently of it. A ramp makes a dropped or flattened channel *measurable* rather than
    /// merely suspected — uniform transparency would look identical to a bug that writes a constant.
    private func rampFrame(shift: Int = 0) throws -> CVPixelBuffer {
        try makeFrame { x, _ in UInt8(x * 255 / (self.width - 1)) } color: { x, y in
            (blue: UInt8((x &+ shift) % 256), green: UInt8(y % 256), red: 128)
        }
    }

    /// Fully opaque — the discriminating case.
    private func opaqueFrame() throws -> CVPixelBuffer {
        try makeFrame { _, _ in 255 } color: { x, y in
            (blue: UInt8(x % 256), green: UInt8(y % 256), red: 200)
        }
    }

    private func makeFrame(alpha: (Int, Int) -> UInt8,
                           color: (Int, Int) -> (blue: UInt8, green: UInt8, red: UInt8)) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &optional)
        let buffer = try XCTUnwrap(optional, "CVPixelBufferCreate failed (\(status))")

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * rowBytes + x * 4
                let (b, g, r) = color(x, y)
                pixel[0] = b; pixel[1] = g; pixel[2] = r; pixel[3] = alpha(x, y)  // BGRA
            }
        }
        return buffer
    }

    private func encode(_ frame: (Int) throws -> CVPixelBuffer) throws -> Data {
        var configuration = TransparentWebMEncoder.Configuration()
        configuration.bitrateKbps = 1_500
        configuration.keyframeIntervalFrames = 5
        let encoder = try TransparentWebMEncoder(width: width, height: height,
                                                 configuration: configuration)
        for i in 0..<frameCount {
            try encoder.append(try frame(i), ptsNanos: Int64(i) * 33_333_333)
        }
        return try encoder.finish()
    }

    // MARK: - 1. Container structure

    func testContainerDeclaresAlphaAndCarriesABlockAdditionalPerFrame() throws {
        let document = try encode { try rampFrame(shift: $0 * 3) }

        let demuxer = MatroskaDemuxer(data: document)
        try demuxer.parseHeaders()
        XCTAssertEqual(demuxer.docType, "webm")

        let track = try XCTUnwrap(demuxer.tracks.first)
        XCTAssertEqual(track.codecID, "V_VP9")
        XCTAssertEqual(track.video?.pixelWidth, width)
        XCTAssertEqual(track.video?.pixelHeight, height)
        XCTAssertEqual(track.video?.hasAlpha, true, "AlphaMode must be set")

        let packets = try demuxer.readAllPackets()
        XCTAssertEqual(packets.count, frameCount)
        XCTAssertEqual(packets.filter { $0.blockAdditional != nil }.count, frameCount,
                       "every frame needs its alpha layer")
        XCTAssertTrue(packets.first?.isKeyframe == true)

        for packet in packets {
            let alpha = try XCTUnwrap(packet.blockAdditional)
            XCTAssertNotEqual(alpha, packet.data, "alpha layer must not be a copy of the colour frame")
            // VP9 uncompressed header: top two bits are the frame marker, 0b10.
            XCTAssertEqual(try XCTUnwrap(alpha.first) >> 6, 0b10, "alpha layer must be a VP9 frame")
        }
    }

    // MARK: - 2. Our own libvpx decode of the alpha layer

    func testAlphaRampSurvivesOurOwnDecode() throws {
        let decoded = try decodeAlphaRow(of: try encode { try rampFrame(shift: $0 * 3) })
        assertIsRamp(decoded)
    }

    /// The discriminating half. If this returned a ramp, or the test above returned a constant,
    /// something is reading the wrong plane.
    func testOpaqueSourceDecodesFullyOpaque() throws {
        let decoded = try decodeAlphaRow(of: try encode { _ in try opaqueFrame() })
        let minimum = try XCTUnwrap(decoded.min())
        XCTAssertGreaterThanOrEqual(minimum, 250,
                                    "a fully opaque source must decode opaque everywhere, got min \(minimum)")
    }

    /// Decode the alpha layer of the first frame and return its middle row of alpha values.
    private func decodeAlphaRow(of document: Data) throws -> [UInt8] {
        let demuxer = MatroskaDemuxer(data: document)
        try demuxer.parseHeaders()
        let packet = try XCTUnwrap(try demuxer.readAllPackets().first)
        let alphaStream = try XCTUnwrap(packet.blockAdditional)

        // A SEPARATE decoder session: the alpha layer is its own VP9 stream with its own reference
        // frames, so feeding it to the colour session would corrupt both.
        let session = try VpxDecoderSession(codecID: "V_VP9")
        var row: [UInt8] = []
        try session.decodeRaw(packet: alphaStream) { image in
            let img = image.pointee
            XCTAssertEqual(Int(img.d_w), self.width)
            XCTAssertEqual(Int(img.d_h), self.height)
            // The luma plane IS the alpha channel — no colour conversion.
            let plane = try XCTUnwrap(img.planes.0)
            let stride = Int(img.stride.0)
            let y = self.height / 2
            row = (0..<self.width).map { plane[y * stride + $0] }
        }
        XCTAssertEqual(row.count, width, "alpha layer produced no frame")
        return row
    }

    // MARK: - 3. Independent decode via ffmpeg's libvpx-vp9

    func testAlphaSurvivesAThirdPartyDecoder() throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }

        let cases: [(String, Data, ([UInt8]) -> Void)] = [
            ("ramp", try encode { try rampFrame(shift: $0 * 3) }, { self.assertIsRamp($0) }),
            ("opaque", try encode { _ in try opaqueFrame() }, { self.assertIsOpaque($0) }),
        ]
        for (label, document, check) in cases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let webm = directory.appendingPathComponent("out.webm")
            let raw = directory.appendingPathComponent("out.rgba")
            try document.write(to: webm)

            // `-c:v libvpx-vp9` BEFORE -i is load-bearing: ffmpeg's native vp9 decoder ignores
            // BlockAdditional and would report this file as opaque no matter how correct it is.
            try run(ffmpeg, ["-y", "-c:v", "libvpx-vp9", "-i", webm.path,
                             "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", raw.path])

            let pixels = try Data(contentsOf: raw)
            XCTAssertEqual(pixels.count, width * height * 4,
                           "\(label): unexpected raw size — did ffmpeg decode the frame?")
            let y = height / 2
            let row = (0..<width).map { x -> UInt8 in
                pixels[pixels.startIndex + (y * width + x) * 4 + 3]   // RGBA → alpha is byte 3
            }
            check(row)
        }
    }

    // MARK: - The media-bridge seam

    /// Drive the encoder through `ExternalAlphaVideoEncoder` exactly as media-bridge would, and
    /// check the alpha survives that path too — a working encoder behind a mis-wired adapter is
    /// still an opaque file.
    func testSeamConformanceProducesTheSameTransparentFile() async throws {
        let encoder = VpxTransparentWebMEncoder()
        XCTAssertTrue(encoder.canWrite(.webmVP9Alpha))
        // The native formats belong to media-bridge's own AVFoundation writers.
        XCTAssertFalse(encoder.canWrite(.movHEVCAlpha))
        XCTAssertFalse(encoder.canWrite(.movProRes4444))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("seam.webm")

        var index = 0
        let written = try await encoder.write(to: output, format: .webmVP9Alpha,
                                              width: width, height: height, frameRate: 30) {
            guard index < self.frameCount else { return nil }
            defer { index += 1 }
            // Real PTS supplied, deliberately not a constant cadence — the seam must pass it
            // through rather than resynthesize it.
            return (buffer: try self.rampFrame(shift: index * 3),
                    ptsNanos: Int64(index) * 33_000_000 + Int64(index % 3) * 1_000_000)
        }
        XCTAssertEqual(written, frameCount)

        let document = try Data(contentsOf: output)
        let demuxer = MatroskaDemuxer(data: document)
        try demuxer.parseHeaders()
        XCTAssertEqual(demuxer.tracks.first?.video?.hasAlpha, true)
        XCTAssertEqual(try demuxer.readAllPackets().count, frameCount)
        assertIsRamp(try decodeAlphaRow(of: document))

        // A format it doesn't claim must be refused, not written opaque.
        await XCTAssertThrowsErrorAsync(
            try await encoder.write(to: output, format: .movHEVCAlpha,
                                    width: self.width, height: self.height, frameRate: 30) { nil })
    }

    private func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Any,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("expected an error", file: file, line: line)
        } catch {
            // expected
        }
    }

    // MARK: - Refusals

    func testEncoderRejectsOddDimensionsAndMismatchedFrames() throws {
        // I420 chroma is half-resolution, so an odd axis has no unambiguous meaning here.
        XCTAssertThrowsError(try TransparentWebMEncoder(width: 161, height: 96))
        XCTAssertThrowsError(try TransparentWebMEncoder(width: 160, height: 97))

        let encoder = try TransparentWebMEncoder(width: width, height: height)
        XCTAssertThrowsError(try encoder.append(try makeFrameOfSize(width: 64, height: 64),
                                                ptsNanos: 0),
                             "frame geometry must match the encoder")

        try encoder.append(try rampFrame(), ptsNanos: 1_000_000_000)
        XCTAssertThrowsError(try encoder.append(try rampFrame(), ptsNanos: 0),
                             "timestamps must not go backwards")
    }

    private func makeFrameOfSize(width w: Int, height h: Int) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &optional)
        return try XCTUnwrap(optional)
    }

    // MARK: - Shared assertions

    /// The ramp must actually be a ramp: dark at one end, opaque at the other, rising in between,
    /// and close to the ideal line. Lossy VP9 blurs it slightly, hence the tolerances.
    private func assertIsRamp(_ row: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        guard row.count == width else {
            return XCTFail("expected \(width) samples, got \(row.count)", file: file, line: line)
        }
        XCTAssertLessThan(row[2], 32, "left edge should be near-transparent", file: file, line: line)
        XCTAssertGreaterThan(row[width - 3], 223, "right edge should be near-opaque", file: file, line: line)
        XCTAssertNotEqual(row.min(), row.max(), "a flattened channel would be constant", file: file, line: line)

        let error = row.enumerated().map { index, value -> Int in
            abs(Int(value) - index * 255 / (width - 1))
        }
        let mean = Double(error.reduce(0, +)) / Double(row.count)
        XCTAssertLessThan(mean, 12.0, "mean alpha error \(mean) — the ramp did not survive",
                          file: file, line: line)

        // Monotonic within a tolerance for ringing around block edges.
        for i in 1..<row.count {
            XCTAssertGreaterThan(Int(row[i]) - Int(row[i - 1]), -20,
                                 "alpha dropped sharply at x=\(i)", file: file, line: line)
        }
    }

    private func assertIsOpaque(_ row: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        let minimum = row.min() ?? 0
        XCTAssertGreaterThanOrEqual(minimum, 250, "expected opaque, got min \(minimum)",
                                    file: file, line: line)
    }

    // MARK: - Tools

    private func tool(_ name: String) -> String? {
        for directory in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let path = directory + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
