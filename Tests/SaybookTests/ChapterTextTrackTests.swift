import AVFoundation
import Foundation
import XCTest
@testable import SaybookCore

/// Tests for the QuickTime chapter **text track** — the structure Apple's
/// players read Chapter Markers from (ticket 12).
///
/// The centre of gravity of this file is `testAVFoundationReadsChapters`: the
/// chapter assertions go through `AVURLAsset.loadChapterMetadataGroups`, the
/// entry point Books, VoiceOver and QuickTime use. That is deliberate. Ticket
/// 02's proof was `ffprobe` plus a round trip through saybook's own `parseChpl`,
/// and both encoded the same `chpl` assumption as the writer — so the suite
/// stayed green while Apple's players showed a chapterless Audiobook.
/// `ffprobe` stays useful (it is an independent reader of `chpl`) but can no
/// longer be the only proof.
///
/// The insertion tests edit **real encoder output** (`encodedBase`) rather than
/// hand-written MP4 bytes. Hand-rolling headers here produced three separate
/// test bugs that looked like module bugs — notably a 64-bit box size smaller
/// than its own 16-byte header, which desynchronises the entire box walk.
final class ChapterTextTrackTests: XCTestCase {

    private let sampleRate = Synthesis.sampleRate          // 22 050
    private let timescale = Synthesis.trackTimescale        // 22 050

    private var markers: [ChapterMarker] {
        [
            .init(sampleOffset: 0, title: "Chapter One"),
            .init(sampleOffset: 22_050, title: "Chapter Two"),
            .init(sampleOffset: 66_150, title: "ch3"),
        ]
    }

    // MARK: - Sample format

    func testSampleIsLengthTitleAndEncd() {
        let bytes = ChapterTextTrack.sample(for: "Dedication")
        XCTAssertEqual(Int(bigEndianU32(bytes, 0) >> 16), 10, "uint16 title length")
        XCTAssertEqual(String(bytes: bytes[2..<12], encoding: .utf8), "Dedication")
        XCTAssertEqual(bigEndianU32(bytes, 12), 12, "encd box size")
        XCTAssertEqual(String(bytes: bytes[16..<20], encoding: .isoLatin1), "encd")
        XCTAssertEqual(bigEndianU32(bytes, 20), 0x0000_0100, "encd declares UTF-8")
        XCTAssertEqual(bytes.count, 2 + 10 + 12)
    }

    func testSampleBlobConcatenatesOneSamplePerMarker() {
        let blob = ChapterTextTrack.sampleBlob(markers: markers)
        XCTAssertEqual(blob.count, markers.reduce(0) { $0 + ChapterTextTrack.sample(for: $1.title).count })
    }

    // MARK: - Durations and offsets

    func testChapterDurationsSpanTheWholeAudiobook() {
        let durations = ChapterTextTrack.stride(over: markers.map(\.sampleOffset), total: 100_000)
        // The last Chapter runs to the end, so the durations sum to the exact
        // frame count — that is what makes the final chapter's end land on the
        // end of the audio rather than short of it.
        XCTAssertEqual(durations, [22_050, 44_100, 100_000 - 66_150])
        XCTAssertEqual(durations.reduce(0, +), 100_000)
    }

    func testStrideOfEmptyMarkersIsEmpty() {
        XCTAssertEqual(ChapterTextTrack.stride(over: [], total: 100), [])
    }

    func testSampleOffsetsAreConsecutive() {
        XCTAssertEqual(ChapterTextTrack.offsets(from: 1000, sizes: [10, 20, 5]), [1000, 1010, 1030])
    }

    func testChapterTrackIDFollowsTheAudioTrackID() {
        XCTAssertEqual(ChapterTextTrack.chapterTrackID(audioTrackID: 1), 2)
        XCTAssertEqual(ChapterTextTrack.chapterTrackID(audioTrackID: 7), 8)
    }

    // MARK: - Insertion into real encoder output

    @MainActor
    func testInsertAddsChapterTrackAndTref() async throws {
        let data = try encodedBase(in: try makeTempDir())
        let out = try ChapterTextTrack.insert(markers: markers, trackTimescale: timescale, into: data)

        let top = topLevelBoxes(out)
        XCTAssertEqual(top.first?.type, "ftyp")
        XCTAssertEqual(top.map(\.type).filter { $0 == "mdat" }.count, 1)
        XCTAssertEqual(top.last?.type, "moov", "moov stays the last top-level box")

        let moov = try XCTUnwrap(top.last)
        let children = childBoxes(out, of: moov)
        XCTAssertEqual(children.map(\.type), ["mvhd", "trak", "udta", "trak"],
                       "the chapter trak is moov's last child, after udta")

        // The audio trak gained tref/chap after tkhd.
        let audio = children[1]
        let audioChildren = childBoxes(out, of: audio)
        XCTAssertEqual(audioChildren.map(\.type), ["tkhd", "tref", "mdia"])
        let tref = audioChildren[1]
        let chap = try XCTUnwrap(childBoxes(out, of: tref).first)
        XCTAssertEqual(chap.type, "chap")
        XCTAssertEqual(bigEndianU32(bytes(out, chap.offset + 8), 0), 2, "chap names the chapter track")

        // The chapter trak's shape, and the handler AVFoundation keys on.
        let chapter = children[3]
        XCTAssertEqual(childBoxes(out, of: chapter).map(\.type), ["tkhd", "edts", "mdia"])
        let mdia = try XCTUnwrap(findBox(in: out, named: "mdia", within: chapter))
        XCTAssertEqual(childBoxes(out, of: mdia).map(\.type), ["mdhd", "hdlr", "minf"])
        let hdlr = try XCTUnwrap(findBox(in: out, named: "hdlr", within: mdia))
        XCTAssertEqual(handler(of: out, hdlr: hdlr), "text",
                       "AVFoundation only reads chapters from a text-handler track")
        let minf = try XCTUnwrap(findBox(in: out, named: "minf", within: mdia))
        XCTAssertEqual(childBoxes(out, of: minf).map(\.type), ["gmhd", "dinf", "stbl"])
        let stbl = try XCTUnwrap(findBox(in: out, named: "stbl", within: minf))
        XCTAssertEqual(childBoxes(out, of: stbl).map(\.type), ["stsd", "stts", "stsc", "stsz", "stco"])

        let grown = data.count + ChapterTextTrack.sampleBlob(markers: markers).count
            + ChapterTextTrack.trefBox(chapterTrackID: 2).count + chapter.size
        XCTAssertEqual(out.count, grown, "nothing else was added or lost")
    }

    @MainActor
    func testInsertKeepsAudioBytesAndStcoValid() async throws {
        let data = try encodedBase(in: try makeTempDir())
        let out = try ChapterTextTrack.insert(markers: markers, trackTimescale: timescale, into: data)

        let mdatBefore = try XCTUnwrap(topLevelBoxes(data).first { $0.type == "mdat" })
        let mdatAfter = try XCTUnwrap(topLevelBoxes(out).first { $0.type == "mdat" })
        let header = headerSize(of: mdatBefore, in: data)

        // The audio payload is byte-identical and unmoved: only `mdat`'s SIZE
        // grew (the samples land at its tail), so the audio track's `stco`
        // offsets still address the audio, not the chapter text.
        let audioLength = mdatBefore.size - header
        XCTAssertEqual(
            [UInt8](out[(mdatAfter.offset + header)..<(mdatAfter.offset + header + audioLength)]),
            [UInt8](data[(mdatBefore.offset + header)..<(mdatBefore.offset + header + audioLength)]),
            "the audio bytes did not move"
        )
        XCTAssertEqual(mdatAfter.size, mdatBefore.size + ChapterTextTrack.sampleBlob(markers: markers).count,
                       "mdat covers exactly the old payload plus the samples")
    }

    @MainActor
    func testSampleTableAddressesTheAppendedSamples() async throws {
        let data = try encodedBase(in: try makeTempDir())
        let out = try ChapterTextTrack.insert(markers: markers, trackTimescale: timescale, into: data)
        let chapterTrak = try XCTUnwrap(trakBoxes(in: out).last)
        let stco = try XCTUnwrap(findBox(in: out, named: "stco", within: chapterTrak))
        XCTAssertEqual(Int(bigEndianU32(bytes(out, stco.offset + 12), 0)), markers.count)

        let mdat = try XCTUnwrap(topLevelBoxes(out).first { $0.type == "mdat" })
        let blob = ChapterTextTrack.sampleBlob(markers: markers)
        let stsz = try XCTUnwrap(findBox(in: out, named: "stsz", within: chapterTrak))
        var offset = Int(bigEndianU32(bytes(out, stco.offset + 16), 0))
        XCTAssertEqual(offset, mdat.offset + mdat.size - blob.count,
                       "the first sample starts where mdat's payload used to end")
        for (i, marker) in markers.enumerated() {
            let size = Int(bigEndianU32(bytes(out, stsz.offset + 20 + i * 4), 0))
            XCTAssertEqual([UInt8](out[offset..<(offset + size)]),
                           ChapterTextTrack.sample(for: marker.title), "sample \(i)")
            offset += size
        }
    }

    @MainActor
    func testChapterTrackDurationAndTimescaleMatchTheAudio() async throws {
        let data = try encodedBase(in: try makeTempDir())
        let out = try ChapterTextTrack.insert(markers: markers, trackTimescale: timescale, into: data)
        let traks = trakBoxes(in: out)
        XCTAssertEqual(traks.count, 2)
        let audioMDHD = try XCTUnwrap(findBox(in: out, named: "mdhd", within: traks[0]))
        let chapterMDHD = try XCTUnwrap(findBox(in: out, named: "mdhd", within: traks[1]))

        // Same timescale means a marker's sample offset is also its time in the
        // chapter track — no rounding anywhere.
        let header = headerSize(of: chapterMDHD, in: out)
        XCTAssertEqual(bigEndianU32(bytes(out, chapterMDHD.offset + header + 12), 0), UInt32(timescale))
        let audioHeader = headerSize(of: audioMDHD, in: out)
        XCTAssertEqual(bigEndianU32(bytes(out, chapterMDHD.offset + header + 12), 0),
                       bigEndianU32(bytes(out, audioMDHD.offset + audioHeader + 12), 0))
        XCTAssertEqual(bigEndianU32(bytes(out, chapterMDHD.offset + header + 16), 0),
                       bigEndianU32(bytes(out, audioMDHD.offset + audioHeader + 16), 0),
                       "the chapter track spans the whole Audiobook")
    }

    @MainActor
    func testEmptyMarkersProduceAWellFormedEmptyChapterTrack() async throws {
        let data = try encodedBase(in: try makeTempDir())
        let out = try ChapterTextTrack.insert(markers: [], trackTimescale: timescale, into: data)
        XCTAssertEqual(trakBoxes(in: out).count, 2, "the chapter trak still exists")
        let stsz = try XCTUnwrap(findBox(in: out, named: "stsz", within: try XCTUnwrap(trakBoxes(in: out).last)))
        XCTAssertEqual(bigEndianU32(bytes(out, stsz.offset + 16), 0), 0, "sample count")
        // Still a file AVFoundation can open, with no chapters to show.
        let chapters = try await avFoundationChapters(at: write(out, in: try makeTempDir()))
        XCTAssertEqual(chapters.count, 0)
    }

    func testInsertRefusesDataWithoutMoov() {
        XCTAssertThrowsError(
            try ChapterTextTrack.insert(markers: markers, trackTimescale: timescale, into: Data([0, 1, 2, 3]))
        ) { error in
            XCTAssertEqual(error as? ChapterTextTrack.ChapterTextTrackError, .noMoovBox)
        }
    }

    func testInsertRefusesMoovThatIsNotLast() {
        // Appending inside moov would shift the media data stco points at.
        let ftyp = box("ftyp", Array("M4B isom".utf8))
        let moov = box("moov", box("mvhd", [UInt8](repeating: 0, count: 8)))
        let mdat = box("mdat", [1, 2, 3, 4])
        XCTAssertThrowsError(
            try ChapterTextTrack.insert(markers: markers, trackTimescale: timescale, into: Data(ftyp + moov + mdat))
        ) { error in
            XCTAssertEqual(error as? ChapterTextTrack.ChapterTextTrackError, .moovNotLast)
        }
    }

    @MainActor
    func testInsertRefusesMoovWithoutAnAudioTrack() async throws {
        // A real mdat (so the refusal is about the missing track, not the media).
        let base = try encodedBase(in: try makeTempDir())
        let moov = try XCTUnwrap(topLevelBoxes(base).last)
        let traks = childBoxes(base, of: moov).filter { $0.type == "trak" }
        let audio = try XCTUnwrap(traks.first)
        // Rebuild moov without the trak.
        let without = [UInt8](base[(moov.offset + 8)..<(audio.offset)])
            + [UInt8](base[(audio.offset + audio.size)..<(moov.offset + moov.size)])
        var rebuilt = [UInt8](base[..<moov.offset])
        rebuilt += Mp4.u32(UInt32(8 + without.count)) + Array("moov".utf8) + without
        XCTAssertThrowsError(
            try ChapterTextTrack.insert(markers: markers, trackTimescale: timescale, into: Data(rebuilt))
        ) { error in
            XCTAssertEqual(error as? ChapterTextTrack.ChapterTextTrackError, .noAudioTrack)
        }
    }

    // MARK: - The consumer that matters: AVFoundation

    /// Encodes a real three-chapter Audiobook and asks AVFoundation for its
    /// chapters — the assertion `ffprobe` could never satisfy, because
    /// `ffprobe` happily read 12 chapters from a file Apple's players rendered
    /// as one long unlabelled track.
    @MainActor
    func testAVFoundationReadsChapters() async throws {
        let dir = try makeTempDir()
        let m4b = try encodeThreeChapterAudiobook(in: dir)
        let chapters = try await avFoundationChapters(at: m4b)
        XCTAssertEqual(chapters.count, 3, "one chapter per non-empty Chapter")

        // Starts are exact in the track's timescale; ends run to the next start.
        // The last chapter's end is the decoded length (frame count plus the
        // encoder's priming), so it is compared against the asset, not a
        // hand-computed number.
        let expected: [(title: String, start: Double, end: Double?)] = [
            ("Chapter One", 0.0, 1.0),
            ("Chapter Two", 1.0, 3.0),
            ("ch3", 3.0, nil),
        ]
        let duration = try await AVURLAsset(url: m4b).load(.duration).seconds
        for (i, want) in expected.enumerated() {
            XCTAssertEqual(chapters[i].title, want.title, "chapter \(i) title")
            XCTAssertEqual(chapters[i].start, want.start, accuracy: 0.02, "chapter \(i) start")
            if let end = want.end {
                XCTAssertEqual(chapters[i].end, end, accuracy: 0.02, "chapter \(i) end")
            }
        }
        XCTAssertEqual(chapters.last?.end ?? 0, duration, accuracy: 0.05, "last chapter reaches the end")
    }

    /// Without the text track AVFoundation sees nothing, whatever `chpl` says.
    /// This is the regression ticket 02's `chpl`-only assertions could not
    /// catch; it pins the reason this module exists.
    @MainActor
    func testAVFoundationSeesNoChaptersFromChplAlone() async throws {
        let dir = try makeTempDir()
        let m4b = try encodeThreeChapterAudiobook(in: dir, withTextTrack: false)

        // The marker the other readers use is definitely there…
        let written = try Data(contentsOf: m4b)
        XCTAssertNotNil(ChapterMarkers.parseChpl(from: written, trackTimescale: timescale))
        // …and Apple's player still shows no chapters.
        let chapters = try await avFoundationChapters(at: m4b)
        XCTAssertEqual(chapters.count, 0, "chpl alone must not satisfy AVFoundation")
    }

    /// The chapter samples are appended *inside* `mdat`, so the edit must not
    /// change what the audio track decodes to.
    @MainActor
    func testAudioStillDecodesAfterInsertion() async throws {
        let dir = try makeTempDir()
        let withTrack = try encodeThreeChapterAudiobook(in: dir, withTextTrack: true)
        let withoutTrack = try encodeThreeChapterAudiobook(in: dir, withTextTrack: false)

        let withDuration = try await AVURLAsset(url: withTrack).load(.duration).seconds
        let plainDuration = try await AVURLAsset(url: withoutTrack).load(.duration).seconds
        XCTAssertEqual(withDuration, plainDuration, accuracy: 0.001,
                       "adding the chapter track changed the audio duration")
        let tracks = try await AVURLAsset(url: withTrack).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1, "exactly one audio track")
        XCTAssertGreaterThan(withDuration, 3.5, "the audio still decodes to roughly its four seconds")
    }

    /// A chapter track whose edit list stops short is silently truncated by
    /// AVFoundation — a 4-second `elst` over a long Audiobook left exactly one
    /// group — so the edit list must cover the whole Audiobook.
    @MainActor
    func testChapterTrackEditListCoversTheWholeAudiobook() async throws {
        let dir = try makeTempDir()
        let m4b = try encodeThreeChapterAudiobook(in: dir)
        let data = try Data(contentsOf: m4b)
        let chapterTrak = try XCTUnwrap(trakBoxes(in: data).last)
        let elst = try XCTUnwrap(findBox(in: data, named: "elst", within: chapterTrak))
        let header = headerSize(of: elst, in: data)
        let segment = Int(bigEndianU32(bytes(data, elst.offset + header + 8), 0))
        let movie = try XCTUnwrap(findBox(in: data, named: "mvhd"))
        let movieHeader = headerSize(of: movie, in: data)
        XCTAssertEqual(segment, Int(bigEndianU32(bytes(data, movie.offset + movieHeader + 16), 0)),
                       "elst segment_duration equals the movie duration")
    }

    // MARK: - Golden fixed-shape boxes
    //
    // These are copied verbatim from the chapter text track of a real
    // Apple-produced M4B. They carry no per-Book value, so copying beats
    // re-deriving: the point is that Apple's parser accepts exactly these
    // bytes. Two checks, for two different failure modes.

    /// Self-consistency, which needs no external file and so always runs.
    /// Transcribing the table by hand is exactly where a dropped nibble hides:
    /// one such typo truncated `stsd` by four bytes and AVFoundation then read
    /// no chapters at all while every other box looked fine.
    func testGoldenBoxesAreSelfConsistent() {
        XCTAssertEqual(ChapterTextTrack.validateGoldens(), [], "a golden's size field disagrees with its length")
        for (kind, fourCC) in [(ChapterTextTrack.Golden.gmhd, "gmhd"),
                               (ChapterTextTrack.Golden.dinf, "dinf"),
                               (ChapterTextTrack.Golden.stsd, "stsd"),
                               (ChapterTextTrack.Golden.stsc, "stsc"),
                               (ChapterTextTrack.Golden.mdhd, "mdhd"),
                               (ChapterTextTrack.Golden.tkhd, "tkhd"),
                               (ChapterTextTrack.Golden.elst, "elst"),
                               (ChapterTextTrack.Golden.hdlr, "hdlr")] {
            let bytes = ChapterTextTrack.golden(kind)
            XCTAssertEqual(String(bytes: bytes[4..<8], encoding: .isoLatin1), fourCC)
        }
    }

    /// Where a reference M4B (any Apple-produced audiobook with chapters) can
    /// be found for the byte-for-byte check. Override with
    /// `SAYBOOK_CHAPTER_REFERENCE_M4B`; the test skips when it is absent.
    private var referenceM4B: URL? {
        guard let path = ProcessInfo.processInfo.environment["SAYBOOK_CHAPTER_REFERENCE_M4B"],
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    func testGoldenBoxesMatchAnAppleProducedM4B() throws {
        guard let reference = referenceM4B else {
            throw XCTSkip("no reference Apple M4B (set SAYBOOK_CHAPTER_REFERENCE_M4B)")
        }
        let data = try Data(contentsOf: reference, options: .mappedIfSafe)
        let chapterTrak = try XCTUnwrap(
            trakBoxes(in: data).first { trak in
                findBox(in: data, named: "hdlr", within: trak).map { handler(of: data, hdlr: $0) } == "text"
            },
            "the reference has no chapter text track"
        )
        for kind in ChapterTextTrack.Golden.allCases {
            let box = try XCTUnwrap(
                findBox(in: data, named: kind.rawValue, within: chapterTrak),
                "the reference has no \(kind.rawValue)"
            )
            XCTAssertEqual(
                [UInt8](data[(data.startIndex + box.offset)..<(data.startIndex + box.offset + box.size)]),
                ChapterTextTrack.golden(kind),
                "\(kind.rawValue) drifted from what Apple writes"
            )
        }
    }

    // MARK: - Fixtures

    /// A real `AVAssetExportSession` M4A with the M4B brand patched — the bytes
    /// the CLI actually edits.
    @MainActor
    private func encodedBase(in dir: URL) throws -> Data {
        let caf = dir.appendingPathComponent("base.caf")
        // Four seconds: long enough that every `markers` offset (the last at
        // 66 150 samples = 3 s) lies inside the audio. A marker past the end
        // makes its chapter duration negative, which is not a case the module
        // is meant to paper over — and it made these tests crash.
        try writeCAF(frames: Int(sampleRate) * 4, at: caf) { _ in 0.1 }
        let m4a = dir.appendingPathComponent("base.m4a")
        try Encode.encodeCAF(from: caf, to: m4a)
        return try Brand.patchFTyp(in: Data(contentsOf: m4a))
    }

    @MainActor
    private func write(_ data: Data, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("book.m4b")
        try data.write(to: url)
        return url
    }

    /// Encodes a real three-chapter Audiobook (1 s tone, 2 s silence, 1 s tone)
    /// through the same `Encode` path the CLI uses, then applies the marker
    /// edits in the CLI's order.
    @MainActor
    private func encodeThreeChapterAudiobook(in dir: URL, withTextTrack: Bool = true) throws -> URL {
        let framesPerSecond = Int(sampleRate)
        let caf = dir.appendingPathComponent("book-\(UUID().uuidString).caf")
        try writeCAF(frames: framesPerSecond * 4, at: caf) { i in
            (i / framesPerSecond) % 2 == 0 ? 0.2 : 0.0
        }
        let m4a = dir.appendingPathComponent("book-\(UUID().uuidString).m4a")
        try Encode.encodeCAF(from: caf, to: m4a)

        var data = try Data(contentsOf: m4a)
        data = try Brand.patchFTyp(in: data)
        data = try ChapterMarkers.insertChpl(markers: markers, trackTimescale: timescale, into: data)
        if withTextTrack {
            data = try ChapterTextTrack.insert(markers: markers, trackTimescale: timescale, into: data)
        }
        return try write(data, in: dir)
    }

    // MARK: - Box reading (an independent walk, deliberately not `Mp4`'s)

    private struct Box { let offset: Int; let size: Int; let type: String }

    private func bytes(_ data: Data, _ offset: Int) -> [UInt8] {
        [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + 4)])
    }

    private func topLevelBoxes(_ data: Data, from: Int? = nil, to: Int? = nil) -> [Box] {
        let end = to ?? data.count
        var o = from ?? 0
        var boxes: [Box] = []
        while o + 8 <= end {
            let size32 = bigEndianU32(bytes(data, o), 0)
            let type = String(
                bytes: data[(data.startIndex + o + 4)..<min(data.startIndex + o + 8, data.startIndex + end)],
                encoding: .isoLatin1
            ) ?? "?"
            guard size32 >= 1, size32 != 0 else { break }
            let size: Int
            if size32 == 1 {
                guard o + 16 <= end else { break }
                size = Int(bigEndianU64([UInt8](data[(data.startIndex + o + 8)..<(data.startIndex + o + 16)]), 0))
            } else {
                size = Int(size32)
            }
            guard size >= 8, o + size <= end else { break }
            boxes.append(Box(offset: o, size: size, type: type))
            o += size
        }
        return boxes
    }

    private func childBoxes(_ data: Data, of box: Box) -> [Box] {
        topLevelBoxes(data, from: box.offset + headerSize(of: box, in: data), to: box.offset + box.size)
    }

    /// 8 for the usual `size`/`type`, 16 when `size` is the 1 that means "a
    /// 64-bit size follows" — the test's own reading of it, so the walk stays
    /// independent of `Mp4`'s.
    private func headerSize(of box: Box, in data: Data) -> Int {
        bigEndianU32(bytes(data, box.offset), 0) == 1 ? 16 : 8
    }

    /// Box types that actually contain child boxes. Parsing a leaf's payload
    /// as a box stream is a bug, not a curiosity: inside `stsd`'s `mp4a` entry
    /// an arbitrary run of bytes can read as size==1 followed by eight bytes
    /// larger than `Int.max`, and `Int(…)` traps on that. Only these descend.
    private static let containerTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "udta", "meta", "ilst",
    ]

    /// The first box named `name`, breadth-first from `within` (or the top
    /// level) downward, descending only into known containers. The seed is a
    /// real list of boxes rather than a synthetic root: a root `Box` would be
    /// asked for its own header size, and starting the walk eight bytes into
    /// the file reads the whole layout as noise.
    private func findBox(in data: Data, named name: String, within: Box? = nil) -> Box? {
        var queue = within.map { childBoxes(data, of: $0) } ?? topLevelBoxes(data)
        while let head = queue.first {
            queue.removeFirst()
            if head.type == name { return head }
            if Self.containerTypes.contains(head.type) { queue.append(contentsOf: childBoxes(data, of: head)) }
        }
        return nil
    }

    private func trakBoxes(in data: Data) -> [Box] {
        guard let moov = topLevelBoxes(data).last(where: { $0.type == "moov" }) else { return [] }
        return childBoxes(data, of: moov).filter { $0.type == "trak" }
    }

    /// The handler fourCC of an `hdlr` box (past size/type/version+flags/pre_defined).
    private func handler(of data: Data, hdlr: Box) -> String {
        let start = data.startIndex + hdlr.offset + 8 + 8
        return String(bytes: data[start..<(start + 4)], encoding: .isoLatin1) ?? "?"
    }

    // MARK: - Byte building for the refusal fixtures

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        u32Array(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }
}
