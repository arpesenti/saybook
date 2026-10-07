// Prints the chapters AVFoundation vends for an Audiobook — one line per
// Chapter, `startSeconds<TAB>title` — or exits non-zero when the file cannot
// be read. Used by `Scripts/e2e.sh` as the assertion that matters for
// Chapter Markers (ticket 12): `ffprobe` reads the `chpl` box, which Apple's
// players ignore entirely, so a file whose markers live only in `chpl` passes
// every ffprobe check and shows no chapters in Books, VoiceOver or QuickTime.
//
// Deliberately standalone (no SaybookCore import): this is an independent
// reader of the artifact, using the same AVFoundation call those players use.
// Compile: swiftc -O -warnings-as-errors -o apple-chapters Scripts/apple-chapters.swift

import AVFoundation
import Foundation

final class ProbeResult: @unchecked Sendable {
    var output: [(start: Double, title: String)] = []
    var failure: Error?
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard !path.isEmpty else {
    FileHandle.standardError.write(Data("usage: apple-chapters <audiobook>\n".utf8))
    exit(2)
}

let asset = AVURLAsset(url: URL(fileURLWithPath: path))
let result = ProbeResult()
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let groups = try await asset.loadChapterMetadataGroups(
            withTitleLocale: Locale(identifier: "en-US"),
            containingItemsWithCommonKeys: [.commonKeyTitle]
        )
        for group in groups {
            let item = group.items.first { $0.commonKey == .commonKeyTitle }
            let title = try? await item?.load(.stringValue)
            result.output.append((group.timeRange.start.seconds, title.flatMap { $0 } ?? ""))
        }
    } catch {
        result.failure = error
    }
    semaphore.signal()
}
semaphore.wait()

if let failure = result.failure {
    FileHandle.standardError.write(Data("error: \(failure)\n".utf8))
    exit(1)
}
for chapter in result.output {
    print("\(chapter.start)\t\(chapter.title)")
}
