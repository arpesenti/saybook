# 01: Skeleton — one-chapter Book to playable M4B

**What to build:** `saybook <book.epub>` on a simple single-chapter, non-DRM EPUB produces a playable M4B Audiobook beside the input. This lays the whole foundation: the Swift package and CLI entry, opening an EPUB (system `ditto` unzip into Scratch, OPF/Spine reading), basic Chapter text extraction (v1-crude: one utterance per Chapter), offline Synthesis via `AVSpeechSynthesizer.write()` with the main runloop pumped, per-chapter CAF in Scratch concatenated in Spine order, AAC encoding, and the M4B brand patch. Output defaults to `<InputBase>.m4b`; existing output → exit 1. One progress line per completed Chapter on stderr.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] `swift build` succeeds with zero third-party dependencies; deployment target macOS 13
- [x] Given a single-chapter EPUB, the command writes `<InputBase>.m4b` beside the input
- [x] `file` reports the output as an M4B Audio Book (major brand `M4B `, compatible brands `m4b mp42 isom`)
- [x] The output decodes cleanly (ffprobe/ffmpeg) as ~22.05 kHz mono AAC with duration within ±10% of the expected value for the Chapter's text length
- [x] One progress line per completed Chapter on stderr
- [x] If the output file already exists, the tool refuses with a readable message and exit 1
- [x] Study the verified prototype probe in this feature directory (`prototype/verified-pipeline.swift`) first — it encodes the plumbing decisions (runloop pumping, buffer writing, export, brand-patch byte layout) with the gotchas measured on this machine

## Comments

- 2026-09-11 (agent): Implemented. Swift package `saybook` (executable) + `SaybookCore` library; pipeline: `Epub.load` (ditto unpack → OPF/Spine, regex-based, `FoundationXML` is not importable from SwiftPM) → per-Chapter `Synthesis.render` (`AVSpeechSynthesizer.write` + main-runloop pump, 22.05 kHz Float32 CAFs) → `Assemble.concatenate` (Spine order) → `Encode.encodeCAF` (`AVAssetExportSession` M4A) → `Brand.patchFTyp` → output beside input. macOS 26 SDK gotchas hit: `AVAudioFile.read(into:)` throws `nilError` at EOF (loop bounded by file length) and `forWriting:format:`/`closeFile()` are gone (settings-based init only). Seams tested: `Brand.patchFTyp` bytes, `Epub.load` on the in-repo `single-chapter.epub` fixture, `Assemble` frame math, and the real binary (exit codes, output location, M4B brand, stderr progress, refusal). Manual checks: `file` → "(.M4B) Audio Book"; ffprobe → aac 22050 Hz mono ~34 kb/s; ffmpeg full decode clean; duration 7.06 s for the fixture's 19 words. Out of scope for this ticket (per tickets 02–07): `chpl` markers, resume/summary, ilst/covr/nav, voice flags, block-level extraction, `--force`/DRM/SIGINT, E2E script/README. Note: `--force`-less refusal message does not yet name a flag (that arrives with ticket 06).
- 2026-09-11 (agent): Two-axis code review ran (Standards: no documented repo standards, Fowler baseline; Spec: this ticket). Findings addressed in the follow-up commit: (1) duplicated PCM float32 settings dict — `Assemble.concatenate` now uses `Synthesis.cafSettings` as the single source; (2) repeated load-UTF-8 guard in `Epub` — extracted `readUTF8(_:)`; (3) repeated match/clean shape in `parseOPF` — extracted `firstCapture(_:in:)`; (4) `clean` renamed `decodeAndTrim`; (5) redundant `import Dispatch` removed; (6) the ±10% duration check is now asserted in `CLITests` (baseline 7.0 s for the fixture's 21 words at the default voice, ±0.7 s) instead of a coarse window. Judgement calls kept as-is: `synthesizeChapters` stays CLI-side orchestration (Feature Envy — moving it onto `Book` would couple parsed data to synthesis); the empty-Chapter skip stays as a crash guard until ticket 06 formalises it; `UtteranceCollector`'s `fileprivate` members are required (read from `render`, outside the nested class).
