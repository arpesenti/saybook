/*
 Drives Apple's private in-process Siri speech engine.

 SiriTTS.framework exports a C++ class, `TTSSynthesizer`, whose
 `synthesize_text_sync(string, vector<uint8_t>&)` renders text to PCM in one
 call. It is reachable from an unentitled process: `xcrun dyld_info -exports`
 lists the symbols and `dlsym` resolves them. (The daemon route —
 `com.apple.sirittsd`, whose `SiriTTSDaemonSession` protocol also offers
 `synthesizeWithRequest:didFinish:` — refuses third-party clients with
 NSCocoaError 4097.)

 Everything here is deliberately defensive:

  - The class layout is unknown, so the object is over-allocated and zeroed
    and Apple's own constructor initialises it. This is the most fragile part
    of the approach; a class that outgrows the reservation would corrupt the
    heap, so the size is generous and the reservation is never freed.
  - Member functions are called as plain functions with `this` as the first
    argument (Itanium ABI), and the return types of everything but
    `ready_for_synthesis` are assumed. `synthesize_text_sync` is the one call
    whose types are known well enough to rely on.
  - `dlsym` takes names with the Mach-O leading underscore stripped — passing
    the `__ZN…` form returns NULL for *every* symbol, which looks like the OS
    blocking you.
  - Apple's engine throws `std::logic_error` on a bad `initialize` argument;
    catching here keeps a saybook run from aborting.
*/

#include "SiriTTSBridge.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <map>
#include <set>
#include <string>
#include <vector>

namespace {

constexpr size_t kObjectBytes = 1 << 17;  // 128 KB reservation for an unknown class

const char *const kFramework =
    "/System/Library/PrivateFrameworks/SiriTTS.framework/Versions/A/SiriTTS";

// Mangled names, verbatim from `xcrun dyld_info -exports` on macOS 27.0.
const char *const kCtor = "__ZN14TTSSynthesizerC1Ev";
const char *const kSetLogLevel = "__ZN14TTSSynthesizer13set_log_levelEi";
const char *const kInitialize =
    "__ZN14TTSSynthesizer10initializeERKNSt3__112basic_stringIcNS0_11char_"
    "traitsIcEENS0_9allocatorIcEEEES8_S8_";
const char *const kReadyForSynthesis = "__ZN14TTSSynthesizer19ready_for_synthesisEv";
const char *const kPreheat = "__ZN14TTSSynthesizer7preheatEv";
const char *const kSynthesizeSync =
    "__ZN14TTSSynthesizer20synthesize_text_syncERKNSt3__112basic_stringIcNS0_"
    "11char_traitsIcEENS0_9allocatorIcEEEERNS0_6vectorIhNS4_IhEEEE";

using CtorFn = void (*)(void *);
using SetLogLevelFn = void (*)(void *, int);
using InitializeFn = long (*)(void *, const std::string *, const std::string *, const std::string *);
using ReadyFn = bool (*)(void *);
using PreheatFn = void (*)(void *);
using SynthesizeFn = long (*)(void *, const std::string *, std::vector<unsigned char> *);

/// SiriTTS's `Diagnostics::log` writes to stdout/stderr from the calling
/// thread, at length, whatever `set_log_level` was given. That is fatal for a
/// CLI: saybook owns stderr for its progress lines, and if stderr is a pipe
/// nobody is draining (a harness, `2>&1 | tee`) the 64 KB buffer fills and
/// `synthesize_text_sync` blocks in `write` forever. So the two descriptors
/// are pointed at /dev/null across the call and restored after it.
///
/// Set SAYBOOK_SIRI_DIAGNOSTICS=1 to keep Apple's chatter — the only way to
/// see why the engine refused a voice.
class SilenceEngineLogging {
 public:
  SilenceEngineLogging() {
    if (getenv("SAYBOOK_SIRI_DIAGNOSTICS") != nullptr) {
      return;
    }
    devnull_ = ::open("/dev/null", O_WRONLY);
    if (devnull_ < 0) {
      return;
    }
    savedOut_ = ::dup(STDOUT_FILENO);
    savedErr_ = ::dup(STDERR_FILENO);
    if (savedOut_ < 0 || savedErr_ < 0) {
      restore();
      return;
    }
    ::dup2(devnull_, STDOUT_FILENO);
    ::dup2(devnull_, STDERR_FILENO);
  }

  SilenceEngineLogging(const SilenceEngineLogging &) = delete;
  SilenceEngineLogging &operator=(const SilenceEngineLogging &) = delete;

  ~SilenceEngineLogging() { restore(); }

 private:
  void restore() {
    if (savedOut_ >= 0) {
      ::dup2(savedOut_, STDOUT_FILENO);
      ::close(savedOut_);
      savedOut_ = -1;
    }
    if (savedErr_ >= 0) {
      ::dup2(savedErr_, STDERR_FILENO);
      ::close(savedErr_);
      savedErr_ = -1;
    }
    if (devnull_ >= 0) {
      ::close(devnull_);
      devnull_ = -1;
    }
  }

  int savedOut_ = -1;
  int savedErr_ = -1;
  int devnull_ = -1;
};

struct Engine {
  void *object = nullptr;
  InitializeFn initialize = nullptr;
  ReadyFn ready = nullptr;
  SynthesizeFn synthesize = nullptr;
};

// One engine per voice asset: loading a voice bundle (FastSpeech2 + WaveRNN +
// G2P models, hundreds of MB) is far too expensive to repeat per Block.
std::map<std::string, Engine *> gEngines;
std::map<std::string, std::string> gFailures;  // negative cache: say why once, reuse

void setError(char *error, size_t cap, const char *format, ...) {
  if (error == nullptr || cap == 0) {
    return;
  }
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(error, cap, format, arguments);
  va_end(arguments);
}

void clearError(char *error, size_t cap) {
  if (error != nullptr && cap > 0) {
    error[0] = '\0';
  }
}

void *library(char *error, size_t cap) {
  static void *handle = nullptr;
  static bool tried = false;
  if (!tried) {
    tried = true;
    handle = dlopen(kFramework, RTLD_LAZY);
    if (handle == nullptr) {
      setError(error, cap, "SiriTTS.framework could not be loaded: %s",
               dlerror() != nullptr ? dlerror() : "unknown error");
    }
  }
  if (handle == nullptr && error != nullptr && cap > 0 && error[0] == '\0') {
    setError(error, cap, "SiriTTS.framework could not be loaded");
  }
  return handle;
}

void *symbol(const char *mangled, char *error, size_t cap) {
  void *handle = library(error, cap);
  if (handle == nullptr) {
    return nullptr;
  }
  char stripped[512];
  strncpy(stripped, mangled, sizeof stripped - 1);
  stripped[sizeof stripped - 1] = '\0';
  if (stripped[0] == '_') {
    memmove(stripped, stripped + 1, strlen(stripped));  // dlsym drops the Mach-O underscore
  }
  void *address = dlsym(handle, stripped);
  if (address == nullptr) {
    setError(error, cap,
             "this macOS does not export the Siri engine symbol %s (the private "
             "API changed)",
             mangled);
  }
  return address;
}

// Loads `dir`'s voice bundle into a reusable engine. Throws on any Apple-side
// failure (the caller converts it to an error message).
Engine *loadEngine(const char *dir, char *error, size_t cap) {
  auto initialize = reinterpret_cast<InitializeFn>(symbol(kInitialize, error, cap));
  auto ready = reinterpret_cast<ReadyFn>(symbol(kReadyForSynthesis, error, cap));
  auto synthesize = reinterpret_cast<SynthesizeFn>(symbol(kSynthesizeSync, error, cap));
  auto ctor = reinterpret_cast<CtorFn>(symbol(kCtor, error, cap));
  if (initialize == nullptr || ready == nullptr || synthesize == nullptr || ctor == nullptr) {
    return nullptr;
  }

  // Loading a voice bundle is where the engine is loudest; nothing it prints
  // is ours to show. See SilenceEngineLogging.
  SilenceEngineLogging silence;

  void *object = aligned_alloc(16, kObjectBytes);
  if (object == nullptr) {
    setError(error, cap, "out of memory loading the Siri engine");
    return nullptr;
  }
  // Never freed: the object's size is unknown, so freeing it would mean
  // trusting our reservation to match what the constructor wrote.
  memset(object, 0, kObjectBytes);

  ctor(object);
  // Ask for the quietest log level we know of; the descriptor silencer below
  // is what actually keeps Apple's chatter out of our stderr.
  if (auto log = reinterpret_cast<SetLogLevelFn>(symbol(kSetLogLevel, nullptr, 0))) {
    log(object, 0);
  }

  const std::string assetDirectory(dir);
  const std::string unused;  // 2nd arg: engine overrides, 3rd: a persistent module name
  initialize(object, &assetDirectory, &unused, &unused);

  if (!ready(object)) {
    free(object);
    setError(error, cap,
             "the Siri engine refused to load the voice bundle at %s (it is not a "
             "usable voice)",
             dir);
    return nullptr;
  }

  if (auto preheat = reinterpret_cast<PreheatFn>(symbol(kPreheat, nullptr, 0))) {
    preheat(object);  // compile/warm the acoustic models once
  }

  auto *engine = new Engine();
  engine->object = object;
  engine->initialize = initialize;
  engine->ready = ready;
  engine->synthesize = synthesize;
  return engine;
}

Engine *engineFor(const char *dir, char *error, size_t cap) {
  const std::string key(dir);
  auto cached = gEngines.find(key);
  if (cached != gEngines.end()) {
    return cached->second;
  }
  auto failed = gFailures.find(key);
  if (failed != gFailures.end()) {
    setError(error, cap, "%s", failed->second.c_str());
    return nullptr;
  }
  Engine *engine = loadEngine(dir, error, cap);
  if (engine == nullptr) {
    gFailures[key] = (error != nullptr && error[0] != '\0') ? error : "could not load the Siri voice";
    return nullptr;
  }
  gEngines[key] = engine;
  return engine;
}

}  // namespace

extern "C" int saybook_siri_synthesize(const char *voice_asset_dir,
                                       const char *text,
                                       int16_t **out_pcm,
                                       size_t *out_count,
                                       char *error,
                                       size_t error_cap) {
  clearError(error, error_cap);
  if (out_pcm != nullptr) {
    *out_pcm = nullptr;
  }
  if (out_count != nullptr) {
    *out_count = 0;
  }
  if (voice_asset_dir == nullptr || text == nullptr || out_pcm == nullptr || out_count == nullptr) {
    setError(error, error_cap, "internal error: missing argument to the Siri bridge");
    return 1;
  }
  if (*text == '\0') {
    setError(error, error_cap, "nothing to speak");
    return 1;
  }

  try {
    Engine *engine = engineFor(voice_asset_dir, error, error_cap);
    if (engine == nullptr) {
      return 1;
    }

    const std::string utterance(text);
    std::vector<unsigned char> bytes;
    long status = 0;
    {
      // Everything Apple's engine prints during synthesis is discarded: see
      // SilenceEngineLogging.
      SilenceEngineLogging silence;
      status = engine->synthesize(engine->object, &utterance, &bytes);
    }

    const size_t samples = bytes.size() / sizeof(int16_t);
    if (samples == 0) {
      setError(error, error_cap,
               "the Siri engine produced no audio for this text (engine status %ld)",
               status);
      return 1;
    }
    int16_t *pcm = static_cast<int16_t *>(malloc(samples * sizeof(int16_t)));
    if (pcm == nullptr) {
      setError(error, error_cap, "out of memory holding the rendered audio");
      return 1;
    }
    memcpy(pcm, bytes.data(), samples * sizeof(int16_t));
    *out_pcm = pcm;
    *out_count = samples;
    return 0;
  } catch (const std::exception &failure) {
    setError(error, error_cap, "the Siri engine failed: %s", failure.what());
    return 1;
  } catch (...) {
    setError(error, error_cap, "the Siri engine failed with an unknown error");
    return 1;
  }
}

extern "C" int saybook_siri_probe(const char *voice_asset_dir, char *error, size_t error_cap) {
  clearError(error, error_cap);
  if (voice_asset_dir == nullptr) {
    setError(error, error_cap, "internal error: missing voice asset directory");
    return 1;
  }
  try {
    SilenceEngineLogging silence;
    if (engineFor(voice_asset_dir, error, error_cap) == nullptr) {
      return 1;
    }
    return 0;
  } catch (const std::exception &failure) {
    setError(error, error_cap, "the Siri engine failed: %s", failure.what());
    return 1;
  } catch (...) {
    setError(error, error_cap, "the Siri engine failed with an unknown error");
    return 1;
  }
}

extern "C" void saybook_siri_free(int16_t *pcm) { free(pcm); }
