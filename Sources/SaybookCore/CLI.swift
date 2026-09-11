import AVFoundation
import Foundation

/// A user-level failure (bad input, existing output): exit code 1.
public struct SaybookError: Error {
    public let message: String
}

/// CLI entry point. Returns the process exit code:
/// 0 ok · 1 input/user error · 2 internal error.
@MainActor
public func saybookMain(_ arguments: [String]) -> Int32 {
    let options: CLIOptions
    do {
        options = try CLIOptions.parse(arguments)
    } catch let error as CLIOptionsError {
        reportOptionsError(error)
        return 1
    } catch {
        report("error: \(error)")
        return 2
    }

    // SIGINT stops the run after the current unit of work (ticket 06):
    // the handler only sets a flag; the run checks it at unit boundaries
    // and exits cleanly with Scratch kept (resume = re-run).
    Signals.install()

    let input = URL(fileURLWithPath: options.inputPath)
    guard FileManager.default.fileExists(atPath: input.path), !isDirectory(input.path) else {
        report("error: No such file: \(input.path)")
        return 1
    }

    // The output path: `-o` when given, else `<InputBase>.m4b` beside the
    // input. The `-o` parent directory must exist: a fast user error before
    // any work starts.
    let output: URL
    if let relative = options.outputPath {
        output = URL(fileURLWithPath: relative)
        guard isDirectory(output.deletingLastPathComponent().path) else {
            report("error: Output directory does not exist: \(output.deletingLastPathComponent().path)")
            return 1
        }
    } else {
        output = input.deletingPathExtension().appendingPathExtension("m4b")
    }
    if FileManager.default.fileExists(atPath: output.path) {
        if isDirectory(output.path) {
            // The tool replaces files, never directories (with or without
            // `--force`).
            report("error: Output path is a directory: \(output.path)")
            return 1
        }
        guard options.force else {
            report("error: Output already exists: \(output.path)")
            return 1
        }
    }

    // An explicit `--voice` must exist before any work starts: a fast
    // failure with no Scratch side effects.
    var explicitVoice: Voice?
    if let reference = options.voice {
        guard let chosen = VoiceSelection.named(reference, in: VoiceCatalog.installed()) else {
            report("error: Unknown voice: \(reference) (see `say -v ?` for installed voices)")
            return 1
        }
        explicitVoice = chosen
    }

    var scratch: URL?
    do {
        let scratchDir = try Scratch.directory(for: input)
        scratch = scratchDir

        let book = try Epub.load(bookAt: input, scratch: scratchDir)

        // The voice for the run: `--voice` when given (resolved above, before
        // any work starts), else the best installed voice for the language
        // `--language` overrides the Book's OPF language for.
        let voice: Voice
        if let explicitVoice {
            voice = explicitVoice
        } else {
            let language = options.language ?? book.language
            guard let chosen = VoiceSelection.best(forLanguage: language, in: VoiceCatalog.installed()) else {
                throw SaybookError(message: "No installed voice for language \"\(language)\"")
            }
            voice = chosen
        }

        // Cached Chapter CAFs are resume state only for the same options:
        // a different Voice or Rate clears them (ticket 04).
        if try Scratch.ensureOptions(Scratch.optionsMarker(voice: voice, rate: options.rate), in: scratchDir) {
            report("note: voice or rate changed — clearing cached chapters")
        }
        report("Voice: \(voice.name) (\(voice.quality.label), \(voice.language)) · Rate: \(formatRate(options.rate))")

        let (renders, skipped) = try synthesizeChapters(of: book, voice: voice, rate: options.rate, in: scratchDir)

        // A SIGINT during the final fast step: the chapters are done, so
        // report them as such.
        try ensureNotInterrupted(completed: book.chapters.count, total: book.chapters.count)

        let combined = scratchDir.appendingPathComponent("book.caf")
        try Assemble.concatenate(renders.map(\.cafURL), to: combined)

        let m4a = scratchDir.appendingPathComponent("book.m4a")
        try Encode.encodeCAF(from: combined, to: m4a)

        // Brand patch, then the Book's identity (ilst + covr), then Chapter
        // Markers (offsets computed from the known per-chapter frame counts),
        // then write straight to the output path. The identity degrades
        // gracefully: a failed box write keeps the file with a warning.
        var data = try Data(contentsOf: m4a)
        data = try Brand.patchFTyp(in: data)
        do {
            data = try Metadata.insert(BookMetadata(book: book), into: data)
        } catch {
            report("warning: could not write title/author metadata: \(error)")
        }
        if case let .missing(reference) = book.cover {
            report("warning: cover image \"\(reference)\" declared but not found; no cover written")
        }
        let offsets = ChapterMarkers.startOffsets(frameCounts: renders.map(\.frameCount))
        let markers = zip(offsets, renders).map { ChapterMarker(sampleOffset: $0, title: $1.title) }
        data = try ChapterMarkers.insertChpl(markers: markers, trackTimescale: Synthesis.trackTimescale, into: data)
        // Publish the output atomically (ticket 06): with `--force` the
        // output file is replaced, so a killed final write must not leave a
        // half-written file at the output path.
        let partial = output.appendingPathExtension("partial")
        try AtomicPublish.produce(partial: partial, to: output) {
            try data.write(to: partial)
        }

        let totalSeconds = Double(renders.reduce(0) { $0 + $1.frameCount }) / Synthesis.sampleRate
        report(summaryLine(
            chapters: book.chapters.count,
            skipped: skipped,
            duration: totalSeconds,
            sizeInBytes: data.count,
            path: output.path
        ))

        if options.keepScratch {
            report("note: scratch kept: \(scratchDir.path)")
        } else {
            try FileManager.default.removeItem(at: scratchDir)
        }
        return 0
    } catch let error as RunInterrupted {
        report("note: interrupted — stopped after \(error.completed) of \(error.total) chapters")
        if let scratch {
            report("note: scratch kept for resume: \(scratch.path)")
        }
        return 1
    } catch Epub.EpubError.notAValidEpub {
        report("error: Not a valid EPUB: \(input.path)")
        return 1
    } catch Epub.EpubError.noReadableChapters {
        report("error: No readable chapters in \(input.path)")
        return 1
    } catch let Epub.EpubError.drmEncrypted(uri) {
        report("error: DRM-protected EPUB: \"\(uri)\" is encrypted (only non-DRM books are supported)")
        return 1
    } catch let error as SaybookError {
        report("error: \(error.message)")
        return 1
    } catch {
        let kept = scratch.map { " (scratch kept: \($0.path))" } ?? ""
        report("error: \(error)\(kept)")
        return 2
    }
}

// MARK: - Per-chapter synthesis

/// The run was stopped by SIGINT after the current unit of work (ticket
/// 06): Scratch is kept, and the run exits 1 with its progress so far.
private struct RunInterrupted: Error {
    /// The Chapters completed when the run stopped.
    let completed: Int
    /// The Book's total Chapter count.
    let total: Int
}

/// Throws `RunInterrupted` when SIGINT arrived since the last check.
private func ensureNotInterrupted(completed: Int, total: Int) throws {
    if Signals.interrupted { throw RunInterrupted(completed: completed, total: total) }
}

/// A synthesised (or cached) Chapter's audio: its CAF plus the exact PCM
/// frame count the Chapter Marker offsets are computed from.
private struct ChapterRender {
    let title: String
    let cafURL: URL
    let frameCount: Int
}

/// Synthesises each non-empty Chapter to its own CAF (in Spine order) and
/// reports one progress line per Chapter on stderr. A Chapter whose CAF
/// already exists in Scratch is skipped (resume: existence = state).
@MainActor
private func synthesizeChapters(of book: Book, voice: Voice, rate: Double, in scratch: URL) throws -> (renders: [ChapterRender], skipped: Int) {
    guard let speechVoice = VoiceCatalog.speechVoice(for: voice) else {
        throw SaybookError(message: "Voice \"\(voice.name)\" is no longer installed")
    }
    try FileManager.default.createDirectory(
        at: Scratch.chaptersDirectory(in: scratch), withIntermediateDirectories: true
    )

    var renders: [ChapterRender] = []
    var skipped = 0
    for (index, chapter) in book.chapters.enumerated() {
        let number = index + 1
        // A SIGINT between Chapters stops before any more work: the
        // chapters completed so far are resume state.
        try ensureNotInterrupted(completed: number - 1, total: book.chapters.count)

        guard !chapter.blocks.isEmpty else {
            // Empty Chapter: no audio, no Chapter Marker.
            skipped += 1
            report("– \(number)/\(book.chapters.count) · \(chapter.title) · (no text)")
            continue
        }

        let cafURL = Scratch.chapterCAFURL(in: scratch, index: number)
        let frameCount: Int
        if FileManager.default.fileExists(atPath: cafURL.path) {
            frameCount = try cafFrameCount(at: cafURL)
            report("⏭ \(number)/\(book.chapters.count) · \(chapter.title) · \(formatDuration(Double(frameCount) / Synthesis.sampleRate)) (cached)")
        } else {
            // One utterance per Block, separated by the inter-Block pause
            // (ticket 05): the Chapter CAF is the atomic concatenation of
            // the per-Block CAFs and the silences between them.
            let segments = try renderBlocks(
                chapter.blocks,
                chapterNumber: number,
                total: book.chapters.count,
                voice: speechVoice,
                rate: rate,
                in: scratch
            )
            let partial = AtomicPublish.partial(for: cafURL)
            try AtomicPublish.produce(partial: partial, to: cafURL) {
                try Assemble.concatenate(segments, to: partial)
            }
            frameCount = try cafFrameCount(at: cafURL)
            report("✓ \(number)/\(book.chapters.count) · \(chapter.title) · \(formatDuration(Double(frameCount) / Synthesis.sampleRate))")
        }
        renders.append(ChapterRender(title: chapter.title, cafURL: cafURL, frameCount: frameCount))
    }

    guard !renders.isEmpty else {
        throw SaybookError(message: "No readable chapters in \(book.title)")
    }
    return (renders, skipped)
}

/// Synthesises a Chapter's Blocks (ticket 05): one utterance per Block, a
/// silence CAF between consecutive Blocks. Returns the segment CAFs in
/// Chapter order (`[block 1, pause, block 2, pause, …, block N]`). A SIGINT
/// stops the run after the current Block (one unit of work): `total` is the
/// Book's Chapter count, and the interrupted Chapter counts as not completed.
@MainActor
private func renderBlocks(
    _ blocks: [Block], chapterNumber: Int, total: Int, voice: AVSpeechSynthesisVoice, rate: Double, in scratch: URL
) throws -> [URL] {
    var segments: [URL] = []
    for (offset, block) in blocks.enumerated() {
        let blockNumber = offset + 1
        if offset > 0 {
            let pauseURL = Scratch.pauseCAFURL(in: scratch, index: chapterNumber, block: blockNumber)
            try Assemble.writeSilenceCAFFrames(Synthesis.blockPauseFrames, to: pauseURL)
            segments.append(pauseURL)
        }
        let cafURL = Scratch.blockCAFURL(in: scratch, index: chapterNumber, block: blockNumber)
        // A killed run may have left a stale file at the final name (same
        // Voice/Rate: the options marker guards that): AtomicPublish
        // replaces it before the rename.
        let utterance = AVSpeechUtterance(string: block.text)
        utterance.voice = voice
        utterance.rate = Float(rate)
        try Synthesis.render(utterance: utterance, to: cafURL)
        // The Block is the unit of work (ticket 06): a SIGINT arrives
        // during the render and is acted on as soon as this Block is done.
        try ensureNotInterrupted(completed: chapterNumber - 1, total: total)
        segments.append(cafURL)
    }
    return segments
}

/// The exact PCM frame count of a CAF (1 frame per sample, mono).
private func cafFrameCount(at url: URL) throws -> Int {
    let file = try AVAudioFile(forReading: url)
    return Int(file.length)
}

/// m:ss (e.g. `2:31`); minutes grow unbounded.
private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
}

/// The final summary line: chapter count, skipped count, total duration,
/// output size, and output path.
private func summaryLine(chapters: Int, skipped: Int, duration: TimeInterval, sizeInBytes: Int, path: String) -> String {
    // Empty Chapters are the only kind skipped: annotate the count so the
    // summary line explains itself (spec: "reported skipped (no text)").
    let skippedText = skipped == 0 ? "0" : "\(skipped) (no text)"
    return "Chapters: \(chapters) · Skipped: \(skippedText) · Duration: \(formatDuration(duration)) · Size: \(formatSize(sizeInBytes)) · Path: \(path)"
}

/// KB/MB/GB with one decimal (1024-based).
private func formatSize(_ bytes: Int) -> String {
    let kib = Double(bytes) / 1024
    if kib < 1024 { return String(format: "%.1f KB", kib) }
    let mib = kib / 1024
    if mib < 1024 { return String(format: "%.1f MB", mib) }
    return String(format: "%.1f GB", mib / 1024)
}

/// True when `path` exists and is a directory.
private func isDirectory(_ path: String) -> Bool {
    var flag: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
}

/// The v1 flag set (ticket 06 added `-o`, `--force` and `--keep-scratch`).
private let usageLine = "Usage: saybook <book.epub> [-o OUT.m4b] [--voice NAME] [--rate 0.0–1.0] [--language LL] [--keep-scratch] [--force]"

/// Readable messages for command-line user errors (exit 1).
private func reportOptionsError(_ error: CLIOptionsError) {
    switch error {
    case .usage:
        report(usageLine)
    case let .unknownOption(option):
        report("error: Unknown option: \(option)")
        report(usageLine)
    case let .missingValue(for: flag):
        report("error: \(flag) requires a value")
        report(usageLine)
    case let .invalidRate(value):
        report("error: Rate must be a number between 0.0 and 1.0: \(value)")
    case let .outOfRangeRate(value):
        report("error: Rate must be between 0.0 and 1.0: \(value)")
    }
}

/// The Rate for the progress line, minimal ("0.5", "1", "0.33").
private func formatRate(_ rate: Double) -> String {
    String(format: "%g", rate)
}

private func report(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
