import Foundation
import XCTest
@testable import SaybookCore

final class EpubTests: XCTestCase {

    func testLoadSingleChapterFixture() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("single-chapter.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "One Chapter Book")
        XCTAssertEqual(book.author, "Test Author")
        XCTAssertEqual(book.language, "en")
        XCTAssertEqual(book.chapters.count, 1)
        // Title falls back to the document's largest heading (ticket 02).
        XCTAssertEqual(book.chapters[0].title, "Chapter One")
        XCTAssertEqual(
            book.chapters[0].text,
            "Chapter One Chapter One The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs."
        )
    }

    func testLoadMultiChapterFixtureTitles() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("multi-chapter.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "Multi Chapter Book")
        XCTAssertEqual(book.chapters.count, 4)
        // Title fallback: largest heading → largest heading → filename →
        // filename (the empty chapter has no heading either).
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter One", "Chapter Two", "ch3", "ch4"])
        // ch4 is an empty document: no readable text.
        XCTAssertTrue(book.chapters[3].text.isEmpty)
        XCTAssertTrue(book.chapters.prefix(3).allSatisfy { !$0.text.isEmpty })
        // ch1 is deliberately short (resume/kill tests kill it mid-ch2/ch3);
        // ch2 and ch3 are long so the kill window is wide.
        XCTAssertGreaterThan(book.chapters[1].text.split(separator: " ").count, 150)
        XCTAssertGreaterThan(book.chapters[2].text.split(separator: " ").count, 100)
        XCTAssertLessThan(book.chapters[0].text.split(separator: " ").count, 30)
    }

    func testLoadRejectsFileThatIsNotAZip() throws {
        let dir = try makeTempDir()
        let fake = dir.appendingPathComponent("fake.epub")
        try "this is not an epub".data(using: .utf8)!.write(to: fake)

        XCTAssertThrowsError(try Epub.load(bookAt: fake, scratch: dir.appendingPathComponent("scratch"))) {
            XCTAssertEqual($0 as? Epub.EpubError, .notAValidEpub)
        }
    }

    func testLoadRejectsZipWithoutContainer() throws {
        let dir = try makeTempDir()
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "junk".data(using: .utf8)!.write(to: src.appendingPathComponent("junk.txt"))
        let archive = dir.appendingPathComponent("junk.epub")
        try zip(paths: [src.appendingPathComponent("junk.txt")], into: archive, cwd: src)

        XCTAssertThrowsError(try Epub.load(bookAt: archive, scratch: dir.appendingPathComponent("scratch"))) {
            XCTAssertEqual($0 as? Epub.EpubError, .notAValidEpub)
        }
    }

    // MARK: - Ticket 03: metadata, cover, navigation

    /// The 1×1 PNG the `nav-cover.epub` fixture declares as its cover
    /// (known-good literal — the fixture's bytes are pinned to this).
    private static let coverPNG: Data = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!

    /// EPUB3 with a navigation document, a TOC page and a titlepage (both
    /// `linear="no"`), a cover page (`properties="doc-cover"`, deliberately
    /// without `linear="no"` — the property rule alone must exclude it), a
    /// declared cover image, and two chapters whose headings deliberately
    /// differ from the nav titles.
    func testLoadNavCoverFixture() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("nav-cover.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "Nav and Cover Book")
        XCTAssertEqual(book.author, "Nav Author")
        // Exactly the two readable chapters: the cover page, TOC page,
        // titlepage and nav document are never spoken.
        XCTAssertEqual(book.chapters.count, 2)
        // Titles come from the navigation entries (not the document headings
        // "Heading One"/"Heading Two"); the nav anchor's #fragment is ignored.
        XCTAssertEqual(book.chapters.map(\.title), ["First Voyage", "Second Voyage"])
        // The spoken text is the chapters' own text only (v1 crude: heading
        // included; block-level extraction arrives in ticket 05) — and none
        // of the never-spoken documents' text leaks in.
        XCTAssertEqual(
            book.chapters.map(\.text),
            [
                "Heading One Heading One The short first chapter text.",
                "Heading Two Heading Two The short second chapter text.",
            ]
        )
        XCTAssertTrue(book.chapters.allSatisfy { !$0.text.contains("never be spoken") })
        // The OPF declares a cover image: its raw bytes are carried.
        XCTAssertEqual(book.cover, .data(Self.coverPNG))
    }

    /// The OPF declares a cover whose file is absent from the archive: a
    /// broken reference degrades to `.missing`, no crash.
    func testLoadMissingCoverFixture() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("missing-cover.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "Broken Cover Book")
        XCTAssertEqual(book.author, "Cover Author")
        XCTAssertEqual(book.cover, .missing(reference: "missing.png"))
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters.map(\.title), ["Only Chapter"])
    }

    /// A Book with no `dc:creator`: the author parses to empty (the
    /// "Unknown" placeholder is applied at the metadata box, not here).
    func testLoadNoAuthorFixture() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("no-author.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "No Author Book")
        XCTAssertEqual(book.author, "")
        XCTAssertEqual(book.cover, .absent)
        XCTAssertEqual(book.chapters.map(\.title), ["Lone Chapter"])
    }

    /// An EPUB2 Book (no navigation document): the largest-heading →
    /// filename fallback from ticket 02 still applies.
    func testLoadEpub2FixtureUsesHeadingFallback() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("epub2.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "EPUB Two Book")
        XCTAssertEqual(book.author, "Old Author")
        XCTAssertEqual(book.cover, .absent)
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter Alpha", "Chapter Beta"])
    }
}
