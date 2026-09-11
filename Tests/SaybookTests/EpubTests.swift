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
        // The head <title> is never spoken: the heading appears exactly
        // once, as its own Block (ticket 05).
        XCTAssertEqual(
            book.chapters[0].blocks.map(\.text),
            [
                "Chapter One",
                "The quick brown fox jumps over the lazy dog.",
                "Pack my box with five dozen liquor jugs.",
            ]
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
        // Block structure (ticket 05): heading Block + paragraph Blocks; the
        // head <title> is never spoken; the empty chapter has no Blocks.
        XCTAssertEqual(book.chapters.map(\.blocks.count), [2, 4, 4, 0])
        XCTAssertEqual(book.chapters[0].blocks.map(\.text), [
            "Chapter One",
            "The quick brown fox jumps over the lazy dog.",
        ])
        XCTAssertTrue(book.chapters[3].blocks.isEmpty)
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
        // The spoken text is the chapters' own Blocks only (ticket 05):
        // heading Block + paragraph Block each, the head <title> never
        // spoken — and none of the never-spoken documents' text leaks in.
        XCTAssertEqual(
            book.chapters.map { $0.blocks.map(\.text) },
            [
                ["Heading One", "The short first chapter text."],
                ["Heading Two", "The short second chapter text."],
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

    // MARK: - Ticket 05: block-level text with natural pauses

    /// The rich fixture: every block-level element, footnotes (EPUB3
    /// `epub:type` and EPUB2 `class`), an image with alt text and a data URI,
    /// and links (anchor text, bare-URL anchor text, mailto href).
    func testLoadBlocksFixtureExtractsBlocks() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("blocks.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "Blocks Book")
        XCTAssertEqual(book.author, "Blocks Author")
        XCTAssertEqual(book.chapters.count, 1)
        // No navigation document: the largest heading is the title.
        XCTAssertEqual(book.chapters[0].title, "Blocks Chapter")

        // One Block per block-level element, in reading order, with the
        // per-Block rules applied (entities decoded, whitespace
        // normalised, footnotes/media/never-spoken subtrees dropped, the
        // footnote reference marker dropped, the bare-URL anchor text kept
        // once).
        XCTAssertEqual(
            book.chapters[0].blocks.map(\.text),
            [
                "Blocks Chapter",
                "First paragraph with a linked anchor and emphasis.",
                "Second paragraph ends with a bare-URL link https://example.org/bare and an email.",
                "Section Heading & Notes",
                "It’s text after the section heading.",
                "First list item.",
                "Second list item with bold text.",
                "First ordered item.",
                "A quoted paragraph inside a blockquote.",
                "line one line two line three",
                "Caption for the fox picture.",
                "Paragraph with a footnote that continues after it.",
                "Final paragraph after all of it.",
            ]
        )

        // No skipped content leaks into any Block.
        let all = book.chapters[0].blocks.map(\.text)
        let joined = all.joined(separator: "\n")
        XCTAssertFalse(joined.contains("never be spoken"), joined) // both footnotes
        XCTAssertFalse(joined.contains("Footnotes"), joined) // the footnote section heading
        XCTAssertFalse(joined.contains("A picture of a fox"), joined) // the img alt text
        XCTAssertFalse(joined.contains("iVBORw"), joined) // the image data URI
        XCTAssertFalse(joined.contains("example.com/anchor"), joined) // a href
        XCTAssertFalse(joined.contains("mailto:"), joined) // a href
        XCTAssertFalse(joined.contains("alert"), joined) // the head <script>
        // The bare-URL anchor text is spoken exactly once; the hrefs are
        // never spoken.
        XCTAssertEqual(joined.components(separatedBy: "https://example.org/bare").count - 1, 1, joined)

        // Whitespace: no doubled spaces, no line breaks, no edge padding —
        // the audible-glitch guard, per Block.
        for block in all {
            XCTAssertFalse(block.contains("  "), block)
            XCTAssertFalse(block.contains("\n"), block)
            XCTAssertEqual(block, block.trimmingCharacters(in: .whitespaces), block)
        }
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
