import Foundation

/// Minimal MP4 box-layout primitives shared by the in-place container edits:
/// `Brand` patches the leading `ftyp`, `ChapterMarkers` inserts `chpl`, and
/// `Metadata` inserts the `meta/ilst` identity boxes. The insertion
/// invariant is shared: `moov` must be the last top-level box, and the new
/// box is appended at the end of `moov`'s last `udta`, so the media data the
/// `stco` sample offsets point at never moves.
enum Mp4 {

    enum Mp4Error: Error, Equatable {
        /// No `moov` box was found (the data is not an MP4/M4B file).
        case noMoovBox
        /// `moov` is not the last top-level box. Appending at the end of
        /// `moov` would shift the media data the `stco` sample offsets point
        /// at, so the insertion is refused rather than corrupted.
        case moovNotLast
    }

    struct Box {
        /// 0-based byte range within the data.
        let range: Range<Int>
        let type: String
    }

    /// Walks top-level boxes of `data` (or of the container at `parent`),
    /// handling 64-bit sizes.
    static func topLevelBoxes(in data: Data, _ parent: Range<Int>? = nil) -> [Box] {
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
                // A 64-bit size needs 8 more bytes than the walk window may hold.
                guard o + 16 <= bounds.to else { break }
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

    /// The `moov` box, which must be the last top-level box (the append-at-
    /// end invariant that keeps the media data the `stco` offsets point at
    /// from moving).
    static func trailingMoov(in data: Data) throws -> Box {
        let top = topLevelBoxes(in: data)
        guard let moov = top.last, moov.type == "moov", moov.range.upperBound == data.count else {
            throw top.contains { $0.type == "moov" } ? Mp4Error.moovNotLast : Mp4Error.noMoovBox
        }
        return moov
    }

    /// `moov`'s last `udta` when it is also `moov`'s last child — the box an
    /// append-at-end insertion can extend without shifting any sibling.
    static func trailingUdta(in moov: Box, of data: Data) -> Box? {
        let children = topLevelBoxes(in: data, moov.range)
        guard let udta = children.last(where: { $0.type == "udta" }),
              udta.range.upperBound == moov.range.upperBound
        else { return nil }
        return udta
    }

    /// Appends `box` at the end of `moov`'s last `udta`, growing both `udta`
    /// and `moov` to cover it — or creates a fresh `udta` when `moov` carries
    /// none. Reusing the existing `udta` (AVAssetExportSession writes one
    /// with encoder metadata) follows the single-`udta`-per-`moov`
    /// convention of Apple's own M4Bs: a reader that consults only the first
    /// `udta` still finds the appended box. `moov` must be the last top-level
    /// box (true of AVAssetExportSession output); every other byte is
    /// preserved, so the media data the `stco` offsets point at does not
    /// shift.
    static func appendToMoovUdta(_ box: Data, into data: Data) throws -> Data {
        let moov = try trailingMoov(in: data)

        var out = [UInt8](data)
        let boxBytes = [UInt8](box)

        guard let udta = trailingUdta(in: moov, of: data) else {
            // No trailing udta: append a new one as moov's last child.
            var udtaBytes = u32(UInt32(8 + boxBytes.count))
            udtaBytes += Array("udta".utf8)
            udtaBytes += boxBytes
            setU32(&out, at: moov.range.lowerBound, UInt32(moov.range.count + udtaBytes.count))
            out += udtaBytes
            return Data(out)
        }

        // Extend the last udta (and moov) to cover the appended box.
        setU32(&out, at: udta.range.lowerBound, UInt32(udta.range.count + boxBytes.count))
        setU32(&out, at: moov.range.lowerBound, UInt32(moov.range.count + boxBytes.count))
        out += boxBytes
        return Data(out)
    }

    static func u32(_ v: UInt32) -> [UInt8] {
        withUnsafeBytes(of: v.bigEndian) { Array($0) }
    }

    static func u64(_ v: UInt64) -> [UInt8] {
        withUnsafeBytes(of: v.bigEndian) { Array($0) }
    }

    /// Overwrites the 4 bytes at `offset` with `value` (big-endian).
    static func setU32(_ bytes: inout [UInt8], at offset: Int, _ value: UInt32) {
        let be = u32(value)
        for k in 0..<4 { bytes[offset + k] = be[k] }
    }
}
