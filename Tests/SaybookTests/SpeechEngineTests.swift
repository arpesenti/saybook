import AVFoundation
import Foundation
import XCTest
@testable import SaybookCore

/// The speech **Engine** seam: which voices each engine offers, how an
/// unusable engine reports itself, and what the private Siri engine can and
/// cannot do on the machine running the tests.
///
/// The Siri engine is private API whose voice bundles macOS delivers on its
/// own schedule, so the tests that need a real voice bundle skip when the
/// machine has none (that is the honest state of a machine, not a failure).
final class SpeechEngineTests: XCTestCase {

    private func voice(
        _ identifier: String, _ name: String, _ language: String, _ quality: VoiceQuality = .premium
    ) -> Voice {
        Voice(identifier: identifier, name: name, language: language, quality: quality)
    }

    // MARK: - Engine naming

    func testEngineNamesAreCaseInsensitiveAndClosed() {
        XCTAssertEqual(SpeechEngine.named("siri"), .siri)
        XCTAssertEqual(SpeechEngine.named("Apple"), .apple)
        XCTAssertNil(SpeechEngine.named("eleven"))
        XCTAssertNil(SpeechEngine.named(""))
    }

    // MARK: - Catalogs

    func testAppleCatalogNeverOffersSiriVoices() {
        // The two catalogs are disjoint: the Siri voices are not registered
        // with the public voice database, so an Apple-engine run can never
        // pick one by accident (and vice versa).
        XCTAssertTrue(SpeechEngine.apple.voices().allSatisfy { !$0.identifier.hasPrefix("siri:") })
        XCTAssertTrue(SpeechEngine.siri.voices().allSatisfy { $0.identifier.hasPrefix("siri:") })
    }

    func testSiriVoicesRemainSelectableByDisplayName() {
        // `--voice martha` must resolve the same way it does for the Apple
        // engine, because the catalog feeds the same selection logic.
        let siri = SpeechEngine.siri.voices()
        guard let first = siri.first else { return }
        XCTAssertEqual(VoiceSelection.named(first.name, in: siri)?.identifier, first.identifier)
        XCTAssertEqual(
            VoiceSelection.named(first.name.lowercased(), in: siri)?.identifier, first.identifier
        )
    }

    func testSiriVoiceHintNamesTheVoicesThatExist() {
        // There is no `say -v ?` for a private engine, so the "unknown voice"
        // error is where a user discovers what may be passed to --voice.
        let hint = SpeechEngine.siri.voiceHint
        XCTAssertTrue(hint.lowercased().contains("siri"), hint)
        let installed = SpeechEngine.siri.voices().map(\.name)
        if installed.isEmpty {
            XCTAssertTrue(hint.contains(SiriVoiceCatalog.assetsRoot), hint)
        } else {
            for name in installed {
                XCTAssertTrue(hint.contains(name), "hint must name \(name): \(hint)")
            }
        }
    }

    // MARK: - Voice bundle parsing (the machine-independent part)

    func testVoiceBundleDescribesNameLanguageAndTier() {
        let bundle: [String: Any] = [
            "MobileAssetProperties": [
                "Name": "martha",
                "LanguagesCompatibility": ["en_GB"],
                "Footprint": "premium",
            ]
        ]
        let described = SiriVoiceCatalog.describe(bundle, directory: "/tmp/voice")
        XCTAssertEqual(described?.name, "Martha")
        XCTAssertEqual(described?.language, "en-GB", "MobileAsset uses underscores in language tags")
        XCTAssertEqual(described?.quality, .premium)
        XCTAssertEqual(described?.identifier, "siri:martha@en-GB")
    }

    func testVoiceBundleFallsBackToBundleNameAndLowestTier() {
        let described = SiriVoiceCatalog.describe(["CFBundleName": "arthur_5173"], directory: "/tmp/voice")
        XCTAssertEqual(described?.name, "Arthur", "the version suffix is stripped")
        XCTAssertEqual(described?.language, "und", "an unknown language is never guessed")
        XCTAssertEqual(described?.quality, .default)
    }

    func testVoiceBundleWithoutANameIsRejected() {
        XCTAssertNil(SiriVoiceCatalog.describe(["CFBundleName": "5173"], directory: "/tmp/voice"))
        XCTAssertNil(SiriVoiceCatalog.describe(nil, directory: "/tmp/voice"))
        XCTAssertNil(SiriVoiceCatalog.describe([:], directory: "/tmp/voice"))
    }

    func testSiriCatalogOnlyListsBundlesTheEngineCanLoad() throws {
        // A voice is listed only when its bundle carries the engine's
        // pipeline description; resources-only assets in the same directory
        // are not voices.
        let installed = SiriVoiceCatalog.installed()
        for entry in installed {
            let directory = try XCTUnwrap(SiriVoiceCatalog.assetDirectory(for: entry))
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directory + "/" + SiriVoiceCatalog.voiceMarker),
                "\(directory) is not a voice bundle"
            )
        }
    }

    // MARK: - Unusable engine reporting

    func testSiriEngineReportsAnUninstallableVoiceAsAUserError() {
        // Never a crash, always exit-1 material: the CLI maps SaybookError to
        // a readable "error:" line.
        let ghost = voice("siri:ghost@en-GB", "Ghost", "en-GB")
        XCTAssertThrowsError(try SpeechEngine.siri.validate(ghost)) { error in
            XCTAssertTrue(error is SaybookError, "expected a user error, got \(error)")
            let message = (error as? SaybookError)?.message ?? ""
            XCTAssertTrue(message.contains("Ghost"), "message must name the voice: \(message)")
            XCTAssertTrue(message.contains("Siri"), "message must name the engine: \(message)")
        }
    }

    func testAppleEngineReportsAnUninstalledVoiceAsAUserError() {
        let ghost = voice("com.apple.voice.does-not-exist", "Ghost", "en-GB")
        XCTAssertThrowsError(try SpeechEngine.apple.validate(ghost)) { error in
            XCTAssertTrue(error is SaybookError, "expected a user error, got \(error)")
        }
    }

    // MARK: - End-to-end render through the private engine

    @MainActor
    func testSiriEngineRendersToThePackageCAFContract() throws {
        guard let siriVoice = SpeechEngine.siri.voices().first else {
            throw XCTSkip("this Mac has no Siri voice bundle installed (\(SpeechEngine.siri.voiceHint))")
        }
        try SpeechEngine.siri.validate(siriVoice)

        let scratch = try makeTempDir()
        let caf = scratch.appendingPathComponent("block.caf")
        try SpeechEngine.siri.render(
            text: "The quick brown fox jumps over the lazy dog.",
            voice: siriVoice,
            rate: CLIOptions.defaultRate,
            to: caf
        )

        let file = try AVAudioFile(forReading: caf)
        XCTAssertEqual(Double(file.processingFormat.sampleRate), Synthesis.sampleRate, accuracy: 0.001)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        // ~2.7 s of speech for that sentence at a normal narrator's rate:
        // a sample-rate mistake would land this 2x off.
        let duration = Double(file.length) / Synthesis.sampleRate
        XCTAssertEqual(duration, 2.8, accuracy: 1.4, "rendered \(duration)s of audio")
    }

    @MainActor
    func testSiriEngineRefusesToSilentlyShortenTheAudio() throws {
        // The converter's frame count is what Chapter Markers are computed
        // from, so a truncated render must fail loudly instead.
        guard let siriVoice = SpeechEngine.siri.voices().first else {
            throw XCTSkip("this Mac has no Siri voice bundle installed")
        }
        let scratch = try makeTempDir()
        let caf = scratch.appendingPathComponent("empty.caf")
        XCTAssertThrowsError(
            try SpeechEngine.siri.render(text: "", voice: siriVoice, rate: 0.5, to: caf)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: caf.path), "a failed render leaves no CAF")
    }
}
