# Single M4B with hand-rolled MP4 boxes, zero external dependencies

saybook emits exactly one Audiobook per Book: one AAC track (all chapters concatenated) in a single M4B file, with Chapter Markers written as a `chpl` box. The container is produced by `AVAssetExportSession` (M4A) and then patched in-process: the `ftyp` major brand is rewritten to `M4B ` with compatible brands `m4b mp42 isom`, and a `chpl` box is inserted. No ffmpeg, no afconvert, no third-party MP4 library.

## Considered options

- Folder of per-chapter M4Bs: zero MP4 surgery, but fragmented playback UX — grouping into one audiobook depends on player heuristics. Rejected.
- `afconvert` / `ffmpeg` for encoding: `afconvert` cannot write m4b on macOS 26 (verified 2026-09-11: `ExtAudioFileCreateWithURL failed ('typ?')`); ffmpeg adds a binary dependency and cannot set the M4B major brand either. Rejected.
- Third-party MP4 authoring library: a heavy dependency for two small box operations. Rejected.

## Consequences

- `AVAssetExportSession`'s preset bitrate is not configurable (~34 kb/s AAC-LC, 22.05 kHz mono — verified); file size is not a tunable in v1.
- The brand patch mirrors the byte layout of Apple's own `say -o x.m4b` output (verified 2026-09-11 on macOS 26.6.2); Apple Books recognises the result as an audiobook.
- `chpl` sample offsets are exact rather than parsed: saybook knows every Chapter's frame count, so offsets are computed from known PCM lengths against the track timescale.
- The `ExtAudioFile` C API (the usual in-process AAC encoder) is not importable from Swift in the Xcode 26.6 SDK, which is why encoding goes through `AVAudioFile` + `AVAssetExportSession`.
