# 07: Test suite, E2E & README

**What to build:** Durable verification and documentation. The full fixture set and unit test suite are green and network-free; a one-command manual E2E proves the tool on a real Book; the README documents build, usage, flags and limitations.

**Blocked by:** 02 (Chapter Markers, resume & summary), 03 (Book metadata, cover & navigation), 04 (Voice & language selection), 05 (Block-level text with natural pauses), 06 (Error paths, safety & signals)

**Status:** ready-for-agent

- [ ] In-repo mini-EPUB fixtures cover: single chapter, multi-chapter with EPUB3 nav, cover image, empty document, EPUB2 (no nav), EPUB3, links/footnotes/images, missing author
- [ ] Unit tests cover: per-Block text extraction rules, `chpl` offset math, and the `ftyp` brand-patch round-trip (patched file still decodes and reports the M4B brand)
- [ ] `swift test` passes with zero network access
- [ ] A manual E2E script: builds the release configuration, runs saybook on a real EPUB (path argument, or a Project Gutenberg download), and asserts output brand, duration, chapter markers and metadata
- [ ] README covers: what the tool is, requirements (macOS 13+), build (`swift build -c release`), usage with all flags, an example run, and limitations (non-DRM only, one Book per run, preset ~34 kb/s bitrate, Apple system voices)
- [ ] The full test suite runs in under 2 minutes
