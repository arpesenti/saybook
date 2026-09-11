import Foundation
import XCTest
@testable import SaybookCore

final class EpubTests: XCTestCase {

    func testLoadSingleChapterFixture() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("single-chapter.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "One Chapter Book")
        XCTAssertEqual(book.author, "Test Author")
        XCTAssertEqual(book.language, "en")
        XCTAssertEqual(book.chapters.count, 1)
        // Title falls back to the document's largest heading (ticket 02).
        XCTAssertEqual(book.chapters[0].title, "Chapter One")
        XCTAssertEqual(
            book.chapters[0].text,
            "Chapter One Chapter One The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs."
        )
    }

    func testLoadThreeChapterFixtureTitles() throws {
        let scratch = try makeTempDir()
        let book = try Epub.load(
            bookAt: fixturesDir.appendingPathComponent("three-chapter.epub"),
            scratch: scratch
        )

        XCTAssertEqual(book.title, "Three Chapter Book")
        XCTAssertEqual(book.chapters.count, 3)
        // Title fallback: largest heading → largest heading → filename.
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter One", "Chapter Two", "ch3"])
        XCTAssertTrue(book.chapters.allSatisfy { !$0.text.isEmpty })
        // ch1 is deliberately short (resume/kill tests kill it mid-ch2/ch3);
        // ch2 and ch3 are long so the kill window is wide.
        XCTAssertGreaterThan(book.chapters[1].text.split(separator: " ").count, 150)
        XCTAssertGreaterThan(book.chapters[2].text.split(separator: " ").count, 100)
        XCTAssertLessThan(book.chapters[0].text.split(separator: " ").count, 30)
    }

    func testLoadRejectsFileThatIsNotAZip() throws {
        let dir = try makeTempDir()
        let fake = dir.appendingPathComponent("fake.epub")
        try "this is not an epub".data(using: .utf8)!.write(to: fake)

        XCTAssertThrowsError(try Epub.load(bookAt: fake, scratch: dir.appendingPathComponent("scratch"))) {
            XCTAssertEqual($0 as? Epub.EpubError, .notAValidEpub)
        }
    }

    func testLoadRejectsZipWithoutContainer() throws {
        let dir = try makeTempDir()
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "junk".data(using: .utf8)!.write(to: src.appendingPathComponent("junk.txt"))
        let archive = dir.appendingPathComponent("junk.epub")
        try zip(paths: [src.appendingPathComponent("junk.txt")], into: archive, cwd: src)

        XCTAssertThrowsError(try Epub.load(bookAt: archive, scratch: dir.appendingPathComponent("scratch"))) {
            XCTAssertEqual($0 as? Epub.EpubError, .notAValidEpub)
        }
    }
}
