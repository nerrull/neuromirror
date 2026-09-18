#include "wwise_audio.h"

#include <cmath>
#include <cstdio>

namespace mirror {

std::string WwiseAudio::DefaultBankDir() {
#ifdef MIRROR_APP_SRC_DIR
    return std::string(MIRROR_APP_SRC_DIR) + "/../../WwiseProject/GeneratedSoundBanks/Mac";
#else
    return "GeneratedSoundBanks/Mac";
#endif
}

}  // namespace mirror

#ifndef MIRROR_HAVE_WWISE

// --- no SDK ------------------------------------------------------------------
// Everything is callable and nothing happens. The error is set once, at init,
// so the panel can say why it is quiet rather than looking broken.
namespace mirror {

WwiseAudio::~WwiseAudio() = default;

bool WwiseAudio::init(const std::string& bank_dir, std::string& err) {
    bank_dir_ = bank_dir;
    err_ = "built without the Wwise SDK (MIRROR_HAVE_WWISE off)";
    err = err_;
    return false;
}
void WwiseAudio::term() {}
void WwiseAudio::update(const AudioParams&) {}
void WwiseAudio::post(const char*) {}
void WwiseAudio::setState(const char*, const char*) {}
void WwiseAudio::stopAll() {}
void WwiseAudio::postFirePlucker() {}
void WwiseAudio::postStrum(float, float) {}
void WwiseAudio::dropStrums(float, float) {}
std::vector<MarkerHit> WwiseAudio::pollFirePluckerMarkers() { return {}; }
bool WwiseAudio::startCapture(const std::string&) { return false; }
void WwiseAudio::stopCapture() {}

}  // namespace mirror

#else

#include <AK/SoundEngine/Common/AkMemoryMgr.h>
#include <AK/SoundEngine/Common/AkMemoryMgrModule.h>
#include <AK/SoundEngine/Common/AkSoundEngine.h>
#include <AK/SoundEngine/Common/AkStreamMgrModule.h>
#include <AK/SoundEngine/Common/IAkStreamMgr.h>
#include <AK/Tools/Common/AkPlatformFuncs.h>

// The plug-ins this project's bank actually references. Each of these headers
// is a single AK_STATIC_LINK_PLUGIN, which is what registers the plug-in with
// the engine at static-init time -- there is no runtime registration call to
// forget. Keep this list in step with GeneratedSoundBanks/Mac/PluginInfo.json:
// a plug-in in the bank and missing here is a bank that loads and a sound that
// is silent, with an AK_PluginNotRegistered in the log and nothing on the bus.
#include <AK/Plugin/AkRoomVerbFXFactory.h>
#include <AK/Plugin/AkTimeStretchFXFactory.h>
#include <AK/Plugin/AkConvolutionReverbFXFactory.h>
#include <AK/Plugin/AkPeakLimiterFXFactory.h>
#include <AK/Plugin/AkParametricEQFXFactory.h>
#include <AK/Plugin/AkFlangerFXFactory.h>
#include <AK/Plugin/AkGuitarDistortionFXFactory.h>
#include <AK/Plugin/AkCompressorFXFactory.h>
#include "MacroOscillatorSourceFactory.h"
#include "DrumSynthSourceFactory.h"
#include "ModalVoiceFXFactory.h"
#include "RacineCombFXFactory.h"
#include "RacineShimmerFXFactory.h"

#ifndef AK_OPTIMIZED
#include <AK/Comm/AkCommunication.h>
#endif

#include "AkDefaultIOHookDeferred.h"

#include <cstdlib>
#include <mutex>

namespace mirror {
namespace {

// The engine is a process-wide singleton whether or not we pretend otherwise,
// and the low-level I/O hook has to outlive every stream, so it lives here
// rather than in the class -- a member would put its lifetime in the hands of
// whoever happens to hold the WwiseAudio.
CAkDefaultIOHookDeferred g_lowLevelIO;

// One game object for the whole piece. There is nothing spatial here -- the
// installation is a room with two speakers, not a world -- so a second object
// would only be a second place to forget to set an RTPC. The listener is
// separate because Wwise requires one for any object with Listener Relative
// Routing, which the scene mixers have on for their aux sends.
constexpr AkGameObjectID kRacineObj = 100;
constexpr AkGameObjectID kListener = 1;

// The strum's own pool: one game object per voice, round-robinned in
// postStrum(), so up to kStrumVoices notes can ring at once each holding its
// own Strum_Tuning -- Strum_Ring's comb is instanced per voice (unlike the
// FirePlucker's shared Metallic_Ring), so this is what per-note pitch needs.
constexpr AkGameObjectID kStrumObjBase = 200;
constexpr unsigned kStrumVoices = 8;

// Marker hits from Play_FirePlucker, queued here by the audio thread and
// drained by pollFirePluckerMarkers() on the main thread. File-scope for the
// same reason g_lowLevelIO is: there is one WwiseAudio in the whole app, and
// the callback the engine calls has no `this` to reach it through.
std::mutex g_markerMutex;
std::vector<MarkerHit> g_markerQueue;

void OnFirePluckerMarker(AkCallbackType in_type, AkEventCallbackInfo* /*in_eventInfo*/,
                          void* in_pCallbackInfo, void* /*in_cookie*/) {
    if (in_type != AK_Marker || !in_pCallbackInfo) return;
    const auto* mi = static_cast<const AkMarkerCallbackInfo*>(in_pCallbackInfo);
    float strength = 1.f;
    if (mi->strLabel && mi->strLabel[0]) {
        strength = std::strtof(mi->strLabel, nullptr);
        strength = strength < 0.f ? 0.f : (strength > 1.f ? 1.f : strength);
    }
    std::lock_guard<std::mutex> lock(g_markerMutex);
    g_markerQueue.push_back({strength});
}

// RTPCs are pushed every frame but only when they have moved. The threshold is
// well under audibility for all of them and keeps a still room from queueing
// nine messages per frame forever.
constexpr float kEpsilon = 1e-4f;

inline bool Moved(float a, float b) { return std::fabs(a - b) > kEpsilon; }

}  // namespace

WwiseAudio::~WwiseAudio() { term(); }

bool WwiseAudio::init(const std::string& bank_dir, std::string& err) {
    if (ready_) return true;
    bank_dir_ = bank_dir;
    err_.clear();

    AkMemSettings memSettings;
    AK::MemoryMgr::GetDefaultSettings(memSettings);
    if (AK::MemoryMgr::Init(&memSettings) != AK_Success) {
        err_ = "AK::MemoryMgr::Init failed";
        err = err_;
        return false;
    }

    AkStreamMgrSettings stmSettings;
    AK::StreamMgr::GetDefaultSettings(stmSettings);
    if (!AK::StreamMgr::Create(stmSettings)) {
        err_ = "AK::StreamMgr::Create failed";
        err = err_;
        term();
        return false;
    }

    AkDeviceSettings deviceSettings;
    AK::StreamMgr::GetDefaultDeviceSettings(deviceSettings);
    if (g_lowLevelIO.Init(deviceSettings) != AK_Success) {
        err_ = "low-level I/O init failed";
        err = err_;
        term();
        return false;
    }
    // AkFileLocationBase concatenates base + file name with no separator of its
    // own, so the trailing slash is load-bearing: without it the banks are
    // looked for at ".../MacInit.bnk".
    if (bank_dir_.empty() || bank_dir_.back() != '/') bank_dir_ += '/';
    g_lowLevelIO.SetBasePath(bank_dir_.c_str());   // AkOSChar is char on POSIX

    AkInitSettings initSettings;
    AkPlatformInitSettings platformInitSettings;
    AK::SoundEngine::GetDefaultInitSettings(initSettings);
    AK::SoundEngine::GetDefaultPlatformInitSettings(platformInitSettings);
    if (AK::SoundEngine::Init(&initSettings, &platformInitSettings) != AK_Success) {
        err_ = "AK::SoundEngine::Init failed";
        err = err_;
        term();
        return false;
    }

#ifndef AK_OPTIMIZED
    // Profiling. Not an afterthought here: the whole point of running the
    // engine in-process is that the sound is no longer visible from Authoring,
    // and this is what gives it back -- connect Wwise's profiler to this app
    // and the busses, voices and RTPC values are the live ones.
    AkCommSettings commSettings;
    AK::Comm::GetDefaultInitSettings(commSettings);
    std::snprintf(commSettings.szAppNetworkName,
                  sizeof(commSettings.szAppNetworkName), "mirror_app");
    AK::Comm::Init(commSettings);   // not fatal: no profiler is not no sound
#endif

    AkBankID bankID = 0;
    if (AK::SoundEngine::LoadBank("Init.bnk", bankID) != AK_Success) {
        err_ = "Init.bnk not found in " + bank_dir_ + " (generate SoundBanks in Wwise)";
        err = err_;
        term();
        return false;
    }
    if (AK::SoundEngine::LoadBank("Racine.bnk", bankID) != AK_Success) {
        err_ = "Racine.bnk not found in " + bank_dir_;
        err = err_;
        term();
        return false;
    }

    AK::SoundEngine::RegisterGameObj(kListener, "Listener");
    AK::SoundEngine::RegisterGameObj(kRacineObj, "Racine");
    for (unsigned i = 0; i < kStrumVoices; ++i) {
        char name[16];
        std::snprintf(name, sizeof(name), "Strum%u", i);
        AK::SoundEngine::RegisterGameObj(kStrumObjBase + i, name);
    }
    AK::SoundEngine::SetDefaultListeners(&kListener, 1);

    ready_ = true;
    sent_any_ = false;
    return true;
}

void WwiseAudio::term() {
    if (AK::SoundEngine::IsInitialized()) {
        AK::SoundEngine::StopAll();
        AK::SoundEngine::UnregisterAllGameObj();
        AK::SoundEngine::ClearBanks();
#ifndef AK_OPTIMIZED
        AK::Comm::Term();
#endif
        AK::SoundEngine::Term();
    }
    if (AK::IAkStreamMgr::Get()) {
        g_lowLevelIO.Term();
        AK::IAkStreamMgr::Get()->Destroy();
    }
    if (AK::MemoryMgr::IsInitialized()) AK::MemoryMgr::Term();
    ready_ = false;
}

void WwiseAudio::update(const AudioParams& p) {
    if (!ready_) return;

    // Global scope (AK_INVALID_GAME_OBJECT): every one of these is a property
    // of the room or of the piece, not of an emitter, and a global value is
    // what any object without its own resolves to.
    const bool all = !sent_any_;
    if (all || Moved(p.proximity, sent_.proximity))
        AK::SoundEngine::SetRTPCValue("Proximity", p.proximity);
    if (all || Moved(p.movement, sent_.movement))
        AK::SoundEngine::SetRTPCValue("Movement", p.movement);
    if (all || Moved(p.centering, sent_.centering))
        AK::SoundEngine::SetRTPCValue("Centering", p.centering);
    if (all || Moved(p.head_yaw, sent_.head_yaw))
        AK::SoundEngine::SetRTPCValue("HeadYaw", p.head_yaw);
    if (all || Moved(p.head_tilt, sent_.head_tilt))
        AK::SoundEngine::SetRTPCValue("HeadTilt", p.head_tilt);
    if (all || Moved(p.fit_level, sent_.fit_level))
        AK::SoundEngine::SetRTPCValue("FitLevel", p.fit_level);
    if (all || Moved(p.scene_progress, sent_.scene_progress))
        AK::SoundEngine::SetRTPCValue("SceneProgress", p.scene_progress);
    if (all || Moved(p.key, sent_.key))
        AK::SoundEngine::SetRTPCValue("Key", p.key);
    if (all || Moved(p.intensity, sent_.intensity))
        AK::SoundEngine::SetRTPCValue("Intensity", p.intensity);
    if (all || Moved(p.transpose, sent_.transpose))
        AK::SoundEngine::SetRTPCValue("Transpose", p.transpose);
    if (all || Moved(p.pad_octave, sent_.pad_octave))
        AK::SoundEngine::SetRTPCValue("PadOctave", p.pad_octave);

    // The pluck's pitch, as the comb's centre frequency. Hz rather than a MIDI
    // note because that is the unit the comb's Frequency property is in, and
    // the note-to-Hz conversion is an exponential a two-point RTPC curve cannot
    // draw. The musical unit stays MIDI right up to `chord`, which converts.
    if (all || Moved(p.comb_hz, sent_.comb_hz))
        AK::SoundEngine::SetRTPCValue("Comb_Tuning", p.comb_hz);

    if (all || Moved(p.comb_glide_ms, sent_.comb_glide_ms))
        AK::SoundEngine::SetRTPCValue("Comb_Glide", p.comb_glide_ms);

    if (all || Moved(p.flanger_rate, sent_.flanger_rate))
        AK::SoundEngine::SetRTPCValue("FlangerRate", p.flanger_rate);

    if (all || Moved(p.flanger_mix, sent_.flanger_mix))
        AK::SoundEngine::SetRTPCValue("FlangerMix", p.flanger_mix);

    // Faded by the engine rather than stepped here, so a single frame's flip
    // is a ramp of pluck_mute_fade_ms.
    if (all || Moved(p.pluck_mute, sent_.pluck_mute))
        AK::SoundEngine::SetRTPCValue("PluckMute", p.pluck_mute, AK_INVALID_GAME_OBJECT,
                                      (AkTimeMs)p.pluck_mute_fade_ms);

    sent_ = p;
    sent_any_ = true;

    // Everything above is queued until this call. Once a frame is the right
    // rate: the audio thread interpolates RTPCs across its own buffer, so
    // pushing more often buys nothing, and pushing less often is audible as
    // stepping on a fast approach.
    AK::SoundEngine::RenderAudio();
}

void WwiseAudio::post(const char* event_name) {
    if (!ready_ || !event_name) return;
    AK::SoundEngine::PostEvent(event_name, kRacineObj);
    ++posted_;
}

void WwiseAudio::postFirePlucker() {
    if (!ready_) return;
    AK::SoundEngine::PostEvent("Play_FirePlucker", kRacineObj, AK_Marker,
                                OnFirePluckerMarker, nullptr);
    ++posted_;
}

void WwiseAudio::postStrum(float hz, float velocity) {
    if (!ready_) return;
    const AkGameObjectID obj = kStrumObjBase + (strum_next_++ % kStrumVoices);
    AK::SoundEngine::SetRTPCValue("Strum_Tuning", hz, obj);
    AK::SoundEngine::SetRTPCValue("Strum_Glide", 0.f, obj);
    AK::SoundEngine::SetRTPCValue("Strum_Velocity", velocity, obj);
    AK::SoundEngine::PostEvent("Play_Strum", obj);
    ++posted_;
    std::fprintf(stderr, "[strum] obj %u  %.0f Hz  vel %.2f\n", (unsigned)obj, hz, velocity);
}

void WwiseAudio::dropStrums(float glide_ms, float hz) {
    if (!ready_) return;
    for (unsigned i = 0; i < kStrumVoices; ++i) {
        AK::SoundEngine::SetRTPCValue("Strum_Glide", glide_ms, kStrumObjBase + i);
        AK::SoundEngine::SetRTPCValue("Strum_Tuning", hz, kStrumObjBase + i);
    }
}

std::vector<MarkerHit> WwiseAudio::pollFirePluckerMarkers() {
    std::vector<MarkerHit> out;
    std::lock_guard<std::mutex> lock(g_markerMutex);
    out.swap(g_markerQueue);
    return out;
}

void WwiseAudio::setState(const char* group, const char* state) {
    if (!ready_ || !group || !state) return;
    AK::SoundEngine::SetState(group, state);
}

void WwiseAudio::stopAll() {
    if (!ready_) return;
    AK::SoundEngine::StopAll();
}

bool WwiseAudio::startCapture(const std::string& abs_wav_path) {
    if (!ready_) return false;
    // Absolute, so it does not land beside the banks: a relative name is
    // resolved against the low-level I/O base path, which is the generated
    // bank directory and no place to write into.
    return AK::SoundEngine::StartOutputCapture(abs_wav_path.c_str()) == AK_Success;
}

void WwiseAudio::stopCapture() {
    if (!ready_) return;
    AK::SoundEngine::StopOutputCapture();
}

}  // namespace mirror

#endif  // MIRROR_HAVE_WWISE
