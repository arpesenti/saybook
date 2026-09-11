// Verified probe: AAC chapter boundaries vs known PCM offsets.
// Measured on macOS 26.6.2 / Swift 6.3.3, 2026-09-11.
//
// Question: saybook's Chapter Marker offsets are computed from known
// per-chapter PCM frame counts (the concatenation is one continuous PCM
// stream before encoding). Do those offsets land at the TRUE chapter
// boundaries in the AAC-encoded track — or does AAC priming / encoder
// delay shift them?
//
// Method: 10 s mono 22 050 Hz Float32 input — 5 s of 440 Hz sine (0.5),
// then 5 s of exact zeros (boundary at frame 110 250). Encoded with
// AVAssetExportSession (the Encode.encodeCAF path), decoded with ffmpeg.
//
// Measured (2026-09-11):
//   decoded frames: 220500 == input frames (the moov edit list trims the
//   AAC priming exactly; total duration is preserved)
//   leading silence: 0 samples (presentation starts at input sample 0)
//   tone->silence:   frame 110250 — delta 0 from the true input boundary
//
// Conclusion: cumulative PCM frame offsets ARE the true chapter boundaries
// (exact, better than one AAC frame), so chpl offsets computed from known
// frame counts need no priming compensation. (MDCT windowing can bleed a
// transition over up to two 1024-sample frames, so boundary *detection* in
// decoded audio should allow ~2 frames; the offset itself is exact.)

import AVFoundation
import Foundation

let dir = URL(fileURLWithPath: "/tmp/saybook-aac-probe")
try? FileManager.default.removeItem(at: dir)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 22050.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
]

// 0-5 s: 440 Hz sine at 0.5; 5-10 s: zeros. Boundary at frame 110 250.
let toneFrames = 5 * 22_050
let total = 10 * 22_050
let cafURL = dir.appendingPathComponent("probe.caf")
let file = try AVAudioFile(forWriting: cafURL, settings: settings)
let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
buffer.frameLength = AVAudioFrameCount(total)
let ch = buffer.floatChannelData![0]
for i in 0..<total {
    ch[i] = i < toneFrames ? Float(0.5 * sin(2 * .pi * 440 * Double(i) / 22050)) : 0
}
try file.write(from: buffer)
print("input frames: \(total), boundary at frame \(toneFrames)")

let m4aURL = dir.appendingPathComponent("probe.m4a")
let asset = AVURLAsset(url: cafURL)
guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
    fatalError("no export session")
}
session.outputFileType = .m4a
let sem = DispatchSemaphore(value: 0)
Task.detached {
    do { try await session.export(to: m4aURL, as: .m4a); print("encode done") }
    catch { print("encode failed: \(error)") }
    sem.signal()
}
sem.wait()

let rawURL = dir.appendingPathComponent("decoded.f32")
let decodeTask = Process()
decodeTask.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
decodeTask.arguments = ["-y", "-v", "error", "-i", m4aURL.path, "-f", "f32le", "-acodec", "pcm_f32le", rawURL.path]
try! decodeTask.run()
decodeTask.waitUntilExit()
print("decode exit: \(decodeTask.terminationStatus)")

let raw = try! Data(contentsOf: rawURL)
let n = raw.count / MemoryLayout<Float>.size
print("decoded frames: \(n) (input \(total); delta \(n - total) = \(Double(n - total) / 22050 * 1000) ms)")

// 512-sample RMS windows (a bare |amp| test hits the sine's zero crossings).
func rms(_ start: Int, _ len: Int) -> Float {
    var sum: Float = 0
    for i in start..<min(start + len, n) {
        let v = raw.withUnsafeBytes { buf in
            buf.load(fromByteOffset: i * MemoryLayout<Float>.size, as: Float.self)
        }
        sum += v * v
    }
    return (sum / Float(len)).squareRoot()
}

// Leading silence (if the encoder delay leaked into the presentation).
var leadingSilence = 0
if rms(0, 512) < 0.01 {
    var j = 0
    while j < min(8192, n - 512) && rms(j, 512) < 0.01 { j += 64 }
    leadingSilence = j
}
print("leading silence samples: \(leadingSilence) (\(Double(leadingSilence) / 22050 * 1000) ms)")

// Tone -> silence transition around the true boundary.
var firstSilence = -1
var i = toneFrames - 4096
while i < min(toneFrames + 8192, n - 512) {
    if rms(i, 512) < 0.01 { firstSilence = i; break }
    i += 64
}
if firstSilence >= 0 {
    let delta = firstSilence - toneFrames
    print("tone->silence at decoded frame \(firstSilence); input boundary \(toneFrames); delta \(delta) samples = \(Double(delta) / 1024) AAC frames")
}
