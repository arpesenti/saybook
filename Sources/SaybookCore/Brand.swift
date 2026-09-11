import Foundation

/// Patches the leading `ftyp` box of an M4A so the file is branded as an M4B
/// Audiobook: major brand `M4B `, compatible brands `m4b mp42 isom`.
/// The byte layout mirrors Apple's own `say -o x.m4b` output (verified in the
/// prototype probe, `prototype/verified-pipeline.swift`).
public enum Brand {

    public enum BrandError: Error, Equatable {
        /// The file does not begin with a well-formed `ftyp` box.
        case missingFtypBox
    }

    /// Rewrites the leading `ftyp` box, preserving every byte after it.
    public static func patchFTyp(in data: Data) throws -> Data {
        guard data.count >= 16 else { throw BrandError.missingFtypBox }
        let ftypSize = Int(readU32(data, at: 0))
        guard ftypSize >= 16, data.count >= ftypSize,
              data[data.startIndex + 4] == 0x66, // "ftyp"
              data[data.startIndex + 5] == 0x74,
              data[data.startIndex + 6] == 0x79,
              data[data.startIndex + 7] == 0x70
        else { throw BrandError.missingFtypBox }

        var box = Data()
        appendU32(&box, 28) // 8 header + 4 major + 3 × 4 compat + 4 minor
        box.append(contentsOf: Array("ftyp".utf8))
        box.append(contentsOf: Array("M4B ".utf8))
        box.append(contentsOf: Array("m4b ".utf8))
        box.append(contentsOf: Array("mp42".utf8))
        box.append(contentsOf: Array("isom".utf8))
        appendU32(&box, 0) // minor version

        var out = box
        out.append(data.dropFirst(ftypSize))
        return out
    }

    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { $0 })
    }
}
