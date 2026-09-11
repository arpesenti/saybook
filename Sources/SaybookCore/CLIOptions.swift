import Foundation

/// The parsed command line:
/// `saybook <book.epub> [-o OUT.m4b] [--voice NAME] [--rate 0.0–1.0] [--language LL] [--keep-scratch] [--force]`.
public struct CLIOptions: Equatable {
    /// The input Book's path.
    public let inputPath: String
    /// An explicit `-o` output path; nil writes `<InputBase>.m4b` beside the input.
    public let outputPath: String?
    /// An explicit `--voice` reference (a voice identifier or display name
    /// as listed by `say -v ?`); nil auto-selects the best installed voice.
    public let voice: String?
    /// The utterance **Rate** on Apple's 0–1 scale, passed through to the
    /// utterance unchanged.
    public let rate: Double
    /// A `--language` override for voice selection; nil uses the Book's OPF
    /// language.
    public let language: String?
    /// Replace an existing output file (`--force`); without it an existing
    /// output is refused (exit 1).
    public let force: Bool
    /// Keep Scratch after a successful run (`--keep-scratch`).
    public let keepScratch: Bool

    /// The Rate the engine speaks at when no `--rate` is given: Apple's
    /// utterance default and the spec default.
    public static let defaultRate: Double = 0.5
}

/// A user error in the command line (exit 1): readable messages, never a
/// crash.
public enum CLIOptionsError: Error, Equatable {
    /// No (or more than one) positional argument.
    case usage
    /// An option outside v1's flag set (e.g. `--loudness`).
    case unknownOption(String)
    /// A value flag given without a value.
    case missingValue(for: String)
    /// `--rate` is not a number.
    case invalidRate(String)
    /// `--rate` is a number outside 0.0–1.0.
    case outOfRangeRate(String)
}

public extension CLIOptions {

    /// Parses `arguments` into options; throws `CLIOptionsError` (a user
    /// error, exit 1) on anything malformed.
    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var inputPath: String?
        var outputPath: String?
        var voice: String?
        var rate = CLIOptions.defaultRate
        var language: String?
        var force = false
        var keepScratch = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--voice", "--rate", "--language", "-o":
                index += 1
                guard index < arguments.count else {
                    throw CLIOptionsError.missingValue(for: arg)
                }
                // --rate takes its value unconditionally: a negative number
                // is an out-of-range rate worth reporting as such. The
                // other three reject flag-like values (voice names and
                // output paths never start with `-`).
                let flagLike = arguments[index].hasPrefix("-")
                if arg != "--rate", flagLike {
                    throw CLIOptionsError.missingValue(for: arg)
                }
                let value = arguments[index]
                switch arg {
                case "--voice":
                    voice = value
                case "--language":
                    language = value
                case "-o":
                    outputPath = value
                case "--rate":
                    guard let parsed = Double(value) else { throw CLIOptionsError.invalidRate(value) }
                    guard (0.0...1.0).contains(parsed) else { throw CLIOptionsError.outOfRangeRate(value) }
                    rate = parsed
                default:
                    break
                }
            case "--force":
                force = true
            case "--keep-scratch":
                keepScratch = true
            case let arg where arg.hasPrefix("-"):
                throw CLIOptionsError.unknownOption(arg)
            default:
                guard inputPath == nil else { throw CLIOptionsError.usage }
                inputPath = arg
            }
            index += 1
        }
        guard let inputPath else { throw CLIOptionsError.usage }
        return CLIOptions(
            inputPath: inputPath,
            outputPath: outputPath,
            voice: voice,
            rate: rate,
            language: language,
            force: force,
            keepScratch: keepScratch
        )
    }
}
