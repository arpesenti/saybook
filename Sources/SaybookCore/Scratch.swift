import CryptoKit
import Foundation

/// The per-run Scratch directory (ADR 0002: per-chapter CAFs live here).
public enum Scratch {

    /// The Scratch directory for `book`, stable across re-runs of the same
    /// command: existing chapter CAFs are picked up (a killed or failed run
    /// resumes, and "existence = resume state"). The identity (absolute
    /// path, size, modification date) keys the directory, so a modified or
    /// moved input starts fresh instead of reusing stale audio.
    ///
    /// Run options are tracked separately: the options marker
    /// (`ensureOptions`) must match for cached CAFs to be resume state, so
    /// a re-run with a different `--voice` or `--rate` never replays audio
    /// synthesised with other options.
    public static func directory(for book: URL) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: book.path)
        let size = (attributes[.size] as? Int) ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(book.resolvingSymlinksInPath().path)|\(size)|\(mtime)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return URL.temporaryDirectory.appendingPathComponent("saybook-\(hex)")
    }

    /// The options marker file inside Scratch.
    public static func optionsURL(in scratch: URL) -> URL {
        scratch.appendingPathComponent("options")
    }

    /// The options marker for a run: the resolved Voice's identifier and the
    /// Rate its Chapter CAFs were (or will be) synthesised with.
    public static func optionsMarker(voice: Voice, rate: Double) -> String {
        String(format: "voice=%@\nrate=%g", voice.identifier, rate)
    }

    /// Ensures Scratch's options marker matches `marker`. A matching marker
    /// keeps the cached Chapter CAFs (resume state); a different or missing
    /// marker clears the cached Chapters — a different voice or rate (or an
    /// unknown origin) must not replay cached audio. Returns true when
    /// cached Chapters were cleared (the unpacked EPUB and the marker file
    /// itself are not cached audio and are never touched).
    @discardableResult
    public static func ensureOptions(_ marker: String, in scratch: URL) throws -> Bool {
        let url = optionsURL(in: scratch)
        let matches = (try? String(contentsOf: url, encoding: .utf8)) == marker
        if matches { return false }
        let chapters = chaptersDirectory(in: scratch).lastPathComponent
        let hadCachedContent = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?
            .contains(chapters) ?? false
        if hadCachedContent {
            // Cached Chapters from a different run (or an unknown origin):
            // clear them, then recreate the directory for the new marker.
            // A failed clear must fail the run, never replay stale audio.
            try FileManager.default.removeItem(at: scratch)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } else if !FileManager.default.fileExists(atPath: scratch.path) {
            // No cached audio (a fresh run): keep the unpacked EPUB, and
            // make sure the directory exists for the marker.
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        }
        try marker.write(to: url, atomically: true, encoding: .utf8)
        return hadCachedContent
    }

    /// The directory inside Scratch holding the per-Chapter CAFs.
    public static func chaptersDirectory(in scratch: URL) -> URL {
        scratch.appendingPathComponent("chapters")
    }

    /// The CAF for the 1-based Chapter `index`. Existence is the resume
    /// state: a CAF at its final name is a finished Chapter.
    public static func chapterCAFURL(in scratch: URL, index: Int) -> URL {
        chaptersDirectory(in: scratch)
            .appendingPathComponent(String(format: "chapter-%03d.caf", index))
    }
}
