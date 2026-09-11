import Foundation

/// A Book's identity as MP4 metadata: the title, the artist (the Book's
/// author), the album (the Book's title again — M4B convention), and the
/// cover image when the Book declares one.
public struct BookMetadata: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let album: String
    public let coverImageData: Data?

    public init(title: String, artist: String, album: String, coverImageData: Data? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.coverImageData = coverImageData
    }

    /// The identity of `book`: title as `©nam` and `©alb` (M4B convention),
    /// author as `©ART` (degraded to "Unknown" at box-write time when
    /// empty), and the cover image when the Book declares one.
    public init(book: Book) {
        self.init(
            title: book.title,
            artist: book.author,
            album: book.title,
            coverImageData: book.cover.imageData
        )
    }
}

/// The Book's identity as MP4 boxes: a `meta` box carrying an `ilst` of
/// `©nam` (title), `©ART` (artist) and `©alb` (album) tags plus a `covr` box
/// holding the cover image when present.
///
/// Layout reference (verified on this machine, ticket 03 research): the tree
/// is `moov/udta/meta { hdlr, ilst }` — FFmpeg's mov muxer writes exactly
/// this, and both `ffprobe` and `mdls` (Spotlight's Audio.mdimporter) read
/// title/artist/album from it; a bare `udta/ilst` without the `meta`
/// wrapper is what `mdls` ignores. Each tag box wraps one `data` box:
/// `version(1)=0 · flags(3)=type · locale(4)=0 · payload`, where type 1 is
/// UTF-8 text and 13/14 are JPEG/PNG inside `covr` (its conventional
/// placement, per the M4B cover-art convention). The encoder
/// (AVAssetExportSession) already writes `udta/meta { hdlr, ilst { … } }`,
/// so insertion merges the tags into that existing `ilst` rather than
/// writing a second one.
public enum Metadata {

    public enum MetadataError: Error, Equatable {
        /// No `moov` box was found (the data is not an MP4/M4B file).
        case noMoovBox
        /// `moov` is not the last top-level box; inserting would shift the
        /// media data the `stco` sample offsets point at.
        case moovNotLast
    }

    /// The parsed `ilst` identity: a `nil` whole means no `meta/ilst` was
    /// found; individual fields are `nil` when their tag is absent.
    public struct IlstMetadata: Sendable, Equatable {
        public let title: String?
        public let artist: String?
        public let album: String?

        public init(title: String?, artist: String?, album: String?) {
            self.title = title
            self.artist = artist
            self.album = album
        }
    }

    // MARK: - Building

    /// Builds the `meta` box (`hdlr` + `ilst`) for `metadata`. An empty
    /// artist degrades to "Unknown" rather than an empty box.
    static func box(for metadata: BookMetadata) -> Data {
        let hdlr = hdlrBox()
        let ilst = container("ilst", ilstTags(for: metadata))
        return container("meta", Mp4.u32(0) + hdlr + ilst) // meta is a FullBox
    }

    /// Inserts the Book's identity into the file's `moov/udta`, merging the
    /// tags into the encoder's existing `meta/ilst` when present and creating
    /// a fresh `meta { hdlr, ilst }` otherwise. Appends at the end of `moov`'
    /// last `udta` (which must be `moov`'s last child, as of
    /// AVAssetExportSession output) so the media data never moves.
    ///
    /// Merging grows `ilst`/`meta`/`udta` to span the bytes appended at the
    /// file end, so it is only safe when `meta` is `udta`'s last child and
    /// `ilst` is `meta`'s last child (true of AVAssetExportSession output);
    /// any other layout appends a fresh `meta` instead of stretching ranges
    /// over sibling boxes.
    public static func insert(_ metadata: BookMetadata, into data: Data) throws -> Data {
        let moov: Mp4.Box
        do {
            moov = try Mp4.trailingMoov(in: data)
        } catch let error as Mp4.Mp4Error {
            throw error == .noMoovBox ? MetadataError.noMoovBox : MetadataError.moovNotLast
        }

        guard let udta = Mp4.trailingUdta(in: moov, of: data) else {
            // No trailing udta: append a fresh one holding a fresh meta.
            return try Mp4.appendToMoovUdta(box(for: metadata), into: data)
        }

        var out = [UInt8](data)
        func growBox(_ range: Range<Int>, by amount: Int) {
            Mp4.setU32(&out, at: range.lowerBound, UInt32(range.count + amount))
        }
        // Appends `bytes` after the current end of moov and grows every
        // enclosing box (always udta and moov; meta/ilst when merging in).
        func append(_ bytes: Data, alsoGrowing boxes: [Range<Int>] = []) {
            for box in boxes { growBox(box, by: bytes.count) }
            growBox(udta.range, by: bytes.count)
            growBox(moov.range, by: bytes.count)
            out.append(contentsOf: bytes)
        }

        let udtaChildren = Mp4.topLevelBoxes(in: data, udta.range)
        // The meta/ilst pair that is last in both containers (the merge-safe
        // shape), when present.
        var mergeMeta: Range<Int>?
        var mergeIlst: Range<Int>?
        if let lastMeta = udtaChildren.last(where: { $0.type == "meta" }),
           lastMeta.range.upperBound == udta.range.upperBound {
            mergeMeta = lastMeta.range
            // meta is a FullBox: children start after its 4-byte header.
            let metaChildren = Mp4.topLevelBoxes(in: data, (lastMeta.range.lowerBound + 4)..<lastMeta.range.upperBound)
            if let lastIlst = metaChildren.last(where: { $0.type == "ilst" }),
               lastIlst.range.upperBound == lastMeta.range.upperBound {
                mergeIlst = lastIlst.range
            }
        }

        if let ilst = mergeIlst, let meta = mergeMeta {
            // Merge into the encoder's existing ilst: the grown ranges cover
            // only the new bytes.
            append(Data(ilstTags(for: metadata)), alsoGrowing: [ilst, meta])
        } else if let meta = mergeMeta {
            // meta without a trailing ilst: append a fresh one as its last
            // child.
            append(container("ilst", ilstTags(for: metadata)), alsoGrowing: [meta])
        } else {
            // No mergeable meta: append a fresh one (hdlr + ilst) as udta's
            // last child.
            append(box(for: metadata))
        }
        return Data(out)
    }

    /// The `©nam`/`©ART`/`©alb` tag boxes plus the `covr` box (when a cover
    /// image is present): the children appended to an `ilst`.
    private static func ilstTags(for metadata: BookMetadata) -> [UInt8] {
        var tags: [UInt8] = []
        tags += tagBox(Tag4CC.title, metadata.title)
        tags += tagBox(Tag4CC.artist, artistLabel(for: metadata))
        tags += tagBox(Tag4CC.album, metadata.album)
        if let cover = metadata.coverImageData {
            tags += covrBox(cover)
        }
        return tags
    }

    /// The `ilst` tag 4CCs, defined once as byte arrays — the first byte is
    /// the copyright sign (0xA9), which is *not* the UTF-8 encoding of "©".
    /// The parser compares against the iso-latin1 spelling derived from the
    /// same bytes.
    private enum Tag4CC {
        static let title: [UInt8] = [0xA9, 0x6E, 0x61, 0x6D]
        static let artist: [UInt8] = [0xA9, 0x41, 0x52, 0x54]
        static let album: [UInt8] = [0xA9, 0x61, 0x6C, 0x62]

        static func isoLatin1(_ bytes: [UInt8]) -> String {
            String(bytes: bytes, encoding: .isoLatin1) ?? ""
        }
    }

    private static func artistLabel(for metadata: BookMetadata) -> String {
        metadata.artist.isEmpty ? "Unknown" : metadata.artist
    }

    /// A 4CC tag box wrapping one `data` box (UTF-8 text).
    private static func tagBox(_ fourCC: [UInt8], _ text: String) -> [UInt8] {
        let dataBox = dataBox(type: 1, payload: Array(text.utf8))
        return Mp4.u32(UInt32(8 + dataBox.count)) + fourCC + dataBox
    }

    /// The `covr` box: the raw image bytes in a `data` box typed 13 (JPEG)
    /// or 14 (PNG) by magic bytes.
    private static func covrBox(_ image: Data) -> [UInt8] {
        let dataBox = dataBox(type: dataBoxType(of: image), payload: [UInt8](image))
        return Mp4.u32(UInt32(8 + dataBox.count)) + Array("covr".utf8) + dataBox
    }

    /// A `data` box: `version(1)=0 · flags(3)=type · locale(4)=0 · payload`
    /// (the type lives in the flags, per the ISO 14496-12 `data` atom).
    private static func dataBox(type: UInt32, payload: [UInt8]) -> [UInt8] {
        Mp4.u32(UInt32(16 + payload.count)) + Array("data".utf8) + Mp4.u32(type) + Mp4.u32(0) + payload
    }

    /// The canonical `mdir` metadata handler, layout-compatible with the
    /// one AVAssetExportSession writes: pre_defined + handler type + 12
    /// reserved zero bytes + an empty (one null byte) handler name.
    private static func hdlrBox() -> [UInt8] {
        Mp4.u32(33) + Array("hdlr".utf8)
            + Mp4.u32(0) // version + flags
            + Mp4.u32(0) // pre_defined
            + Array("mdir".utf8)
            + [UInt8](repeating: 0, count: 12) // reserved
            + [0x00] // empty handler name
    }

    /// The `data` box's type code for `image`: 13 (JPEG) for JPEG magic
    /// bytes, 14 (PNG) for the PNG signature, 13 otherwise (JPEG is the
    /// dominant M4B cover type).
    private static func dataBoxType(of image: Data) -> UInt32 {
        let b = [UInt8](image)
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return 13 }
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if b.count >= png.count, Array(b.prefix(png.count)) == png { return 14 }
        return 13
    }

    private static func container(_ type: String, _ payload: [UInt8]) -> Data {
        Data(Mp4.u32(UInt32(8 + payload.count)) + Array(type.utf8) + payload)
    }

    // MARK: - Parsing

    /// Parses the `©nam`/`©ART`/`©alb` tags out of the file's
    /// `moov/udta/meta/ilst`. Returns nil when the file carries no
    /// well-formed `meta/ilst`.
    public static func parseIlst(from data: Data) -> IlstMetadata? {
        guard let ilst = ilstBox(in: data) else { return nil }
        var title: String?
        var artist: String?
        var album: String?
        for tag in Mp4.topLevelBoxes(in: data, ilst) {
            guard let text = textPayload(in: data, tag.range) else { continue }
            switch tag.type {
            case Tag4CC.isoLatin1(Tag4CC.title): title = text
            case Tag4CC.isoLatin1(Tag4CC.artist): artist = text
            case Tag4CC.isoLatin1(Tag4CC.album): album = text
            default: break
            }
        }
        return IlstMetadata(title: title, artist: artist, album: album)
    }

    /// Parses the cover image bytes out of the file's
    /// `moov/udta/meta/ilst/covr`. Returns nil when the file carries no
    /// `covr` box.
    public static func parseCovr(from data: Data) -> Data? {
        guard let ilst = ilstBox(in: data) else { return nil }
        for covr in Mp4.topLevelBoxes(in: data, ilst) where covr.type == "covr" {
            guard let (_, payload) = rawPayload(in: data, covr.range) else { return nil }
            return payload
        }
        return nil
    }

    /// The `meta/ilst` box of the file, or nil.
    private static func ilstBox(in data: Data) -> Range<Int>? {
        guard let moov = Mp4.topLevelBoxes(in: data).last(where: { $0.type == "moov" }) else { return nil }
        guard let udta = Mp4.topLevelBoxes(in: data, moov.range).last(where: { $0.type == "udta" }) else { return nil }
        guard let meta = Mp4.topLevelBoxes(in: data, udta.range).last(where: { $0.type == "meta" }) else { return nil }
        // meta is a FullBox: children start after its 4-byte header.
        return Mp4.topLevelBoxes(in: data, (meta.range.lowerBound + 4)..<meta.range.upperBound)
            .last { $0.type == "ilst" }?
            .range
    }

    /// A tag box's `data` child decoded as UTF-8 text (type 1).
    private static func textPayload(in data: Data, _ tagRange: Range<Int>) -> String? {
        guard let (type, payload) = rawPayload(in: data, tagRange), type == 1,
              let text = String(bytes: payload, encoding: .utf8)
        else { return nil }
        return text
    }

    /// The `data` child of the box at `range`: its type (from the flags) and
    /// payload.
    private static func rawPayload(in data: Data, _ range: Range<Int>) -> (UInt32, Data)? {
        guard let child = Mp4.topLevelBoxes(in: data, range).first(where: { $0.type == "data" }),
              child.range.count >= 16
        else { return nil }
        let base = data.startIndex + child.range.lowerBound
        let versionAndFlags = (UInt32(data[base + 8]) << 24)
            | (UInt32(data[base + 9]) << 16)
            | (UInt32(data[base + 10]) << 8)
            | UInt32(data[base + 11])
        // The type occupies the low 24 bits (the high byte is the version).
        let type = versionAndFlags & 0x00_FF_FF
        let payloadStart = child.range.lowerBound + 16
        guard payloadStart <= child.range.upperBound else { return nil }
        return (type, Data(data[(base + 16)..<child.range.upperBound]))
    }
}
