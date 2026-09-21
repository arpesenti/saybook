# 11: Can the private Siri engine be told to *perform* (style, prosody, pacing)?

**Type:** research

**What to build:** An answer, with evidence, to whether `TTSSynthesizer`'s expressive-control surface can be driven from saybook — and specifically whether any of it is a **pacing control**, which would let `--rate` work with `--engine siri` instead of being refused (#08's deliberate refusal is only right if nothing is reachable). Deliverable is a research note plus working probe code; no production change in this ticket.

**Blocked by:** 08 (the bridge, and the three call-shape landmines are already recorded there)

**Status:** ready-for-agent

## Known surface

From `xcrun dyld_info -exports /System/Library/PrivateFrameworks/SiriTTS.framework/Versions/A/SiriTTS` (183 exports, macOS 27.0). The mangled names carry the parameter types — decode them rather than guessing:

| Symbol | Recovered shape | Question |
| --- | --- | --- |
| `set_neural_style(std::string)` | `…16set_neural_styleERKNSt3__112basic_stringIc…` | What strings are accepted? Where do the names come from? |
| `set_neural_style(std::vector<float>)` | `…16set_neural_styleERKNSt3__16vectorIf…` | A style *embedding* — where does a usable vector come from? |
| `available_neural_styles()` | **not** `std::string` (calling it as one yields `Bus error: 10`) | Presumably `std::vector<std::string>` — enumerate it. This is the door to everything above. |
| `available_neural_style()` *(singular — also exported)* | `…22available_neural_styleEv` | Different function, not a typo of the above. If the singular returns the *current* style as `std::string` and the plural the *menu*, the pair is directly readable — and `set_neural_style(name)` then round-trips through it. |
| `get_neural_style()` | `…16get_neural_styleEv` | The getter: whatever it returns is the format `set_neural_style` expects. Start here — it is the cheapest way to learn the type without guessing. |
| `set_global_property(GlobalProperty, float)` / `(GlobalProperty, std::string)` | enum value unknown | **Is one of these a rate/pace?** Also `pitch`, `emphasis`, `pause`, `loudness`. |
| `preheat()`, `set_log_level(int)` | used already | — |
| internal `synthesize_text(…, std::vector<Marker>*, std::function<int(CallbackMessage)>)` | `Marker`/`CallbackMessage` enums unknown | Do markers carry per-word timing a narrator pacing feature could use? |

## Where to look (in rough order of payoff)

1. `get_neural_style()` then `available_neural_styles()` on the installed voice — cheapest, most decisive. The getter reveals the representation without guessing; if the enumeration returns names, `set_neural_style(name)` becomes usable and the string half of the question is answered.
2. `strings` over `SiriTTS.framework`, `SiriTTSDaemon` (if present), `SiriSpeechSynthesis.framework` and any daemon/agent that *calls* `set_global_property`, looking for the string arguments and property identifiers callers pass. A caller's constant is better evidence than a guessed enum.
3. The voice bundle itself: `gryphon.cfg` keys (`sample_rate_in: 24000`, `sample_rate_out: 48000`, …), the bundle's `Info.plist`, and `ProsodyTransferAssetPath` / `OrchestratorAssetPath` — **both empty on this Mac**, which is the strongest existing hint that style transfer is an asset-gated feature and that the AFM 3 expressive path (#08's research) is what fills them.
4. `+[SiriTTSNeuralUtils …]` (`isNeuralVoiceReady:`, `hasAMX`, `isANEModelCompiled:`, `isFMPlatform`, `currentSampleRate:`) for what the engine considers ready — `isANEModelCompiled:@"martha"` is `false` here, so some capability may be gated on ANE compilation we cannot trigger.
5. Only if 1–4 come up empty: brute-force `GlobalProperty` over a small ordinal range, with the float form, watching for a duration change — measurable cheaply, since #08 gives a deterministic frame-count assertion (a real pacing control moves the frame count for fixed text; a no-op does not).

## Evidence standard

Primary sources and measurement only — decoded signatures, the bundle's own config, observable output. An audible difference is not evidence of *what* a knob does; a change in the rendered **frame count / spectral envelope for fixed text** is. Record the numbers. `SAYBOOK_SIRI_DIAGNOSTICS=1` is often the fastest way to see a rejected parameter name get complained about.

## Landmines already paid for (see #08 and `.scratch/saybook/prototype/siri-tts-probe.cpp`)

`dlsym` needs the Mach-O leading underscore **stripped**; `initialize`'s third argument is a persistent-module name, **not** a locale (`"en-GB"` aborts with `FrontendModuleBroker: Unknown module 'en-GB'`); `available_neural_styles()` is not `std::string`; there is **no `timeout` on macOS**, so a hung probe looks like a hung shell; the engine's own logging is 153 KB per 6-second Chapter and blocks on an undrained stderr pipe.

## Definition of done

- [ ] A table in `.scratch/saybook/research/siri-expressive-control.md`: every expressive symbol, its decoded signature, what it measurably changes, and what it requires (assets, ANE compilation, entitlement) — including the negatives, reproduced
- [ ] **Explicit verdict on pacing**: does any reachable control change speaking rate for fixed text? This decides whether `--rate` stays refused with `--engine siri`
- [ ] Verdict on whether style is available at all on a Mac without the AFM 3 expressive assets (`ProsodyTransferAssetPath` empty here), stated as a machine-specific result
- [ ] Working additions to `.scratch/saybook/prototype/siri-tts-probe.cpp`, committed, buildable from a repo path
- [ ] A recommendation: build `--style`/`--rate` for the Siri engine, or record it as `wontfix` with the reason — and if "build", a follow-up implementation ticket opened rather than code written here
- [ ] If any finding changes saybook's interface or documented behaviour, an ADR (or an amendment to ADR-0003) rather than a silent edit

## Comments

- 2026-09-19 (agent): Opened from #08, where this was the deferred question ("can the Siri voice perform a book?") and where `available_neural_styles()` first bit me as a `Bus error: 10`. Related and separate: #08 established the AFM 3 expressive-voice path exists in Apple's research but has **no API and no assets** on this OS — if styles here turn out to be asset-gated, that is the same wall, and the honest answer is "wait for Apple to ship it", not "brute-force harder".
