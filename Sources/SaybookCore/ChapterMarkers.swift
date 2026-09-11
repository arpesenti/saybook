import Foundation

/// A Chapter Marker: where a Chapter begins, addressed in the Audiobook's
/// track timescale (one unit per audio sample).
public struct ChapterMarker: Sendable, Equatable {
    /// Offset of the chapter's first sample, in track-timescale units.
    public let sampleOffset: Int
    /// The marker title (the Chapter's title).
    public let title: String

    public init(sampleOffset: Int, title: String) {
        self.sampleOffset = sampleOffset
        self.title = title
    }
}

/// Chapter Markers as a `chpl` box in the M4B container (ADR 0002).
///
/// The box lives in `moov/udta` — the placement Apple's M4B audiobooks and
/// FFmpeg's mov muxer use. Each entry stores the chapter start in 100 ns
/// units:
///
///     size | "chpl" | version(1) = 1 | flags(3) = 0 | reserved(4) = 0 | count(u8)
///     per chapter: start(i64 big-endian, 100 ns) | titleLen(u8) | title(UTF-8)
///
/// Offsets are computed from known per-chapter frame counts, never parsed
/// from the encoded stream (ADR 0001: the speech engine emits no markers).
/// Track-timescale sample offsets are converted to 100 ns units exactly in
/// integer arithmetic; the parse round trip is exact to within one sample.
public enum ChapterMarkers {

    public enum ChapterMarkerError: Error, Equatable {
        /// No `moov` box was found (the data is not an MP4/M4B file).
        case noMoovBox
        /// `moov` is not the last top-level box. Appending `udta/chpl` at the
        /// end of `moov` would shift the media data the `stco` sample offsets
        /// point at, so the insertion is refused rather than corrupted.
        case moovNotLast
    }

    /// Chapter start offsets (track-timescale units) from per-chapter frame
    /// counts: chapter 0 starts at 0; chapter *k* at the sum of the frame
    /// counts of all earlier chapters.
    public static func startOffsets(frameCounts: [Int]) -> [Int] {
        var offsets: [Int] = []
        var sum = 0
        for frames in frameCounts {
            offsets.append(sum)
            sum += frames
        }
        return offsets
    }

    /// Builds the `chpl` box for `markers`, converting each offset from
    /// `trackTimescale` units to 100 ns units.
    /// Titles are truncated to 255 bytes and the chapter count to 255 (the
    /// width of the on-disk fields); both are far beyond real books.
    public static func box(markers: [ChapterMarker], trackTimescale: Int) -> Data {
        var out: [UInt8] = []
        out += u32(0) // size placeholder
        out += Array("chpl".utf8)
        out += [0x01] // version
        out += [0, 0, 0] // flags
        out += [0, 0, 0, 0] // reserved
        out.append(UInt8(min(markers.count, 255)))
        for marker in markers.prefix(255) {
            out += hundredNanoUnits(from: marker.sampleOffset, trackTimescale: trackTimescale)
            let titleBytes = Array(marker.title.utf8).prefix(255)
            out.append(UInt8(titleBytes.count))
            out += Array(titleBytes)
        }
        out.replaceSubrange(0..<4, with: u32(UInt32(out.count)))
        return Data(out)
    }

    /// Appends `box` at the end of `moov`'s last `udta`, growing both `udta`
    /// and `moov` to cover it — or creates a fresh `udta` when `moov` carries
    /// none. Reusing the existing `udta` (AVAssetExportSession writes one
    /// with encoder metadata) follows the single-`udta`-per-`moov`
    /// convention of Apple's own M4Bs: a reader that consults only the first
    /// `udta` still finds the `chpl` box. `moov` must be the last top-level
    /// box (true of AVAssetExportSession output); every other byte is
    /// preserved, so the media data the `stco` offsets point at does not
    /// shift.
    public static func insert(box: Data, into data: Data) throws -> Data {
        let top = topLevelBoxes(in: data)
        guard let moov = top.last, moov.type == "moov", moov.range.upperBound == data.count else {
            throw moovIsAbsent(top) ? ChapterMarkerError.noMoovBox : ChapterMarkerError.moovNotLast
        }

        var out = [UInt8](data)
        let boxBytes = [UInt8](box)
        let moovChildren = topLevelBoxes(in: data, moov.range)

        if let udta = moovChildren.last(where: { $0.type == "udta" }),
           udta.range.upperBound == moov.range.upperBound {
            // Extend the last udta (and moov) to cover the appended box.
            setU32(&out, at: udta.range.lowerBound, UInt32(udta.range.count + boxBytes.count))
            setU32(&out, at: moov.range.lowerBound, UInt32(moov.range.count + boxBytes.count))
            out += boxBytes
        } else {
            // No trailing udta: append a new one as moov's last child.
            var udtaBytes = u32(UInt32(8 + boxBytes.count))
            udtaBytes += Array("udta".utf8)
            udtaBytes += boxBytes
            setU32(&out, at: moov.range.lowerBound, UInt32(moov.range.count + udtaBytes.count))
            out += udtaBytes
        }
        return Data(out)
    }

    /// Convenience: build the box for `markers` and insert it.
    public static func insertChpl(markers: [ChapterMarker], trackTimescale: Int, into data: Data) throws -> Data {
        try insert(box: box(markers: markers, trackTimescale: trackTimescale), into: data)
    }

    /// Parses the `moov/udta/chpl` box, converting 100 ns starts back to
    /// `trackTimescale` units (within one sample). Returns nil when the file
    /// carries no well-formed box. The search walks every `udta` inside
    /// `moov`: AVAssetExportSession output already carries one (encoder
    /// metadata), and the `chpl` box lives in the one appended here.
    public static func parseChpl(from data: Data, trackTimescale: Int) -> [ChapterMarker]? {
        guard let moov = topLevelBoxes(in: data).first(where: { $0.type == "moov" }) else { return nil }
        for udta in topLevelBoxes(in: data, moov.range) where udta.type == "udta" {
            if let chpl = topLevelBoxes(in: data, udta.range).first(where: { $0.type == "chpl" }) {
                return Self.parseChplPayload(chpl.range, in: data, trackTimescale: trackTimescale)
            }
        }
        return nil
    }

    private static func parseChplPayload(_ chpl: Range<Int>, in data: Data, trackTimescale: Int) -> [ChapterMarker]? {
        var pos = chpl.lowerBound + 8 // skip the box header
        let end = chpl.upperBound
        func take(_ n: Int) -> [UInt8]? {
            guard pos + n <= end else { return nil }
            defer { pos += n }
            return [UInt8](data[data.startIndex + pos..<(data.startIndex + pos + n)])
        }

        guard take(4) != nil, // version + flags
              take(4) != nil, // reserved
              let countBytes = take(1)
        else { return nil }
        let count = Int(countBytes[0])

        var markers: [ChapterMarker] = []
        for _ in 0..<count {
            guard let tsBytes = take(8),
                  let lenBytes = take(1),
                  let titleBytes = take(Int(lenBytes[0]))
            else { return nil }
            let ts = tsBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let sampleOffset = Int((Double(ts) * Double(trackTimescale) / 10_000_000).rounded())
            guard let title = String(bytes: titleBytes, encoding: .utf8) else { return nil }
            markers.append(ChapterMarker(sampleOffset: sampleOffset, title: title))
        }
        return markers
    }

    // MARK: - Internals

    private struct Box {
        /// 0-based byte range within the data.
        let range: Range<Int>
        let type: String
    }

    private static func topLevelBoxes(in data: Data, _ parent: Range<Int>? = nil) -> [Box] {
        let bounds = parent.map { (from: $0.lowerBound + 8, to: $0.upperBound) } ?? (from: 0, to: data.count)
        var o = bounds.from
        var boxes: [Box] = []
        while o + 8 <= bounds.to {
            let size32 = (UInt32(data[data.startIndex + o]) << 24)
                | (UInt32(data[data.startIndex + o + 1]) << 16)
                | (UInt32(data[data.startIndex + o + 2]) << 8)
                | UInt32(data[data.startIndex + o + 3])
            let size: Int
            if size32 == 1 {
                var large: UInt64 = 0
                for k in 0..<8 { large = (large << 8) | UInt64(data[data.startIndex + o + 8 + k]) }
                size = Int(large)
            } else {
                size = Int(size32)
            }
            guard size >= 8, o + size <= bounds.to else { break }
            let type = String(bytes: data[(data.startIndex + o + 4)..<(data.startIndex + o + 8)], encoding: .isoLatin1) ?? "?"
            boxes.append(Box(range: o..<(o + size), type: type))
            o += size
        }
        return boxes
    }

    private static func moovIsAbsent(_ boxes: [Box]) -> Bool {
        boxes.allSatisfy { $0.type != "moov" }
    }

    /// Exact integer conversion: samples (track timescale) → 100 ns units,
    /// half-up rounded.
    private static func hundredNanoUnits(from sampleOffset: Int, trackTimescale: Int) -> [UInt8] {
        let value = (Int64(sampleOffset) * 10_000_000 + Int64(trackTimescale) / 2) / Int64(trackTimescale)
        return u64(UInt64(bitPattern: value))
    }

    private static func u32(_ v: UInt32) -> [UInt8] {
        withUnsafeBytes(of: v.bigEndian) { Array($0) }
    }

    private static func u64(_ v: UInt64) -> [UInt8] {
        withUnsafeBytes(of: v.bigEndian) { Array($0) }
    }

    /// Overwrites the 4 bytes at `offset` with `value` (big-endian).
    private static func setU32(_ bytes: inout [UInt8], at offset: Int, _ value: UInt32) {
        let be = u32(value)
        for k in 0..<4 { bytes[offset + k] = be[k] }
    }
}
