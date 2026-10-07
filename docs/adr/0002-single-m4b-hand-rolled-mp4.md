# Single M4B with hand-rolled MP4 boxes, zero external dependencies

saybook emits exactly one Audiobook per Book: one AAC track (all chapters concatenated) in a single M4B file, with Chapter Markers written into the container. The container is produced by `AVAssetExportSession` (M4A) and then patched in-process: the `ftyp` major brand is rewritten to `M4B ` with compatible brands `m4b mp42 isom`, a `chpl` box is inserted, and a QuickTime chapter text track is added. No ffmpeg, no afconvert, no third-party MP4 library.

**The last of those arrived late.** This ADR originally wrote Chapter Markers as a `chpl` box alone and claimed that sufficed for Apple's players; it does not. AVFoundation reads a chapter *text track*, and a `chpl`-only Audiobook shows no chapters in Books, VoiceOver or QuickTime while passing every `ffprobe` check. See [ADR-0004](0004-chapter-markers-apple-readable-text-track.md) for the measurement and the second representation.

## Considered options

- Folder of per-chapter M4Bs: zero MP4 surgery, but fragmented playback UX — grouping into one audiobook depends on player heuristics. Rejected.
- `afconvert` / `ffmpeg` for encoding: `afconvert` cannot write m4b on macOS 26 (verified 2026-09-11: `ExtAudioFileCreateWithURL failed ('typ?')`); ffmpeg adds a binary dependency and cannot set the M4B major brand either. Rejected.
- Third-party MP4 authoring library: a heavy dependency for two small box operations. Rejected.

## Consequences

- `AVAssetExportSession`'s preset bitrate is not configurable (~34 kb/s AAC-LC, 22.05 kHz mono — verified); file size is not a tunable in v1.
- The brand patch mirrors the byte layout of Apple's own `say -o x.m4b` output (verified 2026-09-11 on macOS 26.6.2); Apple Books recognises the result as an audiobook — as a single audio file with its metadata, **not** as a chaptered one. An audiobook whose markers only a third-party reader can see is exactly what this ADR shipped until ADR-0004; the "recognises it as an audiobook" evidence never covered chapters, because nothing in the project asked AVFoundation.
- Chapter Marker offsets are exact rather than parsed: saybook knows every Chapter's frame count, so offsets are computed from known PCM lengths against the track timescale, and both representations (`chpl` and the chapter text track's `stts`/`stsz`/`stco`) are built from the same numbers.
- The `ExtAudioFile` C API (the usual in-process AAC encoder) is not importable from Swift in the Xcode 26.6 SDK, which is why encoding goes through `AVAudioFile` + `AVAssetExportSession`.
