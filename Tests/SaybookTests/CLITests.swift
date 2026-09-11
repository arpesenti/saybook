import AVFoundation
import Foundation
import XCTest
@testable import SaybookCore

/// End-to-end tests of the `saybook` executable: run the real binary against
/// the in-repo fixture and assert CLI behaviour (exit codes, output location,
/// M4B brand, stderr progress).
final class CLITests: XCTestCase {

    private var binary: URL {
        packageRoot.appendingPathComponent(".build/debug/saybook")
    }

    private func run(_ args: [String]) throws -> (exit: Int32, stdout: String, stderr: String) {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("saybook binary not built (run `swift build` first)")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    func testSingleChapterBookProducesPlayableM4B() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
        )
        let expected = dir.appendingPathComponent("book.m4b")

        let result = try run([input.path])

        XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path), "output written beside the input")

        // One progress line per completed Chapter on stderr.
        let lines = result.stderr.split(separator: "\n").map(String.init)
        let progress = lines.filter { $0.hasPrefix("✓") }
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.split(separator: "·").count, 3)
        XCTAssertTrue(progress.first?.contains("1/1") ?? false)

        // The output is branded M4B (major `M4B `, compat `m4b mp42 isom`).
        let data = try Data(contentsOf: expected)
        XCTAssertEqual(String(data: data[8..<12], encoding: .isoLatin1), "M4B ")
        XCTAssertEqual(String(data: data[12..<24], encoding: .isoLatin1), "m4b mp42isom")

        // The output decodes as 22.05 kHz mono AAC. Duration is within ±10% of
        // the expected for the fixture's 21 words at the default voice (rate
        // 0.5): baseline measured at 7.0 s on macOS 26 (ticket 01 comment).
        let file = try AVAudioFile(forReading: expected)
        XCTAssertEqual(file.processingFormat.sampleRate, 22050)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let duration = Double(file.length) / 22050
        XCTAssertEqual(duration, 7.0, accuracy: 0.7, "duration: \(duration)")
    }

    func testExistingOutputIsRefused() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
        )
        let existing = dir.appendingPathComponent("book.m4b")
        let sentinel = Data("existing".utf8)
        try sentinel.write(to: existing)

        let result = try run([input.path])

        XCTAssertEqual(result.exit, 1)
        XCTAssertTrue(result.stderr.lowercased().contains("already exists"), "stderr: \(result.stderr)")
        XCTAssertEqual(try Data(contentsOf: existing), sentinel, "refusal must not clobber the existing file")
    }

    func testMissingArgumentShowsUsage() throws {
        let result = try run([])
        XCTAssertEqual(result.exit, 1)
        XCTAssertTrue(result.stderr.contains("Usage"), "stderr: \(result.stderr)")
    }

    func testInvalidEpubFailsWithUserError() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try "definitely not an epub".data(using: .utf8)!.write(to: input)

        let result = try run([input.path])

        XCTAssertEqual(result.exit, 1, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.lowercased().contains("epub"), "stderr: \(result.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("book.m4b").path))
    }

    func testMissingInputFileFailsWithUserError() throws {
        let dir = try makeTempDir()
        let result = try run([dir.appendingPathComponent("nope.epub").path])
        XCTAssertEqual(result.exit, 1, "stderr: \(result.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("nope.m4b").path))
    }

    // MARK: - Ticket 02: Chapter Markers, resume, summary

    func testMultiChapterBookProducesM4BWithChapterMarkersAndSummary() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("multi-chapter.epub"), to: input
        )
        let expected = dir.appendingPathComponent("book.m4b")

        let result = try run([input.path])

        XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        let data = try Data(contentsOf: expected)

        // One progress line per Chapter: 3 synthesised (✓) and 1 empty
        // (–, reported skipped with its (no text) annotation). The final
        // summary line reports chapter count, skipped count, duration,
        // size, and path.
        let lines = result.stderr.split(separator: "\n").map(String.init)
        let progress = lines.filter { $0.hasPrefix("✓") }
        XCTAssertEqual(progress.count, 3, "stderr: \(result.stderr)")
        let empty = lines.filter { $0.hasPrefix("–") }
        XCTAssertEqual(empty.count, 1, "stderr: \(result.stderr)")
        XCTAssertTrue(empty[0].contains("(no text)"), "stderr: \(result.stderr)")
        let summary = lines.filter { $0.hasPrefix("Chapters:") }
        XCTAssertEqual(summary.count, 1, "stderr: \(result.stderr)")
        let s = summary[0]
        XCTAssertTrue(s.contains("Chapters: 4"), s)
        XCTAssertTrue(s.contains("Skipped: 1 (no text)"), s)
        XCTAssertTrue(s.contains(expected.path), s)

        // Exactly 3 Chapter Markers (the empty chapter carries none), each
        // carrying the Chapter's title (heading fallback: h1, h2, filename).
        let markers = ChapterMarkers.parseChpl(from: data, trackTimescale: Int(Synthesis.sampleRate))
        XCTAssertEqual(markers?.count, 3, "stderr: \(result.stderr)")
        XCTAssertEqual(markers?.map(\.title), ["Chapter One", "Chapter Two", "ch3"])

        // Offsets: chapter 1 at 0, strictly increasing, in track timescale.
        let offsets = markers?.map(\.sampleOffset) ?? []
        XCTAssertEqual(offsets.first, 0)
        for (a, b) in Swift.zip(offsets, offsets.dropFirst()) where b <= a {
            XCTFail("offsets must be strictly increasing: \(offsets)")
        }

        // Total duration ≈ 13 + 184 + 248 words at the default voice
        // (measured ≈ 139 s on macOS 26; the repeated sentences in ch2/ch3
        // read slightly faster than the 0.33 s/word single-chapter baseline).
        let file = try AVAudioFile(forReading: expected)
        let duration = Double(file.length) / Synthesis.sampleRate
        XCTAssertEqual(duration, 139, accuracy: 14, "duration: \(duration)")
    }

    func testResumeSkipsExistingChapters() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("multi-chapter.epub"), to: input
        )
        let expected = dir.appendingPathComponent("book.m4b")

        // Seed Scratch with finished Chapter CAFs of known PCM lengths:
        // 22 050 (1 s tone), 11 025 (0.5 s silence), 33 075 (1.5 s tone).
        let scratch = try Scratch.directory(for: input)
        let frames = [22_050, 11_025, 33_075]
        let cafs = (1...3).map { Scratch.chapterCAFURL(in: scratch, index: $0) }
        for (i, caf) in cafs.enumerated() {
            try FileManager.default.createDirectory(at: caf.deletingLastPathComponent(), withIntermediateDirectories: true)
            let amp: Float = i == 1 ? 0 : 0.5
            try writeCAF(frames: frames[i], at: caf) { _ in amp }
        }
        let result = try run([input.path])

        XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        // The three progress lines are cached-skip lines (no re-synthesis —
        // a re-synthesised book would be ≈ 60 s of speech, not 3 s) and the
        // summary reports the empty chapter as skipped (no text).
        let lines = result.stderr.split(separator: "\n").map(String.init)
        let cached = lines.filter { $0.hasPrefix("⏭") }
        XCTAssertEqual(cached.count, 3, "stderr: \(result.stderr)")
        XCTAssertTrue(cached.allSatisfy { $0.contains("(cached)") })
        let summary = lines.first { $0.hasPrefix("Chapters:") } ?? ""
        XCTAssertTrue(summary.contains("Chapters: 4"), summary)
        XCTAssertTrue(summary.contains("Skipped: 1 (no text)"), summary)

        // The Chapter Marker offsets match the known PCM lengths exactly:
        // chapter k starts where the preceding CAFs end.
        let markers = ChapterMarkers.parseChpl(from: try Data(contentsOf: expected), trackTimescale: Int(Synthesis.sampleRate))
        XCTAssertEqual(markers?.map(\.sampleOffset), [0, 22_050, 33_075], "stderr: \(result.stderr)")
        XCTAssertEqual(markers?.map(\.title), ["Chapter One", "Chapter Two", "ch3"])

        // The output is the concatenation of the cached CAFs: ≈ 3 s, and it
        // carries their content (tone · silence · tone), not speech.
        let file = try AVAudioFile(forReading: expected)
        let duration = Double(file.length) / Synthesis.sampleRate
        XCTAssertEqual(duration, 3.0, accuracy: 0.3, "duration: \(duration)")
        let raw = dir.appendingPathComponent("raw.f32")
        try decodeToFloatPCM(expected, at: raw)
        let pcm = try Data(contentsOf: raw)
        XCTAssertGreaterThan(rms(of: pcm, from: 0, count: 22_050), 0.1, "chapter 1 tone")
        XCTAssertLessThan(rms(of: pcm, from: 22_050, count: 11_025), 0.01, "chapter 2 silence")
        XCTAssertGreaterThan(rms(of: pcm, from: 33_075, count: 33_075), 0.1, "chapter 3 tone")
    }

    func testKilledRunResumesAndCompletes() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("multi-chapter.epub"), to: input
        )
        let expected = dir.appendingPathComponent("book.m4b")
        let scratch = try Scratch.directory(for: input)
        func cafURL(_ n: Int) -> URL { Scratch.chapterCAFURL(in: scratch, index: n) }

        // Run, then kill mid-way: chapter 1 (13 words ≈ 4 s of audio) is
        // done well before the kill; chapter 3 (248 words ≈ 83 s of audio)
        // keeps the kill window open. Whatever the kill lands on, the
        // completed chapters' CAFs must survive and be skipped on the re-run.
        let process = Process()
        process.executableURL = binary
        process.arguments = [input.path]
        try process.run()
        Thread.sleep(forTimeInterval: 1.1)
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal, "first run should be killed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path), "killed run must not write output")

        // The surviving chapter CAFs form a prefix (chapters render in
        // Spine order; the empty chapter 4 never gets a CAF); at least
        // chapter 1 completed before the kill.
        let surviving = (1...3).filter { FileManager.default.fileExists(atPath: cafURL($0).path) }
        XCTAssertEqual(surviving, Array(1...surviving.count), "surviving CAFs must be a prefix: \(scratch.path)")
        XCTAssertFalse(surviving.isEmpty, "no chapter CAF survived the kill: \(scratch.path)")
        if surviving.count < 3 {
            // The chapter that was mid-render must not have published a
            // partial CAF at its final name (atomic publish).
            let next = cafURL(surviving.count + 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: next.path), "mid-render chapter published a partial CAF")
        }
        let frames = try surviving.map { try cafFrameCount(at: cafURL($0)) }

        // Re-run: resumes from Scratch and completes.
        let result = try run([input.path])

        XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        // Every surviving chapter was skipped, not re-synthesised.
        for n in surviving {
            XCTAssertTrue(result.stderr.contains("⏭ \(n)/4"), "chapter \(n) not reported cached: \(result.stderr)")
        }
        // Scratch is deleted on success.
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "scratch kept after success")

        // The final Audiobook is complete and correct: 3 markers with the
        // Chapter titles, and each cached chapter's offset is exactly the
        // end of the preceding chapters' known PCM.
        let markers = ChapterMarkers.parseChpl(from: try Data(contentsOf: expected), trackTimescale: Int(Synthesis.sampleRate))
        XCTAssertEqual(markers?.count, 3, "stderr: \(result.stderr)")
        XCTAssertEqual(markers?.map(\.title), ["Chapter One", "Chapter Two", "ch3"])
        var cumulative = 0
        for (n, frameCount) in Swift.zip(surviving, frames) {
            XCTAssertEqual(markers?[n - 1].sampleOffset, cumulative, "cached chapter \(n) offset")
            cumulative += frameCount
        }
        let file = try AVAudioFile(forReading: expected)
        let duration = Double(file.length) / Synthesis.sampleRate
        XCTAssertEqual(duration, 139, accuracy: 14, "duration: \(duration)")
    }
}
