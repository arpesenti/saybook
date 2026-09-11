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

    let scratch = URL.temporaryDirectory.appendingPathComponent("saybook-\(UUID().uuidString)")
    do {
        let book = try Epub.load(bookAt: input, scratch: scratch)

        let cafURLs = try synthesizeChapters(of: book, in: scratch)

        let combined = scratch.appendingPathComponent("book.caf")
        try Assemble.concatenate(cafURLs, to: combined)

        let m4a = scratch.appendingPathComponent("book.m4a")
        try Encode.encodeCAF(from: combined, to: m4a)

        // Brand patch, then write straight to the final output path.
        let data = try Data(contentsOf: m4a)
        try Brand.patchFTyp(in: data).write(to: output)

        try FileManager.default.removeItem(at: scratch)
        return 0
    } catch Epub.EpubError.notAValidEpub {
        report("error: Not a valid EPUB: \(input.path)")
        return 1
    } catch let error as SaybookError {
        report("error: \(error.message)")
        return 1
    } catch {
        report("error: \(error) (scratch kept: \(scratch.path))")
        return 2
    }
}

// MARK: - Per-chapter synthesis

/// Synthesises each Chapter to its own CAF (in Spine order) and reports one
/// progress line per completed Chapter on stderr.
@MainActor
private func synthesizeChapters(of book: Book, in scratch: URL) throws -> [URL] {
    let chaptersDir = scratch.appendingPathComponent("chapters")
    try FileManager.default.createDirectory(at: chaptersDir, withIntermediateDirectories: true)

    var cafURLs: [URL] = []
    for (index, chapter) in book.chapters.enumerated() {
        let number = index + 1
        var duration: TimeInterval = 0

        if !chapter.text.isEmpty {
            let cafURL = chaptersDir.appendingPathComponent(String(format: "chapter-%03d.caf", number))
            let utterance = AVSpeechUtterance(string: chapter.text)
            utterance.voice = AVSpeechSynthesisVoice(language: book.language) ?? AVSpeechSynthesisVoice()
            try Synthesis.render(utterance: utterance, to: cafURL)
            duration = try cafDuration(at: cafURL)
            cafURLs.append(cafURL)
        }

        report("✓ \(number)/\(book.chapters.count) · \(chapter.title) · \(formatDuration(duration))")
    }

    guard !cafURLs.isEmpty else {
        throw SaybookError(message: "No readable chapters in \(book.title)")
    }
    return cafURLs
}

private func cafDuration(at url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

/// m:ss (e.g. `2:31`); minutes grow unbounded.
private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
}

private func report(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
