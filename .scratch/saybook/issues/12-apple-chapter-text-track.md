# 12: Chapter Markers are invisible to Apple's players (`chpl` is not what AVFoundation reads)

**What to build:** An Audiobook whose Chapter Markers are readable by the players the README promises (Books, VoiceOver, QuickTime) — which means emitting the structure Apple's speech stack actually reads: a **QuickTime chapter text track** referenced from the audio track by `trak/tref/chap`. `chpl` stays as the portable, third-party-facing representation (ffprobe and many non-Apple players read it), but it stops being the only one.

**Blocked by:** nothing (regression against 02's acceptance, discovered in the field)

**Status:** resolved

## The symptom

Real run, 2026-10-05: `saybook ~/Downloads/unseen-academicals.epub --engine siri` → 178 MB M4B, 11:55:27, 12 markers. The user's report: "it does not contain chapter markers".

Two readers disagree about the same bytes:

```
$ ffprobe -show_chapters unseen-academicals.m4b   → 12 chapters   ✓
$ AVURLAsset.chapterMetadataGroups(…)             →  0 chapters   ✗
```

## Root cause (measured, not assumed)

Control file: a real commercial audiobook with 114 chapters
(`/Volumes/Media/Audiobooks/Complete Discworld/Terry Pratchett/Discworld/(#20) Hogfather/(#20) Hogfather.m4b`).
Each row is one box removed/moved from that file, then re-read by AVFoundation:

| File | `chpl` | text track | `tref/chap` | box order | AVFoundation |
| --- | --- | --- | --- | --- | --- |
| Hogfather (original) | ✅ | ✅ | ✅ | `ftyp｜moov｜free｜mdat` | **114** |
| Hogfather − `chpl` | ✗ | ✅ | ✅ | unchanged | **114** — `chpl` is not needed |
| Hogfather − chapter text track | ✅ | ✗ | ✅ | unchanged | **0** — text track is required |
| Hogfather − `tref/chap` | ✅ | ✅ | ✗ | unchanged | **0** — `tref` is required |
| Hogfather with `moov` moved last | ✅ | ✅ | ✅ | `ftyp｜mdat｜moov｜free` | **114** — order is irrelevant |
| **our output** | ✅ | ✗ | ✗ | `ftyp｜mdat｜moov` | **0** |

So a `chpl` box is **neither necessary nor sufficient**. AVFoundation derives chapters from a second `trak` whose `hdlr` handler is `text`, one sample per chapter (`uint16` title length + UTF-8 title + a 12-byte `encd` box), with `stts` durations spanning each chapter and `tkhd`/`mdhd`/`elst` covering the whole Audiobook; the audio track must point at it with `trak/tref/chap` → chapter track ID. Our `moov` has exactly one `trak` (audio), no `tref`, no text track — verified by walking our own `moov`: `mvhd｜trak(tkhd,mdia)｜udta(meta,chpl)`.

`chpl` is a Nero/FFmpeg convention that Apple's muxer also writes for third-party tools; it is what ticket 02 implemented (its comment records "the `chpl` byte layout follows FFmpeg's mov muxer (the format real Apple M4Bs carry)" — true of the box, incomplete as an account of what makes chapters *appear*).

## Two claims this falsifies

- `README.md` "The Audiobook → Container": *"so players with audiobook support (VoiceOver, Audible-compatible apps, …) treat it as one Audiobook with chapters"*. Books/VoiceOver do not.
- ADR 0002 Consequences: *"Apple Books recognises the result as an audiobook"*. It recognises the file and its metadata (our `ilst`/`covr` read back fine) but shows no chapters.

Both need correcting with the measured facts, not softened.

## The container edit required

`Mp4.trailingMoov`/`appendToMoovUdta` establish the invariant that nothing before `moov` moves, so `stco` stays valid. The new edit must respect it while doing three things:

1. Append the chapter sample blob at the **end of the file** (after `moov`) and point the text track's single `stco` entry at that absolute offset.
2. Append a new `trak` as `moov`'s last child (growing `trak` and `moov`).
3. Insert `tref`/`chap` into the audio `trak` (after `tkhd`, before `mdia`, mirroring Apple's child order), growing that `trak` and `moov`.

Because `moov` must stay last for the *other* edits, this edit has to run **after** `Brand`/`Metadata`/`chpl` in `CLI.run`'s sequence. Sample offset math is already exact (`ChapterMarkers.startOffsets` over known frame counts) and is reused unchanged — only the container representation is new.

Timescale choice: keep the chapter track on the audio timescale (22 050) so chapter starts stay exact integers — no ms rounding.

## Checklist

- [x] `ChapterTextTrack` module: builds the text `trak` (`tkhd`/`edts`/`mdia`(`mdhd`,`hdlr`,`minf`(`gmhd`,`dinf`,`stbl`)) and the `tref`/`chap` box from the same `[ChapterMarker]` the `chpl` box is built from
- [x] Byte-for-byte fidelity to Apple's own layout for the fixed-shape boxes (`hdlr`, `gmhd`/`gmin`, the `stsd` `text` entry, `dref`), pinned by a test with a golden byte dump taken from a file Apple's stack produced
- [x] Chapter samples in Apple's format (`uint16` length + UTF-8 + `encd`), one per non-empty Chapter, `stts` durations = consecutive frame-count differences, summing to the Audiobook's exact frame count
- [x] `tref`/`chap` inserted into the audio `trak` without moving any byte before `moov`
- [x] `chpl` still written (third-party readers) and still asserted by the existing ffprobe test
- [x] **The test seam moves to the consumer that matters**: an AVFoundation assertion (`AVURLAsset.chapterMetadataGroups(withTitleLocale:containingItemsWithCommonKeys:)` returns one group per non-empty Chapter with the right title and start time) on a real encoded M4B — the existing ffprobe/`parseChpl` assertions stay but can no longer be the only proof
- [x] `Scripts/e2e.sh`'s `assert_audiobook` gains the same AVFoundation assertion, so the shipping binary is covered (ticket 10's lesson: debug-only coverage hides shipping-config bugs)
- [x] README and ADR 0002 corrected; a new ADR records why chapters are a text track and why `chpl` is kept as well
- [x] An existing-marker repair path is *not* required here: the user re-generates from scratch

## Evidence to keep

The ablation scripts and the AVFoundation harness used to establish the table above live at `/tmp/ablate2.py`, `/tmp/graft3.py` and `/tmp/chtest/` on the reporting machine; the durable form of those facts is the table in this ticket. A hand-grafted text track on our own file (the `/tmp/graft3.py` attempt) did **not** make AVFoundation report chapters, so the layout of the hand-built `trak` is not yet proven — building it inside saybook with a golden-reference test is the point of this ticket, not a python re-implementation.

## Comments

- 2026-10-06 (agent): Filed from the field report "the audiobook was generated but it looks like it does not contain chapter markers". Audio itself is fine (`afinfo`: `m4bf`, 1 ch, 22 050 Hz AAC, 42 926.69 s, offsets exact — ch01 spans 13 121 s for 40 738 words ≈ 186 wpm), so this is a container-metadata defect only.

- 2026-10-06 (agent): **Implemented.** New `Sources/SaybookCore/ChapterTextTrack.swift` builds and inserts the chapter text track and the audio track's `tref/chap`; `CLI.run` calls it after `chpl`, which is the only order that works (it appends a `trak` after `moov`'s trailing `udta`, and `chpl`/`ilst` require `udta` last). The chapter samples are appended to the end of `mdat`'s payload — where `moov` begins, since `moov` must stay last — so no audio byte moves; verified by decoding (duration and packet count unchanged by the edit) and by a test that compares the audio region byte for byte.
  - The fixed-shape boxes (`gmhd`, `dinf`, `stsd`, `stsc`, `hdlr`, and the skeletons of `tkhd`/`mdhd`/`elst`) are copied verbatim from a real Apple-produced M4B and have only their varying fields patched. Hand-building them produced three separate invisible-in-hex failures (an `elst` entry four bytes too long, a `tkhd` whose matrix/width fields were misaligned, and a hand-split hex literal that truncated `stsd` by four bytes), each of which made AVFoundation report zero chapters while every other box looked correct. `testGoldenBoxesAreSelfConsistent` checks each golden's size field against its length without any external file; `testGoldenBoxesMatchAnAppleProducedM4B` compares all eight against the real file (run here with `SAYBOOK_CHAPTER_REFERENCE_M4B` pointing at it — it passes).
  - **`elst` is load-bearing and in the movie timescale.** AVFoundation clips chapter groups to the chapter track's edit list: a four-second `segment_duration` over an 11.9-hour Audiobook left exactly one chapter. `tkhd.duration` and `elst.segment_duration` therefore take `mvhd`'s duration; `mdhd.duration` takes the track's own.
  - **The test seam moved to AVFoundation**, as this ticket required: `ChapterTextTrackTests.testAVFoundationReadsChapters` (real encode → `loadChapterMetadataGroups` → 3 chapters with titles and starts), `testAVFoundationSeesNoChaptersFromChplAlone` (the same file minus the text track reads **0** — the regression ticket 02 could not detect), and `CLITests` now asserts the same thing on the **real binary's** output. That last one was mutation-tested: with the `ChapterTextTrack.insert` call disabled it fails with "AVFoundation sees no chapters in the real binary's output"; with it, it passes.
  - `Scripts/e2e.sh` gained the same assertion for both engines via a new standalone probe, `Scripts/apple-chapters.swift` (compiled by the script, no saybook import — it is an independent reader using the same AVFoundation call). Measured on the fixture: ffprobe 3 chapters **and** AVFoundation 3 chapters, on both the Apple and Siri legs.
  - Titles come from the chapter samples: removing `chpl` from a fixed Audiobook still left AVFoundation reporting the correct titles.
  - Docs: README's Chapter Markers/container bullets and test count, ADR-0002's now-falsified "Apple Books recognises the result as an audiobook" claim, and new ADR-0004 (the ablation table, the decision, and the consequences above). `GLOSSARY.md` gained **Chapter Text Track**.
  - **Not verified: Books/VoiceOver/QuickTime opened by hand.** The claim rests on AVFoundation's chapter API, which those players are built on. ADR-0004 says so explicitly rather than overclaiming.
  - Suite: 187 tests green in debug and release (`swift test -c release`), 20 of them new here. `./Scripts/e2e.sh Tests/SaybookTests/Fixtures/multi-chapter.epub` passes end to end on both engines.
