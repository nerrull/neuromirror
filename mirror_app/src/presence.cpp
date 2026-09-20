#include "presence.h"

#include <algorithm>
#include <cmath>

namespace mirror {
namespace {

// MediaPipe canonical indices. Named here rather than inline because which
// point is "the corner of the eye" is exactly the kind of thing that gets
// mistyped once and then tuned around forever.
constexpr int kEyeOuterL = 33;    // outer corner, frame-left eye
constexpr int kEyeOuterR = 263;   // outer corner, frame-right eye
constexpr int kNoseTip   = 1;
constexpr int kCheekL    = 234;   // frame-left silhouette, ear height
constexpr int kCheekR    = 454;   // frame-right silhouette
constexpr int kChin      = 152;   // bottom of the silhouette

inline float Clamp(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// One-pole toward `target`, with the time constant chosen by which way it is
// going. tau is the time to cover ~63% of the remaining distance.
inline float Slew(float cur, float target, float dt, float rise_tau,
                  float fall_tau) {
    const float tau = (target > cur) ? rise_tau : fall_tau;
    if (tau <= 0.f || dt <= 0.f) return target;
    const float a = 1.f - std::exp(-dt / tau);
    return cur + (target - cur) * a;
}

}  // namespace

void Presence::reset() {
    sig_ = PresenceSignals{};
    raw_ = PresenceSignals{};
    prev_.clear();
    since_seen_ = 1e9f;
}

void Presence::update(const FaceResult& r, float aspect, float dt) {
    if (dt <= 0.f) dt = 1.f / 60.f;
    if (aspect <= 0.f) aspect = 1.f;

    const bool usable = r.valid && r.landmarks.size() > (size_t)kCheekR;

    if (usable) {
        since_seen_ = 0.f;

        const auto& L = r.landmarks;
        const float span_y = std::max(1e-4f, r.max_y - r.min_y);
        const float span_x = std::max(1e-4f, r.max_x - r.min_x);

        // --- proximity: how much of the frame she fills ---------------------
        // Height rather than area: a turned head narrows but does not shorten,
        // so width alone would read a profile view as stepping back.
        raw_.proximity = Clamp(
            (span_y - cfg_.far_span) / std::max(1e-4f, cfg_.near_span - cfg_.far_span),
            0.f, 1.f);

        // --- centering ------------------------------------------------------
        raw_.centering = Clamp(r.centre_x * 2.f - 1.f, -1.f, 1.f);

        // --- tilt: the eye line against the horizon --------------------------
        // Landmarks are normalised per axis, so the vertical difference has to
        // be scaled back by the aspect ratio before it is an angle.
        {
            const float dx = (L[kEyeOuterR].x - L[kEyeOuterL].x) * aspect;
            const float dy = (L[kEyeOuterR].y - L[kEyeOuterL].y);
            raw_.head_tilt = Clamp(std::atan2(dy, dx) * 57.2957795f,
                                   -cfg_.tilt_full, cfg_.tilt_full);
        }

        // --- yaw: the nose off the centre of the silhouette ------------------
        // Not from the pose matrix: this holds up when the matrix is absent or
        // noisy, and it degrades gracefully rather than flipping. The measure
        // is how far the nose sits from halfway between the two cheek points,
        // in units of that half-width -- ±1 is the nose over one cheek, which
        // is roughly a full profile.
        {
            const float mid = 0.5f * (L[kCheekL].x + L[kCheekR].x);
            const float half = std::max(1e-4f, 0.5f * (L[kCheekR].x - L[kCheekL].x));
            raw_.head_yaw = Clamp(((L[kNoseTip].x - mid) / half) * cfg_.yaw_full,
                                  -cfg_.yaw_full, cfg_.yaw_full);
        }

        // --- pitch: the nose tip between the eye line and the chin ----------
        // Looking down brings the tip toward the chin, looking up toward the
        // eyes; the ratio is free of scale and of the aspect ratio, since it
        // is all one axis. See Config for the two numbers it is read against.
        {
            const float eye_y = 0.5f * (L[kEyeOuterL].y + L[kEyeOuterR].y);
            const float face_h = std::max(1e-4f, L[kChin].y - eye_y);
            const float t = (L[kNoseTip].y - eye_y) / face_h;
            raw_.head_pitch = Clamp((cfg_.pitch_neutral - t) / std::max(1e-4f, cfg_.pitch_span)
                                        * cfg_.pitch_full,
                                    -cfg_.pitch_full, cfg_.pitch_full);
        }

        // --- movement: landmark travel, in face widths per second ------------
        // Per-landmark mean rather than the bounding box or the centroid: a
        // centroid barely moves while somebody turns their head or opens their
        // mouth, and the box only reports the extremes. What is wanted is "how
        // much of her is in motion".
        if (prev_.size() == L.size()) {
            double sum = 0.0;
            for (size_t i = 0; i < L.size(); ++i) {
                const float dx = (L[i].x - prev_[i].x) * aspect;
                const float dy = (L[i].y - prev_[i].y);
                sum += std::sqrt(dx * dx + dy * dy);
            }
            const float mean = (float)(sum / (double)L.size());
            const float widths_per_s = (mean / (span_x * aspect)) / dt;
            raw_.movement = Clamp(widths_per_s / std::max(1e-4f, cfg_.move_full),
                                  0.f, 1.f);
        } else {
            raw_.movement = 0.f;
        }
        prev_ = L;
        raw_.present = true;
    } else {
        since_seen_ += dt;
        if (since_seen_ > cfg_.hold_secs) {
            // Released, not zeroed: the slew below walks everything down over
            // fall_tau, so an empty room fades instead of cutting.
            raw_ = PresenceSignals{};
            prev_.clear();
        }
        raw_.present = false;
    }

    sig_.present   = raw_.present;
    sig_.proximity = Slew(sig_.proximity, raw_.proximity, dt, cfg_.rise_tau, cfg_.fall_tau);
    sig_.movement  = Slew(sig_.movement,  raw_.movement,  dt, cfg_.rise_tau, cfg_.fall_tau);
    // Position and angle are two-sided, so "rise" and "fall" would mean
    // "rightward" and "leftward" -- which would make the sound lag one
    // direction and not the other. They get the rise constant both ways.
    sig_.centering = Slew(sig_.centering, raw_.centering, dt, cfg_.rise_tau, cfg_.rise_tau);
    sig_.head_yaw  = Slew(sig_.head_yaw,  raw_.head_yaw,  dt, cfg_.rise_tau, cfg_.rise_tau);
    sig_.head_tilt = Slew(sig_.head_tilt, raw_.head_tilt, dt, cfg_.rise_tau, cfg_.rise_tau);
    sig_.head_pitch = Slew(sig_.head_pitch, raw_.head_pitch, dt, cfg_.rise_tau, cfg_.rise_tau);
}

}  // namespace mirror
