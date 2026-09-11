import AVFoundation
import Foundation
import XCTest
@testable import SaybookCore

final class BrandTests: XCTestCase {

    /// A minimal M4A: ftyp (major "M4A ", minor 1, compat "mp42" "isom") + an mdat box.
    private func makeM4A() -> Data {
        var ftyp = Data()
        appendU32(&ftyp, 24) // size: 8 + 4 major + 4 minor + 8 compat
        ftyp.append(contentsOf: Array("ftyp".utf8))
        ftyp.append(contentsOf: Array("M4A ".utf8))
        appendU32(&ftyp, 1) // minor version
        ftyp.append(contentsOf: Array("mp42".utf8))
        ftyp.append(contentsOf: Array("isom".utf8))

        var mdat = Data()
        appendU32(&mdat, 16) // size: 8 + 8 payload
        mdat.append(contentsOf: Array("mdat".utf8))
        mdat.append(contentsOf: [0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0x22, 0x33])

        return ftyp + mdat
    }

    private func appendU32(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }

    func testPatchRewritesMajorAndCompatibleBrands() throws {
        let patched = try Brand.patchFTyp(in: makeM4A())

        // Exact leading 28 bytes: size, "ftyp", major "M4B ", compat "m4b " "mp42" "isom",
        // minor version 0 (byte layout mirrors Apple's own `say -o x.m4b`, see prototype probe).
        var expected = Data()
        appendU32(&expected, 28)
        expected.append(contentsOf: Array("ftyp".utf8))
        expected.append(contentsOf: Array("M4B m4b mp42isom".utf8))
        appendU32(&expected, 0)
        XCTAssertEqual(Array(patched[..<28]), Array(expected))
    }

    func testPatchPreservesEverythingAfterFtyp() throws {
        let original = makeM4A()
        let patched = try Brand.patchFTyp(in: original)

        // Old ftyp was 24 bytes, new one is 28: the mdat box must follow untouched.
        let originalTail = Array(original[24...])
        XCTAssertEqual(Array(patched[28...]), originalTail)
        XCTAssertEqual(patched.count, original.count + 4)
    }

    func testPatchedDataIsRecognisableAsM4B() throws {
        let patched = try Brand.patchFTyp(in: makeM4A())
        XCTAssertEqual(String(data: patched[8..<12], encoding: .isoLatin1), "M4B ")
        XCTAssertEqual(String(data: patched[12..<24], encoding: .isoLatin1), "m4b mp42isom")
    }

    func testPatchRejectsFileWithoutLeadingFtypBox() {
        var garbage = Data()
        appendU32(&garbage, 16)
        garbage.append(contentsOf: Array("mdat".utf8))
        garbage.append(contentsOf: [0, 0, 0, 0, 0])
        XCTAssertThrowsError(try Brand.patchFTyp(in: garbage)) { error in
            XCTAssertEqual(error as? Brand.BrandError, .missingFtypBox)
        }
    }

    func testPatchRejectsTruncatedInput() {
        XCTAssertThrowsError(try Brand.patchFTyp(in: Data([0x00, 0x00, 0x00, 0x10]))) { error in
            XCTAssertEqual(error as? Brand.BrandError, .missingFtypBox)
        }
    }

    // MARK: - Round trip (ticket 07): the patched file still decodes and
    // reports the M4B brand

    /// The exact 28-byte patched `ftyp` as an independent literal. Deliberately
    /// not built with a shared byte helper: a helper that shares the code
    /// under test would hide the same defect it is meant to assert against
    /// (this is how the dangling-buffer `appendU32` bug from ticket 07
    /// slipped through — the production patch and the test expectation both
    /// wrote the same stack garbage, so the byte equality held by accident).
    private static let expectedPatchedFtyp: [UInt8] = [
        0x00, 0x00, 0x00, 28, // size
        0x66, 0x74, 0x79, 0x70, // "ftyp"
        0x4D, 0x34, 0x42, 0x20, // "M4B "
        0x6D, 0x34, 0x62, 0x20, // "m4b "
        0x6D, 0x70, 0x34, 0x32, // "mp42"
        0x69, 0x73, 0x6F, 0x6D, // "isom"
        0x00, 0x00, 0x00, 0x00, // minor version
    ]

    func testPatchedFtypLeadingBytesMatchTheIndependentLiteral() throws {
        let patched = try Brand.patchFTyp(in: makeM4A())
        XCTAssertEqual(Array(patched[0..<28]), Self.expectedPatchedFtyp)
    }

    /// The round trip the ticket names: a real export-preset M4A, patched,
    /// written to disk — still decodes as audio (AVFoundation reads its full
    /// length) and reports the M4B brand (its own `ftyp` and the system's
    /// `afinfo` format reader both say M4B).
    func testPatchedFileStillDecodesAndReportsM4BBrand() throws {
        let dir = try makeTempDir()
        let frames = 44_100 // 2 s at 22.05 kHz
        let caf = dir.appendingPathComponent("rt.caf")
        try writeCAF(frames: frames, at: caf) { _ in 0.1 }
        let m4a = dir.appendingPathComponent("rt.m4a")
        try Encode.encodeCAF(from: caf, to: m4a)
        let patched = try Brand.patchFTyp(in: try Data(contentsOf: m4a))
        let m4b = dir.appendingPathComponent("rt.m4b")
        try patched.write(to: m4b)

        // Still decodes: AVFoundation opens the M4B and reports the format
        // and (approximately) the full decoded length (AAC priming and the
        // final partial packet add slack).
        let file = try AVAudioFile(forReading: m4b)
        XCTAssertEqual(file.processingFormat.sampleRate, 22050)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let length = Int(file.length)
        XCTAssertTrue(length >= frames && length <= frames + 4096, "decoded length \(length) for \(frames) frames")

        // Reports the M4B brand: the file on disk carries the intact ftyp
        // (size field included — the field the dangling-buffer bug clobbered).
        let onDisk = try Data(contentsOf: m4b)
        XCTAssertEqual(Array(onDisk[0..<28]), Self.expectedPatchedFtyp)

        // The system's own format reader agrees: afinfo reports the M4B
        // file type ID ("m4bf").
        guard let afinfo = which("afinfo") else { throw XCTSkip("afinfo not available") }
        let (exit, stdout, stderr) = try runTool(afinfo, [m4b.path])
        XCTAssertEqual(exit, 0, "afinfo: \(stderr)")
        XCTAssertTrue(stdout.contains("m4bf"), stdout)
    }
}
