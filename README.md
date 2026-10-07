# saybook

`saybook` converts a non-DRM EPUB **Book** into a single audiobook-grade **Audiobook** (M4B): one continuous audio track with Chapter Markers and Book metadata (title, artist, album, cover), spoken by Apple's speech engine entirely offline. A second, **opt-in** engine speaks the Book with Apple's private Siri engine — see [The Siri engine](#the-siri-engine-engine-siri).

```
$ saybook alice.epub
Voice: Daniel (enhanced, en-GB) · Rate: 0.5
– 1/14 · wrap0000 · (no text)
✓ 2/14 · Alice’s Adventures in Wonderland · 1:35
✓ 3/14 · CHAPTER I. Down the Rabbit-Hole · 10:52
✓ 4/14 · CHAPTER II. The Pool of Tears · 10:49
…
Chapters: 14 · Skipped: 1 (no text) · Duration: 160:56 · Size: 38.4 MB · Path: /path/to/alice.m4b
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

Warnings are errors, always: `Package.swift` sets `-warnings-as-errors` on every Swift target and `-Wall -Wextra -Werror` on the C++ bridge, so anything the compiler reports fails the build rather than printing. That is not decoration — ticket 15 is what a green build hid here (an unreachable `catch` around a swallowed error, printing on every production build), and the policy's first act was to catch a deprecated API in this repo's own test helper. The cost is that `unsafeFlags` makes SwiftPM refuse to let another package depend on this one, which is not a thing saybook is for.

## Usage

```
saybook <book.epub> [-o out.m4b] [--voice V] [--rate 0.0–1.0] [--language LL] [--engine apple|siri] [--keep-scratch] [--force]
```

| Flag | Meaning |
| --- | --- |
| `<book.epub>` | The Book to speak (required). Non-DRM only. |
| `-o out.m4b` | Write to an explicit path. Default: `<book>.m4b` beside the input. The parent directory must exist. |
| `--voice V` | Use a specific Voice: a display name or identifier as listed by `say -v ?` (or, for `--engine siri`, in its error messages). Default: the best installed Voice for the Book's language (premium > enhanced > default). |
| `--rate 0.0–1.0` | Speech Rate on Apple's scale; `0.5` is normal and the default. Needs the `apple` engine — the Siri engine speaks at the voice's own rate. |
| `--language LL` | Pick the Voice for `LL` instead of the Book's declared language (e.g. `--language fr-CA`). |
| `--engine E` | `apple` (default) is the public `AVSpeechSynthesizer`; `siri` is Apple's private on-device Siri engine, offline and unsupported — [details](#the-siri-engine-engine-siri). |
| `--keep-scratch` | Keep the Scratch (per-Chapter audio, resume state) after a successful run. |
| `--force` | Replace an existing output file. Without it, an existing output is refused. |

Progress is reported per Chapter on stderr (`✓ N/M · title · m:ss`, `⏭` for a cached Chapter, `–` for an empty one); the final line summarises chapters, skipped, duration, size and path. A run with a non-default engine says so in its header (`Engine: siri (private Siri engine — offline, unsupported)`). Exit codes: `0` success, `1` input/user error (bad EPUB, DRM content, no readable Chapters, no Voice for the language, existing output, interrupted), `2` internal error.

### Example

```sh
swift build -c release
.build/release/saybook ~/Books/alice.epub --voice Alex --rate 0.6
# → ~/Books/alice.m4b
```

### Resume and re-runs

Per-Chapter audio is kept in a per-Book **Scratch** directory (keyed by the Book's path) as resume state. If a run is interrupted (`Ctrl-C` stops it after the current unit of work, keeping its Scratch and reporting progress so far) or fails, **re-running the same command resumes**: finished Chapters are reused, the rest are synthesised. Changing `--engine`, `--voice` or `--rate` clears the Book's Scratch (audio rendered by another engine, voice or rate is not resume state for this one). `--keep-scratch` preserves the Scratch after a successful run.

### The Siri engine (`--engine siri`)

```sh
saybook ~/Books/alice.epub --engine siri --voice Martha
```

Apple ships a second, better on-device speech engine inside `SiriTTS.framework` — the one Siri and Personal Voice use. It is **private API**: nothing in AVFoundation, `FoundationModels` or `say` reaches it, and the `com.apple.sirittsd` XPC service refuses unentitled clients, so saybook calls its C++ `TTSSynthesizer` directly through a small C bridge (`Sources/SiriTTSBridge`). It stays fully offline and dependency-free, and its audio is resampled into the same 22.05 kHz mono contract as the public engine, so chapters, metadata and resume behave identically.

What to expect:

- **Opt-in only.** The default engine is the public one; a run using the private engine labels itself, and a `--engine siri` run that cannot render fails with a readable error and no output file. It never silently falls back to the other engine — a Book in an unrequested voice is worse than a failed run.
- **Voices come from macOS.** Siri voice bundles are downloaded by the system into `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech`; there is no `say -v ?` for them, so saybook lists the installed ones in its `--voice`/`--language` errors. A Mac with no bundle installed cannot use this engine.
- **No rate control**, so `--rate` is refused with `--engine siri`.
- **It costs more.** Measured on the same Book (2:16 of audio, release binary, M4): `--engine siri` takes **16.8 s and ~400 MB peak** against the public engine's **3.2 s and ~98 MB** — ~8× realtime versus ~40×. A 10-hour Book renders in roughly **1¼ hours** instead of ~15 minutes; the one-off voice load is under a second, so the cost is render throughput plus the neural models held resident. Better voice, slower run: know which you are buying.
- **It can break with any OS update** — the bridge binds C++ symbols by mangled name. Unsupported by design: keep it for personal use, and do not ship the binary to anyone else expecting it to work.
- `SAYBOOK_SIRI_DIAGNOSTICS=1` leaves Apple's own engine logging on stderr (it is voluminous and normally muted by the bridge, which otherwise risks blocking on a full stderr pipe).

Design and evidence: `docs/adr/0003-private-siri-speech-engine.md`.

## The Audiobook

- **Container**: M4B (`ftyp` major brand `M4B `, compatible brands `m4b mp42 isom`), so players with audiobook support treat it as one Audiobook with chapters.
- **Audio**: AAC-LC, 22.05 kHz mono, at the export preset's ~34 kb/s — the whole Book is one continuous track.
- **Chapter Markers**: one marker per non-empty Chapter at its exact sample offset (computed from known frame counts, not decoded timing), written **twice** because no single representation is read by everyone: a QuickTime **chapter text track** referenced from the audio track by `trak/tref/chap` — the form AVFoundation reads, and therefore Books, VoiceOver and QuickTime — and a **`chpl`** box in `moov/udta`, which `ffprobe`-based tooling and many third-party players read. `chpl` alone is not enough: a `chpl`-only Audiobook passes every `ffprobe` chapter check and shows no chapters in Apple's players (measured; [ADR-0004](docs/adr/0004-chapter-markers-apple-readable-text-track.md)). Empty Chapters produce no audio and no marker.
- **Metadata**: title, artist (the author; `Unknown` when the Book declares none) and album (the title, per M4B convention) in `ilst`, plus the cover image in `covr` when the Book declares one.
- **Spoken text**: paragraphs, lists, headings, quotes and captions in reading order, with a short natural pause between Blocks. Never spoken: navigation documents, cover and title pages, footnotes, links (anchor text once — never the URL), images and alt text.

## Testing

```sh
swift test
```

The suite (190 tests, ~45 s, zero network access) covers the pipeline at its seams: EPUB parsing against in-repo mini-EPUB fixtures (single/multi-chapter, EPUB2 and EPUB3, nav, cover, empty documents, links/footnotes/images, missing author, DRM, NCX titles), per-Block extraction rules, the audible inter-Block pause (silence runs in the decoded Audiobook, pinned to the frame counts of the engine's own per-Block CAFs), Chapter Marker offset math and `chpl`/`ftyp`/`ilst` box round-trips, Voice selection, the speech **Engine** seam (voice-bundle parsing, an unusable engine reporting itself as a user error, and a real render through the private engine when the Mac has a Siri voice bundle — those tests skip when it does not), and end-to-end runs of the real binary (exit codes, resume, engine switching, SIGINT, flags).

Chapter Markers are asserted through **both** readers, because they disagree: `ffprobe` (which reads `chpl`) and `AVURLAsset.loadChapterMetadataGroups` (the AVFoundation call Books and VoiceOver use, which reads the chapter text track). The AVFoundation half is the one ticket 02 lacked — a `chpl`-only build passes the `ffprobe` assertions and fails those, which is pinned by a test that builds without the text track and asserts Apple's reader sees nothing. The golden bytes of the chapter track's fixed-shape boxes are compared against a real Apple-produced M4B when one is pointed at with `SAYBOOK_CHAPTER_REFERENCE_M4B` (skipped otherwise, since the file is not ours to ship). It is green in both the debug and the release configuration (`swift test -c release`) — the release run matters because it is the shipping configuration.

### Manual E2E

One command, no fixtures: build the release configuration, run the real binary, and assert the Audiobook with independent tools (`afinfo`, `ffprobe` — the latter via `brew install ffmpeg`):

```sh
./Scripts/e2e.sh                                # downloads Project Gutenberg #11 (Alice, ~3 min of synthesis)
./Scripts/e2e.sh ~/Books/alice.epub             # or a local Book (fully offline)
./Scripts/e2e.sh --siri-full ~/Books/alice.epub # also render the Book itself through the private engine (slow)
```

Two legs, the same four assertions each: the M4B brand, a decodable duration (both tools agree), one Chapter Marker per non-empty Chapter with the first at 0:00 and every marker titled, and title/artist metadata matching the Book's OPF.

1. **The Book, default engine** — the leg ticket 07 shipped, unchanged.
2. **A small in-repo Book (the multi-chapter fixture), private engine** (`--engine siri`) — the configuration no test runs, because the CLI suite shells out to the debug binary and `swift test -c release` still executes it. ~33 s on top of leg 1. Two assertions of its own, because both fail silently otherwise: the run must announce `Engine: siri` (an ignored `--engine` would otherwise look exactly like a green default-engine run), and its decoded duration must land within 25 % of the default engine's on the same Book (a sample-rate mistake is a 2× gap). `--siri-full` renders the Book itself instead of the fixture — ~20 min for Alice, since the private engine renders at ~8× realtime against the public engine's ~40×.

The Siri leg **skips** — loudly, and still exiting 0 — on a Mac with no Siri voice bundle: macOS decides which machines have one, and a missing bundle is not a saybook defect. Anything else (a bundle that cannot render, an ignored flag, a bad Audiobook) is a FAIL. `SAYBOOK_SIRI_ASSETS_ROOT=/nonexistent` forces the skip on a Mac that does have a bundle.

## Limitations (v1)

- **Non-DRM Books only** — encrypted content is detected and refused with a clean error.
- **One Book per run** — the whole Book is one Audiobook file; there is no per-Chapter Audiobook.
- **Fixed ~34 kb/s bitrate** — the `AVAssetExportSession` preset's; not a tunable in v1.
- **Apple system Voices only** — quality depends on what the machine has installed (English: premium/enhanced voices are best; exotic languages may only have default-quality Voices, or none, in which case the run fails naming the language).
- **The private Siri engine is unsupported** — `--engine siri` is opt-in, needs a macOS-delivered Siri voice bundle, has no rate control, renders ~5× slower than the public engine, and can stop working with any OS update; the public engine is the supported path.
- **No loudness normalisation** — chapters keep the voice's natural level.
- **Local use** — v1 is a command-line tool (`swift build -c release`), not a signed app.

## Layout

- `Sources/SaybookCore` — the pipeline: `Epub` (parse), `Block`/extraction (text), `Synthesis`/`SpeechEngine`/`SiriSynthesis` (speech), `Assemble`/`Encode` (audio), `Brand`/`ChapterMarkers`/`Metadata`/`Mp4` (M4B finalisation), `Voice`, `CLI`/`CLIOptions`, `Scratch`, `Signals`.
- `Sources/SiriTTSBridge` — the C bridge to the private `SiriTTS.framework` engine (every private symbol reference lives here).
- `Sources/saybook` — the executable entry point.
- `Tests/SaybookTests` — unit + executable-level tests, with mini-EPUB fixtures under `Fixtures/`.
- `Scripts/e2e.sh` — the manual E2E.
- `GLOSSARY.md` — domain vocabulary; `docs/adr/` — architecture decisions (offline synthesis, hand-rolled M4B, the private Siri engine, the Apple-readable chapter text track).
