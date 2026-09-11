# 03: Book metadata, cover & navigation

**What to build:** The Audiobook carries the Book's identity: title, author and album in `ilst` metadata boxes plus the cover image as a `covr` box, all degrading gracefully (a failed box write keeps the file with a warning). Chapter titles are taken from the EPUB3 navigation document when present, with the ticket-02 fallbacks otherwise. Navigation, cover and titlepage Spine documents are never spoken.

**Blocked by:** 01 (Skeleton — one-chapter Book to playable M4B)

**Status:** ready-for-agent

- [ ] `afinfo`/`mdls` on the output show title = Book title, artist = author, album = Book title
- [ ] A missing author degrades to a sensible placeholder (e.g. "Unknown") rather than an empty box
- [ ] When the OPF declares a cover image, a `covr` box is present and the image is extractable from the file
- [ ] When the OPF declares no cover, no `covr` box is written and nothing crashes
- [ ] An EPUB3 Book's Chapter Marker titles match its navigation entries; an EPUB2 Book (no nav) uses the largest-heading → filename fallback
- [ ] A fixture whose Spine contains a TOC/navigation page and a cover page speaks neither of them
- [ ] A deliberately broken cover image (bad reference) degrades gracefully: file still written, warning emitted
