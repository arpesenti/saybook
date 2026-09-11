# Offline synthesis via AVSpeechSynthesizer.write()

saybook renders speech with `AVSpeechSynthesizer.write(_:toBufferCallback:)` (macOS 10.15+; the `toMarkerCallback` variant is macOS 13.0+), which hands generated PCM buffers to the process, instead of the real-time `speak()` API. A probe on macOS 26.6.2 / Swift 6.3.3 (2026-09-11) showed `write()` rendering 21.5 s of audio in 0.39 s (~55× realtime) at 22.05 kHz mono Float32 — a 10-hour book synthesises in ~11 minutes.

## Considered options

- `speak()` + capturing default-output audio: real-time (a 10-hour book takes 10 hours), captures everything else the system plays, fragile. Rejected.
- `say -o chapter.m4b` per chapter: same engine, file output for free, but subprocess-per-chapter, no in-process control, rate only in wpm. Kept as a fallback only.
- `AVSpeechSynthesisProviderAudioUnit`: designed for audio-unit extensions; overkill for a CLI. Rejected.

## Consequences

- `write()` is not featured in the speech-synthesis overview page; expect future readers to look for it and not find it.
- Buffer and delegate callbacks arrive on the main queue; the CLI must keep the main runloop pumped during synthesis.
- The API emits no markers for plain text (only for speech markup), so Chapter Markers are computed from known frame counts, not from engine callbacks.
