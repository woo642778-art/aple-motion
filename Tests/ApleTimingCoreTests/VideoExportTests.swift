import XCTest
import Foundation
import ApleTimingCore

#if canImport(ApleTimingMedia) && canImport(AVFoundation)
import ApleTimingMedia
import AVFoundation
import CoreGraphics
import CoreVideo

final class VideoExportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 500_000]
        ])
        input.mediaTimeScale = 6
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            var waits = 0
            while !input.isReadyForMoreMediaData {
                guard waits < 5000, writer.status == .writing else {
                    throw writer.error ?? NSError(domain: "Fixture", code: 1)
                }
                try await Task.sleep(nanoseconds: 2_000_000); waits += 1
            }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "Fixture", code: 2) }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { throw NSError(domain: "Fixture", code: 3) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let level = UInt8(15 + frame * 18)
            for y in 0..<64 { for x in 0..<64 {
                let p = base.advanced(by: y * stride + x * 4)
                p[0] = level; p[1] = level; p[2] = level; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 6)) else {
                throw writer.error ?? NSError(domain: "Fixture", code: 4)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Fixture", code: 5) }
        return url
    }

    private func document(speed: Double, duration: Double, origin: Double = 0) throws -> TimingDocument {
        let ramp = try SpeedRamp.constant(outputDuration: Tick(seconds: duration), speed: speed, sourceOrigin: origin)
        return try TimingDocument(mode: .speedRamp, keys: ramp.curve.keys, sourceOrigin: origin)
    }

    private func outputLevels(_ url: URL, count: Int) throws -> [Double] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try (0..<count).map { index in
            let image = try generator.copyCGImage(at: CMTime(value: Int64(index), timescale: 6), actualTime: nil)
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw NSError(domain: "Fixture", code: 6)
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
        }
    }

    func testFastPlaybackEncodesExpectedFrames() async throws {
        let dir = try directory(), input = try await fixture(in: dir)
        let output = dir.appendingPathComponent("fast.mp4")
        let report = try await VideoRetimer.export(source: input, destination: output,
            document: document(speed: 2, duration: 1),
            options: VideoExportOptions(width: 64, height: 64, frameRate: FrameRate(6)))
        XCTAssertEqual(report.outputFrameCount, 6)
        XCTAssertEqual(report.sourceFrameCount, 12)
        XCTAssertFalse(report.audioDiscarded)
        let levels = try outputLevels(output, count: 6)
        for i in levels.indices { XCTAssertEqual(levels[i], Double(15 + i * 36), accuracy: 10) }
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.01)
    }

    func testReverseUsesDecreasingSourcePTSAndIncreasingOutputPTS() async throws {
        let dir = try directory(), input = try await fixture(in: dir)
        let output = dir.appendingPathComponent("reverse.mp4")
        let report = try await VideoRetimer.export(source: input, destination: output,
            document: document(speed: -1, duration: 2, origin: 11.0/6),
            options: VideoExportOptions(width: 64, height: 64, frameRate: FrameRate(6)))
        XCTAssertEqual(report.outputFrameCount, 12)
        let levels = try outputLevels(output, count: 12)
        for i in levels.indices { XCTAssertEqual(levels[i], Double(15 + (11-i) * 18), accuracy: 10) }
    }

    func testFreezeRepeatsOneSourceFrame() async throws {
        let dir = try directory(), input = try await fixture(in: dir)
        let output = dir.appendingPathComponent("freeze.mp4")
        let report = try await VideoRetimer.export(source: input, destination: output,
            document: document(speed: 0, duration: 1, origin: 4.0/6),
            options: VideoExportOptions(width: 64, height: 64, frameRate: FrameRate(6)))
        XCTAssertEqual(report.outputFrameCount, 6)
        for level in try outputLevels(output, count: 6) { XCTAssertEqual(level, 87, accuracy: 10) }
    }

    func testOutOfRangeFailsWithoutLeavingPartialOutput() async throws {
        let dir = try directory(), input = try await fixture(in: dir)
        let output = dir.appendingPathComponent("outside.mp4")
        do {
            _ = try await VideoRetimer.export(source: input, destination: output,
                document: document(speed: 2, duration: 2),
                options: VideoExportOptions(width: 64, height: 64, frameRate: FrameRate(6), boundaryPolicy: .reject))
            XCTFail("Out-of-range source mapping must fail")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
    }

    func testExistingOutputIsNeverOverwritten() async throws {
        let dir = try directory(), input = try await fixture(in: dir)
        let output = dir.appendingPathComponent("existing.mp4")
        let sentinel = Data("do not overwrite".utf8)
        try sentinel.write(to: output)
        do {
            _ = try await VideoRetimer.export(source: input, destination: output,
                document: document(speed: 1, duration: 1),
                options: VideoExportOptions(width: 64, height: 64, frameRate: FrameRate(6)))
            XCTFail("Existing output must be protected")
        } catch { XCTAssertEqual(try Data(contentsOf: output), sentinel) }
    }

    func testInvalidEncoderSettingsAreRejected() throws {
        XCTAssertThrowsError(try VideoExportOptions(width: 63, height: 64, frameRate: FrameRate(30)))
        XCTAssertThrowsError(try VideoExportOptions(width: 64, height: 0, frameRate: FrameRate(30)))
        XCTAssertThrowsError(try VideoExportOptions(width: 8192, height: 8192, frameRate: FrameRate(30)))
        XCTAssertThrowsError(try VideoExportOptions(width: 64, height: 64, frameRate: FrameRate(30), bitRate: 0))
    }
}
#else
final class VideoExportTests: XCTestCase {
    func testMediaModuleIsLinked() {
        XCTFail("ApleTimingMedia is not yet implemented and linked into the test target.")
    }
}
#endif
