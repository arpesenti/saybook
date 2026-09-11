import AVFoundation
import Foundation

/// A speech **Voice** (the voice used for synthesis): one of the voices
/// installed on the machine, carrying the identity that selection and the
/// progress line need.
///
/// A pure value type: the selection logic runs over `[Voice]` with no engine
/// dependence, and `VoiceCatalog` is the only place where a catalog entry is
/// resolved back to the engine's `AVSpeechSynthesisVoice`.
public struct Voice: Equatable {
    /// The engine's identifier (e.g. `com.apple.voice.compact.en-US.Samantha`).
    public let identifier: String
    /// The display name `say -v ?` lists (e.g. "Samantha", "Bad News").
    public let name: String
    /// The BCP-47 language tag (e.g. "en-US").
    public let language: String
    /// The quality tier: premium > enhanced > default.
    public let quality: VoiceQuality
}

/// The quality tiers the engine reports per voice, in ascending order.
/// The auto-selection picks the highest tier installed for the language.
public enum VoiceQuality: Int {
    case `default` = 0
    case enhanced = 1
    case premium = 2

    /// The human-readable tier in the progress line ("premium", …).
    var label: String {
        switch self {
        case .default: return "default"
        case .enhanced: return "enhanced"
        case .premium: return "premium"
        }
    }
}

extension VoiceQuality: Comparable {
    public static func < (lhs: VoiceQuality, rhs: VoiceQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Voice selection: pure functions over a `[Voice]` catalog.
///
/// - `best(forLanguage:in:)` picks the highest-quality voice for a language
///   tag: an exact-tag match (case-insensitive) wins over same-language
///   matches (primary subtag — "pt" in "pt-BR"), and within the matched set
///   the premium > enhanced > default ordering wins; ties break to catalog
///   order. No match means no installed voice for the language (the run
///   must fail, never fall back to another language).
/// - `named(_:in:)` resolves an explicit `--voice` reference: the voice's
///   identifier or display name as listed by `say -v ?`, exact first and
///   case-insensitive second; the first catalog match wins.
public enum VoiceSelection {

    public static func best(forLanguage language: String, in voices: [Voice]) -> Voice? {
        let tag = language.lowercased()
        if let exact = bestQuality(of: voices.filter { $0.language.lowercased() == tag }) {
            return exact
        }
        guard let primary = tag.split(separator: "-").first.map(String.init) else { return nil }
        let sameLanguage = voices.filter {
            $0.language.lowercased().split(separator: "-").first.map(String.init) == primary
        }
        return bestQuality(of: sameLanguage)
    }

    public static func named(_ reference: String, in voices: [Voice]) -> Voice? {
        guard !reference.isEmpty else { return nil }
        for voice in voices where voice.identifier == reference || voice.name == reference {
            return voice
        }
        let lower = reference.lowercased()
        for voice in voices where voice.identifier.lowercased() == lower || voice.name.lowercased() == lower {
            return voice
        }
        return nil
    }

    /// The highest-quality voice of `candidates`, the first one in catalog
    /// order on ties (strictly-greater scan).
    private static func bestQuality(of candidates: [Voice]) -> Voice? {
        var best: Voice?
        for candidate in candidates where best == nil || candidate.quality > best!.quality {
            best = candidate
        }
        return best
    }
}

/// The installed-voice catalog: the adapter between the engine's
/// `AVSpeechSynthesisVoice` list and the `Voice` value type selection runs on.
public enum VoiceCatalog {

    /// Every installed voice, in engine order.
    public static func installed() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices().map {
            Voice(
                identifier: $0.identifier,
                name: $0.name,
                language: $0.language,
                quality: VoiceQuality(rawValue: $0.quality.rawValue) ?? .default
            )
        }
    }

    /// The engine voice a catalog entry resolves to. The catalog is
    /// snapshotted per run, so this only fails if a voice is uninstalled
    /// mid-run.
    public static func speechVoice(for voice: Voice) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().first { $0.identifier == voice.identifier }
    }
}
