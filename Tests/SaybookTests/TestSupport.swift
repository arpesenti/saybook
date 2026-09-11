import AVFoundation
import Foundation
import XCTest
@testable import SaybookCore

/// Test helpers: locate the package root, manage temp directories, and write
/// PCM CAFs with known frame counts.
extension XCTestCase {

    /// Walks up from this source file to the directory containing Package.swift.
    var packageRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    var fixturesDir: URL {
        packageRoot.appendingPathComponent("Tests/SaybookTests/Fixtures")
    }

    @discardableResult
    func makeTempDir() throws -> URL {
        let url = URL.temporaryDirectory
            .appendingPathComponent("saybook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Runs `/usr/bin/zip -r <archive> <paths...>` inside `cwd`.
    func zip(paths: [URL], into archive: URL, cwd: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-X", "-r", "-q", archive.path] + paths.map(\.lastPathComponent)
        task.currentDirectoryURL = cwd
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "zip failed: \(archive.path)")
    }

    /// Runs `/usr/bin/zip -X -r <archive> .` inside `root`, preserving
    /// `root`'s directory structure (paths are relative to `root`).
    func zipTree(_ root: URL, into archive: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-X", "-r", "-q", archive.path, "."]
        task.currentDirectoryURL = root
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "zip failed: \(archive.path)")
    }

    /// Writes `content` to `root/...` creating intermediate directories.
    @discardableResult
    func writeTreeFile(_ content: String, at relativePath: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Writes a mono 22.05 kHz Float32 CAF (the Synthesis output format) with
/// `frames` frames, filling sample `i` with `sample(i)`.
func writeCAF(frames: Int, at url: URL, sample: (Int) -> Float) throws {
    let file = try AVAudioFile(forWriting: url, settings: Synthesis.cafSettings)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let channel = buffer.floatChannelData![0]
    for i in 0..<frames { channel[i] = sample(i) }
    try file.write(from: buffer)
}

/// The frame count of a CAF file.
func cafFrameCount(at url: URL) throws -> Int {
    let file = try AVAudioFile(forReading: url)
    return Int(file.length)
}

/// Decodes an M4B/M4A to raw Float32 little-endian mono PCM via ffmpeg.
func decodeToFloatPCM(_ input: URL, at output: URL) throws {
    guard let ffmpeg = which("ffmpeg") else { throw XCTSkip("ffmpeg not available") }
    let (exit, _, stderr) = try runTool(
        ffmpeg, ["-y", "-v", "error", "-i", input.path, "-f", "f32le", "-acodec", "pcm_f32le", output.path]
    )
    XCTAssertEqual(exit, 0, "ffmpeg decode failed: \(stderr)")
}

/// Root-mean-square amplitude of `count` samples starting at `sample`
/// in a Float32 little-endian PCM file.
func rms(of data: Data, from sample: Int, count: Int) -> Float {
    let n = min(count, max(data.count / 4 - sample, 0))
    guard n > 0 else { return 0 }
    var sum: Float = 0
    for i in sample..<(sample + n) {
        let v = data.withUnsafeBytes { buf in
            buf.load(fromByteOffset: i * 4, as: Float.self)
        }
        sum += v * v
    }
    return (sum / Float(n)).squareRoot()
}
