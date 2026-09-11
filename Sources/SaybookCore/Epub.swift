import Foundation

/// A parsed Book: identity metadata plus its Chapters in Spine order.
public struct Book: Sendable {
    public let title: String
    public let author: String
    public let language: String
    /// Readable Spine documents, in reading order.
    public let chapters: [Chapter]
}

/// One readable Spine document with its v1-crude text (whole document, one utterance).
public struct Chapter: Sendable {
    /// The document's largest heading (h1 … h6), or the filename without
    /// extension when the document carries no heading. EPUB3 nav titles
    /// arrive in ticket 03.
    public let title: String
    /// All document text, whitespace-normalised.
    public let text: String
}

/// Opens a non-DRM EPUB: unpacks it with the system `ditto` into Scratch and
/// reads OPF metadata, Spine order, and each Chapter's text.
///
/// Parsing is deliberately crude (regex over machine-generated, well-formed
/// EPUB XML) to stay dependency-free; ticket 05's block-level extraction will
/// replace the per-Chapter text step.
public enum Epub {

    public enum EpubError: Error, Equatable {
        /// The file is not a readable, well-formed EPUB (bad archive, missing
        /// container or OPF, or no readable Spine documents).
        case notAValidEpub
    }

    public static func load(bookAt url: URL, scratch: URL) throws -> Book {
        try unpack(bookAt: url, into: scratch)
        let opfURL = try opfURL(in: scratch)
        let opf = try parseOPF(at: opfURL)

        var chapters: [Chapter] = []
        for idref in opf.spine {
            guard let item = opf.items[idref],
                  item.mediaType.localizedCaseInsensitiveContains("html")
            else { continue }
            let fileURL = opfURL.deletingLastPathComponent().appendingPathComponent(item.href)
            let text = try readUTF8(fileURL)
            let filename = fileURL.deletingPathExtension().lastPathComponent
            chapters.append(
                Chapter(
                    title: chapterTitle(from: text, filename: filename),
                    text: extractText(from: text)
                )
            )
        }
        guard !chapters.isEmpty else { throw EpubError.notAValidEpub }

        return Book(
            title: opf.title,
            author: opf.author,
            language: opf.language.isEmpty ? "en-US" : opf.language,
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
        var spine: [String] = []

        struct Item {
            let href: String
            let mediaType: String
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
            opf.items[id] = OPF.Item(href: href, mediaType: attrs["media-type"] ?? "")
        }
        // <itemref idref="ch1"/>
        for idref in xml.matches(of: /<itemref\b[^>]*\bidref\s*=\s*"([^"]+)"/) {
            opf.spine.append(String(idref.1))
        }
        return opf
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

    // MARK: - Text extraction (v1 crude: whole document, one utterance)

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

    private static func extractText(from html: String) -> String {
        normalize(decodeEntities(stripMarkup(html)))
    }

    /// Removes scripts, styles, and all tags from XHTML markup.
    private static func stripMarkup(_ html: String) -> String {
        html
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
