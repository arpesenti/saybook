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
        let markers = ChapterMarkers.parseChpl(from: data, trackTimescale: Synthesis.trackTimescale)
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
        let markers = ChapterMarkers.parseChpl(from: try Data(contentsOf: expected), trackTimescale: Synthesis.trackTimescale)
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

    // MARK: - Ticket 03: metadata, cover, navigation

    /// The 1×1 PNG the `nav-cover.epub` fixture declares as its cover.
    private static let coverPNG: Data = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!

    func testNavCoverBookCarriesMetadataCoverAndNavTitles() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("nav-cover.epub"), to: input
        )
        let expected = dir.appendingPathComponent("book.m4b")

        let result = try run([input.path])

        XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        // Only the two readable chapters are spoken: the TOC page,
        // titlepage and navigation document are never synthesised.
        let lines = result.stderr.split(separator: "\n").map(String.init)
        let progress = lines.filter { $0.hasPrefix("✓") }
        XCTAssertEqual(progress.count, 2, "stderr: \(result.stderr)")

        let data = try Data(contentsOf: expected)

        // ilst: title = Book title, artist = author, album = Book title.
        let identity = Metadata.parseIlst(from: data)
        XCTAssertEqual(identity?.title, "Nav and Cover Book", "stderr: \(result.stderr)")
        XCTAssertEqual(identity?.artist, "Nav Author")
        XCTAssertEqual(identity?.album, "Nav and Cover Book")

        // covr: the OPF-declared cover image, extractable from the file.
        XCTAssertEqual(Metadata.parseCovr(from: data), Self.coverPNG)

        // Chapter Marker titles come from the EPUB3 navigation entries, not
        // the document headings.
        let markers = ChapterMarkers.parseChpl(from: data, trackTimescale: Synthesis.trackTimescale)
        XCTAssertEqual(markers?.count, 2)
        XCTAssertEqual(markers?.map(\.title), ["First Voyage", "Second Voyage"])
    }

    /// A deliberately broken cover reference (declared, file absent): the
    /// run keeps going — the Audiobook is still written with its metadata,
    /// minus the cover — and a warning is emitted.
    func testBrokenCoverDegradesGracefully() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("missing-cover.epub"), to: input
        )
        let expected = dir.appendingPathComponent("book.m4b")

        let result = try run([input.path])

        XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        let warning = result.stderr.lowercased()
        XCTAssertTrue(warning.contains("warning"), "stderr: \(result.stderr)")
        XCTAssertTrue(warning.contains("cover"), "stderr: \(result.stderr)")

        // The file is still written, with its identity but no cover box.
        let data = try Data(contentsOf: expected)
        XCTAssertEqual(Metadata.parseIlst(from: data)?.title, "Broken Cover Book")
        XCTAssertEqual(Metadata.parseIlst(from: data)?.artist, "Cover Author")
        XCTAssertNil(Metadata.parseCovr(from: data))
    }

    /// A Book with no author: the `©ART` box degrades to "Unknown" rather
    /// than being empty; no cover is declared, so no `covr` box is written.
    func testMissingAuthorWritesUnknownArtist() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("no-author.epub"), to: input
        )
        let expected = dir.appendingPathComponent("book.m4b")

        let result = try run([input.path])

        XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        let data = try Data(contentsOf: expected)
        XCTAssertEqual(Metadata.parseIlst(from: data)?.title, "No Author Book")
        XCTAssertEqual(Metadata.parseIlst(from: data)?.artist, "Unknown")
        XCTAssertEqual(Metadata.parseIlst(from: data)?.album, "No Author Book")
        XCTAssertNil(Metadata.parseCovr(from: data))
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
        let markers = ChapterMarkers.parseChpl(from: try Data(contentsOf: expected), trackTimescale: Synthesis.trackTimescale)
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

    // MARK: - Ticket 04: voice & language selection

    /// The progress header's fields:
    /// `Voice: <name> (<quality>, <language>) · Rate: <rate>`.
    private func voiceLineFields(from stderr: String) -> (name: String, language: String, rate: String)? {
        guard let line = stderr.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix("Voice:") }) else {
            return nil
        }
        let rest = String(line.dropFirst("Voice: ".count))
        guard let sep = rest.firstRange(of: " · Rate: ") else { return nil }
        let head = String(rest[..<sep.lowerBound])
        let rate = String(rest[sep.upperBound...])
        guard let open = head.lastIndex(of: "(") else { return nil }
        let name = head[..<open].trimmingCharacters(in: .whitespaces)
        var inner = String(head[head.index(after: open)...])
        if inner.hasSuffix(")") { inner.removeLast() }
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        return (name, parts[1], rate)
    }

    private func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / Synthesis.sampleRate
    }

    /// No flags: the best installed voice for the Book's OPF language ("en"
    /// for the fixture) is used and named in the progress output, with the
    /// default rate.
    func testDefaultRunReportsSelectedVoiceAndRate() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
        )

        let result = try run([input.path])

        XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        let fields = try XCTUnwrap(voiceLineFields(from: result.stderr), "stderr: \(result.stderr)")
        XCTAssertFalse(fields.name.isEmpty)
        XCTAssertTrue(fields.language.lowercased().hasPrefix("en"), "Book language is en: \(fields)")
        XCTAssertEqual(fields.rate, "0.5")
        // The reported voice is an installed voice (cross-checked against
        // the catalog; the selection itself is unit-tested).
        let installed = VoiceCatalog.installed()
        XCTAssertTrue(installed.contains { $0.name == fields.name }, "reported voice \(fields.name) not installed")
    }

    /// `--voice` accepts a display name and an identifier as listed by
    /// `say -v ?`; the chosen voice is the one used and reported.
    func testExplicitVoiceByDisplayNameAndIdentifier() throws {
        // An en-US voice with a unique display name: `--voice <name>` must
        // then unambiguously resolve to this entry.
        let installed = VoiceCatalog.installed()
        var nameCounts: [String: Int] = [:]
        for voice in installed { nameCounts[voice.name, default: 0] += 1 }
        let candidate = try XCTUnwrap(
            installed.first { $0.language == "en-US" && nameCounts[$0.name] == 1 },
            "no uniquely-named en-US voice installed"
        )

        for reference in [candidate.name, candidate.identifier] {
            let dir = try makeTempDir()
            let input = dir.appendingPathComponent("book.epub")
            try FileManager.default.copyItem(
                at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
            )

            let result = try run([input.path, "--voice", reference])

            XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
            let fields = try XCTUnwrap(voiceLineFields(from: result.stderr), "stderr: \(result.stderr)")
            XCTAssertEqual(fields.name, candidate.name)
            XCTAssertEqual(fields.language, candidate.language)
        }
    }

    /// An unknown voice name fails with exit 1 and names the voice.
    func testUnknownVoiceFailsWithUserError() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
        )

        let result = try run([input.path, "--voice", "NotARealVoice"])

        XCTAssertEqual(result.exit, 1)
        XCTAssertTrue(result.stderr.contains("NotARealVoice"), "stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.lowercased().contains("voice"), "stderr: \(result.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("book.m4b").path))
    }

    /// `--rate` outside 0.0–1.0 (or not a number) fails with exit 1 and
    /// names the offending value.
    func testInvalidRateFailsWithUserError() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
        )
        for value in ["1.5", "-0.1", "abc"] {
            let result = try run([input.path, "--rate", value])
            XCTAssertEqual(result.exit, 1, "stderr: \(result.stderr)")
            XCTAssertTrue(result.stderr.lowercased().contains("rate"), "stderr: \(result.stderr)")
            XCTAssertTrue(result.stderr.contains(value), "offending value not named: \(result.stderr)")
        }
    }

    /// `--language` with no installed Voice fails with exit 1 and names the
    /// language.
    func testLanguageWithoutInstalledVoiceFailsNamingTheLanguage() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
        )

        let result = try run([input.path, "--language", "xx-XX"])

        XCTAssertEqual(result.exit, 1, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("xx-XX"), "stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.lowercased().contains("voice"), "stderr: \(result.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("book.m4b").path))
    }

    /// `--language` overrides the Book's language for voice selection.
    func testLanguageOverrideSelectsVoiceForThatLanguage() throws {
        guard VoiceCatalog.installed().contains(where: { $0.language.lowercased().hasPrefix("fr") })
        else { throw XCTSkip("no French voice installed") }
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
        )

        let result = try run([input.path, "--language", "fr"])

        XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        let fields = try XCTUnwrap(voiceLineFields(from: result.stderr), "stderr: \(result.stderr)")
        XCTAssertTrue(fields.language.lowercased().hasPrefix("fr"), "stderr: \(result.stderr)")
    }

    /// The Rate reaches the utterance: a faster rate yields clearly shorter
    /// audio than a slower one on the same fixture.
    func testRateChangesDuration() throws {
        let dir = try makeTempDir()
        for (name, rate) in [("rate-fast.epub", "0.8"), ("rate-slow.epub", "0.3")] {
            let input = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(
                at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
            )
            let result = try run([input.path, "--rate", rate])
            XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        }

        let fast = try duration(of: dir.appendingPathComponent("rate-fast.m4b"))
        let slow = try duration(of: dir.appendingPathComponent("rate-slow.m4b"))
        XCTAssertGreaterThan(slow, fast, "rate 0.3 (\(slow) s) must be slower than rate 0.8 (\(fast) s)")
        XCTAssertGreaterThan(slow - fast, 1.0, "rates passed through unchanged must differ audibly")
    }

    /// A different voice renders different audio: the flag reaches the
    /// engine, not just the progress line. (Objective stand-in for the
    /// ticket's audible-difference manual check.)
    func testExplicitVoiceChangesTheAudio() throws {
        guard let distinct = VoiceCatalog.installed().first(where: { $0.name == "Zarvox" })
        else { throw XCTSkip("Zarvox not installed") }
        let dir = try makeTempDir()
        for (name, extra) in [("voice-a.epub", [String]()), ("voice-b.epub", ["--voice", distinct.name])] {
            let input = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(
                at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
            )
            let result = try run([input.path] + extra)
            XCTAssertEqual(result.exit, 0, "stderr: \(result.stderr)")
        }

        let rawA = dir.appendingPathComponent("a.f32")
        let rawB = dir.appendingPathComponent("b.f32")
        try decodeToFloatPCM(dir.appendingPathComponent("voice-a.m4b"), at: rawA)
        try decodeToFloatPCM(dir.appendingPathComponent("voice-b.m4b"), at: rawB)
        let a = try Data(contentsOf: rawA)
        let b = try Data(contentsOf: rawB)
        XCTAssertGreaterThan(a.count, 22_050 * 3)
        XCTAssertGreaterThan(b.count, 22_050 * 3)
        let n = min(a.count, b.count) / 4
        var maxDiff: Float = 0
        for i in 0..<n {
            let sa = a.withUnsafeBytes { $0.load(fromByteOffset: i * 4, as: Float.self) }
            let sb = b.withUnsafeBytes { $0.load(fromByteOffset: i * 4, as: Float.self) }
            maxDiff = max(maxDiff, abs(sa - sb))
        }
        XCTAssertGreaterThan(maxDiff, 0.1, "different voices must render different audio")
    }

    /// An option outside v1's flag set fails with exit 1 and the usage.
    func testUnknownOptionShowsUsage() throws {
        let dir = try makeTempDir()
        let input = dir.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(
            at: fixturesDir.appendingPathComponent("single-chapter.epub"), to: input
        )

        let result = try run([input.path, "--force"])

        XCTAssertEqual(result.exit, 1)
        XCTAssertTrue(result.stderr.contains("--force"), "stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("Usage"), "stderr: \(result.stderr)")
    }
}

