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
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { $0 })
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
}
