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
    /// v1 title: the document filename without extension (refined in ticket 02).
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
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8)
            else { throw EpubError.notAValidEpub }
            chapters.append(
                Chapter(
                    title: fileURL.deletingPathExtension().lastPathComponent,
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
        guard let data = try? Data(contentsOf: containerURL),
              let xml = String(data: data, encoding: .utf8)
        else { throw EpubError.notAValidEpub }
        // <rootfile full-path="OEBPS/content.opf" media-type="..."/>
        guard let path = xml.firstMatch(of: /<rootfile\b[^>]*\bfull-path\s*=\s*"([^"]+)"/)?.1
        else { throw EpubError.notAValidEpub }
        let opf = scratch.appendingPathComponent(String(path))
        guard FileManager.default.fileExists(atPath: opf.path) else { throw EpubError.notAValidEpub }
        return opf
    }

    private static func parseOPF(at url: URL) throws -> OPF {
        guard let data = try? Data(contentsOf: url),
              let xml = String(data: data, encoding: .utf8)
        else { throw EpubError.notAValidEpub }

        var opf = OPF()
        if let m = xml.firstMatch(of: /(?s)<dc:title[^>]*>(.*?)<\/dc:title>/) {
            opf.title = clean(m.1)
        }
        if let m = xml.firstMatch(of: /(?s)<dc:creator[^>]*>(.*?)<\/dc:creator>/) {
            opf.author = clean(m.1)
        }
        if let m = xml.firstMatch(of: /(?s)<dc:language[^>]*>(.*?)<\/dc:language>/) {
            opf.language = clean(m.1)
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

    private static func clean(_ raw: Substring) -> String {
        decodeEntities(String(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseAttributes(_ raw: Substring) -> [String: String] {
        var attrs: [String: String] = [:]
        for m in raw.matches(of: /\b([\w-]+)\s*=\s*"([^"]*)"/) {
            attrs[String(m.1)] = String(m.2)
        }
        return attrs
    }

    // MARK: - Text extraction (v1 crude: whole document, one utterance)

    private static func extractText(from html: String) -> String {
        let text = html
            .replacing(/(?is)<script\b[^>]*>.*?<\/script>/, with: "")
            .replacing(/(?is)<style\b[^>]*>.*?<\/style>/, with: "")
            .replacing(/<[^>]+>/, with: "")
        return normalize(decodeEntities(text))
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
