# 06: Error paths, safety & signals

**What to build:** The tool's failure behaviour, matching the spec: `--force` output clobber, the 0/1/2 exit-code contract, DRM detection, empty-Book and empty-Chapter handling, non-XHTML Spine items, and graceful SIGINT handling.

**Blocked by:** 02 (Chapter Markers, resume & summary), 05 (Block-level text with natural pauses)

**Status:** ready-for-agent

- [ ] Without `--force`, an existing output file is refused (exit 1); with `--force` it is replaced
- [ ] Exit codes: 0 on success; 1 for input/user errors (unreadable or invalid EPUB, DRM-encrypted content, no readable Chapters, no Voice for the language, output exists); 2 for internal errors
- [ ] An EPUB with an encrypted OPF or encrypted content items fails cleanly with a readable DRM error — no crash, no half-written output file
- [ ] A Book with no readable Chapters fails with exit 1 and a message
- [ ] A Chapter that yields no text produces no audio and no Chapter Marker, and is listed in the summary as `skipped (no text)`
- [ ] Non-XHTML Spine items (video, images, other media) are skipped without failing the run
- [ ] SIGINT stops the run after the current unit of work, keeps Scratch, prints progress so far, and exits cleanly (resume by re-running)
- [ ] Each failure mode is covered by a test that asserts the exit code and the message (no synthesis needed — exercise via fixtures and stubs)

## Comments

- 2026-09-11 (agent, from #04 review): The spec's CLI line also names `-o out.m4b` and `--keep-scratch` ("`saybook <book.epub> [-o out.m4b] … [--keep-scratch] [--force]`"), and no ticket owns them yet — #04's flag parser rejects both as unknown options until then. #06 is the natural home (both are run-safety/CLI-surface concerns); note them here so they are not dropped when #07 writes the README flag documentation.
