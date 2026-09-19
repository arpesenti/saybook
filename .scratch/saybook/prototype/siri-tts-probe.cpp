// Probe: call Apple's private in-process SiriTTS engine (SiriTTS.framework) directly.
//
// Why: AVSpeechSynthesizer exposes 184 legacy voices and nothing from the Siri "gryphon"
// neural stack. This probe proves the Siri engine is reachable in-process without XPC or
// entitlements: dlopen + dlsym (names WITHOUT the Mach-O leading underscore) + Apple's own
// constructor. It over-allocates the object because the class layout is unknown.
//
// Build:  c++ -std=c++17 .scratch/saybook/prototype/siri-tts-probe.cpp -o /tmp/siri-probe
// Run:    /tmp/siri-probe [maxStep]      (1 ctor, 2 log level, 3 descriptions,
//                                        4 initialize, 5 ready, 6 preheat + synthesize)
// Result on macOS 27.0 / M4: ready_for_synthesis=1, using_gryphon_frontend=1,
//   synthesize_text_sync -> 263,640 bytes of 16-bit little-endian PCM (~2.70 s).
// See .scratch/saybook/research/private-api-speech-synthesis.md for the full analysis.
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static void* H = nullptr; static void* obj = nullptr;

static void* S(const char* n) {
    char nm[512]; strncpy(nm, n, sizeof nm - 1); nm[sizeof nm - 1] = 0;
    if (nm[0] == '_') memmove(nm, nm + 1, strlen(nm));
    void* p = dlsym(H, nm);
    if (!p) printf("   [no symbol] %s\n", nm);
    return p;
}
using Ctor = void(*)(void*);
using StrF = void(*)(void*, void*);                 // std::string return (sret in x8 -> arg0)
using BoolF = bool(*)(void*);
using LogF = void(*)(void*, int);
using InitF = long(*)(void*, const std::string*, const std::string*, const std::string*);
using SynchF = long(*)(void*, const std::string*, std::vector<unsigned char>*);
using HeatF = void(*)(void*);

static std::string str(const char* m) {
    auto f = (StrF)S(m); if (!f) return "<none>";
    std::string out; f(&out, obj); return out;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    int maxStep = argc > 1 ? atoi(argv[1]) : 6;
    H = dlopen("/System/Library/PrivateFrameworks/SiriTTS.framework/Versions/A/SiriTTS", RTLD_LAZY);
    if (!H) { printf("dlopen failed\n"); return 1; }
    obj = aligned_alloc(16, 1 << 17); memset(obj, 0, 1 << 17);

    if (maxStep >= 1) { printf("STEP1 ctor\n"); ((Ctor)S("__ZN14TTSSynthesizerC1Ev"))(obj); }
    if (maxStep >= 2) { printf("STEP2 set_log_level(4)\n"); auto f=(LogF)S("__ZN14TTSSynthesizer13set_log_levelEi"); if(f) f(obj,4); }
    if (maxStep >= 3) {
        printf("STEP3 engine_desc  = [%s]\n", str("__ZN14TTSSynthesizer22get_engine_descriptionEv").c_str());
        printf("      voice_desc   = [%s]\n", str("__ZN14TTSSynthesizer21get_voice_descriptionEv").c_str());
    }
    const std::string asset =
        "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto/"
        "3403d3390d315521bb488133f9b1f0c887c096e3.asset/AssetData";
    const std::string root =
        "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto/"
        "3403d3390d315521bb488133f9b1f0c887c096e3.asset";
    const std::string empty, martha("martha"), loc("en-GB");

    if (maxStep >= 4) {
        auto init = (InitF)S("__ZN14TTSSynthesizer10initializeERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEES8_S8_");
        if (init) {
            printf("STEP4 initialize(assetData,\"\",\"\")\n");
            long r1 = init(obj, &asset, &empty, &empty);
            printf("      -> raw return 0x%lx\n", r1);
        }
    }
    if (maxStep >= 5) {
        auto rdy = (BoolF)S("__ZN14TTSSynthesizer19ready_for_synthesisEv");
        printf("STEP5 ready_for_synthesis = %d\n", rdy ? rdy(obj) : -1);
        printf("      engine_desc = [%s]\n", str("__ZN14TTSSynthesizer22get_engine_descriptionEv").c_str());
        printf("      voice_desc  = [%s]\n", str("__ZN14TTSSynthesizer21get_voice_descriptionEv").c_str());
        auto gry = (BoolF)S("__ZN14TTSSynthesizer22using_gryphon_frontendEv");
        printf("      using_gryphon_frontend = %d\n", gry ? gry(obj) : -1);
    }
    if (maxStep >= 6) {
        auto heat = (HeatF)S("__ZN14TTSSynthesizer7preheatEv");
        printf("STEP6 preheat\n"); if (heat) heat(obj);
        auto syn = (SynchF)S("__ZN14TTSSynthesizer20synthesize_text_syncERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEERNS0_6vectorIhNS4_IhEEEE");
        if (syn) {
            std::string text = "The quick brown fox jumps over the lazy dog.";
            std::vector<unsigned char> out;
            printf("STEP6 synthesize_text_sync(\"%s\")\n", text.c_str());
            long r = syn(obj, &text, &out);
            printf("      -> raw return 0x%lx, bytes=%zu\n", r, out.size());
            if (out.size() > 64) {
                FILE* fp = fopen("/tmp/siri_out.bin", "wb");
                fwrite(out.data(), 1, out.size(), fp); fclose(fp);
                printf("      wrote /tmp/siri_out.bin  head=");
                for (int i = 0; i < 16 && i < (int)out.size(); i++) printf("%02x ", out[i]);
                printf("\n");
            }
        }
    }
    printf("DONE\n");
    return 0;
}
