import AVFoundation
import Foundation

/// Offline speech Synthesis via `AVSpeechSynthesizer.write()`.
/// The engine renders 22.05 kHz mono Float32 PCM buffers (~55x realtime) and
/// delivers buffer and delegate callbacks on the main queue.
public enum Synthesis {

    /// The engine's native output format: 22.05 kHz mono Float32 PCM.
    /// Never mutated after creation, hence the explicit non-Sendable escape hatch.
    nonisolated(unsafe) public static let cafSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 22050.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    public enum SynthesisError: Error, Equatable {
        /// The engine cancelled the utterance or the CAF write failed.
        case failed(String)
    }

    /// Synthesises one utterance offline and writes its PCM to `cafURL`.
    /// Must run on the main thread: callbacks arrive on the main queue, so
    /// the main runloop is pumped until `didFinish` fires (which happens
    /// *after* the last buffer — see the prototype probe).
    @MainActor
    public static func render(utterance: AVSpeechUtterance, to cafURL: URL) throws {
        let collector = UtteranceCollector()
        let file = try AVAudioFile(forWriting: cafURL, settings: cafSettings)

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
        if let error = collector.error {
            try? FileManager.default.removeItem(at: cafURL)
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
