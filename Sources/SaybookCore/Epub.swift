import Foundation

/// A parsed Book: identity metadata plus its Chapters in Spine order.
public struct Book: Sendable {
    public let title: String
    public let author: String
    public let language: String
    /// The Book's cover image, as declared in the OPF.
    public let cover: CoverImage
    /// Readable Spine documents, in reading order.
    public let chapters: [Chapter]

    /// The cover image the OPF declares (`properties="cover"` or the EPUB2
    /// `<meta name="cover"/>` reference).
    public enum CoverImage: Sendable, Equatable {
        /// The OPF declares no cover image.
        case absent
        /// The raw image bytes of the OPF-declared cover.
        case data(Data)
        /// The OPF declares a cover whose file could not be read (a broken
        /// reference): the run keeps going without a cover and reports a
        /// warning.
        case missing(reference: String)

        /// The image bytes when the cover is present.
        var imageData: Data? {
            if case let .data(image) = self { return image }
            return nil
        }
    }
}

/// The smallest unit of spoken text within a Chapter (ticket 05): the
/// whitespace-normalised text of one block-level element (a paragraph,
/// list item, blockquote, preformatted text, heading, or figcaption). Each
/// Block is synthesised as one utterance, with an audible pause between
/// Blocks.
public struct Block: Sendable, Equatable {
    /// The Block's spoken text, whitespace-normalised.
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// One readable Spine document: its title and its Blocks in reading order.
/// Each Block is synthesised as one utterance, with an audible pause
/// between Blocks (ticket 05).
public struct Chapter: Sendable {
    /// The document's title: the EPUB3 navigation entry for the document
    /// when present, else the document's largest heading (h1 … h6), else the
    /// filename without extension.
    public let title: String
    /// The document's spoken Blocks in reading order (ticket 05).
    public let blocks: [Block]

    /// All Block texts joined by single spaces (`""` when the Chapter has
    /// no Blocks).
    public var text: String {
        blocks.map(\.text).joined(separator: " ")
    }
}

/// Opens a non-DRM EPUB: unpacks it with the system `ditto` into Scratch and
/// reads OPF metadata (title/author/language/cover), Spine order, each
/// Chapter's Blocks (ticket 05), and Chapter titles from the EPUB3
/// navigation document when present.
///
/// The OPF is parsed with deliberately crude regexes over machine-generated,
/// well-formed EPUB XML (staying dependency-free); the content documents are
/// walked with Foundation's `XMLParser`, which handles the ordered, nested
/// block structure the regexes would not.
public enum Epub {

    public enum EpubError: Error, Equatable {
        /// The file is not a readable, well-formed EPUB (bad archive, missing
        /// container or OPF, or no readable Spine documents).
        case notAValidEpub
    }

    /// `properties` values marking a Spine document as never spoken: the
    /// EPUB3 navigation document, cover pages, and titlepage-type documents
    /// (`nav`, `cover`, `doc-cover`, `doc-titlepage`).
    private static let neverSpokenProperties: Set<String> = [
        "nav", "cover", "doc-cover", "doc-titlepage",
    ]

    public static func load(bookAt url: URL, scratch: URL) throws -> Book {
        try unpack(bookAt: url, into: scratch)
        let opfURL = try opfURL(in: scratch)
        let opf = try parseOPF(at: opfURL)
        let opfDir = opfURL.deletingLastPathComponent()

        // Chapter titles from the EPUB3 navigation document when present;
        // otherwise the largest-heading → filename fallback applies.
        let navItem = opf.itemOrder.compactMap { opf.items[$0] }.first { $0.properties.contains("nav") }
        let navTitles = navTitles(of: navItem, relativeTo: opfDir)

        // The cover image the OPF declares, if any.
        let cover = coverImage(declaredBy: opf, opfDir: opfDir)

        var chapters: [Chapter] = []
        for ref in opf.spine {
            guard let item = opf.items[ref.idref],
                  item.mediaType.localizedCaseInsensitiveContains("html")
            else { continue }
            // Navigation, cover and titlepage Spine documents are never
            // spoken.
            if !ref.linear
                || !Set(ref.properties).isDisjoint(with: neverSpokenProperties)
                || !Set(item.properties).isDisjoint(with: neverSpokenProperties) { continue }
            let fileURL = opfDir.appendingPathComponent(item.href)
            let text = try readUTF8(fileURL)
            let filename = fileURL.deletingPathExtension().lastPathComponent
            chapters.append(
                Chapter(
                    title: navTitles[fileURL.standardized.path] ?? chapterTitle(from: text, filename: filename),
                    blocks: extractBlocks(from: text)
                )
            )
        }
        guard !chapters.isEmpty else { throw EpubError.notAValidEpub }

        return Book(
            title: opf.title,
            author: opf.author,
            language: opf.language.isEmpty ? "en-US" : opf.language,
            cover: cover,
            chapters: chapters
        )
    }

    // MARK: - Unpacking

    private static func unpack(bookAt url: URL, into scratch: URL) throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", url.path, scratch.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { throw EpubError.notAValidEpub }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw EpubError.notAValidEpub }
    }

    // MARK: - OPF

    private struct OPF {
        var title = ""
        var author = ""
        var language = ""
        var items: [String: Item] = [:]
        /// Manifest order (dictionary order is not).
        var itemOrder: [String] = []
        var spine: [SpineRef] = []
        /// The EPUB2 `<meta name="cover" content="…"/>` item id, when present.
        var coverMetaID: String?

        struct Item {
            let href: String
            let mediaType: String
            /// The `properties` attribute, whitespace-separated (e.g.
            /// "nav", "cover").
            let properties: [String]
        }

        struct SpineRef {
            let idref: String
            /// `linear="no"` documents (TOC, cover page, titlepage, …) are
            /// never spoken.
            let linear: Bool
            let properties: [String]
        }
    }

    private static func opfURL(in scratch: URL) throws -> URL {
        let containerURL = scratch.appendingPathComponent("META-INF/container.xml")
        let xml = try readUTF8(containerURL)
        // <rootfile full-path="OEBPS/content.opf" media-type="..."/>
        guard let path = xml.firstMatch(of: /<rootfile\b[^>]*\bfull-path\s*=\s*"([^"]+)"/)?.1
        else { throw EpubError.notAValidEpub }
        let opf = scratch.appendingPathComponent(String(path))
        guard FileManager.default.fileExists(atPath: opf.path) else { throw EpubError.notAValidEpub }
        return opf
    }

    private static func parseOPF(at url: URL) throws -> OPF {
        let xml = try readUTF8(url)

        var opf = OPF()
        if let title = firstCapture(/(?s)<dc:title[^>]*>(.*?)<\/dc:title>/, in: xml) {
            opf.title = title
        }
        if let author = firstCapture(/(?s)<dc:creator[^>]*>(.*?)<\/dc:creator>/, in: xml) {
            opf.author = author
        }
        if let language = firstCapture(/(?s)<dc:language[^>]*>(.*?)<\/dc:language>/, in: xml) {
            opf.language = language
        }
        // <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        for item in xml.matches(of: /<item\b([^>]*?)\/>/) {
            let attrs = parseAttributes(item.1)
            guard let id = attrs["id"], let href = attrs["href"] else { continue }
            opf.items[id] = OPF.Item(
                href: href,
                mediaType: attrs["media-type"] ?? "",
                properties: splitProperties(attrs["properties"])
            )
            opf.itemOrder.append(id)
        }
        // <itemref idref="ch1" linear="no"/>
        for idref in xml.matches(of: /<itemref\b([^>]*?)\/>/) {
            let attrs = parseAttributes(idref.1)
            guard let id = attrs["idref"] else { continue }
            opf.spine.append(
                OPF.SpineRef(
                    idref: id,
                    linear: attrs["linear"] != "no",
                    properties: splitProperties(attrs["properties"])
                )
            )
        }
        // <meta name="cover" content="cover"/> (EPUB2 cover declaration)
        for meta in xml.matches(of: /<meta\b([^>]*?)\/>/) {
            let attrs = parseAttributes(meta.1)
            if attrs["name"] == "cover" || attrs["name"] == "cover-image" {
                opf.coverMetaID = attrs["content"]
                break
            }
        }
        return opf
    }

    /// A whitespace-separated `properties` attribute as a list.
    private static func splitProperties(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: " ").map(String.init)
    }

    /// The first capture group of `regex` in `xml`, entity-decoded and trimmed.
    /// (A single-capture regex literal has output type (wholeMatch, capture).)
    private static func firstCapture(_ regex: Regex<(Substring, Substring)>, in xml: String) -> String? {
        xml.firstMatch(of: regex).map { decodeAndTrim($0.1) }
    }

    private static func decodeAndTrim(_ raw: Substring) -> String {
        decodeEntities(String(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a file as UTF-8; a missing or non-UTF-8 file is a bad EPUB.
    private static func readUTF8(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { throw EpubError.notAValidEpub }
        return text
    }

    private static func parseAttributes(_ raw: Substring) -> [String: String] {
        var attrs: [String: String] = [:]
        for m in raw.matches(of: /\b([\w-]+)\s*=\s*"([^"]*)"/) {
            attrs[String(m.1)] = String(m.2)
        }
        return attrs
    }

    // MARK: - Navigation & cover

    /// Chapter titles from the EPUB3 navigation document: each anchor's
    /// `href` (resolved against the nav document; the URL's `path` drops any
    /// fragment) mapped to the anchor's text, keyed by the document's
    /// absolute path so the Spine lookup is `fileURL.standardized.path`. A
    /// missing or unreadable nav document yields no titles (the heading →
    /// filename fallback then applies); the first entry wins per document.
    private static func navTitles(of navItem: OPF.Item?, relativeTo opfDir: URL) -> [String: String] {
        guard let navItem else { return [:] }
        let navURL = opfDir.appendingPathComponent(navItem.href)
        guard let html = try? readUTF8(navURL) else { return [:] }
        var titles: [String: String] = [:]
        for match in html.matches(of: /<a\b[^>]*\bhref\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)<\/a>/) {
            guard let resolved = URL(string: String(match.1), relativeTo: navURL),
                  !resolved.standardized.path.isEmpty
            else { continue }
            let title = normalize(decodeEntities(stripMarkup(String(match.2))))
            guard !title.isEmpty else { continue }
            titles[resolved.standardized.path, default: title] = title
        }
        return titles
    }

    /// The raw image bytes of the cover the OPF declares: EPUB3 marks it
    /// with a `cover` property (manifest item or Spine itemref), EPUB2 with
    /// `<meta name="cover" content="item-id"/>`. A declared cover whose file
    /// is missing or unreadable is `.missing` (a broken reference degrades
    /// to a warning, not a failure).
    private static func coverImage(declaredBy opf: OPF, opfDir: URL) -> Book.CoverImage {
        var coverID: String?
        for id in opf.itemOrder {
            let spineMarksCover = opf.spine.first { $0.idref == id }?.properties.contains("cover") ?? false
            let itemMarksCover = opf.items[id]?.properties.contains("cover") ?? false
            if spineMarksCover || itemMarksCover {
                coverID = id
                break
            }
        }
        if coverID == nil { coverID = opf.coverMetaID }
        guard let id = coverID, let item = opf.items[id] else { return .absent }
        let fileURL = opfDir.appendingPathComponent(item.href)
        guard let data = try? Data(contentsOf: fileURL) else { return .missing(reference: item.href) }
        return .data(data)
    }

    // MARK: - Block extraction (ticket 05)

    /// Block-level element names: each opens a Block.
    private static let blockElementNames: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "figcaption",
    ]

    /// Element names whose whole subtree is never spoken: the document head
    /// (metadata, never content), scripts, styles, and media.
    private static let neverSpokenElements: Set<String> = [
        "head", "script", "style", "svg", "canvas", "picture", "video", "audio",
    ]

    /// XHTML's void elements: no closing tag and no content, so they cannot
    /// open or end a skip region.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// `class` tokens marking a footnote or a footnote section (EPUB2/EPUB3
    /// convention).
    private static let footnoteClassTokens: Set<String> = ["footnote", "footnotes"]

    /// Whether the element opens a never-spoken subtree: a named
    /// never-spoken element, or any element marked as a footnote (an
    /// `epub:type` token of `footnote`, or a `footnote`/`footnotes` class
    /// token).
    private static func isNeverSpoken(_ name: String, attributes: [String: String]) -> Bool {
        if neverSpokenElements.contains(name) { return true }
        if let type = attributes["epub:type"],
           type.split(separator: " ").map({ $0.lowercased() }).contains("footnote")
        { return true }
        if let classAttribute = attributes["class"],
           classAttribute.split(separator: " ").map({ $0.lowercased() }).contains(where: footnoteClassTokens.contains)
        { return true }
        return false
    }

    /// The document's Blocks in reading order (ticket 05). A content
    /// document that is not well-formed XML degrades to its whole-document
    /// text as a single Block (the v1 behaviour, minus the head): a broken
    /// document degrades to unstructured speech, never to a silently empty
    /// chapter. (Footnote subtrees cannot be detected without the parser
    /// and may be spoken in that degraded path.)
    static func extractBlocks(from html: String) -> [Block] {
        if let data = html.data(using: .utf8) {
            let extractor = BlockExtractor()
            let parser = XMLParser(data: data)
            parser.delegate = extractor
            if parser.parse() {
                return extractor.finish()
            }
        }
        let text = extractText(from: html)
        return text.isEmpty ? [] : [Block(text: text)]
    }

    /// Walks one content document in document order and yields its Blocks
    /// (ticket 05).
    ///
    /// A Block starts at every block-level element; the element's text
    /// (markup stripped, entities decoded by the parser, whitespace
    /// normalised) becomes the Block, and a Block that normalises to
    /// nothing yields none. Text outside any block-level element becomes a
    /// Block of its own, so no content is dropped. Never-spoken subtrees
    /// (head, scripts, styles, media, footnotes) are dropped whole.
    private final class BlockExtractor: NSObject, XMLParserDelegate {
        private var blocks: [Block] = []
        /// Text accumulated for the Block (or stray run) currently open.
        private var current = ""
        /// The document depth (non-void elements) and the depth at which
        /// the current never-spoken subtree started (0 = not inside one).
        private var depth = 0
        private var skipDepth = 0

        /// The parsed Blocks (call after a successful `XMLParser.parse()`).
        func finish() -> [Block] {
            flush()
            return blocks
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            let name = elementName.lowercased()
            guard !Epub.voidElements.contains(name) else { return }
            if skipDepth > 0 {
                depth += 1
                return
            }
            depth += 1
            if Epub.isNeverSpoken(name, attributes: attributes) {
                skipDepth = depth
            } else if Epub.blockElementNames.contains(name) {
                flush()
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let name = elementName.lowercased()
            guard !Epub.voidElements.contains(name) else { return }
            if skipDepth > 0 {
                depth -= 1
                // The skipped element itself just closed when the depth
                // drops below the depth at which the skip started.
                if depth < skipDepth { skipDepth = 0 }
                return
            }
            depth -= 1
            if Epub.blockElementNames.contains(name) {
                flush()
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0 else { return }
            current += string
        }

        private func flush() {
            let text = Epub.normalize(current)
            guard !text.isEmpty else { return }
            blocks.append(Block(text: text))
            current = ""
        }
    }

    /// The document's title: the first non-empty largest heading (h1 first,
    /// then h2 … h6), or `filename` when the document has no heading text.
    private static func chapterTitle(from html: String, filename: String) -> String {
        // One pass over all headings: (open level, inner markup, close level).
        let regex = /(?is)<h([1-6])\b[^>]*>(.*?)<\/h([1-6])>/
        var innerByLevel: [Int: [Substring]] = [:]
        for match in html.matches(of: regex) where match.1 == match.3 {
            guard let level = Int(match.1) else { continue }
            innerByLevel[level, default: []].append(match.2)
        }
        for level in 1...6 {
            for inner in innerByLevel[level] ?? [] {
                let text = normalize(decodeEntities(stripMarkup(String(inner))))
                if !text.isEmpty { return text }
            }
        }
        return filename
    }

    /// The v1 whole-document text (head, scripts and styles dropped):
    /// the fallback for content documents that are not well-formed XML.
    private static func extractText(from html: String) -> String {
        normalize(decodeEntities(stripMarkup(html)))
    }

    /// Removes the document head, scripts, styles, and all tags from XHTML
    /// markup (the v1 whole-document text step; Block extraction replaces
    /// it for well-formed documents).
    private static func stripMarkup(_ html: String) -> String {
        html
            .replacing(/(?is)<head\b[^>]*>.*?<\/head>/, with: "")
            .replacing(/(?is)<script\b[^>]*>.*?<\/script>/, with: "")
            .replacing(/(?is)<style\b[^>]*>.*?<\/style>/, with: "")
            .replacing(/<[^>]+>/, with: "")
    }

    /// Collapses whitespace runs to single spaces.
    private static func normalize(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Decodes XML entities (numeric `&#39;`/`&#x27;` and the five predefined
    /// named ones) so the engine never hears raw markup.
    private static func decodeEntities(_ s: String) -> String {
        let numeric = s
            .replacing(/&#x([0-9A-Fa-f]+);/) { m in
                scalarValue(UInt32(m.1, radix: 16) ?? 0)
            }
            .replacing(/&#(\d+);/) { m in
                scalarValue(UInt32(m.1) ?? 0)
            }
        return numeric
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func scalarValue(_ value: UInt32) -> String {
        guard let scalar = Unicode.Scalar(value) else { return "" }
        return String(Character(scalar))
    }
}
