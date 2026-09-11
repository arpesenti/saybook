import AVFoundation
import Foundation
import XCTest
@testable import SaybookCore

/// Unit tests for the Book-identity boxes: `ilst` (title/artist/album) and
/// `covr` (cover image) inside `moov/udta/meta`.
///
/// Byte-layout reference (verified on this machine, ticket 03 research):
/// FFmpeg's mov muxer writes `moov/udta/meta { hdlr("mdir"), ilst { … } }`,
/// and that is the layout both `ffprobe` and `mdls` (Spotlight's
/// Audio.mdimporter) read title/artist/album from. Each tag box holds one
/// `data` box: `version(1)=0 · flags(3)=type · locale(4)=0 · payload`, where
/// type 1 = UTF-8 text and 13/14 = JPEG/PNG for `covr`. The encoder
/// (AVAssetExportSession) already writes `udta/meta { hdlr, ilst { ---- } }`,
/// so insertion must merge the tags into that existing `ilst`.
final class MetadataTests: XCTestCase {

    private let png: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    ]

    private let jpeg: [UInt8] = [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
    ]

    // MARK: - ilst round-trip

    func testInsertRoundTripsTitleArtistAlbum() throws {
        let out = try Metadata.insert(
            BookMetadata(title: "Book Title", artist: "Book Author", album: "Book Title"),
            into: syntheticEncoderM4B()
        )

        let parsed = Metadata.parseIlst(from: out)
        XCTAssertEqual(parsed?.title, "Book Title")
        XCTAssertEqual(parsed?.artist, "Book Author")
        XCTAssertEqual(parsed?.album, "Book Title")
    }

    func testEmptyArtistDegradesToUnknown() throws {
        let out = try Metadata.insert(
            BookMetadata(title: "Book Title", artist: "", album: "Book Title"),
            into: syntheticEncoderM4B()
        )
        XCTAssertEqual(Metadata.parseIlst(from: out)?.artist, "Unknown")
    }

    func testNonASCIITextSurvivesRoundTrip() throws {
        let out = try Metadata.insert(
            BookMetadata(title: "Tïtle & Ünïcode", artist: "Aúthor", album: "Àlbum"),
            into: syntheticEncoderM4B()
        )
        let parsed = Metadata.parseIlst(from: out)
        XCTAssertEqual(parsed?.title, "Tïtle & Ünïcode")
        XCTAssertEqual(parsed?.artist, "Aúthor")
        XCTAssertEqual(parsed?.album, "Àlbum")
    }

    // MARK: - covr

    func testInsertRoundTripsCovrWithPNGType() throws {
        let out = try Metadata.insert(
            BookMetadata(title: "T", artist: "A", album: "T", coverImageData: Data(png)),
            into: syntheticEncoderM4B()
        )
        XCTAssertEqual(Metadata.parseCovr(from: out), Data(png))

        // The `data` box's type lives in the flags: version 0 + flags 14 (PNG).
        let covr = covrBox(in: out)
        let payload: [UInt8] = Array(out[covr.lowerBound + 8..<covr.upperBound])
        XCTAssertEqual(bigEndianU32(payload, 0), UInt32(16 + png.count), "data box size")
        XCTAssertEqual(String(bytes: payload[4..<8], encoding: .isoLatin1), "data")
        XCTAssertEqual(Array(payload[8..<12]), [0x00, 0x00, 0x00, 0x0E], "type 14 = PNG")
        XCTAssertEqual(Array(payload[16..<(16 + png.count)]), png, "image bytes")
    }

    func testInsertRoundTripsCovrWithJPEGType() throws {
        let out = try Metadata.insert(
            BookMetadata(title: "T", artist: "A", album: "T", coverImageData: Data(jpeg)),
            into: syntheticEncoderM4B()
        )
        XCTAssertEqual(Metadata.parseCovr(from: out), Data(jpeg))
        let covr = covrBox(in: out)
        let payload: [UInt8] = Array(out[covr.lowerBound + 8..<covr.upperBound])
        XCTAssertEqual(Array(payload[8..<12]), [0x00, 0x00, 0x00, 0x0D], "type 13 = JPEG")
    }

    func testNoCoverWritesNoCovrBox() throws {
        let out = try Metadata.insert(
            BookMetadata(title: "T", artist: "A", album: "T"),
            into: syntheticEncoderM4B()
        )
        XCTAssertNil(Metadata.parseCovr(from: out))
    }

    // MARK: - Insertion placement

    /// An MP4-shaped file the way AVAssetExportSession emits one:
    /// `ftyp`, `mdat`, `moov { mvhd, udta { meta { hdlr, ilst { ---- } } } }`.
    private func syntheticEncoderM4B() -> Data {
        // A minimal `----` (iTunes extended) box with a UTF-8 `data` child,
        // the shape AVAssetExportSession writes into the encoder's ilst.
        let encoderData = u32Array(16 + 7)
            + Array("data".utf8) + u32Array(1) + u32Array(0) + Array("encoder".utf8)
        let encoderTag = u32Array(UInt32(8 + encoderData.count)) + Array("----".utf8) + encoderData
        let ilst: [UInt8] = u32Array(UInt32(8 + encoderTag.count)) + Array("ilst".utf8) + encoderTag
        let hdlr: [UInt8] = u32Array(33) + Array("hdlr".utf8)
            + u32Array(0) // version + flags
            + u32Array(0) // pre_defined
            + Array("mdir".utf8) + [UInt8](repeating: 0, count: 12) // reserved
            + [0x00] // empty handler name
        let meta: [UInt8] = u32Array(UInt32(8 + 4 + hdlr.count + ilst.count))
            + Array("meta".utf8) + u32Array(0) // meta is a FullBox
            + hdlr + ilst
        let udta: [UInt8] = u32Array(UInt32(8 + meta.count)) + Array("udta".utf8) + meta
        let mvhd: [UInt8] = u32Array(16) + Array("mvhd".utf8) + [UInt8](repeating: 0, count: 8)
        let moov: [UInt8] = u32Array(UInt32(8 + mvhd.count + udta.count)) + Array("moov".utf8) + mvhd + udta
        let ftyp: [UInt8] = u32Array(16) + Array("ftyp".utf8) + Array("M4A isom".utf8)
        let mdat: [UInt8] = u32Array(12) + Array("mdat".utf8) + [1, 2, 3, 4]
        return Data(ftyp + mdat + moov)
    }

    func testInsertMergesIntoExistingEncoderIlst() throws {
        let original = syntheticEncoderM4B()
        let out = try Metadata.insert(
            BookMetadata(title: "T", artist: "A", album: "B", coverImageData: Data(png)),
            into: original
        )

        // Top level: ftyp, mdat, moov — moov grew, nothing moved.
        let top = topLevelBoxes(out)
        XCTAssertEqual(top.map(\.type), ["ftyp", "mdat", "moov"])
        let moov = top[2]
        XCTAssertEqual(moov.range.upperBound, out.count)
        XCTAssertEqual(Array(out[..<moov.range.lowerBound]), Array(original[..<moov.range.lowerBound]))

        // moov: mvhd (untouched) + one udta.
        let moovChildren = topLevelBoxes(out, in: moov.range)
        XCTAssertEqual(moovChildren.map(\.type), ["mvhd", "udta"])

        // udta: exactly one meta.
        let udta = moovChildren[1]
        let udtaChildren = topLevelBoxes(out, in: udta.range)
        XCTAssertEqual(udtaChildren.map(\.type), ["meta"])

        // meta (FullBox): hdlr + one ilst.
        let meta = udtaChildren[0]
        let metaChildren = topLevelBoxes(out, in: (meta.range.lowerBound + 4)..<meta.range.upperBound)
        XCTAssertEqual(metaChildren.map(\.type), ["hdlr", "ilst"])
        let ilst = metaChildren[1]

        // The ilst keeps the encoder's box and gains the identity tags plus
        // the cover: ----, ©nam, ©ART, ©alb, covr.
        let ilstChildren = topLevelBoxes(out, in: ilst.range)
        XCTAssertEqual(ilstChildren.map(\.type), ["----", "©nam", "©ART", "©alb", "covr"])

        // The encoder's box is preserved byte-for-byte.
        let originalIlst = ilstBox(in: original)
        let encoderOriginal = topLevelBoxes(original, in: originalIlst).first { $0.type == "----" }!
        XCTAssertEqual(
            [UInt8](out[ilstChildren[0].range]),
            [UInt8](original[encoderOriginal.range]),
            "encoder box preserved"
        )
    }

    func testInsertCreatesUdtaMetaWhenAbsent() throws {
        // moov with only mvhd: no udta at all.
        let mvhd: [UInt8] = u32Array(16) + Array("mvhd".utf8) + [UInt8](repeating: 0, count: 8)
        let moov: [UInt8] = u32Array(UInt32(8 + mvhd.count)) + Array("moov".utf8) + mvhd
        let ftyp: [UInt8] = u32Array(16) + Array("ftyp".utf8) + Array("M4A isom".utf8)
        let data = Data(ftyp + moov)

        let out = try Metadata.insert(
            BookMetadata(title: "T", artist: "A", album: "B"),
            into: data
        )

        let top = topLevelBoxes(out)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov"])
        let moovChildren = topLevelBoxes(out, in: top[1].range)
        XCTAssertEqual(moovChildren.map(\.type), ["mvhd", "udta"])
        let udta = moovChildren[1]
        let udtaChildren = topLevelBoxes(out, in: udta.range)
        XCTAssertEqual(udtaChildren.map(\.type), ["meta"])
        // The fresh meta carries the mdir handler and the ilst.
        let meta = udtaChildren[0]
        let metaChildren = topLevelBoxes(out, in: (meta.range.lowerBound + 4)..<meta.range.upperBound)
        XCTAssertEqual(metaChildren.map(\.type), ["hdlr", "ilst"])
        XCTAssertEqual(Metadata.parseIlst(from: out)?.title, "T")
    }

    /// A `chpl` box after the encoder's `meta` inside `udta` (the layout
    /// that exists after Chapter Markers are inserted): merging into that
    /// `meta` would stretch `meta`/`ilst` over the `chpl` bytes, so a fresh
    /// `meta` must be appended instead.
    func testInsertAppendsFreshMetaWhenEncoderMetaIsNotLastInUdta() throws {
        let encoder = syntheticEncoderM4B() // …udta { meta { hdlr, ilst } }
        let chpl: [UInt8] = u32Array(24) + Array("chpl".utf8) + [UInt8](repeating: 0, count: 16)
        // Grow the udta and moov of the synthetic file to hold the chpl.
        let top = topLevelBoxes(encoder)
        let moov = top.last { $0.type == "moov" }!
        var bytes = [UInt8](encoder)
        let udta = topLevelBoxes(encoder, in: moov.range).last { $0.type == "udta" }!
        bytes.replaceSubrange(udta.range.lowerBound..<(udta.range.lowerBound + 4), with: u32Array(UInt32(udta.range.count + chpl.count)))
        bytes.replaceSubrange(moov.range.lowerBound..<(moov.range.lowerBound + 4), with: u32Array(UInt32(moov.range.count + chpl.count)))
        bytes += chpl
        let withChpl = Data(bytes)

        let out = try Metadata.insert(
            BookMetadata(title: "T", artist: "A", album: "B"),
            into: withChpl
        )

        // udta: the encoder's meta and chpl are preserved, and the fresh
        // meta is appended as udta's last child.
        let outTop = topLevelBoxes(out)
        let outMoov = outTop.last { $0.type == "moov" }!
        let outUdta = topLevelBoxes(out, in: outMoov.range).last { $0.type == "udta" }!
        let udtaChildren = topLevelBoxes(out, in: outUdta.range)
        XCTAssertEqual(udtaChildren.map(\.type), ["meta", "chpl", "meta"])

        // The encoder's meta and the chpl are byte-identical to the input.
        let inputUdtaChildren = topLevelBoxes(withChpl, in: topLevelBoxes(withChpl, in: topLevelBoxes(withChpl).last { $0.type == "moov" }!.range).last { $0.type == "udta" }!.range)
        XCTAssertEqual(
            [UInt8](out[udtaChildren[0].range]), [UInt8](withChpl[inputUdtaChildren[0].range]),
            "encoder meta untouched"
        )
        XCTAssertEqual(
            [UInt8](out[udtaChildren[1].range]), [UInt8](withChpl[inputUdtaChildren[1].range]),
            "chpl untouched"
        )

        // The identity is readable from the fresh meta (the last one).
        XCTAssertEqual(Metadata.parseIlst(from: out)?.title, "T")
        XCTAssertEqual(Metadata.parseIlst(from: out)?.artist, "A")
    }

    /// A box claiming a 64-bit size with a truncated extended-size field
    /// stops the box walk instead of trapping.
    func testBoxWalkStopsAtTruncated64BitSize() {
        let truncated: [UInt8] = u32Array(1) + Array("moov".utf8) + [0, 0, 0, 0]
        XCTAssertTrue(Mp4.topLevelBoxes(in: Data(truncated)).isEmpty, "truncated size must stop the walk")
    }

    func testInsertThrowsWhenMoovIsMissing() {
        let ftyp: [UInt8] = u32Array(16) + Array("ftyp".utf8) + Array("M4A isom".utf8)
        let mdat: [UInt8] = u32Array(12) + Array("mdat".utf8) + [1, 2, 3]
        XCTAssertThrowsError(try Metadata.insert(
            BookMetadata(title: "T", artist: "A", album: "B"),
            into: Data(ftyp + mdat)
        )) {
            XCTAssertEqual($0 as? Metadata.MetadataError, .noMoovBox)
        }
    }

    func testInsertThrowsWhenMoovIsNotLast() {
        let ftyp: [UInt8] = u32Array(16) + Array("ftyp".utf8) + Array("M4A isom".utf8)
        let moov: [UInt8] = u32Array(16) + Array("moov".utf8) + [UInt8](repeating: 0, count: 4)
        let mdat: [UInt8] = u32Array(12) + Array("mdat".utf8) + [1, 2, 3]
        XCTAssertThrowsError(try Metadata.insert(
            BookMetadata(title: "T", artist: "A", album: "B"),
            into: Data(ftyp + moov + mdat)
        )) {
            XCTAssertEqual($0 as? Metadata.MetadataError, .moovNotLast)
        }
    }

    // MARK: - Independent verification (ffprobe)

    /// Encodes real audio, writes the identity boxes, and asserts that
    /// FFmpeg's own mov demuxer reads back title/artist/album.
    func testFFProbeReadsInsertedMetadata() throws {
        guard let ffprobe = which("ffprobe") else { throw XCTSkip("ffprobe not available") }
        let dir = try makeTempDir()
        let caf = dir.appendingPathComponent("m.caf")
        try writeCAF(frames: 22_050, at: caf, sample: { _ in 0.1 })
        let m4a = dir.appendingPathComponent("m.m4a")
        try Encode.encodeCAF(from: caf, to: m4a)

        var data = try Data(contentsOf: m4a)
        data = try Brand.patchFTyp(in: data)
        data = try Metadata.insert(
            BookMetadata(title: "FF Title", artist: "FF Artist", album: "FF Album", coverImageData: Data(png)),
            into: data
        )
        let m4b = dir.appendingPathComponent("m.m4b")
        try data.write(to: m4b)

        let (exit, stdout, stderr) = try runTool(ffprobe, ["-v", "error", "-show_format", "-of", "json", m4b.path])
        XCTAssertEqual(exit, 0, "ffprobe: \(stderr)")
        let json = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as! [String: Any]
        let format = json["format"] as! [String: Any]
        let tags = format["tags"] as? [String: String] ?? [:]
        XCTAssertEqual(tags["title"], "FF Title")
        XCTAssertEqual(tags["artist"], "FF Artist")
        XCTAssertEqual(tags["album"], "FF Album")
    }

    // MARK: - Helpers (independent box walk — an independent re-implementation is the point)

    private struct Box {
        let range: Range<Int>
        let type: String
    }

    private func topLevelBoxes(_ data: Data, in parent: Range<Int>? = nil) -> [Box] {
        let (from, to) = parent.map { ($0.lowerBound + 8, $0.upperBound) } ?? (0, data.count)
        var o = from
        var boxes: [Box] = []
        while o + 8 <= to {
            let size = Int(bigEndianU32([UInt8](data[data.startIndex + o..<(data.startIndex + o + 8)]), 0))
            guard size >= 8, o + size <= to else { break }
            let type = String(bytes: data[(data.startIndex + o + 4)..<(data.startIndex + o + 8)], encoding: .isoLatin1) ?? "?"
            boxes.append(Box(range: o..<(o + size), type: type))
            o += size
        }
        return boxes
    }

    /// The `covr` box inside the file's `meta/ilst`.
    private func covrBox(in data: Data) -> Range<Int> {
        let moov = topLevelBoxes(data).first { $0.type == "moov" }!
        let udta = topLevelBoxes(data, in: moov.range).first { $0.type == "udta" }!
        let meta = topLevelBoxes(data, in: udta.range).first { $0.type == "meta" }!
        let ilst = topLevelBoxes(data, in: (meta.range.lowerBound + 4)..<meta.range.upperBound).first { $0.type == "ilst" }!
        return topLevelBoxes(data, in: ilst.range).first { $0.type == "covr" }!.range
    }

    /// The `ilst` box inside the file's `meta`.
    private func ilstBox(in data: Data) -> Range<Int> {
        let moov = topLevelBoxes(data).first { $0.type == "moov" }!
        let udta = topLevelBoxes(data, in: moov.range).first { $0.type == "udta" }!
        let meta = topLevelBoxes(data, in: udta.range).first { $0.type == "meta" }!
        return topLevelBoxes(data, in: (meta.range.lowerBound + 4)..<meta.range.upperBound).first { $0.type == "ilst" }!.range
    }
}
