#ifndef SAYBOOK_SIRI_TTS_BRIDGE_H
#define SAYBOOK_SIRI_TTS_BRIDGE_H

/*
 The C entry point into Apple's private in-process Siri speech engine
 (SiriTTS.framework's C++ TTSSynthesizer). Implemented in SiriTTSBridge.cpp.

 There is no public API for this engine: AVSpeechSynthesizer exposes only the
 legacy com.apple.voice.* voices and silently falls back to the default voice
 for any identifier it does not know (verified on macOS 27: unknown `-v`
 values produce byte-identical output to the default). See
 .scratch/saybook/research/private-api-speech-synthesis.md.

 The header stays pure C so SaybookCore can import this target without
 Swift/C++ interoperability enabled.
*/

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { SAYBOOK_SIRI_ERROR_CAP = 512 };

/* The sample rate and channel count of the PCM this returns: mono int16,
   little-endian, no container header. Corroborated by the voice bundle's own
   gryphon.cfg ("sample_rate_in": 24000 → "sample_rate_out": 48000) and by
   comparing rendered durations against AVSpeechSynthesizer's for the same
   sentences (ratios ~0.94/0.97/0.84, i.e. a slightly faster narrator, not a
   2x rate error). Caller converts to Synthesis.cafSettings. */
#define SAYBOOK_SIRI_SAMPLE_RATE 48000.0
#define SAYBOOK_SIRI_CHANNELS 1

/* Renders `text` with the Siri voice whose extracted asset directory is
   `voice_asset_dir` (a MobileAsset .../AssetData directory containing
   gryphon.cfg), and returns its audio as newly allocated PCM.

   Returns 0 on success and then sets *out_pcm / *out_count (samples, not
   bytes); the caller frees *out_pcm with saybook_siri_free().

   Returns non-zero on failure, leaves *out_pcm null, and writes a
   human-readable reason into `error` (at most error_cap bytes). Never
   propagates a C++ exception: Apple's engine throws std::logic_error for
   bad engine arguments, which would otherwise abort the process.

   The engine instance for a voice asset is created on first use and reused,
   because loading a voice bundle is expensive. Not thread-safe: saybook
   renders from one thread. */
int saybook_siri_synthesize(const char *voice_asset_dir,
                            const char *text,
                            int16_t **out_pcm,
                            size_t *out_count,
                            char *error,
                            size_t error_cap);

/* Probes the engine once (load the voice, ask it whether it can synthesise)
   without rendering. Returns 0 when this voice is usable, non-zero with a
   reason in `error` otherwise. Lets the CLI fail before any work starts. */
int saybook_siri_probe(const char *voice_asset_dir, char *error, size_t error_cap);

void saybook_siri_free(int16_t *pcm);

#ifdef __cplusplus
}
#endif

#endif /* SAYBOOK_SIRI_TTS_BRIDGE_H */
