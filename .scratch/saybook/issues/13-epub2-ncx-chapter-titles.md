# 13: Chapter titles fall back to filenames on EPUB2 books (NCX `navMap` is never read)

**What to build:** Chapter titles come from the Book's own navigation wherever it declares it — the EPUB3 nav document **or** the EPUB2 `toc.ncx` `navMap` — so Chapter Markers and the progress lines carry the author's titles rather than internal filenames.

**Blocked by:** nothing (blocks nothing; #12 will want titled markers, so do this before or with it)

**Status:** resolved

## The symptom

The real run produced markers titled:

```
Unseen Academicals · unseenacademicals_ded01 · Contents · unseenacademicals_ch01
· unseenacademicals_ch02 · unseenacademicals_ch03 · unseenacademicals_ch04
· About the Author · Also by Terry Pratchett · Credits · Copyright · About the Publisher
```

Four of the twelve are internal filenames. The Book declares proper labels for all of them — they are sitting in `OEBPS/toc.ncx`, which saybook never opens.

## Root cause (measured)

`Epub.load` sources titles two ways (`Epub.swift`):

```swift
let navItem = opf.itemOrder.compactMap { opf.items[$0] }.first { $0.properties.contains("nav") }
let navTitles = navTitles(of: navItem, relativeTo: opfDir)
…
title: navTitles[fileURL.standardized.path] ?? chapterTitle(from: text, filename: filename)
```

1. `properties.contains("nav")` is an **EPUB3** mechanism. This Book's OPF is `version="2.0"` and no item carries `properties` at all (grep for `properties` in the OPF: no matches) → `navItem` is nil → `navTitles` is empty for every document.
2. `chapterTitle` then scans `<h1>`…`<h6>` for the first non-empty heading. The four affected documents have only `<h2 class="chapterNumber"> </h2>` — a heading that exists and is **whitespace-only**, so `normalize` empties it, the loop finds nothing at any level, and the function returns `filename`.
3. `toc.ncx` is never parsed: `grep -n "ncx\|navMap\|navLabel" Sources/SaybookCore/Epub.swift` returns nothing. `EpubTests` has an EPUB2 fixture, but the fixtures give their documents real headings, so the fallback never had to reach for a title source that does not exist.

What the NCX actually offers (verified against this Book):

```
3. Dedication                -> unseenacademicals_ded01.html
5. Begin Reading             -> unseenacademicals_ch01.html#ch01
7. Other Books by Terry Pratchett -> unseenacademicals_adc01.html#adc01
```

Note the two wrinkles an implementation must decide rather than assume:

- NCX `src` values carry **fragments** (`…ch01.html#ch01`) and are relative to the NCX, not the OPF; the lookup key is the document path with the fragment stripped.
- The NCX label for `ch01` is *"Begin Reading"* — a reader-facing string, not a chapter title. For a Pratchett book that is arguably the author's intent, but it is worth stating explicitly which source wins when both a heading and an NCX label exist, and recording it in `GLOSSARY.md`'s Chapter/Spine sense.

## Decisions to make (recommendations in brackets)

1. **Precedence.** [nav document → NCX `navMap` → largest non-empty heading → filename.] The nav document and NCX are both author-declared navigation, so both beat heuristics over body markup; keep the current fallbacks below them so EPUB2 books with no NCX are unaffected.
2. **Where the NCX is found.** [The OPF's `<spine toc="…">` attribute, falling back to the manifest item whose media type is `application/x-dtbncx+xml`.] Both are in the OPF we already parse; do not go hunting the archive for files.
3. **Do not trust NCX order as reading order.** Spine stays the order of Chapters (that is the glossary's definition); the NCX is consulted **only** as a title dictionary keyed by document path.

## Checklist

- [x] `Epub` parses the NCX (`<navPoint>` → `<navLabel><text>` + `<content src>`), resolves `src` against the NCX's directory, strips fragments, and keys titles by resolved document path (first label wins on duplicates)
- [x] Precedence nav → NCX → heading → filename, with `chapterTitle`'s whitespace-only-heading case covered by a test (a document whose only heading is `<h2> </h2>` must reach the next source, not silently return the filename when a declared title exists)
- [x] The `<span class="smallCaps">`-style markup inside `navLabel` is stripped and entities decoded, reusing the existing `normalize`/`decodeEntities`/`stripMarkup` helpers
- [x] New in-repo fixture: EPUB2, `toc.ncx` present, chapter documents with whitespace-only headings — the exact shape of the Book in the field report; asserts titles are the NCX labels, not filenames
- [x] Existing EPUB2/EPUB3 fixtures still pass unchanged (the fallbacks are not removed)
- [x] `GLOSSARY.md` records that navigation-declared titles outrank heading heuristics

## Comments

- 2026-10-06 (agent): Filed alongside #12 from the same real-Book run. Offsets and audio are correct; only the titles are wrong, which makes this a cosmetic-but-embarrassing defect that becomes more visible once #12 makes the markers appear in Apple's players at all.

- 2026-10-06 (agent): **Implemented.** `Epub` now parses the EPUB2 NCX: the item is found through `<spine toc="…">` and falls back to the manifest's `application/x-dtbncx+xml` media type (both already in the parsed OPF, so nothing hunts the archive); `<navLabel><text>` is paired with the following `<content src>`, `src` is resolved against the NCX document, and the URL's `path` drops the fragment — giving the same key the Spine lookup already uses for the EPUB3 nav document. Titles are normalised with the existing `stripMarkup`/`decodeEntities`/`normalize` helpers, so `The Second &amp; Last` reads correctly.
  - Precedence is nav → NCX → largest non-empty heading → filename, expressed as a single `declaredTitles` merge (`navTitles.merging(ncxTitles) { navTitle, _ in navTitle }`). The NCX contributes **titles only**: reading order stays the Spine, never the NCX's `playOrder` (recorded in the glossary).
  - Tests (`EpubTests`): `testLoadEpub2NcxTitlesOutrankTheHeadingFallback` builds the field-report shape at test time (EPUB2, `toc.ncx`, one document with a real `<h1>Chapter One</h1>` and one whose only heading is `<h2 class="chapterNumber"> </h2>`) and asserts the NCX labels win for both — so it pins both "declared beats heading" and "NCX rescues the filename case". `testLoadEpub2NcxFoundByMediaTypeWhenSpineNamesNoToc` covers the fallback lookup, and `testLoadEpub2WithoutNcxKeepsTheHeadingFallback` pins that an EPUB2 Book with no NCX still yields `["Chapter One", "ch2"]`. Mutation-tested: with the NCX merge disabled the two NCX tests fail with exactly the field report's `["Chapter One", "ch2"]`.
  - Deviation from the checklist: the fixture is **built in the test** from a written tree and zipped, rather than added as a checked-in `.epub`. It matches the existing pattern for the ticket-06 error-path fixtures and keeps the EPUB's bytes reviewable in the diff instead of inside an archive.
  - GLOSSARY gained a **Chapter Title** entry recording the precedence; `spec.md`'s parse step now reads "EPUB3 nav → EPUB2 NCX `navMap` → largest heading → filename". The existing `epub2.epub` fixture has no `toc.ncx` (checked) so its published expectations are unchanged.
