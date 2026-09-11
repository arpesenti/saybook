# saybook

`saybook` converts a non-DRM EPUB **Book** into a single audiobook-grade **Audiobook** (M4B): one continuous audio track with Chapter Markers and Book metadata (title, artist, album, cover), spoken by Apple's speech engine entirely offline.

```
$ saybook book.epub
Voice: Daniel (enhanced, en-GB) · Rate: 0.5
✓ 1/12 · CHAPTER I. Down the Rabbit-Hole · 10:52
✓ 2/12 · CHAPTER II. The Pool of Tears · 10:49
…
Chapters: 12 · Skipped: 1 (no text) · Duration: 2:04:09 · Size: 35.2 MB · Path: /path/to/book.m4b
```

## Requirements

- macOS 13 (Ventura) or later
- A Swift 6 toolchain (Xcode Command Line Tools)
- No third-party runtime dependencies — only system frameworks and `ditto`

## Build

```sh
swift build -c release
# binary: .build/release/saybook
```

## Usage

```
saybook <book.epub> [-o out.m4b] [--voice V] [--rate 0.0–1.0] [--language LL] [--keep-scratch] [--force]
```

| Flag | Meaning |
| --- | --- |
| `<book.epub>` | The input Book (required). Non-DRM only. |
| `-o out.m4b` | Write to an explicit path. Default: `<book>.m4b` beside the input. The parent directory must exist. |
| `--voice V` | Use a specific Voice: a display name or identifier as listed by `say -v ?`. Default: the best installed Voice for the Book's language (premium > enhanced > default). |
| `--rate 0.0–1.0` | Speech Rate on Apple's scale; `0.5` is normal and the default. |
| `--language LL` | Pick the Voice for `LL` instead of the Book's declared language (e.g. `--language fr-CA`). |
| `--keep-scratch` | Keep the working directory after a successful run (per-chapter audio, resume state). |
| `--force` | Replace an existing output file. Without it, an existing output is refused. |

Progress is reported per Chapter on stderr (`✓ N/M · title · m:ss`, `⏭` for a cached Chapter, `–` for an empty one); the final line summarises chapters, skipped, duration, size and path. Exit codes: `0` success, `1` input/user error (bad EPUB, DRM content, no readable Chapters, no Voice for the language, existing output, interrupted), `2` internal error.

### Example

```sh
swift build -c release
.build/release/saybook ~/Books/alice.epub --voice Alex --rate 0.6
# → ~/Books/alice.m4b
```

### Resume and re-runs

Per-Chapter audio is cached in a working directory keyed by the Book's path. If a run is interrupted (`Ctrl-C` stops it after the current unit of work, keeping its working directory and reporting progress so far) or fails, **re-running the same command resumes**: finished Chapters are reused, the rest are synthesised. Changing `--voice` or `--rate` clears the cached Chapters for that Book (a different voice/rate must be re-synthesised). `--keep-scratch` preserves the working directory after a successful run.

## The Audiobook

- **Container**: M4B (`ftyp` major brand `M4B `, compatible brands `m4b mp42 isom`), so players with audiobook support (VoiceOver, Audible-compatible apps, …) treat it as one Audiobook with chapters.
- **Audio**: AAC-LC, 22.05 kHz mono, at the export preset's ~34 kb/s — the whole Book is one continuous track.
- **Chapter Markers**: one `chpl` marker per non-empty Chapter at its exact sample offset (computed from known frame counts, not decoded timing). Empty Chapters produce no audio and no marker.
- **Metadata**: title, artist (the author; `Unknown` when the Book declares none) and album (the title, per M4B convention) in `ilst`, plus the cover image in `covr` when the Book declares one.
- **Spoken text**: paragraphs, lists, headings, quotes and captions in reading order, with a short natural pause between Blocks. Never spoken: navigation documents, cover and title pages, footnotes, links (anchor text once — never the URL), images and alt text.

## Testing

```sh
swift test
```

The suite (137 tests, ~30 s, zero network access) covers the pipeline at its seams: EPUB parsing against in-repo mini-EPUB fixtures (single/multi-chapter, EPUB2 and EPUB3, nav, cover, empty documents, links/footnotes/images, missing author, DRM), per-Block extraction rules, Chapter Marker offset math and `chpl`/`ftyp`/`ilst` box round-trips, Voice selection, and end-to-end runs of the real binary (exit codes, resume, SIGINT, flags). It is green in both the debug and the release configuration (`swift test -c release`) — the release run matters because it is the shipping configuration.

### Manual E2E

One command, no fixtures: build the release configuration, run the real binary on a real Book, and assert the Audiobook with independent tools (`afinfo`, `ffprobe` — the latter via `brew install ffmpeg`):

```sh
./Scripts/e2e.sh                       # downloads Project Gutenberg #11 (Alice, ~3 min of synthesis)
./Scripts/e2e.sh ~/Books/alice.epub    # or a local Book (fully offline)
```

Asserted: the M4B brand, a decodable duration (both tools agree), one Chapter Marker per non-empty Chapter with the first at 0:00 and every marker titled, and title/artist metadata matching the Book's OPF.

## Limitations (v1)

- **Non-DRM Books only** — encrypted content is detected and refused with a clean error.
- **One Book per run** — the whole Book is one output file; there is no per-Chapter output.
- **Fixed ~34 kb/s bitrate** — the `AVAssetExportSession` preset's; not a tunable in v1.
- **Apple system Voices only** — quality depends on what the machine has installed (English: premium/enhanced voices are best; exotic languages may only have default-quality Voices, or none, in which case the run fails naming the language).
- **No loudness normalisation** — chapters keep the voice's natural level.
- **Local use** — v1 is a command-line tool (`swift build -c release`), not a signed app.

## Layout

- `Sources/SaybookCore` — the pipeline: `Epub` (parse), `Block`/extraction (text), `Synthesis` (speech), `Assemble`/`Encode` (audio), `Brand`/`ChapterMarkers`/`Metadata`/`Mp4` (M4B finalisation), `Voice`, `CLI`/`CLIOptions`, `Scratch`, `Signals`.
- `Sources/saybook` — the executable entry point.
- `Tests/SaybookTests` — unit + executable-level tests, with mini-EPUB fixtures under `Fixtures/`.
- `Scripts/e2e.sh` — the manual E2E.
- `CONTEXT.md` — domain vocabulary; `docs/adr/` — architecture decisions (offline synthesis, hand-rolled M4B).
