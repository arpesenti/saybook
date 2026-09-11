# 02: Chapter Markers, resume & summary

**What to build:** A multi-Chapter Book produces one Audiobook with a titled Chapter Marker at each Chapter start; re-running the same command resumes from existing Scratch (Chapters whose CAF already exists are not re-synthesised); a final summary is printed. Marker offsets come from known per-chapter frame counts against the track timescale — computed, not parsed.

**Blocked by:** 01 (Skeleton — one-chapter Book to playable M4B)

**Status:** claimed

- [ ] A 3-chapter fixture produces one M4B with exactly 3 Chapter Markers (`chpl`), each carrying the Chapter's title
- [ ] Marker offsets land at the true Chapter boundaries (within one AAC frame), verified by a test that parses the `chpl` and compares against known PCM lengths
- [ ] Chapter titles fall back: largest heading in the document → filename (EPUB3 nav titles arrive in ticket 03)
- [ ] Kill the run mid-way, re-run: existing Chapters are skipped, no re-synthesis, and the final Audiobook is complete and correct
- [ ] Final summary reports: chapter count, skipped count, total duration, output size and path
- [ ] Scratch is deleted on success and kept on failure
