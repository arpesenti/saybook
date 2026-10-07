# Saybook

A macOS CLI tool that converts an EPUB Book into a single M4B Audiobook via offline speech synthesis.

## Language

**Book**:
The input EPUB file. A Book has a title, an author, a language, and a Spine.
_Avoid_: input, source, ebook

**Spine**:
The Book's ordered list of content documents. Spine order is reading order, and therefore chapter order.
_Avoid_: TOC, table of contents (that is navigation; the spine is the reading order)

**Chapter**:
A unit of spoken text corresponding to one readable document of the Book's Spine, carrying a title.
_Avoid_: section, part, track

**Chapter Title**:
A Chapter's label, taken from the Book's own navigation when it declares one — the EPUB3 navigation document, or the EPUB2 NCX `navMap` — and otherwise from the document's own markup: its first non-empty largest heading, or failing that the filename. Declared navigation always outranks the markup heuristics, and the NCX contributes titles only: reading order comes from the Spine, never from the NCX's `playOrder`.
_Avoid_: heading, label, nav title

**Block**:
The smallest unit of spoken text within a Chapter (a paragraph, list, or heading). Each Block is synthesised as one utterance.
_Avoid_: sentence, paragraph (paragraph is one kind of Block)

**Audiobook**:
The output artifact: a single M4B file containing the whole Book as one continuous audio track, labelled with Chapter Markers and Book metadata.
_Avoid_: output, product, M4B

**Chapter Marker**:
A timestamped label inside the Audiobook marking where a Chapter begins. An Audiobook carries the markers in two container representations — a QuickTime chapter text track (what Apple's players read) and a `chpl` box (what `ffprobe`-based players read) — because neither is read by everyone.
_Avoid_: bookmark, cue point

**Chapter Text Track**:
The QuickTime chapter text track: a second track whose samples are the Chapter titles, referenced from the audio track. It is the representation AVFoundation reads, and therefore the one Books, VoiceOver and QuickTime show. Read by no other player, which is why the `chpl` box is written as well.
_Avoid_: chapter track, text track (both are shorthand for this)

**Voice**:
The speech voice used for synthesis. Chosen automatically for the Book's language; overridable per run.
_Avoid_: speaker, narrator

**Rate**:
Speech speed on Apple's 0–1 utterance scale (0.5 = normal).
_Avoid_: speed, wpm

**Synthesis**:
Offline generation of speech audio from text — never real-time playback to a device.
_Avoid_: playback, TTS

**Scratch**:
The per-run working directory holding intermediate per-chapter audio. Deleted on success; kept on failure or on request.
_Avoid_: temp, cache, workdir
