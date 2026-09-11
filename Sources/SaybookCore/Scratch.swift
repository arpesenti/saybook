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
    /// Note: the identity does not (yet) include run options; when ticket 04
    /// adds `--voice`/`--rate`, they must be folded in or cached CAFs
    /// synthesised with a different Voice would be replayed.
    public static func directory(for book: URL) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: book.path)
        let size = (attributes[.size] as? Int) ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(book.resolvingSymlinksInPath().path)|\(size)|\(mtime)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return URL.temporaryDirectory.appendingPathComponent("saybook-\(hex)")
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
