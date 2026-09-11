import AVFoundation
import Foundation

/// Offline speech Synthesis via `AVSpeechSynthesizer.write()`.
/// The engine renders 22.05 kHz mono Float32 PCM buffers (~55x realtime) and
/// delivers buffer and delegate callbacks on the main queue.
public enum Synthesis {

    /// The engine's native output sample rate; the timescale of every CAF
    /// this package writes and of the concatenated Audiobook track.
    public static let sampleRate: Double = 22_050

    /// The same rate as `Int`: the track timescale the Chapter Marker offsets
    /// are expressed in.
    public static let trackTimescale: Int = 22_050

    /// The engine's native output format: 22.05 kHz mono Float32 PCM.
    /// Never mutated after creation, hence the explicit non-Sendable escape hatch.
    nonisolated(unsafe) public static let cafSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// The silence inserted between a chapter's Blocks (ticket 05): ~0.3 s,
    /// so the output sounds like a narrator breathing between paragraphs.
    public static let blockPauseDuration: TimeInterval = 0.3

    /// `blockPauseDuration` in PCM frames at the engine's sample rate.
    public static var blockPauseFrames: Int {
        Int((blockPauseDuration * sampleRate).rounded())
    }

    public enum SynthesisError: Error, Equatable {
        /// The engine cancelled the utterance or the CAF write failed.
        case failed(String)
    }

    /// Synthesises one utterance offline and writes its PCM to `cafURL`.
    /// Must run on the main thread: callbacks arrive on the main queue, so
    /// the main runloop is pumped until `didFinish` fires (which happens
    /// *after* the last buffer — see the prototype probe).
    ///
    /// The CAF is published atomically (rendered to a `.partial` sibling,
    /// renamed on success): a killed run never leaves a partial file at the
    /// final name, which is what resume keys on.
    @MainActor
    public static func render(utterance: AVSpeechUtterance, to cafURL: URL) throws {
        let partial = AtomicPublish.partial(for: cafURL)
        // A killed run may have left a stale partial at this name: replace
        // it rather than render into it.
        try? FileManager.default.removeItem(at: partial)
        let collector = UtteranceCollector()
        do {
            // The AVAudioFile is released (closing the underlying file) at
            // the end of this scope, before the atomic publish.
            let file = try AVAudioFile(forWriting: partial, settings: cafSettings)

            let synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = collector
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                do {
                    // Write the engine's buffer directly: a freshly allocated
                    // buffer has frameLength 0 and would store zero bytes.
                    try file.write(from: pcm)
                } catch {
                    collector.fail(error)
                }
            }

            while collector.state == .running {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        if let error = collector.error {
            try? FileManager.default.removeItem(at: partial)
            throw SynthesisError.failed("\(error)")
        }
        do {
            try AtomicPublish.publish(partial: partial, to: cafURL)
        } catch {
            throw SynthesisError.failed("\(error)")
        }
    }

    /// Collects the delegate outcome. Callbacks arrive on the main queue; the
    /// main thread is the only reader, so the lock is defensive.
    private final class UtteranceCollector: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        fileprivate enum State { case running, done, failed }

        private let lock = NSLock()
        private var _state: State = .running
        private var _error: Error?

        fileprivate var state: State {
            lock.lock(); defer { lock.unlock() }
            return _state
        }

        fileprivate var error: Error? {
            lock.lock(); defer { lock.unlock() }
            return _error
        }

        fileprivate func fail(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            guard _state == .running else { return }
            _state = .failed
            _error = error
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            lock.lock(); defer { lock.unlock() }
            guard _state == .running else { return }
            _state = .done
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            fail(CancellationError())
        }
    }
}
