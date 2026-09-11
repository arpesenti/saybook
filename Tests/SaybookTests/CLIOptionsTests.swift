import Foundation
import XCTest
@testable import SaybookCore

/// Ticket 04: `--voice`, `--rate`, `--language` flag parsing.
///
/// Seam under test: `CLIOptions.parse(_:)` — the CLI's public surface for
/// turning arguments into validated options (unknown flags and bad rates are
/// user errors, exit 1).
final class CLIOptionsTests: XCTestCase {

    func testDefaultsWhenOnlyTheBookIsGiven() throws {
        let options = try CLIOptions.parse(["book.epub"])
        XCTAssertEqual(options.inputPath, "book.epub")
        XCTAssertNil(options.voice)
        XCTAssertEqual(options.rate, 0.5, "the spec default is 0.5")
        XCTAssertNil(options.language)
    }

    func testFlagsInAnyOrder() throws {
        let options = try CLIOptions.parse([
            "--rate", "0.8", "--voice", "Alex", "book.epub", "--language", "fr-FR",
        ])
        XCTAssertEqual(options.inputPath, "book.epub")
        XCTAssertEqual(options.voice, "Alex")
        XCTAssertEqual(options.rate, 0.8)
        XCTAssertEqual(options.language, "fr-FR")
    }

    func testRateBindsToItsValue() throws {
        XCTAssertEqual(try CLIOptions.parse(["book.epub", "--rate", "0"]).rate, 0.0)
        XCTAssertEqual(try CLIOptions.parse(["book.epub", "--rate", "1"]).rate, 1.0)
        XCTAssertEqual(try CLIOptions.parse(["book.epub", "--rate", "0.25"]).rate, 0.25)
    }

    func testMissingArgumentIsUsage() {
        XCTAssertThrowsError(try CLIOptions.parse([])) {
            XCTAssertEqual($0 as? CLIOptionsError, .usage)
        }
    }

    func testTwoPositionalsAreUsage() {
        XCTAssertThrowsError(try CLIOptions.parse(["a.epub", "b.epub"])) {
            XCTAssertEqual($0 as? CLIOptionsError, .usage)
        }
    }

    func testFlagWithoutValueIsMissingValue() {
        for (flag, value) in ["--voice": "voice", "--language": "language"] {
            XCTAssertThrowsError(try CLIOptions.parse(["book.epub", flag])) {
                XCTAssertEqual($0 as? CLIOptionsError, .missingValue(for: value))
            }
            // A flag-like argument is not consumed as the value.
            XCTAssertThrowsError(try CLIOptions.parse(["book.epub", flag, "--rate", "0.5"])) {
                XCTAssertEqual($0 as? CLIOptionsError, .missingValue(for: value))
            }
        }
        // --rate has no value at all when it ends the arguments.
        XCTAssertThrowsError(try CLIOptions.parse(["book.epub", "--rate"])) {
            XCTAssertEqual($0 as? CLIOptionsError, .missingValue(for: "rate"))
        }
        // …but a flag-looking value is still taken: a negative rate is an
        // out-of-range rate, reported as such.
        XCTAssertThrowsError(try CLIOptions.parse(["book.epub", "--rate", "--voice"])) {
            XCTAssertEqual($0 as? CLIOptionsError, .invalidRate("--voice"))
        }
    }

    func testNonNumericRateIsInvalidRate() {
        XCTAssertThrowsError(try CLIOptions.parse(["book.epub", "--rate", "abc"])) {
            XCTAssertEqual($0 as? CLIOptionsError, .invalidRate("abc"))
        }
    }

    func testOutOfRangeRateIsRejected() {
        for value in ["1.01", "2", "-0.1", "-1"] {
            XCTAssertThrowsError(try CLIOptions.parse(["book.epub", "--rate", value])) {
                XCTAssertEqual($0 as? CLIOptionsError, .outOfRangeRate(value))
            }
        }
    }

    func testUnknownFlagIsRejected() {
        // v1 has no --force/--keep-scratch/-o (ticket 06 and friends):
        // they are unknown flags until then.
        for flag in ["--force", "--keep-scratch", "-o"] {
            XCTAssertThrowsError(try CLIOptions.parse(["book.epub", flag])) {
                XCTAssertEqual($0 as? CLIOptionsError, .unknownOption(flag))
            }
        }
    }
}
