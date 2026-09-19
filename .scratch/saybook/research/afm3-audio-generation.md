# Can saybook speak with AFM 3 (the new Apple Foundation Model that generates audio)?

Research date: 2026-09-19. Host: macOS 27.0 (build 26A428), MacBook Pro M4 (Mac16,10), 16 GB,
Swift 6.4, CLT SDKs `MacOSX26.5.sdk` + `MacOSX27.0.sdk`.

## Verdict

**Apple's claim is true; the developer opportunity is not (yet) there.**

1. AFM 3 Core Advanced — the 20B sparse on-device model — really does generate speech. That is
   what powers Siri Expressive Voices ([Apple ML Research, audio synthesis](#sources)).
2. **That audio path has no public API in macOS 27.** Zero audio types in the Foundation Models
   framework, zero new speech-synthesis API in AVFAudio since macOS 14, no new speech framework in
   the 27 SDK, no AFM-backed voice in the runtime voice list. Every check is listed in
   [§4](#4-what-is-not-available-the-checks-ran).
3. **What *is* public:** AFM 3 Core Advanced as a **text** model, selectable via
   `SystemLanguageModel.Variant.coreAdvanced3` (macOS 27). Confirmed live on this M4/16 GB Mac.
4. So `saybook --engine afm3` (audio) is **not implementable today**. Two honest options, both in
   [§5](#5-consequences-for-saybook): use AFM 3's *text* output to make the existing engine speak
   far better (buildable now), and cut an engine seam so a future AFM3 audio API drops in cleanly.

---

## 1. What AFM 3 actually is

Announced WWDC 2026 (8 June). Five models, co-built with Google, per
[Introducing the Third Generation of Apple's Foundation Models](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models):

| Model | Where | Notes |
| --- | --- | --- |
| AFM 3 Core | on-device | 3B dense, successor to the current on-device model |
| **AFM 3 Core Advanced** | on-device | **20B sparse, activates 1–4B per request. Natively multimodal — "enabling helpful features like expressive voices and higher-accuracy dictation." Gated to "our most capable Apple silicon systems."** |
| AFM 3 Cloud | Private Cloud Compute | server workhorse |
| ADM 3 Cloud (Image) | Private Cloud Compute | image generation/editing (Image Playground) |
| AFM 3 Cloud Pro | Private Cloud Compute | agentic tool use, complex reasoning |

## 2. What the "audio" in AFM 3 is

Not a TTS voice bank — a learned audio token path. From
[Memory Efficient Audio Synthesis with Decoupled Temporal Depth Diffusion Transformers](https://machinelearning.apple.com/research/audio-synthesis-diffusion-transformers):
AFM emits *semantic audio tokens*; a **detokenizer** (streaming encoder + temporal decoder + a
shared DiT-style depth decoder, causal sliding-window KV cache) converts them to RVQ audio on the
Apple Matrix Coprocessor. Sustains ~10 ms/step (**~16× real time**), ~21 MB peak runtime memory,
**329 MB of on-device assets**, streaming 20–320 s of audio alongside the model.

It is described as real-time and streaming, and as belonging to Siri. Nothing on that page or the
AFM 3 page mentions developer access.

## 3. What developers get on macOS 27 (verified against the installed SDK)

Source of truth: `MacOSX27.0.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`
(3,647 lines; availability markers: 272× macOS 27.0, 239× macOS 26.0, 11× macOS 26.4).

New in macOS 27 and relevant here:

- `SystemLanguageModel.Variant { displayName }` with `static var core3`, **`static var coreAdvanced3`**
  (interface lines 470–503), and `SystemLanguageModel.variant` (line 470) — i.e. you can *ask which
  model you got* and the advanced one is a named, addressable variant.
- `LanguageModel` protocol + `LanguageModelExecutor` (1483, 1711) — third-party LLM providers plug in
  (WWDC26 session 339); capabilities `.vision`, `.guidedGeneration`, `.reasoning`, `.toolCalling` (1511–1524).
- `PrivateCloudComputeLanguageModel` with `Availability.{available, unavailable(.deviceNotEligible, .systemNotReady)}` (73–85).
- `SystemLanguageModel.contextSize` (line ~447) — 4096 pre-27, larger on 27.
- Vision is **input only**: `Transcript.Content` has exactly `case text(TextSegment)` and
  `case image(ImageAttachment)` (lines 2289, 2380). **There is no audio case.**

Live probe on this Mac (`import FoundationModels`):

```
isAvailable: true
availability: available
variant: AFM 3 Core Advanced | Variant(displayName: "AFM 3 Core Advanced")
caps contains vision: true
```

So the flagship on-device model — the one that generates the expressive speech — **is already
handed to third-party apps**, but only its text head.

WWDC26 "What's new in the Foundation Models framework" (session 241) lists vision input, PCC access,
`BarcodeReaderTool`/`OCRTool`/Spotlight RAG tools, dynamic profiles, the Evaluations framework, the
open model abstraction layer, and the `fm` CLI + Python SDK. It does **not** mention audio, speech
generation, expressive voices, or TTS.

## 4. What is NOT available (the checks ran)

Re-runnable; each row is a command, not an opinion.

| Check | Result |
| --- | --- |
| `grep -ic audio FoundationModels.swiftinterface` | **0** (also 0 for speech/voice/speak/detoken/waveform/pcm) |
| `grep -o "macos(2[0-9]…)" AVFAudio/…/AVSpeechSynthesis.h` | **no matches** — newest marker in the whole header is `macos(14.0)`. No new TTS API in macOS 26 *or* 27 |
| `AVSpeechSynthesisVoiceQuality` cases | unchanged: default / enhanced / premium. No expressive/AFM tier |
| `grep -ril expressive` across all 27-SDK public headers + modules | **no matches** |
| new frameworks in `MacOSX27.0.sdk` vs `MacOSX26.5.sdk` | 34 new (CoreAI, MediaIntelligence, MusicUnderstanding, VisualIntelligence, `_Vision_FoundationModels`, AppIntents sugar…). **None speech/TTS** |
| `grep -rl SpeechSynth` outside AVFAudio | only `AUComponent.h`, `AXSettings.h` — no new synthesiser |
| `grep -rilE "audioGenerat\|generateAudio\|TextToAudio\|audioTokens"` | only RealityFoundation (spatial audio for RealityKit) — unrelated |
| CoreAI / MediaIntelligence / MusicUnderstanding public interfaces | no `synthes*`/speech API |
| runtime `AVSpeechSynthesisVoice.speechVoices()` | **180 voices, all `quality == .enhanced` (1)**, none with `siri`/`afm`/`express`/`neural`/`foundation` in name or id, every voice reports 22 050 Hz mono float PCM. `say -v '?'` lists 184. The AFM voices are **not** hiding behind the legacy engine |
| `/usr/bin/fm` strings (macOS 27's new FM CLI) | "Apple Foundation Models CLI", `--model system - On-device Apple Foundation Model (default)`, Chat, "Chat Completions API server". **No audio/voice/output-audio flags.** Needs `sudo fm license` before first run |

The private frameworks that would carry this (`SiriTTS`, `SiriSpeechSynthesis`, `TextToSpeech`) ship
in the dyld shared cache on macOS 27, not as on-disk binaries — reaching them means private symbols,
App Store rejection, and breakage at every point release. Not worth it for a tool whose whole value is
being a dependable offline CLI.

## 5. Consequences for saybook

### A drop-in AFM 3 audio engine is impossible today
There is nothing to call. Do not add a `--engine` flag that has no second implementation behind it.

### Do this now: use AFM 3's *text* head to make the existing engine speak better
This is the only way AFM 3 can legally improve saybook's audio today, and it fits the spec's
constraints (offline, zero deps, ADR-0001 untouched) because `SystemLanguageModel` is on-device:

- **Prosody markup.** `AVSpeechUtterance(ssmlRepresentation:)` is macOS 13+
  (`AVSpeechSynthesis.h:176,193`), so it needs no new OS. Have AFM 3 Core Advanced tag a paragraph's
  `<break time>`, `<emphasis>`, `<prosody rate/pitch>` and per-speaker voice, then render via the
  existing `Synthesis.render` path. Note the header warning: `pitchMultiplier` does not apply to an
  SSML utterance (`AVSpeechSynthesis.h:189`), so `--rate`/pitch handling has to move into the markup.
- **Dialogue attribution** → per-line voice/pitch, for fiction.
- **Text repair** (OCR artefacts, hyphenation, heading punctuation, `<phoneme>` for names) — cheap,
  high-perceived-quality wins on real EPUBs.

Gate it: `if #available(macOS 27.0, *)` + `SystemLanguageModel.default.availability == .available`,
and fall back silently to today's plain-text path otherwise (`.unavailable(.deviceNotEligible)` is a
real outcome — see the `UnavailableReason` enum, interface lines 82–85).

### When Apple ships an audio API: the seam to cut in advance
Verified load-bearing spots (all paths relative to `Sources/SaybookCore/`):

1. **No seam exists today.** Synthesis is hard-wired: `Synthesis.render(utterance:to:)`
   (`Synthesis.swift:52`) takes an `AVSpeechUtterance` — the engine type leaks into `CLI.swift:282-285`
   (`renderBlocks`). Introduce a small protocol, "text in → CAF at the fixed format out", and make
   `renderBlocks`' `voice:` parameter engine-neutral. `Voice` itself (`Voice.swift:11-19`) is already
   engine-free; only `VoiceCatalog.speechVoice(for:)` (`Voice.swift:117`) maps back to AVFoundation.
2. **The format contract is the real boundary**: `Synthesis.sampleRate`/`trackTimescale` = 22 050 and
   `Synthesis.cafSettings` (mono Float32) at `Synthesis.swift:11,15,19`. `Assemble.concatenate`
   (`Assemble.swift:15`) and `writeSilenceCAFFrames` (`Assemble.swift:38-46`) do **no** format check or
   conversion — a 44.1 kHz/stereo engine output corrupts durations silently. Any AFM3 output (the paper
   implies higher fidelity) must be resampled into this exact CAF shape at the engine boundary.
3. **Chapter markers are frame-count arithmetic** off `AVAudioFile.length` → `ChapterMarkers.startOffsets`
   (`ChapterMarkers.swift:42`) scaled by `trackTimescale` (`ChapterMarkers.swift:143-147`). A different
   sample rate drifts every marker and the reported total duration.
4. **Scratch invalidation must learn about the engine**: `Scratch.optionsMarker(voice:rate:)`
   (`Scratch.swift:34`) keys cache reuse on voice identifier + rate only. Add the engine id, or cached
   CAFs get replayed across engines.
5. **Flag plumbing**: `CLIOptions` struct (`CLIOptions.swift:5-24`), `parse` loop (`CLIOptions.swift:49-98`,
   value flags grouped at `:61`), and the help string `usageLine` (`CLI.swift:331`).
6. `Encode` assumes the M4A export preset (22.05 kHz mono AAC-LC ~34 kb/s, `Encode.swift:5-20`) and
   `Mp4` assumes `moov` is the last box (`Mp4.swift:57-63`) — a non-MP4 engine output breaks both.

### Also available now, no AFM 3 needed
- **Personal Voice** voices are reachable through the public engine: `AVSpeechSynthesizer.requestPersonalVoiceAuthorization`
  and `AVSpeechSynthesisVoiceTraitIsPersonalVoice` (`AVSpeechSynthesis.h:90,276,287`, macOS 14+). Worth a
  `--personal-voice` flag for accessibility users; still the legacy engine, still offline.
- This machine has **no premium voices installed** (all 180 report `.enhanced`), so
  `VoiceSelection.bestQuality` (`Voice.swift:87-93`) can never return `.premium` here. Worth surfacing
  in the "no better voice available" message rather than silently picking an enhanced voice.

## 6. Watch list (re-run each macOS point release)

```sh
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk   # bump the version
F=$SDK/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface
grep -ic "audio\|speech\|voice" $F                            # >0 ⇒ Apple opened the door
grep -rn "macos(2[6-9]" $SDK/System/Library/Frameworks/AVFAudio.framework/Versions/A/Headers/AVSpeechSynthesis.h
grep -ril "expressive" $SDK/System/Library/Frameworks/*/Versions/A/Headers
swiftc -target arm64-apple-macos27.0 /tmp/voiceprobe.swift -o /tmp/voiceprobe && /tmp/voiceprobe   # new voices/qualities
sudo fm license && fm --help                                  # check for an audio output flag
```

Also watch: a follow-up to WWDC26 session 241, any `AVSpeechSynthesizer` "expressive"/"quality" API in
the release notes, and whether Apple extends the `AVSpeechSynthesisProvider` extension mechanism
(macOS 13+, `AVSpeechSynthesisProvider.h`) to system-provided AFM voices — that extension point is the
natural place an Apple-owned expressive voice would eventually surface.

Filed as: Feedback Assistant → Accessibility/Speech *and* Foundation Models, asking for the AFM 3
expressive-voice synthesiser to be exposed to third-party apps (offline, batch/offline-render mode,
ideally with `AVSpeechUtterance`-compatible buffer output so tools like saybook can render without
real-time playback).

## Sources

Primary (own the claims):
- https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models — AFM 3 family, sizes, "expressive voices", device gating.
- https://machinelearning.apple.com/research/audio-synthesis-diffusion-transformers — expressive-voice detokenizer, 10 ms/step ≈16× realtime, ~21 MB peak, 329 MB assets.
- `MacOSX27.0.sdk/…/FoundationModels.swiftinterface` — variant `.core3`/`.coreAdvanced3` (lines 470–503), `Transcript.Content` text|image only (2289, 2380), `LanguageModelCapabilities` (1483–1524), `PrivateCloudComputeLanguageModel.Availability` (73–85), zero audio types.
- `MacOSX27.0.sdk/…/AVFAudio/…/AVSpeechSynthesis.h` — voice quality enum (22–25), SSML init (176, 193), personal-voice API (90, 276, 287); no `macos(2x)` availability markers.
- Runtime probes on this Mac: `SystemLanguageModel.default` → variant "AFM 3 Core Advanced", available, vision capable; `AVSpeechSynthesisVoice.speechVoices()` → 180 voices, all `.enhanced`, no AFM/expressive ids.
- `/usr/bin/fm` strings — text/chat/serve CLI only, no audio flags.
- WWDC26 session 241 (Foundation Models what's new) and session 339 (bring your own LLM provider) — no audio capability announced.

Secondary (context only, not load-bearing):
- TechRadar on AFM Core Advanced device gating (12 GB RAM floor on iPhone).
- 9to5Mac / ModelDex / Frontierbeat WWDC26 recaps of the five-model lineup.
