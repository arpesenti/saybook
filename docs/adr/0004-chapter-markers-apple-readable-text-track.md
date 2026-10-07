# Chapter Markers Apple's players read: a chapter text track, not only `chpl`

saybook writes Chapter Markers twice, in two container representations, because no single one is read by everyone:

1. **A QuickTime chapter text track** — a second `trak` whose `mdia/hdlr` handler is `text`, one text sample per Chapter, referenced from the audio track by `trak/tref/chap`. This is what **AVFoundation** reads, and therefore what Books, VoiceOver, QuickTime Player and every `AVPlayer`-based app read. `ChapterTextTrack` builds and inserts it.
2. **A `chpl` box** in `moov/udta` — a Nero/QuickTime convention that **FFmpeg and many third-party players** read (`ffprobe -show_chapters`, VLC, foobar2000). `ChapterMarkers` keeps building it.

Ticket 02 wrote only the second, and the README promised the first. Measured on macOS 27.0 / M4, 2026-10-06, against a real commercial audiobook with 114 chapters, removing or moving one structure at a time and asking `AVURLAsset.loadChapterMetadataGroups(withTitleLocale:containingItemsWithCommonKeys:)`:

| File | `chpl` | text track | `tref/chap` | AVFoundation |
| --- | --- | --- | --- | --- |
| commercial M4B | ✅ | ✅ | ✅ | **114 chapters** |
| − `chpl` | ✗ | ✅ | ✅ | **114 chapters** (so `chpl` is not needed for this) |
| − chapter text track | ✅ | ✗ | ✅ | **0** |
| − `tref/chap` | ✅ | ✅ | ✗ | **0** |
| `moov` moved to the end of the file | ✅ | ✅ | ✅ | **114** (box order is irrelevant) |
| a saybook Audiobook before this change | ✅ | ✗ | ✗ | **0** |

So `chpl` is **neither necessary nor sufficient** for Apple's players, and a file can pass every `ffprobe` chapter assertion while showing no chapters in Books. Ticket 02's tests proved the artifact with `ffprobe` and with saybook's own `parseChpl` — both read `chpl`, so both agreed with the writer and the suite stayed green.

## Decision

Write both representations from the **same** `[ChapterMarker]`, and move the Chapter Marker test seam to the consumer that matters: `AVURLAsset.loadChapterMetadataGroups` must return one group per non-empty Chapter with the right title and start. `ffprobe` stays as the independent reader of `chpl`; it can no longer be the only proof. `Scripts/e2e.sh` asserts both against the release binary (`Scripts/apple-chapters.swift` is the AVFoundation probe), and `CLITests` asserts both against the real binary's output on the fixture.

## Consequences

- **The chapter track's boxes are copied, not derived.** The boxes that carry no per-Book value (`gmhd`, `dinf`, `stsd`, `stsc`, `hdlr`, and the skeletons of `tkhd`, `mdhd`, `elst`) are byte-for-byte the ones a real Apple-produced M4B carries, with only the varying fields patched at documented offsets. Hand-building them failed in ways that are invisible in hex: an `elst` whose entry was four bytes too long, a `tkhd` whose matrix and width fields were misaligned, and a hand-split hex literal that silently truncated `stsd` by four bytes — each of which made AVFoundation report zero chapters while every *other* box looked correct. `ChapterTextTrackTests.testGoldenBoxesAreSelfConsistent` checks every golden's declared size against its length (no external file needed), and `testGoldenBoxesMatchAnAppleProducedM4B` compares them to a real Apple file when one is pointed at with `SAYBOOK_CHAPTER_REFERENCE_M4B`.
- **The chapter track runs on the audio track's timescale** (22 050), so a Chapter's start is its sample offset with no conversion and no rounding. `mdhd.duration` is the exact frame count, and the `stts` durations are the gaps between consecutive starts, the last running to the end: the durations sum to the frame count, so the final Chapter ends exactly where the audio ends.
- **`elst` is load-bearing, and it is in the movie timescale.** AVFoundation clips chapter groups to the chapter track's edit list: a `segment_duration` of four seconds over an 11.9-hour Audiobook left exactly **one** chapter visible. `tkhd.duration` and `elst.segment_duration` therefore take `mvhd`'s duration (movie timescale), while `mdhd.duration` takes the track's own — reading one for the other happens to work on saybook's own output, where the encoder sets both timescales to 22 050, and is wrong in general.
- **The insertion obeys the existing contract**: nothing before `moov` moves. The chapter samples are appended to the end of `mdat`'s payload (which is where `moov` begins, since `moov` must be last) and the new boxes are appended inside `moov`, so every audio byte keeps its absolute address and the audio track's `stco` stays valid. Verified by decoding: the audio duration and packet count are unchanged by the edit.
- **This edit must run last**, after `Brand`, `ilst`/`covr` and `chpl`. Those append into `moov`'s trailing `udta`, which requires `udta` to be `moov`'s last child; this one appends a `trak` after it.
- **Titles come from the chapter samples.** Verified by removing `chpl` from a saybook Audiobook: AVFoundation still reported the correct chapter titles, taken from the text track's samples.
- **`chpl` stays.** It costs 336 bytes on an 11.9-hour Book and is what makes `ffprobe`-based tooling (and therefore most non-Apple players, and this project's own E2E assertions) show chapters at all.
- **Unverified: Books itself.** The measurement is AVFoundation's own chapter API, the framework those players are built on. Books, VoiceOver and QuickTime were not opened by hand; if a user reports no chapters in one of them, this ADR's table is the place to start, and its claim should be narrowed rather than re-asserted.
