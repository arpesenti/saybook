# 09: `testBlocksAreSeparatedByAudiblePauses` is red on main

**What to build:** A green suite again — `swift test` and `swift test -c release` both passing — without weakening the assertion past what ticket 05 actually promised: that the injected **0.3 s inter-Block pause is audible**, and that natural inter-word gaps are not mistaken for it.

**Blocked by:** none

**Status:** needs-triage

## The failure

`Tests/SaybookTests/CLITests.swift:216`, deterministic (identical on every one of 5 runs, debug and release):

```
XCTAssertEqual failed: ("3") is not equal to ("2") - two inter-Block pauses, got: ["0.53", "0.55", "0.22"]
```

Not caused by #08: reproduced with the same three numbers from a pristine `git worktree` at HEAD `18df32f`. It is red on main today, and the ticket that owns the behaviour (#05) is `Status: resolved`, so nothing currently owns this.

## Why it fails (measured 2026-09-19, macOS 27.0 / 26A428)

The fixture is `single-chapter.epub`: 3 Blocks (heading + two paragraphs) → exactly 2 injected pauses. Decoding the finished M4B and listing silent 10 ms-window runs (`rms < 0.01`) bounded by speech on both sides:

| start | length | what it is |
| --- | --- | --- |
| 0.80 s | 0.53 s | Block 1 → 2 boundary (0.3 s injected + engine edge silence) |
| 3.94 s | 0.55 s | Block 2 → 3 boundary |
| **6.95 s** | **0.22 s** | **the trailing edge of the last Block** — the file is 7.2 s |

So the count changed, not the window: the third silence is the **end of the file** leaking into the measurement, and it is 0.22 s against the detection floor of `sampleRate / 5` = **0.2 s**. Two things moved together:

- **The voice's edge silence grew with the OS.** The test's own comment records the injected pauses at 0.36–0.46 s on macOS 26; they are now 0.53 and 0.55 s, and the previously sub-floor trailing edge is now 0.22 s — 20 ms over the floor. This is the `Daniel` (enhanced, en-GB) render, i.e. engine behaviour the test measured but does not control.
- **The edge filter is a hard-edge test.** The guard is `offset > 0, end < totalFrames` ("not touching the file edges"), but AAC decoding leaves ~30 ms of sub-threshold material after the last real silence, so the final Block's edge silence is not recognised as an edge and gets counted as an interior pause.

The assertion's premise — *"natural inter-word pauses are far shorter (<0.1 s) and never touch a whole 0.2 s window run"* — held on macOS 26 and is 20 ms from not holding on macOS 27. Expect this shape again with any voice or OS change.

## Triage questions

1. Is a 0.22 s trailing silence an implementation defect (Block padding at Chapter end) or acceptable engine output? The injected pause is `postUtteranceDelay`, so a trailing pause after the last Block is arguably a small wart in the Chapter's audio either way — worth a separate look if so.
2. Which fix is honest? Candidates, none of them free:
   - ignore runs starting within ~0.5 s of the decoded end (targets the actual failure mode; keeps the 0.2–0.5 s spec window intact),
   - raise the floor to ~0.3 s (narrows the spec's own audible window — probably wrong),
   - assert against the *expected* Block boundaries (heading length + paragraph lengths) rather than counting runs anywhere in the file — the most faithful to ticket 05, and immune to OS drift, but more machinery.
3. Should any pause-length assertion be pinned to the OS/voice it was measured on, or is a per-OS drift margin acceptable? #05 measured on macOS 26; nothing recorded that the numbers were load-bearing per OS.

## Checklist

- [ ] Root cause confirmed (defect in the rendered audio, or measurement premise)
- [ ] Decision recorded here under `## Comments`, with the fix candidate chosen and the rejected ones named
- [ ] `swift test` and `swift test -c release` both green
- [ ] The regression the test exists for still has teeth: a build that drops the inter-Block pause fails this test (prove it, e.g. by zeroing `postUtteranceDelay` temporarily and seeing red)
- [ ] The test comment states which macOS and Voice it was measured against

## Comments

- 2026-09-19 (agent): Opened from #08. While verifying that ticket's suite run I found this red; it is unrelated to the Siri engine (identical at HEAD in a clean worktree). The table above is from `/tmp/pauses.swift` (AVAudioFile read of the finished M4B, 10 ms windows, `rms < 0.01`, runs bounded by speech) — reproducible in one command: `saybook Tests/SaybookTests/Fixtures/single-chapter.epub -o /tmp/p1.m4b --force` then the run listing. Total silent runs of any length: 27; longest 0.55 s.
