# 05: Block-level text with natural pauses

**What to build:** Extraction and prosody quality. Text is split into Blocks (block-level elements: paragraphs, list items, blockquotes, preformatted text, headings, figcaptions) and each Block is synthesised as one utterance with a ~0.3 s pause between Blocks, so the output sounds like a narrator breathing between paragraphs. Footnotes, image data and alt text are never spoken; link anchor text is spoken once and never a URL; whitespace is normalised.

**Blocked by:** 01 (Skeleton — one-chapter Book to playable M4B)

**Status:** ready-for-agent

- [ ] Paragraphs in the output are separated by audible pauses (~0.2–0.5 s of silence); flow within a paragraph is continuous
- [ ] A fixture containing footnotes (e.g. `epub:type="footnote"` and a footnote section) never speaks the footnote text
- [ ] Images, image data URIs and alt text are never spoken; heading and figcaption text is spoken
- [ ] Link anchor text is spoken exactly once; hrefs/URLs are never spoken
- [ ] Whitespace runs are normalised to single spaces; no doubled spaces or stray line breaks audible as glitches
- [ ] A unit test asserts the per-Block rules against the fixture documents (Blocks and their text, no skipped content leaked in)
