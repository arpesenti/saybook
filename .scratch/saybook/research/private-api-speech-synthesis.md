# Can saybook use a private API for speech synthesis?

Research date: 2026-09-19. Host: macOS 27.0 (26A428), MacBook Pro M4 (Mac16,10), 16 GB.
Follows [afm3-audio-generation.md](afm3-audio-generation.md), which established that **no public API**
reaches Apple's generative/expressive speech. This note answers the follow-up: *given this is a
personal CLI with no App Store distribution, is a private API viable?*

## Verdict

**Yes — one door is open, and it is already proven working on this machine.**

| Door | State |
| --- | --- |
| `sirittsd` XPC (`com.apple.sirittsd`) — Siri's own TTS daemon, full request/reply synthesis protocol | **Refused.** `NSCocoaErrorDomain Code=4097` from an unentitled CLI |
| `SiriTTS.framework` — the C++ `TTSSynthesizer` engine the daemon drives, **in-process** | **Works.** `synthesize_text_sync` → 263,640 bytes of 16-bit PCM from a 100-line probe, no entitlements, no daemon |

What you get: the **Siri "gryphon" neural voice** (FastSpeech2 + WaveRNN, `martha` en-GB is installed
here) — audibly a tier above the `com.apple.voice.enhanced.*` voices AVFoundation exposes.

What you do **not** get: the AFM 3 expressive voices specifically. They are not installed on this
Mac (see [§4](#4-afm-3-expressive-voices-are-not-here)). The private door leads to the *previous*
generation of Siri voices, not to AFM 3.

Runnable proof: `.scratch/saybook/prototype/siri-tts-probe.cpp`

```
$ c++ -std=c++17 .scratch/saybook/prototype/siri-tts-probe.cpp -o /tmp/siri-probe && /tmp/siri-probe 6
STEP4 initialize(assetData,"","")
STEP5 ready_for_synthesis = 1
      using_gryphon_frontend = 1
STEP6 synthesize_text_sync("The quick brown fox jumps over the lazy dog.")
      -> raw return 0x0, bytes=263640
```

---

## 1. The closed door: the XPC daemon

`/System/Library/LaunchAgents/com.apple.sirittsd.plist` (a **user-session agent**, not a root daemon)
runs `/System/Library/PrivateFrameworks/SiriTTSService.framework/sirittsd` and vends Mach service
`com.apple.sirittsd`. The runtime class `SiriTTSDaemonSession` is the complete XPC protocol, and it is
almost a specification for what saybook wants:

```
-synthesizeWithRequest:didFinish:              <- render, no playback
-estimateDurationWithRequest:didFinish:        <- duration up front (chapter math!)
-speakWithSpeechRequest:didFinish:
-getSynthesisVoiceMatching:reply:              <- voice selection
-downloadedVoicesMatching:reply:
-didGenerateAudioWithRequestId:audio:          <- client callback
-didGenerateWordTimingsWithRequestId:wordTimingInfo:
-textToPhonemeWithRequest:didFinish:
-prewarmWithRequest:didFinish:
```

Connecting from a plain CLI fails:

```
calling pingWithReply: …
ERROR HANDLER: Couldn't communicate with a helper application.
  (Error Domain=NSCocoaErrorDomain Code=4097 "connection to service named com.apple.sirittsd")
```

Control (a Mach service that does not exist) produces a *different* result (`INVALIDATED`, no error),
so the service is registered and simply will not talk to us. Re-verify:
`/tmp/ping.swift` pattern in this file's history, or any `NSXPCConnection(machServiceName: "com.apple.sirittsd")`.

## 2. The open door: `SiriTTS.framework` in process

`xcrun dyld_info -exports` works on shared-cache images — this is the primary source, not a blog post:

```sh
xcrun dyld_info -exports /System/Library/PrivateFrameworks/SiriTTS.framework/Versions/A/SiriTTS
# 183 exports; class namespaces: TTSSynthesizer, TTSSynthesizerEventBus, NeuralTTSUtils,
#                                     FastRewriter, SiriTTS::PipelineTool, Observable
```

The usable surface (demangled from the export trie):

| Symbol | Why it matters |
| --- | --- |
| `TTSSynthesizer::initialize(string, string, string)` | loads a voice asset bundle |
| `TTSSynthesizer::synthesize_text_sync(string&, vector<unsigned char>&)` | **text → audio, synchronous, single call** |
| `TTSSynthesizer::synthesize_text_with_markers_async(...)` | audio **plus `Marker`s** — word timing for chapter markers |
| `TTSSynthesizer::ready_for_synthesis()`, `preheat()` | readiness / model warm-up |
| `TTSSynthesizer::available_neural_styles()`, `set_neural_style(string)`, `set_neural_style(vector<float>)` | expressive style control |
| `TTSSynthesizer::set_global_property(GlobalProperty, float\|string)` | rate/volume/pitch (enum values unknown) |
| `TTSSynthesizer::set_synthesis_mode`, `set_neural_cost`, `set_prohibit_neural`, `set_global_whisper` | engine modes |
| `TTSSynthesizer::load_voice_resource(path\|bytes, …)` | load a voice from a path or a memory buffer |
| `TTSSynthesizer::dynamic_prompts`, `set_dynamic_prompt(s)`, `set_prompts_disabled` | prompt-conditioned voices |
| `TTSSynthesizer::has_word_timing_support`, `has_phatic_responses`, `available_phonesets`, `get_voice_description`, `dump_analysis` | capability queries |
| `TTSSynthesizerEventBus::on_audio(function<void(const vector<float>&)>)` | streaming float PCM |
| `NeuralTTSUtils::is_h12_platform()`, … | platform gates |

**Three things that cost me an hour and will cost you nothing:**

1. `dlsym` takes names with the **Mach-O leading underscore stripped**: `__ZN14TTSSynthesizerC1Ev`
   becomes `_ZN14TTSSynthesizerC1Ev`. Everything returns `NULL` otherwise — including `CFStringCreateWithCString`,
   which makes you conclude the OS is blocking you when it isn't.
2. `initialize()`'s **third argument is a persistent-module name, not a locale**. Passing `"en-GB"`
   aborts: `std::logic_error: FrontendModuleBroker: Unknown module 'en-GB'`. Passing `""` works.
3. The object's size is unknown (private C++ class). Over-allocating 128 KB and calling
   `TTSSynthesizerC1Ev` on it works; it is also the single most fragile part of the approach.

## 3. Output format

`synthesize_text_sync` returns **raw 16-bit little-endian PCM**, no container header:

- 263,640 bytes for "The quick brown fox jumps over the lazy dog." → 131,820 samples
- float32 interpretation gives NaN → it is int16, not float; absmax 26,751, mean |x| 2,263 (sane speech)
- last non-silent sample at 2.702 s; AVFoundation's `Daniel` renders the same sentence in **2.842 s**
  (`afinfo`), so 2.70 s is the right ballpark → **48 kHz mono** (or 24 kHz interleaved stereo — the two
  are indistinguishable from duration alone, and adjacent-sample correlation can't separate them)
- `+[SiriTTSNeuralUtils currentSampleRate:@"martha"]` = **24000.0** (also for `en-GB`) — Apple's own
  number for the voice, so the returned buffer is 2× the model's nominal rate (WaveRNN upsampling)

Confirm the authoritative ASBD before writing a CAF: `OPTTSAudioDescription` exposes
`sample_rate`, `channels_per_frame`, `bits_per_channel`, `bytes_per_frame`, `format_id`, and
`audioStreamBasicDescription` — that is what the daemon hands its clients.

**saybook impact:** the buffer must be converted into `Synthesis.cafSettings` — mono Float32 at
22 050 Hz (`Sources/SaybookCore/Synthesis.swift:11,19`) — *inside* the new engine. `Assemble.concatenate`
(`Assemble.swift:15`) does no format check or resampling, and chapter markers are frame arithmetic off
`trackTimescale` (`ChapterMarkers.swift:143-147`), so anything else silently corrupts durations.

## 4. AFM 3 expressive voices are NOT here

The private engine is the pre-AFM Siri voice. Evidence:

- The only installed Siri voice asset is `martha` (230 MB), and its `Info.plist` says
  `EngineConfigTemplateType = fastspeech2_mil_base` — FastSpeech2, not the AFM 3 DiT detokenizer.
  Files: `compact_fastspeech2`, `compact_wavernn`, `wavernn_config.json`, `g2p_seq2seq.bin`,
  `p2a/`, `anetec/`, `prompts/` (RVQ codebooks `prompt_k_vq_0..7.bin`), `gryphon.cfg`.
  Path: `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto/`
- The advanced pipeline slots in that same plist are **empty**: `ProsodyTransferAssetPath`,
  `OrchestratorAssetPath`, `BERTAssetPath`, `DialogAssetPath`.
- Zero matches for `expressive` across all 93 `*.xml` metadata files under `/System/Library/AssetsV2`.
  (`grep -ril expressive` — beware: macOS has no `timeout`; a `timeout …` wrapper fails silently and
  looks like a negative result.)
- But the code is gated and waiting: `SiriTTSService.FmVoiceProvider`, `SiriTTSService.IsFmVoiceCondition`,
  `SiriTTSService.SynthesisEngineSelectionAction`, `SiriTTSService.PCCClient`, `SiriTTSService.DeviceSynthesisAction`
  exist, and `+[SiriTTSNeuralUtils isFMPlatform]` returns **true** on this M4/16 GB Mac, alongside
  `hasAMX = true`, `hasANE = true`, `isNeuralPlatform = true`, `isNaturalPlatform = true`.

So the FM voice *plumbing* is present and this Mac is *eligible*; only the model assets are absent
(no AFM 3 voice asset has been delivered to this machine). Whether a later point release ships them is
the thing to watch.

## 5. Don't bother: the dead ends I already walked

- **`com.apple.ttsbundle.gryphon-neural_martha_en-GB_premium` through AVFoundation** — no. The private
  voice database `+[TTSSpeechManager availableVoices]` (and both `availableVoices:` BOOL variants)
  returns the same 184/185 `com.apple.voice.*` identifiers AVFoundation publishes; zero entries contain
  `gryphon`, `siri`, `premium` or `personal`.
- **Forcing an identifier** — `+[TTSSpeechSynthesizer _speechVoiceForIdentifier:language:footprint:]`
  returns `com.apple.voice.compact.en-GB.Daniel` for *every* identifier tried, including nonsense ones.
  `say` behaves identically: `say -v ZebraNope`, `say -v martha`, `say -v com.apple.ttsbundle.gryphon-…`
  and `say -v Daniel` produce **byte-identical** AIFF files (`md5 9054eb83…`). Silent fallback, always.
- **Downloading "premium" AVFoundation voices** — the macOS 27 catalogue
  (`com_apple_MobileAsset_MacinTalkVoiceAssets.xml`) offers 22 voices, 20 `compact` + 2 `premium`
  (legacy `Alex` and `Vicki`, build 9M5868). No neural tier. Your 180 installed voices are already all
  `.enhanced`, the top of that ladder.
- **`VoiceServices.framework`** — on macOS 27 the framework contains only `TTSResources`; the old
  `VSSpeechSynthesizer` route from the macOS 11 era is gone.

## 6. What wiring this into saybook actually costs

Honest scope, worst parts first:

1. **Unknown ABI.** Class size (over-allocated), plus unknown enums `SynthesisMode`, `GlobalProperty`,
   `NeuralComputingCost` and unknown structs `Marker`, `CallbackMessage`. Anything touching them is
   trial-and-error. `synthesize_text_sync` avoids all of them — which is why the probe used it.
   Return types are guesswork too: calling `available_neural_styles()` as if it returned `std::string`
   dies with `Bus error: 10` (it is almost certainly `std::vector<std::string>` — sret size mismatch
   smashes the stack). Only `get_engine_description` / `get_voice_description` / `get_locale` are
   confirmed `std::string`, and they returned **empty** here even after a successful `initialize`.
2. **Point-release fragility.** These are unexported-by-intent C++ symbols; they can change signature
   or vanish in 27.1. Mitigation: resolve every symbol at launch; if *any* is missing or
   `ready_for_synthesis` is false, log once and fall back to the AVFoundation path. Never hard-crash,
   never half-write a chapter.
3. **Voice availability is not yours to choose.** `SiriSpeechSynthesis.framework/…/tts_voices.plist`
   lists 48 Siri voices across ~24 locales (name/gender/locale/default only — no quality field), but
   which assets exist on a given Mac is decided by MobileAsset and `sirittsd`'s `voiceUpdate`/
   `neuralCompiling` XPC activities (the latter requires "significant user inactivity"). Here, exactly
   one voice (`martha`, en-GB) is installed, and `+[SiriTTSNeuralUtils isANEModelCompiled:@"martha"]`
   is still **false** → engine falls back off-ANE. A `--voice`-style flag must therefore mean
   "use the Siri voice *if one is present*", not "pick any of 48".
4. **Two new seams in existing code** (unchanged from the previous note): a synthesis protocol behind
   `Synthesis.render(utterance:to:)` (`Synthesis.swift:52`), and the engine id added to
   `Scratch.optionsMarker(voice:rate:)` (`Scratch.swift:34`) so cached CAFs are never replayed across
   engines. Flag plumbing: `CLIOptions.swift:5-24,49-98` + `usageLine` (`CLI.swift:331`).
5. **Spec drift.** `spec.md` promises "Apple's speech engine, offline, zero third-party dependencies".
   A private Siri engine is still offline and dependency-free, but it is not the documented public
   engine — worth an ADR (e.g. `docs/adr/0003-private-siri-speech-engine.md`) recording that this is an
   unsupported, opt-in path and stating the failure mode when Apple changes it.

Not a flag-level change. It is a bounded but real RE project — one evening to get `martha` speaking into
saybook's CAF pipeline, indefinitely ongoing to keep alive across releases.

## 7. Recommendation

Ship it behind an explicit opt-in that defaults off (`--engine siri`, or env `SAYBOOK_ENGINE=siri`),
documented as unsupported, with automatic fallback. Then, before investing further, spend 20 minutes on
the two cheap questions the probe raises:

1. What do the neural styles offer for `martha`? That is where "expressive" lives without AFM 3 — the
   difference between "nicer voice" and "audiobook that performs the book". Caution: read
   `available_neural_styles()` as a `std::vector<std::string>`, not a `std::string` (the latter bus-errors,
   see §6.1); `set_neural_style(std::string)` is the safer first probe since its argument type is known.
2. What are the `GlobalProperty` float knobs? (`set_global_property(GlobalProperty, float)` almost
   certainly carries rate/volume, which today only exists via `AVSpeechUtterance.rate`.) Brute-force the
   enum over a small range and watch the output, or read `gryphon.cfg` in the voice bundle for the
   module/property names it expects.

Both are answerable with the same probe file — it is step-driven on purpose, so a crash identifies the
exact call that was wrong.

## Sources

All primary and local to this machine unless marked. Re-run any line to re-verify.

- `xcrun dyld_info -exports /System/Library/PrivateFrameworks/SiriTTS.framework/Versions/A/SiriTTS` — the `TTSSynthesizer` API surface (183 exports).
- `.scratch/saybook/prototype/siri-tts-probe.cpp` — working call: `initialize` → `ready_for_synthesis=1` → `synthesize_text_sync` → 263,640 bytes.
- `/System/Library/LaunchAgents/com.apple.sirittsd.plist` — `MachServices { com.apple.sirittsd }`, `neuralCompiling`/`voiceUpdate` XPC activities.
- Runtime class dumps of `SiriTTSService`, `SiriSpeechSynthesis`, `TextToSpeech` via `objc_copyClassNamesForImage` + `class_copyMethodList` — `SiriTTSDaemonSession`, `OPTTS*` protocol classes, `FmVoiceProvider`, `IsFmVoiceCondition`, `SiriTTSNeuralUtils` (`isFMPlatform`, `hasAMX`, `isNeuralVoiceReady:`, `isANEModelCompiled:`, `currentSampleRate:`), `TTSSpeechManager +availableVoices`, `TTSSpeechSynthesizer +_speechVoiceForIdentifier:language:footprint:`, `SiriVoiceLoader`, `VoiceSmuggler`.
- `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto/*/.asset/AssetData/` — `martha_5173`, `EngineConfigTemplateType = fastspeech2_mil_base`, empty `ProsodyTransferAssetPath`/`OrchestratorAssetPath`; `Info.plist` `CFBundleIdentifier = com.apple.MobileAsset.VoiceServices.GryphonVoice`, `Footprint = premium`, `Type = natural`.
- `/System/Library/AssetsV2/com_apple_MobileAsset_TTSAXResourceModelAssets/…/Contents/` — 501 voice preview CAFs, 135 named `com.apple.ttsbundle.gryphon[_neural]_<voice>_<locale>_premium`.
- `/System/Library/PrivateFrameworks/SiriSpeechSynthesis.framework/Versions/A/Resources/tts_voices.plist` — 48 Siri voices, keys `default/gender/locale/name` only.
- `/System/Library/AssetsV2/com_apple_MobileAsset_MacinTalkVoiceAssets/…xml` — 22 downloadable AVFoundation voices, 20 compact + 2 premium (Alex, Vicki).
- `MacOSX27.0.sdk/…/AVFAudio/…/AVSpeechSynthesis.h` — newest availability marker is `macos(14.0)`; no new public TTS API in macOS 26 or 27.
- Negative results, all reproduced: 0 audio/speech types in `FoundationModels.swiftinterface`; `say` byte-identical fallback across unknown voices; 184/185 identical ids from private `+[TTSSpeechManager availableVoices]`; `grep -ril expressive` across 93 AssetsV2 metadata files = no matches.
- Secondary, context only: [Apple ML Research — AFM 3](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models), [Apple ML Research — expressive-voice detokenizer](https://machinelearning.apple.com/research/audio-synthesis-diffusion-transformers) (FastSpeech2 ≠ AFM 3 path; AFM 3 assets are ~329 MB and absent here).

## Outcome (2026-09-19)

Wired up as `saybook --engine siri` — ticket `.scratch/saybook/issues/08-private-siri-engine.md`, decision in `docs/adr/0003-private-siri-speech-engine.md`. Three things the probe left open were settled by the implementation:

- **Sample rate: 48 kHz mono signed 16-bit LE.** `gryphon.cfg` in the voice bundle is explicit — `sample_rate_in: 24000`, `sample_rate_out: 48000`, `sample_rate: 48000` — which resolves the ambiguity the probe could not (2.702 s of audio is 48 kHz mono or 24 kHz interleaved stereo). `+[SiriTTSNeuralUtils currentSampleRate:]`'s 24 000 is the pre-vocoder stage. Cross-checked against the public engine on the same fixture: 135.7 s vs 128.0 s.
- **`synthesize_text_sync` can block forever on stderr.** `Diagnostics::log` writes to stdout/stderr from the calling thread regardless of `set_log_level`: one 6-second Chapter emitted **153 873 bytes**, so any caller whose stderr is an undrained pipe deadlocks once the 64 KB buffer fills (`sample` shows `Diagnostics::log → vfprintf → __sflush → _swrite → __write_nocancel`). The production bridge `dup2`s `/dev/null` over both descriptors across every engine call; `SAYBOOK_SIRI_DIAGNOSTICS=1` restores the chatter. The probe never saw this because its stderr was a terminal.
- **Loading a voice is expensive enough to cache.** One `TTSSynthesizer` per voice asset is held for the process's life (the object is deliberately not freed: its true size is unknown, so the 128 KB over-reservation cannot be trusted to `free`). The probe's one-shot process shape hid this.
