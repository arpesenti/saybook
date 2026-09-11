import AVFoundation
import Foundation

/// Concatenates the per-Chapter PCM CAFs (written with `Synthesis.cafSettings`,
/// already in Spine order) into one CAF.
public enum Assemble {

    public enum AssembleError: Error, Equatable {
        /// No input CAFs were given (e.g. every Chapter was skipped).
        case noInputFiles
    }

    public static func concatenate(_ inputs: [URL], to output: URL) throws {
        guard !inputs.isEmpty else { throw AssembleError.noInputFiles }
        let out = try AVAudioFile(forWriting: output, settings: Synthesis.cafSettings)
        let capacity = AVAudioFrameCount(65_536)

        for input in inputs {
            let file = try AVAudioFile(forReading: input)
            // Bounded by the file length: a read at EOF throws (nilError) in
            // current AVFoundation rather than returning zero frames.
            let total = file.length
            var done: AVAudioFramePosition = 0
            let buffer = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: capacity)!
            while done < total {
                buffer.frameLength = 0
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                done += AVAudioFramePosition(buffer.frameLength)
                try out.write(from: buffer)
            }
        }
    }

    /// A silence CAF of exactly `frames` zero samples in the standard
    /// Synthesis format: the inter-Block pause (ticket 05). Overwrites any
    /// file already at `output` (a re-run re-renders the whole chapter).
    public static func writeSilenceCAFFrames(_ frames: Int, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        let out = try AVAudioFile(forWriting: output, settings: Synthesis.cafSettings)
        let buffer = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData![0].update(repeating: 0, count: frames)
        try out.write(from: buffer)
    }
}
