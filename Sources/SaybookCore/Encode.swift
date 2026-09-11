import AVFoundation
import Foundation
import Dispatch

/// Encodes a PCM CAF into an M4A (AAC-LC ~34 kb/s, 22.05 kHz mono) with
/// `AVAssetExportSession`. The `ExtAudioFile` C API is not importable from
/// Swift in the current SDK, which is why this path exists (ADR 0002).
public enum Encode {

    public enum EncodeError: Error, Equatable {
        case noExportSession
        case exportFailed(String)
    }

    public static func encodeCAF(from cafURL: URL, to m4aURL: URL) throws {
        try? FileManager.default.removeItem(at: m4aURL)
        let asset = AVURLAsset(url: cafURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw EncodeError.noExportSession
        }
        session.outputFileType = .m4a

        // Detached so the export runs off the main thread: the caller blocks
        // on the semaphore, and a main-actor task could never start.
        let semaphore = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        Task.detached {
            do {
                try await session.export(to: m4aURL, as: .m4a)
            } catch {
                failure.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let error = failure.error {
            throw EncodeError.exportFailed("\(error)")
        }
    }

    private final class FailureBox: @unchecked Sendable {
        var error: Error?
    }
}
