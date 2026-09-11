import Foundation
import XCTest
@testable import SaybookCore

/// Ticket 04: Voice & language selection.
///
/// Seam under test: `VoiceSelection.best(forLanguage:in:)` and
/// `VoiceSelection.named(_:in:)` — pure selection over a `[Voice]` catalog,
/// so the quality ordering and matching rules are pinned with synthetic
/// voices (the machine's real catalog reports one quality tier only).
/// `VoiceCatalog` is smoke-tested against the machine's installed voices.
final class VoiceTests: XCTestCase {

    private func voice(
        _ name: String,
        _ language: String,
        _ quality: VoiceQuality,
        identifier: String? = nil
    ) -> Voice {
        Voice(
            identifier: identifier ?? "id.\(name.lowercased())",
            name: name,
            language: language,
            quality: quality
        )
    }

    // MARK: - best(forLanguage:in:)

    func testBestPrefersHighestQualityWithinLanguage() {
        let voices = [
            voice("Plain", "en-US", .default),
            voice("Better", "en-US", .enhanced),
            voice("Finest", "en-US", .premium),
        ]
        XCTAssertEqual(VoiceSelection.best(forLanguage: "en-US", in: voices)?.name, "Finest")
    }

    func testBestExactLanguageBeatsCrossRegionQuality() {
        // A book tagged en-US keeps an installed en-US voice over a
        // higher-quality en-GB one: language fidelity beats quality.
        let voices = [
            voice("Plain", "en-US", .default),
            voice("Fancy", "en-GB", .premium),
        ]
        XCTAssertEqual(VoiceSelection.best(forLanguage: "en-US", in: voices)?.name, "Plain")
    }

    func testBestFallsBackToPrimarySubtagWhenExactTagIsMissing() {
        // Only pt-PT is installed for a pt-BR book: same-language (pt)
        // beats nothing.
        let voices = [voice("Plain", "pt-PT", .default)]
        XCTAssertEqual(VoiceSelection.best(forLanguage: "pt-BR", in: voices)?.name, "Plain")
    }

    func testBestBareLanguageMatchesAnyRegion() {
        let voices = [
            voice("Plain", "en-GB", .default),
            voice("Fancy", "en-AU", .premium),
        ]
        XCTAssertEqual(VoiceSelection.best(forLanguage: "en", in: voices)?.name, "Fancy")
    }

    func testBestTiesBreakToCatalogOrder() {
        let voices = [
            voice("First", "en-GB", .enhanced),
            voice("Second", "en-US", .enhanced),
        ]
        XCTAssertEqual(VoiceSelection.best(forLanguage: "en", in: voices)?.name, "First")
    }

    func testBestIsCaseInsensitiveOnLanguageTags() {
        let voices = [voice("Plain", "en-US", .default)]
        XCTAssertEqual(VoiceSelection.best(forLanguage: "EN-us", in: voices)?.name, "Plain")
        XCTAssertEqual(VoiceSelection.best(forLanguage: "en-us", in: voices)?.name, "Plain")
    }

    func testBestReturnsNilWhenLanguageIsUninstalled() {
        let voices = [
            voice("Plain", "en-US", .default),
            voice("GermanOnly", "de-DE", .premium),
        ]
        XCTAssertNil(VoiceSelection.best(forLanguage: "fr", in: voices))
        XCTAssertNil(VoiceSelection.best(forLanguage: "xx-XX", in: voices))
    }

    func testBestIgnoresOtherLanguagesEvenAtHigherQuality() {
        let voices = [
            voice("Plain", "en-US", .default),
            voice("FrenchPremium", "fr-FR", .premium),
        ]
        XCTAssertEqual(VoiceSelection.best(forLanguage: "en", in: voices)?.name, "Plain")
    }

    // MARK: - named(_:in:)

    func testNamedMatchesIdentifierExactly() {
        let voices = [
            voice("Plain", "en-US", .default, identifier: "com.apple.test.Plain"),
        ]
        XCTAssertEqual(VoiceSelection.named("com.apple.test.Plain", in: voices)?.name, "Plain")
    }

    func testNamedMatchesDisplayNameExactly() {
        let voices = [
            voice("Bad News", "en-US", .default),
        ]
        XCTAssertEqual(VoiceSelection.named("Bad News", in: voices)?.name, "Bad News")
    }

    func testNamedIsCaseInsensitive() {
        let voices = [
            voice("Samantha", "en-US", .default, identifier: "com.apple.test.Samantha"),
        ]
        XCTAssertEqual(VoiceSelection.named("samANTHA", in: voices)?.name, "Samantha")
        XCTAssertEqual(VoiceSelection.named("COM.APPLE.TEST.Samantha", in: voices)?.name, "Samantha")
    }

    func testNamedFirstMatchWinsOnCollidingNames() {
        // Real catalogs carry the same display name in several languages
        // (e.g. "Eddy" in en-GB, en-US, de-DE, …): the first catalog entry
        // wins.
        let voices = [
            voice("Eddy", "en-GB", .enhanced),
            voice("Eddy", "en-US", .enhanced),
        ]
        XCTAssertEqual(VoiceSelection.named("Eddy", in: voices)?.language, "en-GB")
    }

    func testNamedReturnsNilForUnknownReference() {
        let voices = [voice("Plain", "en-US", .default)]
        XCTAssertNil(VoiceSelection.named("NotARealVoice", in: voices))
        XCTAssertNil(VoiceSelection.named("", in: voices))
    }

    // MARK: - VoiceQuality

    func testQualityOrdersDefaultEnhancedPremium() {
        XCTAssertLessThan(VoiceQuality.default, VoiceQuality.enhanced)
        XCTAssertLessThan(VoiceQuality.enhanced, VoiceQuality.premium)
        XCTAssertEqual(VoiceQuality.premium, VoiceQuality(rawValue: 2))
        XCTAssertEqual(VoiceQuality.enhanced, VoiceQuality(rawValue: 1))
        XCTAssertEqual(VoiceQuality.default, VoiceQuality(rawValue: 0))
    }

    // MARK: - VoiceCatalog (machine smoke)

    func testCatalogReportsInstalledVoices() {
        let voices = VoiceCatalog.installed()
        XCTAssertFalse(voices.isEmpty, "no voices installed on this machine")
        for voice in voices {
            XCTAssertFalse(voice.identifier.isEmpty)
            XCTAssertFalse(voice.name.isEmpty)
            XCTAssertFalse(voice.language.isEmpty)
        }
        // Every catalog entry resolves to a real engine voice.
        XCTAssertNotNil(VoiceCatalog.speechVoice(for: voices[0]))
    }

    func testBestForEnglishResolvesOnThisMachine() {
        // Every macOS ships English voices: the fixture books (language
        // "en") must always be speakable here.
        let best = VoiceSelection.best(forLanguage: "en", in: VoiceCatalog.installed())
        XCTAssertNotNil(best, "no English voice installed")
        XCTAssertTrue(best?.language.lowercased().hasPrefix("en") ?? false)
    }
}
