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

    // MARK: - Ticket 06: error paths, safety & signals

    /// The `META-INF/container.xml` pointing at `OEBPS/content.opf` (shared
    /// by the in-memory mini-EPUBs below).
    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    /// Builds a minimal one-chapter EPUB tree under `root` (mimetype,
    /// META-INF, OEBPS) with knobs for the DRM signals: an arbitrary
    /// `encryption.xml` (root-relative item URIs), the chapter item's
    /// manifest media type, and the Spine's itemrefs.
    private func makeMiniEpub(
        in root: URL,
        ch1MediaType: String = "application/xhtml+xml",
        ch1Href: String = "ch1.xhtml",
        spineXML: String = "<itemref idref=\"ch1\"/>",
        encryptionXML: String? = nil
    ) throws {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:mini</dc:identifier>
            <dc:title>Mini Book</dc:title>
            <dc:creator>Mini Author</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="ch1" href="\(ch1Href)" media-type="\(ch1MediaType)"/>
          </manifest>
          <spine>
            \(spineXML)
          </spine>
        </package>
        """
        let ch1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Mini Chapter</title></head>
        <body><h1>Mini Chapter</h1><p>Some text.</p></body>
        </html>
        """
        try writeTreeFile("application/epub+zip", at: "mimetype", under: root)
        try writeTreeFile(Self.containerXML, at: "META-INF/container.xml", under: root)
        try writeTreeFile(opf, at: "OEBPS/content.opf", under: root)
        try writeTreeFile(ch1, at: "OEBPS/\(ch1Href)", under: root)
        if let encryptionXML { try writeTreeFile(encryptionXML, at: "META-INF/encryption.xml", under: root) }
    }

    /// A real DRM-style book: `META-INF/encryption.xml` lists the content
    /// document AND the manifest declares it with the `x-enc+xml` media type.
    func testLoadDrmContentFixtureFailsWithDrmError() throws {
        let scratch = try makeTempDir()
        XCTAssertThrowsError(
            try Epub.load(bookAt: fixturesDir.appendingPathComponent("drm-content.epub"), scratch: scratch)
        ) { error in
            XCTAssertEqual(error as? Epub.EpubError, .drmEncrypted(uri: "ch1.xhtml"))
        }
    }

    /// An encrypted OPF: `container.xml` still resolves, but the OPF's
    /// bytes are cipher text. The run must fail with the DRM error before
    /// attempting to parse the OPF.
    func testLoadDrmOpfFixtureFailsWithDrmError() throws {
        let scratch = try makeTempDir()
        XCTAssertThrowsError(
            try Epub.load(bookAt: fixturesDir.appendingPathComponent("drm-opf.epub"), scratch: scratch)
        ) { error in
            XCTAssertEqual(error as? Epub.EpubError, .drmEncrypted(uri: "OEBPS/content.opf"))
        }
    }

    /// The encryption.xml signal alone: the chapter is listed in
    /// `META-INF/encryption.xml` while the manifest still calls it XHTML.
    func testLoadFailsWhenSpineItemListedInEncryptionXml() throws {
        let dir = try makeTempDir()
        let root = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeMiniEpub(in: root, encryptionXML: """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns:enc="urn:oasis:names:tc:opendocument:xmlns:encryption">
          <enc:EncryptedData URI="OEBPS/ch1.xhtml" Type="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
        </encryption>
        """)
        let archive = dir.appendingPathComponent("mini.epub")
        try zipTree(root, into: archive)

        XCTAssertThrowsError(try Epub.load(bookAt: archive, scratch: dir.appendingPathComponent("scratch"))) {
            XCTAssertEqual($0 as? Epub.EpubError, .drmEncrypted(uri: "ch1.xhtml"))
        }
    }

    /// The media-type signal alone: the manifest declares the chapter as
    /// encrypted data (`x-enc+xml`) and there is no `encryption.xml`.
    func testLoadFailsWhenSpineItemDeclaredEncryptedMediaType() throws {
        let dir = try makeTempDir()
        let root = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeMiniEpub(in: root, ch1MediaType: "application/x-enc+xml")
        let archive = dir.appendingPathComponent("mini.epub")
        try zipTree(root, into: archive)

        XCTAssertThrowsError(try Epub.load(bookAt: archive, scratch: dir.appendingPathComponent("scratch"))) {
            XCTAssertEqual($0 as? Epub.EpubError, .drmEncrypted(uri: "ch1.xhtml"))
        }
    }

    /// DRM is a Book-level constraint (spec: "encrypted content → clean
    /// error"): an `encryption.xml` entry that names a non-Spine item (a
    /// cover image) still makes the book DRM-protected.
    func testLoadFailsWhenNonSpineItemIsEncrypted() throws {
        let dir = try makeTempDir()
        let root = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTreeFile("application/epub+zip", at: "mimetype", under: root)
        try writeTreeFile(Self.containerXML, at: "META-INF/container.xml", under: root)
        try writeTreeFile("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:drm-cover</dc:identifier>
            <dc:title>DRM Cover Book</dc:title>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="cover" href="art.png" media-type="image/png"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """, at: "OEBPS/content.opf", under: root)
        try writeTreeFile("<html><body><p>Text.</p></body></html>", at: "OEBPS/ch1.xhtml", under: root)
        try writeTreeFile("""
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns:enc="urn:oasis:names:tc:opendocument:xmlns:encryption">
          <enc:EncryptedData URI="OEBPS/art.png" Type="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
        </encryption>
        """, at: "META-INF/encryption.xml", under: root)
        let archive = dir.appendingPathComponent("mini.epub")
        try zipTree(root, into: archive)

        XCTAssertThrowsError(try Epub.load(bookAt: archive, scratch: dir.appendingPathComponent("scratch"))) {
            XCTAssertEqual($0 as? Epub.EpubError, .drmEncrypted(uri: "art.png"))
        }
    }

    /// A Book whose Spine holds only never-spoken documents (a `linear="no"`
    /// cover page): no readable Chapters is its own error, distinct from a
    /// structurally invalid EPUB.
    func testLoadNoReadableChaptersFixture() throws {
        let scratch = try makeTempDir()
        XCTAssertThrowsError(
            try Epub.load(
                bookAt: fixturesDir.appendingPathComponent("no-readable-chapters.epub"),
                scratch: scratch
            )
        ) { error in
            XCTAssertEqual(error as? Epub.EpubError, .noReadableChapters)
        }
    }

    /// An empty Spine (no itemrefs at all) is the same failure.
    func testLoadEmptySpineIsNoReadableChapters() throws {
        let dir = try makeTempDir()
        let root = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeMiniEpub(in: root, spineXML: "")
        let archive = dir.appendingPathComponent("mini.epub")
        try zipTree(root, into: archive)

        XCTAssertThrowsError(try Epub.load(bookAt: archive, scratch: dir.appendingPathComponent("scratch"))) {
            XCTAssertEqual($0 as? Epub.EpubError, .noReadableChapters)
        }
    }

    /// Non-XHTML Spine items (video, images, other media) are skipped
    /// without failing the run: the fixture's `intro.mp4` and `art.png` are
    /// not even in the archive, so reading them would fail the run.
    func testLoadSkipsNonXhtmlSpineItems() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("media-spine.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "Media Spine Book")
        // Only the two XHTML documents are readable Spine documents.
        XCTAssertEqual(book.chapters.map(\.title), ["Media One", "Media Two"])
        XCTAssertEqual(book.chapters[0].blocks.map(\.text), ["Media One", "The quick brown fox jumps over the lazy dog."])
        XCTAssertEqual(book.chapters[1].blocks.map(\.text), ["Media Two", "Pack my box with five dozen liquor jugs."])
    }
}
