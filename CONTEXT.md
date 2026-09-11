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

**Block**:
The smallest unit of spoken text within a Chapter (a paragraph, list, or heading). Each Block is synthesised as one utterance.
_Avoid_: sentence, paragraph (paragraph is one kind of Block)

**Audiobook**:
The output artifact: a single M4B file containing the whole Book as one continuous audio track, labelled with Chapter Markers and Book metadata.
_Avoid_: output, product, M4B

**Chapter Marker**:
A timestamped label inside the Audiobook marking where a Chapter begins.
_Avoid_: bookmark, cue point

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
