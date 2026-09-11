import AVFoundation
import Foundation
import XCTest
@testable import SaybookCore

/// Unit tests for the `chpl` Chapter Marker box: offset math, byte layout,
/// insertion, and parsing. Layout reference: the `chpl` atom as written by
/// FFmpeg's mov muxer and found in real M4B audiobooks (see the ticket 02
/// comment for the research trail).
final class ChapterMarkersTests: XCTestCase {

    private let markers: [ChapterMarker] = [
        .init(sampleOffset: 0, title: "Chapter One"),
        .init(sampleOffset: 22_050, title: "Chapter Two"),
        .init(sampleOffset: 66_150, title: "ch3"),
    ]

    // MARK: - Offset math

    func testStartOffsetsAreCumulativeFrameCounts() {
        XCTAssertEqual(ChapterMarkers.startOffsets(frameCounts: [11_025, 22_050, 33_075]), [0, 11_025, 33_075])
    }

    func testStartOffsetsSingleChapter() {
        XCTAssertEqual(ChapterMarkers.startOffsets(frameCounts: [22_050]), [0])
    }

    func testStartOffsetsEmpty() {
        XCTAssertEqual(ChapterMarkers.startOffsets(frameCounts: []), [])
    }

    // MARK: - Byte layout

    func testBoxByteLayout() {
        let box = ChapterMarkers.box(markers: markers, trackTimescale: 22_050)

        // 8 header + 9 (ver+flags+reserved+count) + 3 × (8 + 1 + title)
        let titleBytes: [Int] = ["Chapter One".utf8.count, "Chapter Two".utf8.count, "ch3".utf8.count]
        let contentLength = 9 + 3 * (9) + titleBytes.reduce(0, +)
        XCTAssertEqual(box.count, 8 + contentLength)

        let b = [UInt8](box)
        XCTAssertEqual(bigEndianU32(b, 0), UInt32(box.count), "box size field")
        XCTAssertEqual(String(bytes: b[4..<8], encoding: .isoLatin1), "chpl")
        XCTAssertEqual(b[8], 0x01, "version 1")
        XCTAssertEqual(Array(b[9..<12]), [0, 0, 0], "flags")
        XCTAssertEqual(Array(b[12..<16]), [0, 0, 0, 0], "reserved")
        XCTAssertEqual(b[16], 3, "chapter count")

        // Chapter 2 starts at 22 050 samples of 22 050 Hz = exactly 1 s =
        // 10 000 000 units of 100 ns.
        XCTAssertEqual(bigEndianU64(b, 17), 0, "chapter 1 offset")
        XCTAssertEqual(bigEndianU64(b, 17 + 9 + titleBytes[0]), 10_000_000, "chapter 2 offset in 100 ns")
        XCTAssertEqual(bigEndianU64(b, 17 + (9 + titleBytes[0]) + (9 + titleBytes[1])), 3 * 10_000_000, "chapter 3 offset")

        // Titles are raw UTF-8, one length byte each, no padding or null.
        let lenPos = 17 + 8
        XCTAssertEqual(b[lenPos], UInt8(titleBytes[0]))
        XCTAssertEqual(String(bytes: b[(lenPos + 1)..<(lenPos + 1 + titleBytes[0])], encoding: .utf8), "Chapter One")
    }

    // MARK: - Insertion

    /// A minimal MP4-shaped file: `ftyp`, `mdat` (64-bit size, as produced by
    /// AVAssetExportSession), then `moov` with one fake child.
    private func syntheticM4B() -> Data {
        let ftyp: [UInt8] = u32Array(16) + Array("ftyp".utf8) + Array("M4A isom".utf8)
        XCTAssertEqual(ftyp.count, 16)
        let mdat: [UInt8] = u32Array(1) + Array("mdat".utf8) + u64Array(20) + [1, 2, 3, 4]
        let child: [UInt8] = u32Array(16) + Array("mvhd".utf8) + [UInt8](repeating: 0, count: 8)
        let moov: [UInt8] = u32Array(UInt32(8 + child.count)) + Array("moov".utf8) + child
        return Data(ftyp + mdat + moov)
    }

    func testInsertAppendsUdtaInsideMoovAndGrowsMoov() throws {
        let box = ChapterMarkers.box(markers: markers, trackTimescale: 22_050)
        let data = syntheticM4B()

        let out = try ChapterMarkers.insert(box: box, into: data)

        // Top-level walk: ftyp, mdat, moov (grown by the udta size).
        let boxes = topLevelBoxes(out)
        XCTAssertEqual(boxes.map(\.type), ["ftyp", "mdat", "moov"])
        let udtaSize = 8 + box.count
        XCTAssertEqual(boxes[2].size, 8 + 16 + udtaSize, "moov grew by exactly the udta box")

        // moov children: mvhd (untouched), then udta containing chpl.
        let moovOff = boxes[2].offset
        let moovChildren = topLevelBoxes(out, from: moovOff + 8, to: moovOff + boxes[2].size)
        XCTAssertEqual(moovChildren.map(\.type), ["mvhd", "udta"])
        let udtaOff = moovChildren[1].offset
        let chplChildren = topLevelBoxes(out, from: udtaOff + 8, to: udtaOff + moovChildren[1].size)
        XCTAssertEqual(chplChildren.map(\.type), ["chpl"])
        XCTAssertEqual([UInt8](out[chplChildren[0].offset..<chplChildren[0].offset + box.count]), [UInt8](box))

        // Every byte before moov is preserved.
        XCTAssertEqual(Array(out[..<moovOff]), Array(data[..<moovOff]))
    }

    func testInsertMergesIntoExistingUdta() throws {
        // A moov that already ends in a udta (AVAssetExportSession writes
        // one with encoder metadata) must absorb the chpl box into THAT
        // udta — not grow a second udta (single-udta-per-moov convention of
        // Apple's own M4Bs).
        let ftyp: [UInt8] = u32Array(16) + Array("ftyp".utf8) + Array("M4A isom".utf8)
        let mdat: [UInt8] = u32Array(12) + Array("mdat".utf8) + [1, 2, 3, 4]
        let mvhd: [UInt8] = u32Array(16) + Array("mvhd".utf8) + [UInt8](repeating: 0, count: 8)
        let encoderMeta: [UInt8] = u32Array(12) + Array("meta".utf8) + [UInt8](repeating: 5, count: 4)
        let udta: [UInt8] = u32Array(UInt32(8 + encoderMeta.count)) + Array("udta".utf8) + encoderMeta
        let moov: [UInt8] = u32Array(UInt32(8 + mvhd.count + udta.count)) + Array("moov".utf8) + mvhd + udta
        let data = Data(ftyp + mdat + moov)

        let box = ChapterMarkers.box(markers: markers, trackTimescale: 22_050)
        let out = try ChapterMarkers.insert(box: box, into: data)

        // Top-level unchanged: ftyp, mdat, moov — grown by exactly the chpl.
        let boxes = topLevelBoxes(out)
        XCTAssertEqual(boxes.map(\.type), ["ftyp", "mdat", "moov"])
        let moovOff = boxes[2].offset
        XCTAssertEqual(boxes[2].size, 8 + mvhd.count + udta.count + box.count, "moov grew by exactly the chpl")

        // moov children: mvhd, udta — one udta, at its original offset.
        let moovChildren = topLevelBoxes(out, from: moovOff + 8, to: moovOff + boxes[2].size)
        XCTAssertEqual(moovChildren.map(\.type), ["mvhd", "udta"], "no second udta")
        let udtaOff = moovChildren[1].offset
        XCTAssertEqual(udtaOff, ftyp.count + mdat.count + 8 + mvhd.count, "the same udta, in place")
        XCTAssertEqual(moovChildren[1].size, 8 + encoderMeta.count + box.count, "udta grew by the chpl")

        // The udta's children: the encoder box, then chpl.
        let udtaChildren = topLevelBoxes(out, from: udtaOff + 8, to: udtaOff + moovChildren[1].size)
        XCTAssertEqual(udtaChildren.map(\.type), ["meta", "chpl"])
        XCTAssertEqual([UInt8](out[udtaChildren[1].offset..<udtaChildren[1].offset + box.count]), [UInt8](box))

        // Every byte except the two size fields I grew is preserved:
        // everything before moov, and the mvhd region between moov's header
        // and the udta.
        XCTAssertEqual(Array(out[..<moovOff]), Array(data[..<moovOff]))
        XCTAssertEqual(Array(out[(moovOff + 8)..<udtaOff]), Array(data[(moovOff + 8)..<udtaOff]))
    }

    func testInsertThrowsWhenMoovIsMissing() {
        let data: [UInt8] = u32Array(16) + Array("ftyp".utf8) + Array("M4A isom".utf8)
        XCTAssertThrowsError(try ChapterMarkers.insert(box: ChapterMarkers.box(markers: markers, trackTimescale: 22_050), into: Data(data))) {
            XCTAssertEqual($0 as? ChapterMarkers.ChapterMarkerError, .noMoovBox)
        }
    }

    func testInsertThrowsWhenMoovIsNotLast() {
        // moov first, mdat after: appending would shift the samples moov's
        // stco points at.
        let ftyp: [UInt8] = u32Array(16) + Array("ftyp".utf8) + Array("M4A isom".utf8)
        let moov: [UInt8] = u32Array(16) + Array("moov".utf8) + [UInt8](repeating: 0, count: 4)
        let mdat: [UInt8] = u32Array(12) + Array("mdat".utf8) + [UInt8](repeating: 7, count: 4)
        XCTAssertThrowsError(try ChapterMarkers.insert(box: ChapterMarkers.box(markers: markers, trackTimescale: 22_050), into: Data(ftyp + moov + mdat))) {
            XCTAssertEqual($0 as? ChapterMarkers.ChapterMarkerError, .moovNotLast)
        }
    }

    // MARK: - Parsing (round-trip)

    func testParseChplRoundTripsThroughInsertion() throws {
        let data = try ChapterMarkers.insertChpl(markers: markers, trackTimescale: 22_050, into: syntheticM4B())
        let parsed = ChapterMarkers.parseChpl(from: data, trackTimescale: 22_050)
        XCTAssertEqual(parsed, markers, "parse(insert(box)) == markers")
    }

    func testParseChplReturnsNilWithoutChplBox() {
        XCTAssertNil(ChapterMarkers.parseChpl(from: syntheticM4B(), trackTimescale: 22_050))
    }

    // MARK: - Independent verification (ffprobe)

    /// Builds a real M4A with known chapter boundaries, inserts markers, and
    /// asserts that FFmpeg's own mov demuxer reads back the same chapters.
    func testFFProbeReadsInsertedChapters() throws {
        guard let ffprobe = which("ffprobe") else { throw XCTSkip("ffprobe not available") }
        let dir = try makeTempDir()
        let frames = 44_100 // 2 s at 22 050 Hz
        let caf = dir.appendingPathComponent("p.caf")
        try writeCAF(frames: frames, at: caf, sample: { _ in 0.1 })
        let m4a = dir.appendingPathComponent("p.m4a")
        try Encode.encodeCAF(from: caf, to: m4a)
        var data = try Data(contentsOf: m4a)
        data = try Brand.patchFTyp(in: data)

        let realMarkers = [
            ChapterMarker(sampleOffset: 0, title: "Alpha"),
            ChapterMarker(sampleOffset: 11_025, title: "Beta"),
            ChapterMarker(sampleOffset: 22_050, title: "Gamma"),
        ]
        let out = try ChapterMarkers.insertChpl(markers: realMarkers, trackTimescale: 22_050, into: data)
        let m4b = dir.appendingPathComponent("p.m4b")
        try out.write(to: m4b)

        let (exit, stdout, stderr) = try runTool(ffprobe, ["-v", "error", "-show_chapters", "-of", "json", m4b.path])
        XCTAssertEqual(exit, 0, "ffprobe: \(stderr)")
        let json = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as! [String: Any]
        let chapters = json["chapters"] as! [[String: Any]]
        XCTAssertEqual(chapters.count, 3)
        for (i, marker) in realMarkers.enumerated() {
            let title = chapters[i]["tags"] as? [String: Any]
            XCTAssertEqual(title?["title"] as? String, marker.title)
            let start = Double(chapters[i]["start_time"] as! String) ?? 0
            let expected = Double(marker.sampleOffset) / 22_050
            XCTAssertEqual(start, expected, accuracy: 0.001, "ffprobe chapter \(i) start")
        }
    }

    // MARK: - Helpers

    private struct Box {
        let offset: Int
        let size: Int
        let type: String
    }

    /// Walks top-level MP4 boxes (handling 64-bit sizes); within `from..<to`
    /// when scanning a container's children.
    private func topLevelBoxes(_ data: Data, from: Int? = nil, to: Int? = nil) -> [Box] {
        let base = data.startIndex
        let end = to ?? data.count
        var o = from ?? 0
        var boxes: [Box] = []
        while o + 8 <= end {
            let size32 = u32(data, o)
            let type = String(bytes: data[(base + o + 4)..<min(base + o + 8, end)], encoding: .isoLatin1) ?? "?"
            let size: Int
            if size32 == 1 {
                size = Int(u64(data, o + 8))
            } else {
                size = Int(size32)
            }
            guard size >= 8, o + size <= end else { break }
            boxes.append(Box(offset: o, size: size, type: type))
            o += size
        }
        return boxes
    }

    private func u32(_ data: Data, _ off: Int) -> UInt32 {
        let b = data.startIndex + off
        return (UInt32(data[b]) << 24) | (UInt32(data[b + 1]) << 16) | (UInt32(data[b + 2]) << 8) | UInt32(data[b + 3])
    }

    private func u64(_ data: Data, _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(data[data.startIndex + off + k]) }
        return v
    }
}

// MARK: - Byte helpers (shared by test files that hand-roll MP4 bytes)

func u32Array(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
func u64Array(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }

func bigEndianU32(_ b: [UInt8], _ off: Int) -> UInt32 {
    (UInt32(b[off]) << 24) | (UInt32(b[off + 1]) << 16) | (UInt32(b[off + 2]) << 8) | UInt32(b[off + 3])
}

func bigEndianU64(_ b: [UInt8], _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    for k in 0..<8 { v = (v << 8) | UInt64(b[off + k]) }
    return v
}

/// Runs an executable, returning its exit status and captured output.
func runTool(_ path: String, _ args: [String]) throws -> (exit: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: out, encoding: .utf8) ?? "", String(data: err, encoding: .utf8) ?? "")
}

/// `which(1)` for a tool on PATH.
func which(_ name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
    } catch { return nil }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(data: out, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (process.terminationStatus == 0 && path?.isEmpty == false) ? path : nil
}
