# 14: Spine documents that are pure furniture still count as Chapters

**What to build:** The progress lines and the final summary report Chapter counts that match what a listener would call the book: a Spine document whose every Block is dropped by the extraction rules (a footnote-only document, an all-image page) is not an Empty Chapter announced to the user — it is not a Chapter at all.

**Blocked by:** nothing

**Status:** needs-triage

## The symptom

`unseen-academicals.epub` (Terry Pratchett, EPUB2, 460 KB) has 40 Spine documents. The run reported `1/39 … 39/39`, i.e. 39 Chapters, of which 27 produced the empty-chapter line `– n/39 · footnoteN · (no text)`. The real book has 12 speakable units.

The count is not cosmetic: `– N/M` lines are 27 of the 39 progress lines, and the summary's `Chapters: 39 · Skipped: 27 (no text)` describes a book that does not read that way.

## Root cause (measured)

The OPF's Spine lists the footnotes as ordinary top-level documents:

```xml
<itemref idref="ch04"/> … <itemref idref="atp01"/>
<itemref idref="footnote1"/><itemref idref="footnote2"/> … <itemref idref="footnote27"/>
```

(no `linear="no"`, no `properties` — the OPF is `version="2.0"` and declares no `properties` anywhere). `Epub.load` therefore makes a Chapter for each. Each footnote document is entirely `<p class="footnote" id="footnoteN">…</p>` (verified for every one of the 27: no block-level element outside a `footnote`/`footnotePara`/`footnoteRef` class), so `extractBlocks` correctly drops everything → `chapter.blocks.isEmpty` → `CLI.synthesizeChapters`'s Empty-Chapter branch: no audio, no marker, `skipped += 1`, progress line printed. The offsets stay exact (this is *not* an audio defect: ch01 spans 13 121 s for 40 738 words ≈ 186 wpm).

So the extraction rules are right — the spec says footnotes are never spoken — and the accounting around them is what is wrong. The gap in the model: **Empty Chapter** is defined as "no Blocks", and a document the rules discard *entirely* is indistinguishable from a document that is genuinely blank.

## Why it is `needs-triage` rather than a straight fix

The spec line is "skip footnotes" and the README's "Never spoken: … footnotes" — both satisfied. Whether a footnote-only document should also be **excluded from the Chapter count** is a domain question about what a Chapter is (see `GLOSSARY.md`: "a unit of spoken text corresponding to one readable document of the Book's Spine, carrying a title" — a document with no spoken text and no title of its own does not satisfy that definition). Grilling that out with the maintainer is cheaper than guessing, because it changes what the summary promises:

1. [Recommended] A Chapter must have at least one Block *or* a title from a navigation source; a Spine document that yields neither is dropped before the run, and the summary reports it separately (e.g. `Chapters: 12 · Not spoken: 27 (footnotes)`), so nothing is silently lost.
2. Keep counting them and only fix the wording. Cheapest, but leaves 27 `–` lines.
3. Detect footnote documents structurally (all Blocks dropped as footnotes) and exclude them from Chapters while keeping a single aggregate note. Closest to the listener's expectation.

Whatever is chosen, the rule must be **reportable**: the user must be able to see which documents were dropped and why, because a rule that silently discards content is how a book loses its final chapter to a CSS class name.

## Checklist

- [ ] Decision recorded (which of the above, and why) in this ticket, plus `GLOSSARY.md` if the definition of Chapter changes
- [ ] `Epub.load` distinguishes "no Blocks because blank" from "no Blocks because everything was dropped as furniture", and the latter is classified before the run starts
- [ ] Progress and summary stop presenting dropped documents as Chapters; the summary still accounts for every Spine document, so the numbers can be reconciled
- [ ] Fixture: a Spine carrying footnote documents after the last real chapter (the shape of the reported Book), asserting the Chapter count and the summary line
- [ ] The existing empty-document behaviour (a genuinely blank Spine document) keeps its current `skipped (no text)` treatment, pinned so the two cases cannot silently merge again

## Comments

- 2026-10-06 (agent): Filed with #12/#13 from the same run. Low severity for this Book (the audio is right), but it is the reason the user saw `39` chapters for a 12-chapter novel, and it interacts with #13: once NCX titles arrive, a dropped footnote document with a heading outside its footnotes would otherwise become a titled Chapter.

- 2026-10-06 (agent): **Left `needs-triage` on purpose.** #12 and #13 are fixed and green; this one is not a defect in the same sense — the audio is correct (footnote documents produce no Blocks, no audio and no marker, which is what the spec asks for), and what is wrong is the accounting: a 12-chapter novel reported `Chapters: 39 · Skipped: 27` and 27 `– n/39 … (no text)` progress lines. Which of the three options to take is a domain decision about what a Chapter is, and it changes what the summary promises, so it wants the maintainer rather than an agent guessing. Nothing here blocks a regeneration.
