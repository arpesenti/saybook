import Foundation
import XCTest
@testable import SaybookCore

/// Ticket 04: Scratch options marker — cached Chapter CAFs are only resume
/// state when the run's Voice and Rate match the marker the previous run
/// wrote; a different voice or rate clears them.
final class ScratchTests: XCTestCase {

    private func marker(voice: Voice? = nil, rate: Double = 0.5) -> String {
        let voice = voice ?? Voice(
            identifier: "com.apple.test.Plain", name: "Plain", language: "en-US", quality: .enhanced
        )
        return Scratch.optionsMarker(voice: voice, rate: rate)
    }

    private func seedChapterCAF(in scratch: URL) throws {
        let caf = Scratch.chapterCAFURL(in: scratch, index: 1)
        try FileManager.default.createDirectory(at: caf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeCAF(frames: 22_050, at: caf) { _ in 0.5 }
    }

    func testFreshScratchGetsMarker() throws {
        let scratch = try makeTempDir()
        let cleared = try Scratch.ensureOptions(marker(), in: scratch)
        XCTAssertFalse(cleared, "nothing to clear on a fresh Scratch")
        XCTAssertEqual(try String(contentsOf: Scratch.optionsURL(in: scratch), encoding: .utf8), marker())
    }

    func testMatchingMarkerKeepsCachedChapters() throws {
        let scratch = try makeTempDir()
        try Scratch.ensureOptions(marker(), in: scratch)
        try seedChapterCAF(in: scratch)

        let cleared = try Scratch.ensureOptions(marker(), in: scratch)

        XCTAssertFalse(cleared, "same options: cached Chapter CAFs are resume state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Scratch.chapterCAFURL(in: scratch, index: 1).path))
    }

    func testChangedRateClearsCachedChapters() throws {
        let scratch = try makeTempDir()
        try Scratch.ensureOptions(marker(rate: 0.5), in: scratch)
        try seedChapterCAF(in: scratch)

        let cleared = try Scratch.ensureOptions(marker(rate: 0.9), in: scratch)

        XCTAssertTrue(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Scratch.chapterCAFURL(in: scratch, index: 1).path))
        XCTAssertEqual(try String(contentsOf: Scratch.optionsURL(in: scratch), encoding: .utf8), marker(rate: 0.9))
    }

    func testChangedVoiceClearsCachedChapters() throws {
        let scratch = try makeTempDir()
        let other = Voice(
            identifier: "com.apple.test.Other", name: "Other", language: "en-US", quality: .premium
        )
        try Scratch.ensureOptions(marker(voice: other, rate: 0.5), in: scratch)
        try seedChapterCAF(in: scratch)

        let cleared = try Scratch.ensureOptions(marker(rate: 0.5), in: scratch)

        XCTAssertTrue(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Scratch.chapterCAFURL(in: scratch, index: 1).path))
    }

    func testMarkerLessScratchIsUnknownOriginAndCleared() throws {
        // A Scratch without a marker was not written by a run that tracks
        // options: accepting its CAFs could replay audio for a different
        // Voice/Rate, so it is cleared.
        let scratch = try makeTempDir()
        try seedChapterCAF(in: scratch)

        let cleared = try Scratch.ensureOptions(marker(), in: scratch)

        XCTAssertTrue(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Scratch.chapterCAFURL(in: scratch, index: 1).path))
    }

    func testUnpackedEpubWithoutMarkerIsNotCachedContent() throws {
        // A fresh run unpacks the EPUB into Scratch before the marker is
        // written: that unpacked content is not cached audio, so it neither
        // triggers a clear nor the "clearing cached chapters" report.
        let scratch = try makeTempDir()
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("OEBPS"), withIntermediateDirectories: true
        )

        let cleared = try Scratch.ensureOptions(marker(), in: scratch)

        XCTAssertFalse(cleared, "a fresh run must not report a clear")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("OEBPS").path))
        XCTAssertEqual(try String(contentsOf: Scratch.optionsURL(in: scratch), encoding: .utf8), marker())
    }

    // MARK: - Ticket 05: per-Block CAF naming

    func testBlockAndPauseCAFURLsLiveInTheChaptersDirectory() throws {
        let scratch = try makeTempDir()
        let block = Scratch.blockCAFURL(in: scratch, index: 3, block: 1)
        let pause = Scratch.pauseCAFURL(in: scratch, index: 3, block: 2)

        // Per-Block parts live beside the Chapter CAF (the same directory
        // `ensureOptions` clears), named so a chapter's parts sort together.
        XCTAssertEqual(
            block,
            scratch.appendingPathComponent("chapters/chapter-003-block-001.caf")
        )
        XCTAssertEqual(
            pause,
            scratch.appendingPathComponent("chapters/chapter-003-pause-002.caf")
        )
        // Part names never collide with the Chapter CAF's final name.
        XCTAssertNotEqual(block, Scratch.chapterCAFURL(in: scratch, index: 3))
        XCTAssertNotEqual(pause, Scratch.chapterCAFURL(in: scratch, index: 3))
    }
}
