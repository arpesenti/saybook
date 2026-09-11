import AVFoundation
import Foundation
import XCTest
@testable import SaybookCore

final class AssembleTests: XCTestCase {

    /// Writes a mono 22.05 kHz Float32 CAF containing `frames` frames.
    private func writeCAF(frames: Int, at url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: Synthesis.cafSettings)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for i in 0..<frames { channel[i] = Float(i % 128) / 128 }
        try file.write(from: buffer)
    }

    private func open(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url)
    }

    func testConcatenateSumsFramesAndPreservesFormat() throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("a.caf")
        let b = dir.appendingPathComponent("b.caf")
        let out = dir.appendingPathComponent("out.caf")
        try writeCAF(frames: 22050, at: a) // 1.0 s
        try writeCAF(frames: 11025, at: b) // 0.5 s

        try Assemble.concatenate([a, b], to: out)

        let file = try open(out)
        XCTAssertEqual(file.length, 33075)
        XCTAssertEqual(file.processingFormat.sampleRate, 22050)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.processingFormat.commonFormat, .pcmFormatFloat32)
    }

    func testConcatenateCopiesAudioContentInOrder() throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("a.caf")
        let b = dir.appendingPathComponent("b.caf")
        let out = dir.appendingPathComponent("out.caf")
        try writeCAF(frames: 4, at: a)
        try writeCAF(frames: 3, at: b)

        try Assemble.concatenate([a, b], to: out)

        let file = try open(out)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 7)
        // writeCAF fills with Float(i % 128) / 128, so the seam is at value 0.
        let expected: [Float] = [0, 1 / 128, 2 / 128, 3 / 128, 0, 1 / 128, 2 / 128]
        let actual = (0..<7).map { buffer.floatChannelData![0][$0] }
        XCTAssertEqual(actual, expected)
    }

    func testConcatenateSingleInputIsACopy() throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("a.caf")
        let out = dir.appendingPathComponent("out.caf")
        try writeCAF(frames: 11025, at: a)

        try Assemble.concatenate([a], to: out)

        let file = try open(out)
        XCTAssertEqual(file.length, 11025)
    }

    func testConcatenateEmptyListThrows() {
        let dir = try! makeTempDir()
        XCTAssertThrowsError(try Assemble.concatenate([], to: dir.appendingPathComponent("out.caf")))
    }

    // MARK: - Ticket 05: the inter-Block pause

    /// The pause is ~0.3 s (the ticket's 0.2–0.5 s audible window) at the
    /// engine's sample rate.
    func testBlockPauseIsAboutThreeTenthsOfASecond() {
        let seconds = Double(Synthesis.blockPauseFrames) / Synthesis.sampleRate
        XCTAssertEqual(seconds, 0.3, accuracy: 0.01, "seconds: \(seconds)")
        XCTAssertGreaterThanOrEqual(seconds, 0.2)
        XCTAssertLessThanOrEqual(seconds, 0.5)
    }

    func testWriteSilenceCAFHasExactFrameCountAndZeroSamples() throws {
        let dir = try makeTempDir()
        let out = dir.appendingPathComponent("silence.caf")

        try Assemble.writeSilenceCAFFrames(Synthesis.blockPauseFrames, to: out)

        let file = try open(out)
        XCTAssertEqual(Int(file.length), Synthesis.blockPauseFrames)
        XCTAssertEqual(file.processingFormat.sampleRate, 22050)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.processingFormat.commonFormat, .pcmFormatFloat32)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        for i in 0..<Int(buffer.frameLength) {
            XCTAssertEqual(buffer.floatChannelData![0][i], 0, "sample \(i) is not zero")
        }
    }

    /// A re-run re-renders the pause: an existing file at the target is
    /// overwritten, not kept.
    func testWriteSilenceCAFOverwritesAnExistingFile() throws {
        let dir = try makeTempDir()
        let out = dir.appendingPathComponent("silence.caf")
        try writeCAF(frames: 22_050, at: out) // a stale, longer file

        try Assemble.writeSilenceCAFFrames(1000, to: out)

        XCTAssertEqual(try open(out).length, 1000)
    }
}
