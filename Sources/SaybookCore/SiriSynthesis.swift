import AVFoundation
import Foundation
import SiriTTSBridge

/// The **Siri** speech engine: Apple's on-device neural voices (internally
/// "gryphon" — FastSpeech2 acoustic model + WaveRNN vocoder + a neural
/// G2P), reached through `SiriTTSBridge`.
///
/// This is the voice Siri speaks with and it is a clear tier above what
/// `AVSpeechSynthesizer` exposes — but it is a *private* API: no public
/// surface reaches it (see `docs/adr/0003` and the research notes), so the
/// engine is opt-in (`--engine siri`), documented as unsupported, and every
/// failure degrades to a readable message rather than a crash. It stays
/// offline and dependency-free, so ADR 0001's premise holds.
public enum SiriSynthesis {

    /// The sample rate of the PCM the engine returns — its own contract, not
    /// this package's (`Synthesis.sampleRate`); `render` resamples into the
    /// CAF format.
    public static let inputSampleRate: Double = 48_000

    /// A Siri-engine failure (missing framework, changed private API,
    /// unusable voice asset, resampling failure). Always a user-readable
    /// message.
    public enum SiriError: Error, Equatable {
        case message(String)
    }

    /// The engine's message for a Siri failure (engine name unavailable).
    public static func message(of error: SiriError) -> String {
        switch error {
        case let .message(text): return text
        }
    }

    /// Loads the voice's engine and asks it whether it can synthesise, so a
    /// run fails before any chapter work starts. Throws `SiriError`.
    public static func validate(voice: Voice) throws {
        guard let directory = SiriVoiceCatalog.assetDirectory(for: voice) else {
            throw SiriError.message("Siri voice \"\(voice.name)\" is no longer installed")
        }
        var message = [CChar](repeating: 0, count: Int(SAYBOOK_SIRI_ERROR_CAP))
        guard withCString(directory, { saybook_siri_probe($0, &message, SAYBOOK_SIRI_ERROR_CAP) }) == 0 else {
            throw SiriError.message(readable(message, fallback: "the Siri engine cannot use this voice"))
        }
    }

    /// Renders one utterance and writes it as a CAF at `Synthesis.cafSettings`
    /// (22.05 kHz mono Float32), published atomically like every other CAF.
    @MainActor
    public static func render(text: String, voice: Voice, to cafURL: URL) throws {
        guard let directory = SiriVoiceCatalog.assetDirectory(for: voice) else {
            throw SiriError.message("Siri voice \"\(voice.name)\" is no longer installed")
        }

        var pcm: UnsafeMutablePointer<Int16>?
        var sampleCount = 0
        var message = [CChar](repeating: 0, count: Int(SAYBOOK_SIRI_ERROR_CAP))
        let status = withCString(directory) { directoryPointer in
            withCString(text) { textPointer in
                saybook_siri_synthesize(
                    directoryPointer, textPointer, &pcm, &sampleCount,
                    &message, SAYBOOK_SIRI_ERROR_CAP
                )
            }
        }
        defer { if let pcm { saybook_siri_free(pcm) } }
        guard status == 0, let pcm, sampleCount > 0 else {
            throw SiriError.message(
                readable(message, fallback: "the Siri engine produced no audio")
            )
        }
        try writeCAF(samples: pcm, count: sampleCount, to: cafURL)
    }

    // MARK: - Format conversion

    /// Converts the engine's 48 kHz mono int16 PCM into this package's CAF
    /// contract (22.05 kHz mono Float32) and publishes it atomically. The
    /// frame count of the result is what Chapter Markers are computed from,
    /// so nothing here may silently truncate or pad the audio.
    private static func writeCAF(samples: UnsafeMutablePointer<Int16>, count: Int, to cafURL: URL) throws {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: inputSampleRate, channels: 1, interleaved: true
        ), let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count))
        else {
            throw SiriError.message("could not describe the Siri engine's audio format")
        }
        input.frameLength = AVAudioFrameCount(count)
        memcpy(input.int16ChannelData![0], samples, count * MemoryLayout<Int16>.size)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Synthesis.sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw SiriError.message("could not build the Siri audio converter")
        }
        // Offline render: quality costs nothing but time, and this is the
        // only lossy step between the engine and the listener.
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let expected = Double(count) * Synthesis.sampleRate / inputSampleRate
        // The output buffer must hold the whole downsampled render; the
        // converter pads a few frames for the resampling filter, so allow
        // slack rather than run out of room at the end.
        let capacity = AVAudioFrameCount(expected.rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw SiriError.message("could not allocate the converted audio")
        }

        // The one-shot `convert(to:from:)` rejects sample-rate conversion
        // with paramErr, so feed the converter through its input block: the
        // whole render in one buffer, then end of stream.
        //
        // This call is *not* throwing in Swift: it returns an output status and
        // takes an `NSErrorPointer`. A `try`/`catch` here compiled but was dead
        // code — the compiler's "no calls to throwing functions" warning — and
        // `error: nil` threw the reason away, so a failed conversion was
        // reported later as a frame-count mismatch (or not at all). Read the
        // status and the error, which is what the code always meant.
        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .endOfStream
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return input
        }
        // Only `.error` is an error: hitting end of stream is how this call
        // finishes with a finite input, and the frame-count guards below judge
        // the result either way.
        guard status != .error else {
            throw SiriError.message(
                "could not convert the Siri audio to \(Int(Synthesis.sampleRate)) Hz: "
                    + (conversionError?.localizedDescription ?? "the converter reported an error")
            )
        }
        let produced = Int(output.frameLength)
        guard produced > 0 else {
            throw SiriError.message("the Siri audio conversion produced no audio")
        }
        // A short render means the converter ran out of room or stopped early:
        // every later Chapter Marker would drift, so refuse rather than ship
        // silently wrong audio.
        guard abs(Double(produced) - expected) <= max(0.02 * expected, 64) else {
            throw SiriError.message(
                "the Siri audio conversion produced \(produced) frames where \(Int(expected)) were expected"
            )
        }

        let partial = AtomicPublish.partial(for: cafURL)
        do {
            // The file is closed (released) at the end of this scope, before
            // the atomic rename.
            let file = try AVAudioFile(forWriting: partial, settings: Synthesis.cafSettings)
            try file.write(from: output)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw SiriError.message("could not write the rendered audio: \(error)")
        }
        do {
            try AtomicPublish.publish(partial: partial, to: cafURL)
        } catch {
            throw SiriError.message("could not save the rendered audio: \(error)")
        }
    }

    /// Runs `body` with a C string for `value`.
    private static func withCString<R>(_ value: String, _ body: (UnsafePointer<CChar>) -> R) -> R {
        value.withCString(body)
    }

    /// The engine's message when it gave one, a fallback when it did not.
    private static func readable(_ buffer: [CChar], fallback: String) -> String {
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<length].map { UInt8(bitPattern: $0) }
        let message = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }
}

/// The Siri engine's installed-voice catalog.
///
/// Siri voices are not registered with the speech-synthesis voice database —
/// `AVSpeechSynthesisVoice.speechVoices()` never lists them, and passing one
/// of their identifiers to AVFoundation or `say` silently falls back to the
/// default voice. What exists on disk is a MobileAsset bundle per downloaded
/// voice, and macOS decides which ones a machine has (here: one). So this
/// catalog reports what is actually usable, and selection over it behaves
/// exactly like the Apple-engine catalog.
public enum SiriVoiceCatalog {

    /// Where macOS keeps the Siri text-to-speech voice bundles.
    ///
    /// `SAYBOOK_SIRI_ASSETS_ROOT` overrides it — the same kind of debugging
    /// hook as `SAYBOOK_SIRI_DIAGNOSTICS` — so the "this Mac has no Siri voice
    /// bundle" path is reachable on a Mac that has one: point it at an empty
    /// directory and the catalog reports no voices. `Scripts/e2e.sh` uses that
    /// to prove its Siri leg skips rather than fails, and `CLITests` uses it to
    /// assert the message the script's skip keys on. Read once per process.
    static let assetsRoot: String =
        ProcessInfo.processInfo.environment["SAYBOOK_SIRI_ASSETS_ROOT"]
        ?? "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto"

    /// The file that distinguishes a synthesizable voice bundle from a
    /// resources-only asset: the engine's pipeline description.
    static let voiceMarker = "gryphon.cfg"

    /// Every usable installed Siri voice, sorted by name then language.
    public static func installed() -> [Voice] {
        entries().map(\.voice)
    }

    /// The extracted asset directory a catalog entry renders from.
    public static func assetDirectory(for voice: Voice) -> String? {
        entries().first { $0.voice == voice }?.directory
            ?? entries().first { $0.voice.identifier == voice.identifier }?.directory
    }

    /// A `(voice, directory)` pair per voice bundle, deduplicated by identity.
    private static func entries() -> [(voice: Voice, directory: String)] {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(atPath: assetsRoot) else { return [] }
        var seen = Set<String>()
        var found: [(voice: Voice, directory: String)] = []
        for child in children.sorted() {
            let dataDirectory = assetsRoot + "/" + child + "/AssetData"
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: dataDirectory, isDirectory: &isDirectory), isDirectory.boolValue,
                  manager.fileExists(atPath: dataDirectory + "/" + voiceMarker)
            else { continue }
            guard let voice = describe(plist(in: dataDirectory), directory: dataDirectory),
                  seen.insert(voice.identifier).inserted
            else { continue }
            found.append((voice, dataDirectory))
        }
        return found.sorted {
            $0.voice.name.lowercased() == $1.voice.name.lowercased()
                ? $0.voice.language < $1.voice.language
                : $0.voice.name.lowercased() < $1.voice.name.lowercased()
        }
    }

    /// The `Voice` a voice bundle describes; nil when the bundle is not
    /// self-describing enough to select by name and language. Internal so the
    /// plist parsing is testable without a downloaded voice.
    static func describe(_ properties: [String: Any]?, directory: String) -> Voice? {
        let mobileAsset = properties?["MobileAssetProperties"] as? [String: Any]
        let name = (mobileAsset?["Name"] as? String)
            ?? ((properties?["CFBundleName"] as? String).map {
                $0.components(separatedBy: "_").dropLast().joined(separator: "_")
            })
        guard let name, !name.isEmpty else { return nil }
        let languages = mobileAsset?["LanguagesCompatibility"] as? [String]
        let language = (languages?.first ?? "").replacingOccurrences(of: "_", with: "-")
        let quality: VoiceQuality
        switch (mobileAsset?["Footprint"] as? String)?.lowercased() {
        case "premium": quality = .premium
        case "enhanced": quality = .enhanced
        default: quality = .default
        }
        return Voice(
            identifier: "siri:\(name)@\(language.isEmpty ? "und" : language)",
            name: name.capitalized,
            language: language.isEmpty ? "und" : language,
            quality: quality
        )
    }

    /// The bundle's `Info.plist` as a dictionary.
    private static func plist(in directory: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: directory + "/Info.plist"),
              let object = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              )
        else { return nil }
        return object as? [String: Any]
    }
}
