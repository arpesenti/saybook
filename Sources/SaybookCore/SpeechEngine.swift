import AVFoundation
import Foundation

/// The speech **Engine** a run renders with.
///
/// Both engines are offline, dependency-free and system-provided (ADR 0001's
/// premise), and both honour the same format contract: `render` writes a CAF
/// at `Synthesis.cafSettings`, so everything downstream — concatenation,
/// Chapter Markers, the M4A export — is engine-independent.
///
/// `apple` is the public engine (`AVSpeechSynthesizer`) and the default.
/// `siri` is Apple's on-device neural voice reached only through private API
/// (`SiriSynthesis`); it is opt-in and unsupported, so it must never be
/// reachable by accident: `--engine siri` says it out loud in the run header.
public enum SpeechEngine: String, CaseIterable, Sendable {

    /// Apple's public speech engine: the `com.apple.voice.*` voices that
    /// `say -v ?` and `AVSpeechSynthesisVoice.speechVoices()` list.
    case apple

    /// Apple's private on-device Siri neural voices (ADR 0003).
    case siri

    /// The engine named by `--engine`; nil for anything else.
    public static func named(_ reference: String) -> SpeechEngine? {
        SpeechEngine(rawValue: reference.lowercased())
    }

    /// The voices this engine offers: what `--voice` and `--language` select
    /// over. Re-enumerated per call, like the Apple catalog.
    public func voices() -> [Voice] {
        switch self {
        case .apple: return VoiceCatalog.installed()
        case .siri: return SiriVoiceCatalog.installed()
        }
    }

    /// Where to look for this engine's voices, for the "no voice" messages.
    /// For the Siri engine this doubles as the discovery route: the private
    /// engine has no `say -v ?` equivalent, so the names come back here.
    public var voiceHint: String {
        switch self {
        case .apple:
            return "see `say -v ?` for installed voices"
        case .siri:
            let installed = SiriVoiceCatalog.installed().map(\.name)
            return installed.isEmpty
                ? "no Siri voice bundle is installed on this Mac — macOS downloads them "
                    + "itself, into \(SiriVoiceCatalog.assetsRoot)"
                : "installed Siri voices: \(installed.joined(separator: ", "))"
        }
    }

    /// Fails when `voice` cannot be rendered by this engine. Called once
    /// before any chapter work, so an unusable engine or a voice uninstalled
    /// between selection and synthesis is a fast, plain error (exit 1).
    public func validate(_ voice: Voice) throws {
        switch self {
        case .apple:
            guard VoiceCatalog.speechVoice(for: voice) != nil else {
                throw SaybookError(message: "Voice \"\(voice.name)\" is no longer installed")
            }
        case .siri:
            do {
                try SiriSynthesis.validate(voice: voice)
            } catch let error as SiriSynthesis.SiriError {
                let message = SiriSynthesis.message(of: error)
                throw SaybookError(
                    message: "Siri engine unavailable for voice \"\(voice.name)\": \(message) "
                        + "(the Apple engine needs no such setup — drop --engine to use it)"
                )
            }
        }
    }

    /// Renders one Block's text and writes it to `cafURL` as a CAF at
    /// `Synthesis.cafSettings`. `rate` is Apple's 0–1 utterance scale and
    /// only the Apple engine can honour it (`--engine siri` rejects `--rate`).
    @MainActor
    public func render(text: String, voice: Voice, rate: Double, to cafURL: URL) throws {
        switch self {
        case .apple:
            guard let speechVoice = VoiceCatalog.speechVoice(for: voice) else {
                throw Synthesis.SynthesisError.failed("voice \"\(voice.name)\" is no longer installed")
            }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = speechVoice
            utterance.rate = Float(rate)
            try Synthesis.render(utterance: utterance, to: cafURL)
        case .siri:
            try SiriSynthesis.render(text: text, voice: voice, to: cafURL)
        }
    }
}
