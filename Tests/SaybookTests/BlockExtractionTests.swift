import Foundation
import XCTest
@testable import SaybookCore

/// Ticket 05: the per-Block extraction rules at the `extractBlocks` seam —
/// block-level elements become Blocks, never-spoken subtrees are dropped,
/// link anchor text is spoken once, and whitespace is normalised.
final class BlockExtractionTests: XCTestCase {

    /// Wraps `body` in a minimal XHTML document so the single-root XML
    /// parser accepts it.
    private func doc(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Doc Title</title><style>p { margin: 0 }</style></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private func texts(_ blocks: [Block]) -> [String] { blocks.map(\.text) }

    // MARK: - Block-level elements

    func testEveryBlockLevelElementProducesOneBlockInReadingOrder() {
        let html = doc("""
        <h1>Heading one</h1>
        <p>Paragraph one.</p>
        <h6>Heading six</h6>
        <ul><li>Item one.</li><li>Item two.</li></ul>
        <blockquote>Quoted text.</blockquote>
        <pre>pre one
            pre two</pre>
        <figure><figcaption>Caption.</figcaption></figure>
        """)

        XCTAssertEqual(
            texts(Epub.extractBlocks(from: html)),
            [
                "Heading one",
                "Paragraph one.",
                "Heading six",
                "Item one.",
                "Item two.",
                "Quoted text.",
                "pre one pre two",
                "Caption.",
            ]
        )
    }

    func testNestedBlockElementsYieldOneBlockPerElement() {
        // A paragraph inside a blockquote is the blockquote's content: one
        // Block with the paragraph's text.
        let html = doc("""
        <blockquote>
        <p>A quoted paragraph.</p>
        </blockquote>
        """)
        XCTAssertEqual(texts(Epub.extractBlocks(from: html)), ["A quoted paragraph."])
    }

    func testStrayTextOutsideBlocksBecomesItsOwnBlock() {
        // Text not wrapped in a block-level element must not be dropped:
        // it becomes its own Block.
        let html = doc("""
        <div>
        <span>Stray lead-in.</span>
        <p>Wrapped.</p>
        <span>Stray tail.</span>
        </div>
        """)
        XCTAssertEqual(
            texts(Epub.extractBlocks(from: html)),
            ["Stray lead-in.", "Wrapped.", "Stray tail."]
        )
    }

    // MARK: - Never-spoken content

    func testDocumentHeadIsNeverSpoken() {
        // The head's title would duplicate the h1 in the v1 whole-document
        // text: it is document metadata, not spoken content.
        let html = doc("""
        <h1>Only Heading</h1>
        <p>Body text.</p>
        """)
        XCTAssertEqual(
            texts(Epub.extractBlocks(from: html)),
            ["Only Heading", "Body text."]
        )
    }

    func testScriptsAndStylesInBodyAreNeverSpoken() {
        let html = doc("""
        <p>Before.</p>
        <style>.x { color: red }</style>
        <script>var x = 'never spoken';</script>
        <p>After.</p>
        """)
        XCTAssertEqual(texts(Epub.extractBlocks(from: html)), ["Before.", "After."])
    }

    func testEpubTypeFootnoteSubtreesAreNeverSpoken() {
        // EPUB3 footnotes: the reference marker, the aside body, and any
        // block-level element inside a footnote-typed subtree are dropped.
        let html = doc("""
        <p>Text with a footnote<sup><a epub:type="footnote" href="#fn">1</a></sup> marker.</p>
        <aside epub:type="footnote" id="fn">Footnote body must never be spoken.</aside>
        <section epub:type="footnote"><h2>Footnotes</h2><p>Another footnote body.</p></section>
        <p>After the footnotes.</p>
        """)
        XCTAssertEqual(
            texts(Epub.extractBlocks(from: html)),
            ["Text with a footnote marker.", "After the footnotes."]
        )
    }

    func testFootnoteClassSubtreesAreNeverSpoken() {
        // EPUB2-style footnote section: a class-marked container and its
        // blocks (heading included).
        let html = doc("""
        <p>Main text.</p>
        <div class="footnotes">
        <h3>Footnotes</h3>
        <p class="footnote">A class-marked footnote.</p>
        </div>
        <p>Tail text.</p>
        """)
        XCTAssertEqual(texts(Epub.extractBlocks(from: html)), ["Main text.", "Tail text."])
    }

    func testImagesAndOtherMediaAreNeverSpoken() {
        // img (incl. data-URI src and alt text), picture/source, svg, video
        // and audio subtrees produce no Blocks; an empty paragraph yields
        // no Block at all.
        let html = doc("""
        <figure>
        <img src="data:image/png;base64,iVBORw0KGgo" alt="Alt text must not be spoken"/>
        <picture><source srcset="x.png"/><img src="x.png" alt="Also not spoken"/></picture>
        <svg><text>Vector text.</text></svg>
        <video><source src="movie.mp4"/><p>Fallback text.</p></video>
        <audio src="sound.mp3"></audio>
        <figcaption>The caption is spoken.</figcaption>
        </figure>
        <p></p>
        <p>Visible text.</p>
        """)
        XCTAssertEqual(
            texts(Epub.extractBlocks(from: html)),
            ["The caption is spoken.", "Visible text."]
        )
    }

    // MARK: - Links

    func testLinkAnchorTextIsSpokenOnceAndHrefsAreNeverSpoken() {
        let html = doc("""
        <p>Read <a href="https://example.com/target">the article</a> about <a href="https://example.org/plain">https://example.org/plain</a>.</p>
        """)
        let blocks = Epub.extractBlocks(from: html)
        XCTAssertEqual(texts(blocks), ["Read the article about https://example.org/plain."])
        let joined = blocks.map(\.text).joined(separator: " ")
        // The href of the first link leaks in nowhere; the anchor text is
        // spoken exactly once.
        XCTAssertFalse(joined.contains("example.com/target"), joined)
        XCTAssertEqual(joined.components(separatedBy: "the article").count - 1, 1, joined)
    }

    // MARK: - Whitespace & entities

    func testWhitespaceRunsAreNormalisedToSingleSpaces() {
        // Explicit escapes: the tab and blank-line runs are the subject of
        // the test (and a multi-line literal cannot hold leading tabs).
        let body = """
        <p>
        Leading   spaces,
        multiple  lines,
        and\ta tab.
        </p>
        <pre>a
        \tb

        \tc</pre>
        """
        let html = doc(body)
        XCTAssertEqual(
            texts(Epub.extractBlocks(from: html)),
            ["Leading spaces, multiple lines, and a tab.", "a b c"]
        )
    }

    func testXmlEntitiesAreDecoded() {
        let html = doc("""
        <p>Tom &amp; Jerry&#8217;s &lt;book&gt;.</p>
        """)
        XCTAssertEqual(texts(Epub.extractBlocks(from: html)), ["Tom & Jerry’s <book>."])
    }

    // MARK: - Degradation

    func testMalformedDocumentFallsBackToWholeDocumentText() {
        // A content document that is not well-formed XML still yields its
        // text (one Block, v1 behaviour) rather than a silently empty
        // chapter.
        let html = doc("<p>Unclosed paragraph")
        XCTAssertEqual(texts(Epub.extractBlocks(from: html)), ["Unclosed paragraph"])
    }
}
