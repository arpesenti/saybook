import Darwin
import Foundation

/// Cooperative SIGINT handling (ticket 06): the handler only sets a flag —
/// a word-sized store, the only thing it does, the only thing signal
/// context allows. The run checks `interrupted` at its unit boundaries
/// (between Blocks, between Chapters, before encoding) and stops cleanly
/// there: progress so far is reported, Scratch is kept for resume, and the
/// run exits 1. A second SIGINT restores the default action and re-raises,
/// so a stuck run can always be force-killed.
enum Signals {

    /// Set by the signal handler, read by the main run: a word-sized store
    /// is effectively atomic on every platform this runs on, which is all a
    /// signal handler may rely on.
    nonisolated(unsafe) static var interrupted = false

    /// Installs the SIGINT handler. Idempotent.
    static func install() {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = saybookSignalHandler
        sigaction(SIGINT, &action, nil)
    }
}

/// The C-convention SIGINT handler (file scope: a static method does not
/// convert to a C function pointer). Word-sized store only — the sole thing
/// signal context allows.
private func saybookSignalHandler(_ number: Int32) {
    if Signals.interrupted {
        // A second SIGINT forces: restore the default action and
        // re-raise so the run dies the usual way.
        signal(SIGINT, SIG_DFL)
        raise(SIGINT)
    }
    Signals.interrupted = true
}
