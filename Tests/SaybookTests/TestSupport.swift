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

/// A maximal run of near-silent 10 ms windows inside decoded audio: a
/// candidate inter-Block pause (see `interiorSilentRuns`).
struct SilentRun {
    /// The run's first sample.
    let start: Int
    /// The first sample after the run.
    let end: Int
    let duration: TimeInterval

    init(start: Int, end: Int, sampleRate: Int) {
        self.start = start
        self.end = end
        self.duration = Double(end - start) / Double(sampleRate)
    }
}

/// The maximal runs of `pcm` (Float32 little-endian mono at `sampleRate`) that
/// read as inter-Block pauses: at least `minimum` and at most `maximum` seconds
/// of near-silence, **bounded by speech on both sides**.
///
/// Both halves of that guard matter. A Chapter's Block CAFs each end in the
/// engine's own edge silence (measured 0.21–0.22 s per side on macOS 27), which
/// is long enough to clear a 0.2 s floor on its own, and the last Block's edge
/// silence runs to the end of the file — so "a long silence somewhere inside the
/// audio" is not by itself a pause between Blocks:
///
/// - every window of the file is tested, the ragged final one included, so a
///   silent run that reaches the end of the file *ends* at the end of the file
///   and is recognised as an edge rather than counted as an interior pause;
/// - a window at the noise floor (a codec's tail material, a dither bed) is
///   above the silence floor without being speech, so the run must have a
///   genuinely speech-loud window within 0.5 s on each side.
func interiorSilentRuns(in pcm: Data, sampleRate: Int, minimum: TimeInterval, maximum: TimeInterval) -> [SilentRun] {
    let window = max(1, sampleRate / 100)   // 10 ms
    let silenceFloor: Float = 0.01
    let speechFloor: Float = 0.05
    let speechReach = max(1, Int(0.5 * Double(sampleRate)) / window)
    let totalFrames = pcm.count / 4
    let windowCount = (totalFrames + window - 1) / window

    // One pass over the windows: a window is silent below `silenceFloor`, and
    // is loud (speech) at or above `speechFloor`. `rms` clamps to the file, so
    // the final partial window is measured over the frames that exist.
    var silent = [Bool](repeating: false, count: windowCount)
    var loud = [Bool](repeating: false, count: windowCount)
    for index in 0..<windowCount {
        let level = rms(of: pcm, from: index * window, count: window)
        silent[index] = level < silenceFloor
        loud[index] = level >= speechFloor
    }

    var runs: [SilentRun] = []
    var index = 0
    while index < windowCount {
        guard silent[index] else {
            index += 1
            continue
        }
        var last = index
        while last + 1 < windowCount, silent[last + 1] { last += 1 }
        let start = index * window
        let end = min((last + 1) * window, totalFrames)
        let run = SilentRun(start: start, end: end, sampleRate: sampleRate)
        let speechBefore = (max(0, index - speechReach)..<index).contains(where: { loud[$0] })
        let speechAfter = ((last + 1)..<min(windowCount, last + 1 + speechReach)).contains(where: { loud[$0] })
        if start > 0, end < totalFrames, run.duration >= minimum, run.duration <= maximum,
           speechBefore, speechAfter {
            runs.append(run)
        }
        index = last + 1
    }
    return runs
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
