import AVFoundation
import Foundation
import XCTest
@testable import SaybookCore

/// The silence measurement the inter-Block-pause e2e test depends on
/// (`interiorSilentRuns`), tested against synthetic PCM at the exact shapes
/// real engine output produces — including the one that made
/// `testBlocksAreSeparatedByAudiblePauses` red on macOS 27: a Chapter's last
/// Block ends in ~0.2 s of engine edge silence that runs to the end of the
/// file, and the file's last 182 frames (8 ms) are too short to fill a 10 ms
/// window, so a scanner that only tests whole windows sees the run as
/// "interior" and counts it as an inter-Block pause.
final class SilenceMeasurementTests: XCTestCase {

    private let sampleRate = 22_050
    private let window = 22_050 / 100   // the scanner's 10 ms window

    /// The inter-Block-pause scan the e2e test uses.
    private func pauses(in pcm: Data) -> [SilentRun] {
        interiorSilentRuns(in: pcm, sampleRate: sampleRate, minimum: 0.2, maximum: 1.5)
    }

    /// `count` frames of a ± square wave of `amplitude`, as Float32 LE: a
    /// window's RMS equals its amplitude, so 0.15 is speech, 0.012 is
    /// sub-speech junk (above the silence floor, below the speech floor) and
    /// 0 is digital silence.
    private func frames(_ count: Int, _ amplitude: Float) -> Data {
        var data = Data(capacity: count * 4)
        for i in 0..<count {
            let sign: Float = i % 2 == 0 ? 1 : -1
            data.append(contentsOf: withUnsafeBytes(of: amplitude * sign) { Array($0) })
        }
        return data
    }

    /// PCM built from (window count, amplitude) runs.
    private func pcm(_ runs: [(windows: Int, amplitude: Float)]) -> Data {
        runs.reduce(Data()) { $0 + frames($1.windows * window, $1.amplitude) }
    }

    /// Loud speech of `seconds` (rounded down to whole windows).
    private func speech(_ seconds: TimeInterval) -> (windows: Int, amplitude: Float) {
        (Int(seconds * Double(sampleRate)) / window, 0.15)
    }

    private func durations(_ runs: [SilentRun]) -> [TimeInterval] {
        runs.map { $0.duration.rounded(to: 0.01) }
    }

    func testFindsAnInteriorPauseAndIgnoresANaturalGap() {
        // speech · 0.4 s silence · speech · 0.08 s inter-word gap · speech
        let runs = pauses(in: pcm([speech(0.5), (40, 0), speech(0.5), (8, 0), speech(0.5)]))

        XCTAssertEqual(durations(runs), [0.4], "only the 0.4 s run is a pause")
    }

    func testIgnoresTrailingSilenceThatEndsInARaggedPartialWindow() {
        // The macOS 27 shape: speech, then 0.22 s of edge silence of which
        // the last 182 frames cannot fill a window, then the end of the file.
        // Those frames are not silence either, just 200x below the floor.
        let runs = pauses(in: pcm([speech(0.5), (22, 0)]) + frames(182, 0.00005))

        XCTAssertEqual(durations(runs), [], "trailing edge silence is not an inter-Block pause")
    }

    func testIgnoresLeadingSilenceAtTheHeadOfTheFile() {
        let runs = pauses(in: pcm([(30, 0), speech(0.5), (40, 0), speech(0.5)]))

        XCTAssertEqual(durations(runs), [0.4], "the head silence is an edge, only the interior one is a pause")
        XCTAssertEqual(runs.first?.start, (30 + 50) * window, "the pause starts after the head silence and the speech that follows it")
    }

    func testIgnoresSilenceFollowedOnlyBySubSpeechJunk() {
        // The decoder-junk shape: the silence is followed to the end of the
        // file by material above the silence floor but nowhere near speech,
        // so nothing bounds it as a pause between two Blocks.
        let runs = pauses(in: pcm([speech(0.5), (30, 0), (60, 0.012)]))

        XCTAssertEqual(durations(runs), [], "junk is not speech")
    }

    func testIgnoresSilencePrecededOnlyBySubSpeechJunk() {
        // The mirror shape: the "run of silence" is really the noise floor.
        let runs = pauses(in: pcm([(60, 0.012), (30, 0), speech(0.5)]))

        XCTAssertEqual(durations(runs), [], "junk is not speech")
    }

    func testIgnoresSilenceLongerThanTheMaximum() {
        let runs = pauses(in: pcm([speech(0.5), (200, 0), speech(0.5)]))

        XCTAssertEqual(durations(runs), [], "2 s of silence is not an inter-Block pause")
    }

    func testIgnoresASilentFile() {
        XCTAssertEqual(durations(pauses(in: pcm([(200, 0)]))), [], "a whole-silent file has no pauses")
    }
}

private extension TimeInterval {
    /// Rounded for readable, quantisation-tolerant assertions on window runs.
    func rounded(to step: TimeInterval) -> TimeInterval {
        (self / step).rounded() * step
    }
}
