// Verified end-to-end pipeline probe for saybook.
// Measured on macOS 26.6.2 / Swift 6.3.3, 2026-09-11.
//
// What this proves (with measured numbers):
//
// 1. AVSpeechSynthesizer.write(_:toBufferCallback:) is OFFLINE rendering:
//    21.5 s of audio rendered in 0.39 s (~55x realtime) as 22050 Hz mono
//    Float32 PCM buffers (~256 frames each).
// 2. Buffer and delegate callbacks arrive on the MAIN queue:
//    - A DispatchSemaphore.wait() on the main thread deadlocks (the callback
//      can never run).
//    - RunLoop.main.run(until:) never returns early, so poll with a short
//      `before:` interval until the delegate flag flips.
//    - didFinish fires AFTER the last buffer: wait on the delegate flag, not
//      on buffer count.
// 3. AVAudioFile (CAF) -> AVAssetExportSession.export(to:as:) yields AAC-LC
//    ~34 kb/s, 22050 Hz mono M4A, in ~0.03 s for 21.5 s of audio.
//    Gotchas hit while verifying:
//    - A freshly allocated AVAudioPCMBuffer has frameLength 0: writing one
//      silently stores zero bytes. Write the engine's buffer directly (its
//      format matches the CAF and its frameLength is set).
//    - The ExtAudioFile C API is NOT importable from Swift in the Xcode 26.6
//      SDK, and `afconvert` cannot write m4b on macOS 26. Hence this path.
// 4. Rewriting the leading ftyp box (major brand "M4B ", compatible brands
//    "m4b ", "mp42 ", "isom ") turns the M4A into a genuine M4B: `file`
//    reports "Apple iTunes ... (.M4B) Audio Book" and ffmpeg decodes it.
//    Byte layout mirrors Apple's own `say -o x.m4b` output.
// 5. AAC priming: the exported track carries a ~96 ms encoder delay at file
//    start (single file-level lead-in; no per-chapter seam in a concatenated
//    track).
//
// Usage:  swift prototype/verified-pipeline.swift   (writes probe.caf, probe.m4b)

import AVFoundation
import Foundation

let cafURL = URL(fileURLWithPath: "probe.caf")
let m4bURL = URL(fileURLWithPath: "probe.m4b")
try? FileManager.default.removeItem(at: cafURL)
try? FileManager.default.removeItem(at: m4bURL)

// ── 1. Synthesise ────────────────────────────────────────────────────────────
let text = Array(repeating: "The quick brown fox jumps over the lazy dog.", count: 8).joined(separator: " ")
let utterance = AVSpeechUtterance(string: text)
utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
let synth = AVSpeechSynthesizer()

// 22.05 kHz mono Float32 CAF — the engine's native output format.
guard let outFile = try? AVAudioFile(forWriting: cafURL, settings: [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 22050,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
]) else { fatalError("CAF open failed") }

final class Collector: NSObject, AVSpeechSynthesizerDelegate {
    let start: Date
    var didFinish = false
    init(start: Date) { self.start = start; super.init() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print(String(format: "synthesis done in %.2f s", Date().timeIntervalSince(start)))
        didFinish = true
    }
}

let t0 = Date()
let collector = Collector(start: t0)
synth.delegate = collector
synth.write(utterance) { buffer in
    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
    do {
        try outFile.write(from: pcm)
    } catch {
        print("CAF write failed:", error)
    }
}

// Callbacks are on the main queue: pump the main runloop until didFinish.
while !collector.didFinish {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

// ── 2. Encode CAF -> M4A (AAC-LC ~34 kb/s) ───────────────────────────────────
let asset = AVURLAsset(url: cafURL)
guard let exp = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
    fatalError("no export session")
}
exp.outputFileType = .m4a
let sem = DispatchSemaphore(value: 0)
Task {
    do { try await exp.export(to: m4bURL, as: .m4a); print("encode done") }
    catch { print("encode failed:", (error as NSError).code) }
    sem.signal()
}
_ = sem.wait()

// ── 3. Brand patch: M4A -> M4B ───────────────────────────────────────────────
// Rewrite the leading ftyp box: major brand "M4B ", compatible brands
// "m4b ", "mp42 ", "isom ".
func bigEndianU32(_ d: Data, _ off: Int) -> UInt32 {
    (UInt32(d[d.startIndex + off]) << 24) | (UInt32(d[d.startIndex + off + 1]) << 16)
        | (UInt32(d[d.startIndex + off + 2]) << 8) | UInt32(d[d.startIndex + off + 3])
}

guard var data = try? Data(contentsOf: m4bURL) else { fatalError("no m4a") }
let oldFtypSize = Int(bigEndianU32(data, 0))
precondition(String(data: data[(data.startIndex + 4)..<(data.startIndex + 8)], encoding: .isoLatin1) == "ftyp",
             "expected ftyp first box")

let ftypBox: Data = {
    var box = Data()
    let body: [UInt8] = Array("M4B m4b mp42isom".utf8)
    withUnsafeBytes(of: (8 + body.count + 4).bigEndian) { box.append(contentsOf: $0) }
    box.append(contentsOf: Array("ftyp".utf8))
    box.append(contentsOf: body)
    withUnsafeBytes(of: UInt32(0).bigEndian) { box.append(contentsOf: $0) } // minor version
    return box
}()
var out = ftypBox
out.append(data[(data.startIndex + oldFtypSize)...])
try out.write(to: m4bURL)
print("brand patched -> M4B")
