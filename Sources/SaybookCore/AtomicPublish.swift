import Foundation

/// Atomic file publishing for the per-Chapter CAF pipeline (ADR 0002's
/// resume contract): render to a `.partial` sibling, rename on success, so
/// a killed run never leaves a partial at the final name — the existence
/// of a file at its final name is what per-Chapter resume keys on.
enum AtomicPublish {

    /// The `.partial` sibling of a CAF's final name (`x.caf` →
    /// `x.caf.partial`).
    static func partial(for cafURL: URL) -> URL {
        cafURL.deletingPathExtension().appendingPathExtension("caf.partial")
    }

    /// Runs `work` (which writes a fresh file to `partial`), then publishes
    /// it to `final` (`publish`). A stale partial is cleared first, and on
    /// any failure the partial is removed and the error rethrown.
    static func produce(partial: URL, to final: URL, work: () throws -> Void) throws {
        try? FileManager.default.removeItem(at: partial)
        do {
            try work()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try publish(partial: partial, to: final)
    }

    /// Atomically publishes an existing `partial` file to `final` by
    /// rename: a stale file at `final` (left by a killed or pre-atomic run)
    /// is replaced, and on failure the partial is removed and the error
    /// rethrown.
    static func publish(partial: URL, to final: URL) throws {
        do {
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}
