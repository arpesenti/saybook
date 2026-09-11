# saybook — EPUB → M4B

## What it is

`saybook book.epub` reads a non-DRM EPUB **Book**, speaks it with Apple's speech engine offline, and writes one audiobook-grade **Audiobook** (M4B) beside the input. macOS 13+ (Ventura), Swift 6, zero third-party dependencies.

## Pipeline (all in-process)

1. **Parse** — unzip (system `ditto` into **Scratch**), OPF metadata (title/author/language/cover), **Spine** order. Exclude `nav` / `doc-cover` / `doc-titlepage` documents. Chapters = readable Spine documents; titles: EPUB3 nav → largest heading → filename.
2. **Extract** — XHTML → **Blocks** (paragraphs, lists, headings, figcaptions); skip footnotes, links (anchor text spoken once, never URLs), images, alt text; normalise whitespace.
3. **Synthesise** — `AVSpeechSynthesizer.write()` per Block (0.3 s `postUtteranceDelay` between Blocks), **Voice** auto-picked per language (premium > enhanced > default), **Rate** 0.5 default. Main runloop pumped. ~55× realtime.
4. **Assemble** — per-chapter PCM → Scratch CAF (per-chapter; existence = resume state), concatenated in Spine order.
5. **Encode** — one CAF → `AVAssetExportSession` → M4A (AAC-LC ~34 kb/s, 22.05 kHz mono).
6. **Finalise** — `ftyp` brand patch → `M4B ` + `m4b mp42 isom`; insert `chpl` (exact sample offsets from known frame counts vs track timescale); write `ilst` metadata (title/author/album) + `covr` cover (degrade gracefully if any box fails); delete Scratch.

## CLI

```
saybook <book.epub> [-o out.m4b] [--voice V] [--rate 0.0–1.0] [--language LL] [--keep-scratch] [--force]
```

- Output default: `<InputBase>.m4b` beside the input; no clobber without `--force`.
- Progress per Chapter to stderr (`✓ 12/34 · The Voyage · 2:31`); final summary (chapters, skipped, duration, size, path). No ETA. No config file.
- Exit codes: 0 ok · 1 input/user error (bad EPUB, DRM-encrypted content, no readable Chapters, no Voice for language, output exists) · 2 internal error.
- SIGINT: stop gracefully, keep Scratch, report progress (resume = re-run).
- Empty Chapters: no audio, no Chapter Marker, reported `skipped (no text)` in the summary.

## Constraints

- Non-DRM EPUBs only (encrypted content → clean error). One Book per invocation.
- No loudness normalisation. Apple system voices only.
- Bitrate is the export preset's (~34 kb/s) — not a v1 tunable.
- v1 is local use: `swift build -c release`.

## Tests

- In-repo hand-rolled mini-EPUB fixtures (single/multi-chapter, nav, cover image, empty doc, EPUB2/3, links/footnotes/images, missing author).
- Unit tests: extraction per-Block rules, `chpl` offset math, `ftyp` brand-patch round-trip. `swift test` green with zero network.
- Manual E2E script: release build + real Book, asserts brand, duration, markers, metadata.

## References

- Glossary: `CONTEXT.md` (Book, Spine, Chapter, Block, Audiobook, Chapter Marker, Voice, Rate, Synthesis, Scratch)
- `docs/adr/0001-offline-synthesis-via-avspeechsynthesizer-write.md`
- `docs/adr/0002-single-m4b-hand-rolled-mp4.md`
- Verified pipeline probe (measured on macOS 26.6.2, Swift 6.3.3, 2026-09-11): `prototype/verified-pipeline.swift` in this directory
