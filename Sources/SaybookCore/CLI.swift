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
    guard arguments.count == 1 else {
        report("Usage: saybook <book.epub>")
        return 1
    }
    let input = URL(fileURLWithPath: arguments[0])
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
    else {
        report("error: No such file: \(input.path)")
        return 1
    }

    let output = input.deletingPathExtension().appendingPathExtension("m4b")
    guard !FileManager.default.fileExists(atPath: output.path) else {
        report("error: Output already exists: \(output.path)")
        return 1
    }

    var scratch: URL?
    do {
        let scratchDir = try Scratch.directory(for: input)
        scratch = scratchDir

        let book = try Epub.load(bookAt: input, scratch: scratchDir)

        let (renders, skipped) = try synthesizeChapters(of: book, in: scratchDir)

        let combined = scratchDir.appendingPathComponent("book.caf")
        try Assemble.concatenate(renders.map(\.cafURL), to: combined)

        let m4a = scratchDir.appendingPathComponent("book.m4a")
        try Encode.encodeCAF(from: combined, to: m4a)

        // Brand patch, then Chapter Markers (offsets computed from the known
        // per-chapter frame counts), then write straight to the output path.
        var data = try Data(contentsOf: m4a)
        data = try Brand.patchFTyp(in: data)
        let offsets = ChapterMarkers.startOffsets(frameCounts: renders.map(\.frameCount))
        let markers = zip(offsets, renders).map { ChapterMarker(sampleOffset: $0, title: $1.title) }
        data = try ChapterMarkers.insertChpl(markers: markers, trackTimescale: Int(Synthesis.sampleRate), into: data)
        try data.write(to: output)

        let totalSeconds = Double(renders.reduce(0) { $0 + $1.frameCount }) / Synthesis.sampleRate
        report(summaryLine(
            chapters: book.chapters.count,
            skipped: skipped,
            duration: totalSeconds,
            sizeInBytes: data.count,
            path: output.path
        ))

        try FileManager.default.removeItem(at: scratchDir)
        return 0
    } catch Epub.EpubError.notAValidEpub {
        report("error: Not a valid EPUB: \(input.path)")
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
private func synthesizeChapters(of book: Book, in scratch: URL) throws -> (renders: [ChapterRender], skipped: Int) {
    try FileManager.default.createDirectory(
        at: Scratch.chaptersDirectory(in: scratch), withIntermediateDirectories: true
    )

    var renders: [ChapterRender] = []
    var skipped = 0
    for (index, chapter) in book.chapters.enumerated() {
        let number = index + 1

        guard !chapter.text.isEmpty else {
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
            let utterance = AVSpeechUtterance(string: chapter.text)
            utterance.voice = AVSpeechSynthesisVoice(language: book.language) ?? AVSpeechSynthesisVoice()
            try Synthesis.render(utterance: utterance, to: cafURL)
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

private func report(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
