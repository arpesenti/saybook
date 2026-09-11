import AVFoundation
import Foundation
import XCTest

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

        // The output decodes as 22.05 kHz mono AAC with a plausible duration
        // for the fixture's short chapter text.
        let file = try AVAudioFile(forReading: expected)
        XCTAssertEqual(file.processingFormat.sampleRate, 22050)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let duration = Double(file.length) / 22050
        XCTAssertGreaterThan(duration, 4, "duration: \(duration)")
        XCTAssertLessThan(duration, 60, "duration: \(duration)")
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
}
