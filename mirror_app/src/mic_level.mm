#include "mic_level.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>

#if MIRROR_HAVE_KINECT
#include "audio_capture.h"
#endif

namespace mirror {

#if MIRROR_HAVE_KINECT

struct MicLevel::Impl {
    AudioCapture cap;
};

MicLevel::MicLevel() : impl_(std::make_unique<Impl>()) {}
MicLevel::~MicLevel() { stop(); }

bool MicLevel::start(std::string& err) {
    if (impl_->cap.running()) return true;

    AudioSelector sel;
    sel.model_uid = kKinectV2ModelUid;
    sel.min_input_channels = 1;
    sel.allow_default_fallback = false;   // the Kinect mic, or nothing

    // The sensor's USB audio interface may still be re-attaching from a reset
    // kinect_source.cpp triggered moments ago (measured ~0.1s there, but the
    // OS's own re-enumeration on top of that can take longer) -- poll rather
    // than fail on the first look.
    if (!impl_->cap.start(sel, err, /*wait_seconds=*/3.0)) {
        fprintf(stderr,
                "mic: Kinect v2 mic array (model %s) not available: %s\n",
                kKinectV2ModelUid, err.c_str());
        return false;
    }

    smoothedDb_ = -100.f;
    lastPollTime_ = -1.0;
    return true;
}

void MicLevel::stop() { impl_->cap.stop(); }
bool MicLevel::running() const { return impl_->cap.running(); }

float MicLevel::level() {
    if (!impl_->cap.running()) return 0.f;

    float peak = 0.f, rms = 0.f;
    impl_->cap.levels(/*ch=*/0, /*count=*/2048, &peak, &rms);
    const float db = 20.f * log10f(std::max(rms, 1e-7f));

    const double now = std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    const double dt = (lastPollTime_ < 0.0) ? 0.0 : std::max(0.0, now - lastPollTime_);
    lastPollTime_ = now;

    // ~150ms attack, ~500ms release: fast enough that a burst of room noise
    // registers within a beat, slow enough that a single word or a chair
    // scrape does not read as the whole room getting loud. Same constants as
    // the previous per-audio-block smoothing, just applied per call now.
    const double tau = (db > smoothedDb_) ? 0.15 : 0.50;
    const float c = (dt > 0.0) ? (float)std::exp(-dt / tau) : 1.f;
    smoothedDb_ = c * smoothedDb_ + (1.f - c) * db;

    const float span = std::max(1.f, ceilDb - floorDb);
    return std::clamp((smoothedDb_ - floorDb) / span, 0.f, 1.f);
}

#else  // !MIRROR_HAVE_KINECT

// No freenect2 SDK built in, so there is no Kinect mic array to bind to --
// same degrade-without-hardware story as the video side of this sensor (see
// kinect_target.h). Logged once, from start(), rather than every frame.
struct MicLevel::Impl {};

MicLevel::MicLevel() : impl_(std::make_unique<Impl>()) {}
MicLevel::~MicLevel() = default;

bool MicLevel::start(std::string& err) {
    err = "no Kinect support built (freenect2 SDK not found at configure time)";
    fprintf(stderr, "mic: %s -- room responsivity disabled\n", err.c_str());
    return false;
}

void MicLevel::stop() {}
bool MicLevel::running() const { return false; }
float MicLevel::level() { return 0.f; }

#endif  // MIRROR_HAVE_KINECT

}  // namespace mirror
