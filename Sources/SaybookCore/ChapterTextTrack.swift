import Foundation

/// The Chapter Markers in the form Apple's players read: a QuickTime
/// **chapter text track** — a second `trak` carrying one text sample per
/// Chapter, referenced from the audio track by `trak/tref/chap`.
///
/// Why this exists alongside `chpl` (ticket 12): `chpl` is a Nero/FFmpeg
/// convention that `ffprobe` and many third-party players read, but
/// **AVFoundation does not derive chapters from it**. Measured on this machine
/// by ablating a real commercial M4B box by box and asking
/// `AVURLAsset.chapterMetadataGroups(withTitleLocale:containingItemsWithCommonKeys:)`:
///
///   - `chpl` removed → chapters still read (so `chpl` is neither necessary
///     nor sufficient for AVFoundation),
///   - chapter text track removed → zero chapters,
///   - `tref/chap` removed → zero chapters.
///
/// So the layout that makes chapters *appear* in Books, VoiceOver and
/// QuickTime is: a `trak` whose `mdia/hdlr` handler is `text`, with `stts`
/// durations spanning each Chapter, `stsz`/`stco` addressing one sample per
/// Chapter (each sample: `uint16` title length + UTF-8 title + an `encd`
/// box), plus a `tref/chap` in the audio track naming that track's ID.
///
/// The boxes that carry no per-Book value (`gmhd`, `dinf`, `stsd`, `stsc`) are
/// byte-for-byte the ones a real Apple-produced M4B carries — the `golden`
/// table below, pinned by `ChapterTextTrackTests`. Everything that does vary
/// (track ID, timescale, duration, the sample table) is computed here, field
/// by field, from the audio track's own `mdhd`/`tkhd`.
///
/// Insertion obeys the same invariant as `Brand`, `Metadata` and
/// `ChapterMarkers`: the media data the `stco` offsets point at never moves.
/// The chapter samples go at the **end of `mdat`**, which sits immediately
/// before `moov` (`moov` must be last), so every audio byte keeps its absolute
/// address; only box sizes and `mdat`'s size grow. Because of that, this edit
/// must run **after** the `udta` appends (`Metadata`, `chpl`), which require
/// `udta` to be `moov`'s last child.
public enum ChapterTextTrack {

    public enum ChapterTextTrackError: Error, Equatable {
        /// No `moov` box was found (the data is not an MP4/M4B file).
        case noMoovBox
        /// `moov` is not the last top-level box.
        case moovNotLast
        /// `moov` carries no audio `trak` with the `tkhd`/`mdia`/`mdhd` this
        /// track is built from.
        case noAudioTrack
        /// No `mdat` to append the chapter samples to, or `mdat` does not end
        /// before `moov` begins.
        case noMediaData
        /// The Chapter offsets are not expressible in the audio track's
        /// timescale.
        case timescaleMismatch
    }

    /// The chapter track's ID: one past the audio track's, so it cannot
    /// collide with the ID the encoder assigned.
    public static func chapterTrackID(audioTrackID: UInt32) -> UInt32 { audioTrackID &+ 1 }

    /// Builds the chapter text track and the audio track's `tref`, and inserts
    /// both into `data`.
    ///
    /// - Parameters:
    ///   - markers: the same `[ChapterMarker]` the `chpl` box is built from.
    ///   - trackTimescale: the timescale `markers`' `sampleOffset`s are
    ///     expressed in (`Synthesis.trackTimescale`). The chapter track is put
    ///     on the audio track's own timescale so chapter starts stay exact
    ///     integers; a mismatch is an error rather than a silent rounding.
    public static func insert(
        markers: [ChapterMarker], trackTimescale: Int, into data: Data
    ) throws -> Data {
        let moov: Mp4.Box
        do { moov = try Mp4.trailingMoov(in: data) }
        catch let error as Mp4.Mp4Error {
            throw error == .noMoovBox
                ? ChapterTextTrackError.noMoovBox : ChapterTextTrackError.moovNotLast
        }
        guard let audio = Mp4.topLevelBoxes(in: data, moov.range).first(where: { $0.type == "trak" }),
              let tkhd = Mp4.childBox(in: data, of: audio, named: "tkhd"),
              let mdia = Mp4.childBox(in: data, of: audio, named: "mdia"),
              let mdhd = Mp4.childBox(in: data, of: mdia, named: "mdhd"),
              let mvhd = Mp4.childBox(in: data, of: moov, named: "mvhd")
        else { throw ChapterTextTrackError.noAudioTrack }
        guard let mdat = Mp4.topLevelBoxes(in: data).first(where: { $0.type == "mdat" }),
              mdat.range.upperBound <= moov.range.lowerBound
        else { throw ChapterTextTrackError.noMediaData }

        let trackTimescaleOfAudio = try timescale(in: data, mdhd)
        let trackDuration = try duration(in: data, mdhd)
        let audioTrackID = try trackID(in: data, tkhd)
        // `tkhd.duration` and `elst.segment_duration` are expressed in the
        // MOVIE timescale, so they take mvhd's duration; `mdhd.duration` (the
        // sample table's world) is in the track's own timescale. The encoder
        // sets both timescales to 22 050, so the two numbers coincide — but
        // reading the movie's own is the correct source, not a happy accident.
        let movieDuration = try duration(in: data, mvhd, versioned: false)
        guard trackTimescaleOfAudio > 0 else { throw ChapterTextTrackError.noAudioTrack }
        let starts: [Int]
        if trackTimescaleOfAudio == trackTimescale {
            starts = markers.map(\.sampleOffset)
        } else {
            // Exact conversion, half-up; a marker that does not land on a
            // sample boundary is a bug in the caller, not something to hide.
            guard markers.allSatisfy({ $0.sampleOffset >= 0 }) else {
                throw ChapterTextTrackError.timescaleMismatch
            }
            starts = markers.map {
                Int((Int64($0.sampleOffset) * Int64(trackTimescaleOfAudio) + Int64(trackTimescale) / 2)
                    / Int64(trackTimescale))
            }
        }

        let trackID = chapterTrackID(audioTrackID: audioTrackID)
        let samples = sampleBlob(markers: markers)
        let sampleSizes = markers.map { sample(for: $0.title).count }
        let sampleDurations = stride(over: starts, total: trackDuration)
        // The samples land at the end of `mdat`'s payload, which — `moov`
        // being the last top-level box — is exactly where `moov` begins. The
        // chapter track's `stco` addresses them by absolute offset, so this is
        // the one number the sample table depends on.
        let samplesAt = mdat.range.upperBound

        let trak = track(
            trackID: trackID, timescale: trackTimescaleOfAudio, trackDuration: trackDuration, movieDuration: movieDuration,
            sampleSizes: sampleSizes, sampleDurations: sampleDurations, firstSampleOffset: samplesAt
        )
        let tref = trefBox(chapterTrackID: trackID)

        // Only the `moov` subtree is mutated, and it is edited in its OWN
        // coordinate space and then re-joined. Patching boxes inside a detached
        // copy and concatenating the pieces avoids the trap of writing a size at
        // a position an earlier insertion has already shifted — the bug that put
        // the chapter trak inside `udta` during development. The samples go
        // between the two pieces, so every audio byte keeps its address and the
        // chapter track's `stco` can name absolute offsets.
        var moovBytes = [UInt8](data[moov.range])
        let local = moov.range.lowerBound

        // tref/chap into the audio trak, after tkhd (Apple's child order).
        moovBytes.insert(contentsOf: tref, at: tkhd.range.upperBound - local)
        // The chapter trak as moov's last child.
        moovBytes.append(contentsOf: trak)
        // Every ancestor of an inserted box grows to still cover it. Both size
        // fields sit inside `moov` before either insertion point above, so
        // neither edit can have moved them.
        grow(&moovBytes, at: moov.range.lowerBound - local, by: tref.count + trak.count, headerOf: moov, in: data)
        grow(&moovBytes, at: audio.range.lowerBound - local, by: tref.count, headerOf: audio, in: data)

        var out = [UInt8](data[data.startIndex..<mdat.range.upperBound])
        out.append(contentsOf: samples)
        out.append(contentsOf: moovBytes)

        // mdat now ends with the samples it must still cover.
        setSize(&out, of: mdat, grownBy: samples.count, measuredIn: data)
        return Data(out)
    }

    // MARK: - Samples

    /// One chapter sample: `uint16` title length, UTF-8 title, then an `encd`
    /// box (the text encoding Apple's own chapter samples declare).
    public static func sample(for title: String) -> [UInt8] {
        let text = Array(title.utf8).prefix(65_535)
        var out: [UInt8] = [UInt8(text.count >> 8), UInt8(text.count & 0xff)]
        out += Array(text)
        out += Mp4.u32(12) + Array("encd".utf8) + Mp4.u32(0x0000_0100)
        return out
    }

    /// All Chapter samples concatenated — the blob appended to `mdat`.
    public static func sampleBlob(markers: [ChapterMarker]) -> [UInt8] {
        markers.flatMap { sample(for: $0.title) }
    }

    /// One duration per Chapter: the gap to the next start, the last Chapter
    /// running to the end of the Audiobook. Summing to `total` is what makes
    /// the last chapter's end land exactly on the end of the audio.
    public static func stride(over starts: [Int], total: Int) -> [Int] {
        guard !starts.isEmpty else { return [] }
        return starts.indices.map { i in
            let end = i + 1 < starts.count ? starts[i + 1] : total
            return Swift.max(0, end - starts[i])
        }
    }

    /// Absolute offsets of consecutive samples given where the first lands.
    static func offsets(from first: Int, sizes: [Int]) -> [Int] {
        var out: [Int] = []
        var at = first
        for size in sizes { out.append(at); at += size }
        return out
    }

    // MARK: - Box construction

    /// The chapter `trak`: `tkhd`, `edts/elst`, `mdia { mdhd, hdlr,
    /// minf { gmhd, dinf, stbl { stsd, stts, stsc, stsz, stco } } }`.
    public static func track(
        trackID: UInt32, timescale: Int, trackDuration: Int, movieDuration: Int,
        sampleSizes: [Int], sampleDurations: [Int], firstSampleOffset: Int
    ) -> [UInt8] {
        // The three boxes whose fixed bytes Apple's own chapter track carries
        // are copied and have only their varying fields patched, at offsets
        // verified against AVAssetExportSession's audio boxes and Apple's
        // chapter track (see the table in "Reading the encoder's audio track"):
        //
        //   tkhd  ver@0 · track_ID@12 · duration@20   (movie timescale)
        //   mdhd  ver@0 · timescale@12 · duration@16  (this track's timescale)
        //   elst  ver@0 · entry_count@4 · segment_duration@8 · media_time@12
        //         · media_rate@16 (integer 2 + fraction 2, so 1.0 = 0x0001_0000)
        //
        // elst is what makes the chapters visible: AVFoundation clips chapter
        // groups to the chapter track's edit list, so a segment_duration short
        // of the Audiobook silently truncates the chapter list (a 4-second edit
        // list over an 11.9-hour book left exactly one group).
        let tkhd = patch(golden(.tkhd), at: 8 + 12, Mp4.u32(trackID))
        let tkhdDuration = patch(tkhd, at: 8 + 20, Mp4.u32(UInt32(movieDuration)))
        let mdhd = patch(golden(.mdhd), at: 8 + 12, Mp4.u32(UInt32(timescale)))
        let mdhdDuration = patch(mdhd, at: 8 + 16, Mp4.u32(UInt32(trackDuration)))
        let elst = patch(golden(.elst), at: 8 + 8, Mp4.u32(UInt32(movieDuration)))
        let elstEntry = patch(elst, at: 8 + 12, Mp4.u32(0))          // media_time
        let elstRate = patch(elstEntry, at: 8 + 16, Mp4.u32(0x0001_0000))  // rate 1.0

        let stbl = box("stbl", golden(.stsd)
            + fullBox("stts", Mp4.u32(UInt32(sampleDurations.count))
                + sampleDurations.flatMap { Mp4.u32(1) + Mp4.u32(UInt32($0)) })
            + golden(.stsc)
            + fullBox("stsz", Mp4.u32(0) + Mp4.u32(UInt32(sampleSizes.count))
                + sampleSizes.flatMap { Mp4.u32(UInt32($0)) })
            + fullBox("stco", Mp4.u32(UInt32(sampleSizes.count))
                + offsets(from: firstSampleOffset, sizes: sampleSizes).flatMap { Mp4.u32(UInt32($0)) }))
        let minf = box("minf", golden(.gmhd) + golden(.dinf) + stbl)
        let mdia = box("mdia", mdhdDuration + golden(.hdlr) + minf)
        return box("trak", tkhdDuration + box("edts", elstRate) + mdia)
    }

    /// Overwrites `bytes` at `offset` with `value`, leaving a copy.
    private static func patch(_ bytes: [UInt8], at offset: Int, _ value: [UInt8]) -> [UInt8] {
        var out = bytes
        precondition(offset + value.count <= out.count, "golden box too short to patch")
        for (i, byte) in value.enumerated() { out[offset + i] = byte }
        return out
    }

    /// `trak/tref/chap` naming the chapter track.
    public static func trefBox(chapterTrackID: UInt32) -> [UInt8] {
        box("tref", box("chap", Mp4.u32(chapterTrackID)))
    }

    private static let identityMatrix: [UInt8] = [
        0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0x00, 0x00, 0x00,
    ]

    // MARK: - Golden fixed-shape boxes
    //
    // Verbatim from the chapter text track of a real Apple-produced M4B
    // (ticket 12). They carry no per-Book value, so they are copied rather
    // than re-derived; a test pins them against that reference so a future
    // edit cannot quietly change the container Apple's parser accepts.

    enum Golden: String, CaseIterable {
        case dinf, elst, gmhd, hdlr, mdhd, stsc, stsd, tkhd
    }

    static func golden(_ kind: Golden) -> [UInt8] {
        switch kind {
        case .dinf:
            return hex("0000002464696e660000001c6472656600000000000000010000000c616c697300000001")
        case .elst:
            return hex("0000001c656c737400000000000000010153895b0000000000010000")
        case .hdlr:
            return hex("0000003968646c720000000000000000746578740000000000000000000000004170706c652054657874204d656469612048616e646c657200")
        case .mdhd:
            return hex("000000206d64686400000000ddcbe0c2ddcbe0c20000ac44617bffff15c70000")
        case .tkhd:
            return hex("0000005c746b686400000001ddcbe0c2ddcbe0c20000000200000000617bffff"
                + "000000000000000000000000010000000001000000000000000000000000000000010000"
                + "00000000000000000000000040000000000000a0000000a0")
        case .gmhd:
            return hex("0000004c676d686400000018676d696e000000000040800080008000000000000000002c"
                + "74657874000100000000000000000000000000000001000000000000000000000000000040000000")
        case .stsc:
            return hex("0000001c737473630000000000000001000000010000000100000001")
        case .stsd:
            return hex("0000004b7374736400000000000000010000003b74657874000000000000000100000001"
                + "00000001ffffffffffff0000000000000000000000000000000000000000000000000000000000")
        }
    }

    /// Every golden must be a self-consistent box: its own `size` field equal
    /// to its length. Transcribing these by hand is exactly where a dropped
    /// nibble hides (one such typo silently truncated `stsd` and AVFoundation
    /// then read no chapters at all), so the table is checked against itself
    /// rather than relying only on the external reference file.
    static func validateGoldens() -> [Golden] {
        Golden.allCases.filter { golden in
            let bytes = self.golden(golden)
            guard bytes.count >= 8 else { return true }
            let declared = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            return Int(declared) != bytes.count
        }
    }

    static func hex(_ digits: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = Substring(digits)
        while !rest.isEmpty {
            bytes.append(UInt8(rest.prefix(2), radix: 16) ?? 0)
            rest = rest.dropFirst(2)
        }
        return bytes
    }

    // MARK: - Box primitives

    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        Mp4.u32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }

    /// A FullBox: `size`/`type` then a zero `version`+`flags` word, then
    /// `fields`.
    private static func fullBox(_ type: String, _ fields: [UInt8]) -> [UInt8] {
        box(type, Mp4.u32(0) + fields)
    }

    /// Grows a box's size field, in either the 32-bit or the 64-bit header
    /// form. `measured` is the buffer the box's range was measured in — read
    /// from it, never from the buffer being mutated, whose layout is mid-edit
    /// (and which for a whole Audiobook is not cheap to copy).
    private static func setSize(
        _ bytes: inout [UInt8], of box: Mp4.Box, grownBy growth: Int, measuredIn measured: Data
    ) {
        writeSize(&bytes, at: box.range.lowerBound, size: box.range.count + growth,
                  header: Mp4.headerSize(of: box, in: measured))
    }

    /// As `setSize`, for a box addressed by offset inside a detached subtree.
    private static func grow(
        _ bytes: inout [UInt8], at offset: Int, by growth: Int, headerOf box: Mp4.Box, in measured: Data
    ) {
        writeSize(&bytes, at: offset, size: box.range.count + growth,
                  header: Mp4.headerSize(of: box, in: measured))
    }

    private static func writeSize(_ bytes: inout [UInt8], at offset: Int, size: Int, header: Int) {
        if header == 16 {
            Mp4.setU64(&bytes, at: offset + 8, UInt64(size))
        } else {
            Mp4.setU32(&bytes, at: offset, UInt32(size))
        }
    }

    // MARK: - Reading the encoder's audio track
    //
    // Offsets below are measured from the START of the box (so `+8` is past
    // `size`/`type`, and `+12` is past `version`+`flags` too). Getting these
    // wrong is not academic: reading `mdhd.timescale` four bytes late reads the
    // *duration* instead, and reading `tkhd.track_ID` four bytes late reads a
    // reserved zero — which silently gave the chapter track the same ID as the
    // audio track and AVFoundation reported no chapters at all.
    //
    //   mdhd v0: ver@0 · created@4 · modified@8 · timescale@12 · duration@16 ·
    //            language@20 (2) + pre_defined@22 (2)
    //   mdhd v1: ver@0 · created@4 (8 bytes) · modified@12 (8 bytes) ·
    //            timescale@20 · duration@24 (8 bytes)
    //   tkhd v0: ver@0 · created@4 · modified@8 · track_ID@12 · reserved@16 ·
    //            duration@20
    //   tkhd v1: ver@0 · created@4 (8) · modified@12 (8) · track_ID@20
    //
    // (Verified against AVAssetExportSession's own output on this machine:
    // audio mdhd timescale@12 == 22 050, duration@16 == the frame count,
    // tkhd track_ID@12 == 1.)

    private static func timescale(in data: Data, _ mdhd: Mp4.Box) throws -> Int {
        let at = base(of: mdhd, in: data) + (try version(of: mdhd, in: data) == 1 ? 20 : 12)
        return Int(try be32(in: data, at: at))
    }

    /// The box's `duration`. `mdhd` and `mvhd` agree on the v0 layout
    /// (timescale@12, duration@16); only `mdhd` also has a v1 form.
    private static func duration(in data: Data, _ box: Mp4.Box, versioned: Bool = true) throws -> Int {
        let base = base(of: box, in: data)
        if versioned, try version(of: box, in: data) == 1 {
            return Int(try be64(in: data, at: base + 24))
        }
        return Int(try be32(in: data, at: base + 16))
    }

    private static func trackID(in data: Data, _ tkhd: Mp4.Box) throws -> UInt32 {
        let base = base(of: tkhd, in: data)
        return try be32(in: data, at: base + (version(of: tkhd, in: data) == 1 ? 20 : 12))
    }

    /// Where a FullBox's version byte sits (past `size`/`type`).
    private static func base(of box: Mp4.Box, in data: Data) -> Int {
        box.range.lowerBound + Mp4.headerSize(of: box, in: data)
    }

    private static func version(of box: Mp4.Box, in data: Data) throws -> UInt8 {
        let at = base(of: box, in: data)
        guard at < data.count else { throw ChapterTextTrackError.noAudioTrack }
        return data[data.startIndex + at]
    }

    private static func be32(in data: Data, at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= data.count else { throw ChapterTextTrackError.noAudioTrack }
        let i = data.startIndex + at
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private static func be64(in data: Data, at: Int) throws -> UInt64 {
        guard at >= 0, at + 8 <= data.count else { throw ChapterTextTrackError.noAudioTrack }
        let i = data.startIndex + at
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(data[i + k]) }
        return v
    }
}
