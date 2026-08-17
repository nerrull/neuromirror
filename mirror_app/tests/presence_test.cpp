// presence_test — the room, as numbers, without a room.
//
// What this module gets wrong is never visible as a wrong number; it is visible
// as a sound that behaves oddly, hours later, with a person standing in front
// of the piece. A movement signal that is really reporting proximity (because
// it was measured in pixels rather than face widths), a yaw whose sign is
// inverted, a smoothing pass that zeroes everything the first time the tracker
// drops a frame -- each of those is a plausible-looking float and an installation
// that feels broken. So the whole approach-and-leave is driven here from
// synthetic landmarks, where the ground truth is known by construction.
//
// The face is a fabrication: 478 points on a circle, with the five landmarks
// presence.cpp actually reads placed deliberately. That is the point -- the test
// is of the arithmetic between the landmarks and the signals, not of MediaPipe.

#include "presence.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace {

int failures = 0;

void check(bool ok, const char* what) {
    if (!ok) { std::printf("FAIL: %s\n", what); ++failures; }
}

constexpr int kEyeOuterL = 33, kEyeOuterR = 263, kNoseTip = 1;
constexpr int kCheekL = 234, kCheekR = 454;

// A face of a given size, at a given place, turned and cocked by given amounts.
// `yaw` and `roll` are in the same -1..1 / degrees units the signals come back
// in, so the assertions can be about the values that went in.
mirror::FaceResult MakeFace(float cx, float cy, float height, float yaw01,
                            float roll_deg, float aspect) {
    mirror::FaceResult r;
    r.valid = true;
    r.landmarks.resize(478);

    const float half_h = height * 0.5f;
    const float half_w = half_h / aspect;   // a face is roughly as wide as tall

    // The filler points: a ring, so the bounds are the face's bounds and the
    // per-landmark movement measure has something to measure.
    for (int i = 0; i < 478; ++i) {
        const float a = (float)i / 478.f * 6.2831853f;
        r.landmarks[i].x = cx + half_w * std::cos(a);
        r.landmarks[i].y = cy + half_h * std::sin(a);
    }

    // The five that are actually read. Cheeks set the width the nose is
    // measured against; the eye corners set the tilt.
    r.landmarks[kCheekL] = {cx - half_w, cy, 0.f};
    r.landmarks[kCheekR] = {cx + half_w, cy, 0.f};
    r.landmarks[kNoseTip] = {cx + yaw01 * half_w, cy, 0.f};

    const float rr = roll_deg * 0.0174532925f;
    const float eye = half_w * 0.6f;
    r.landmarks[kEyeOuterL] = {cx - eye * std::cos(rr),
                               cy - eye * std::sin(rr) * aspect, 0.f};
    r.landmarks[kEyeOuterR] = {cx + eye * std::cos(rr),
                               cy + eye * std::sin(rr) * aspect, 0.f};

    r.min_x = cx - half_w; r.max_x = cx + half_w;
    r.min_y = cy - half_h; r.max_y = cy + half_h;
    r.centre_x = cx; r.centre_y = cy;
    return r;
}

// Hold a face still for a while, so the smoothing settles on it.
void Settle(mirror::Presence& p, const mirror::FaceResult& f, float aspect,
            float seconds) {
    const float dt = 1.f / 60.f;
    for (int i = 0; i < (int)(seconds / dt); ++i) p.update(f, aspect, dt);
}

}  // namespace

int main() {
    const float aspect = 4.f / 3.f;
    const float dt = 1.f / 60.f;

    // --- proximity spans the configured range ------------------------------
    {
        mirror::Presence p;
        const auto& cfg = p.config();
        Settle(p, MakeFace(0.5f, 0.5f, cfg.far_span, 0.f, 0.f, aspect), aspect, 2.f);
        check(p.signals().proximity < 0.05f, "a face at the far span reads 0");
        Settle(p, MakeFace(0.5f, 0.5f, cfg.near_span, 0.f, 0.f, aspect), aspect, 3.f);
        check(p.signals().proximity > 0.95f, "a face at the near span reads 1");
        // Past the near span it must not keep climbing -- everything downstream
        // treats these as 0..1 ranges.
        Settle(p, MakeFace(0.5f, 0.5f, 0.9f, 0.f, 0.f, aspect), aspect, 2.f);
        check(p.signals().proximity <= 1.f, "proximity is clamped at 1");
    }

    // --- centering is signed and centred ------------------------------------
    {
        mirror::Presence p;
        Settle(p, MakeFace(0.5f, 0.5f, 0.3f, 0.f, 0.f, aspect), aspect, 2.f);
        check(std::fabs(p.signals().centering) < 0.02f, "centred reads 0");
        Settle(p, MakeFace(0.85f, 0.5f, 0.3f, 0.f, 0.f, aspect), aspect, 2.f);
        check(p.signals().centering > 0.6f, "frame right is positive");
        Settle(p, MakeFace(0.15f, 0.5f, 0.3f, 0.f, 0.f, aspect), aspect, 2.f);
        check(p.signals().centering < -0.6f, "frame left is negative");
    }

    // --- yaw and tilt: sign, scale and rest ---------------------------------
    {
        mirror::Presence p;
        Settle(p, MakeFace(0.5f, 0.5f, 0.3f, 0.f, 0.f, aspect), aspect, 2.f);
        check(std::fabs(p.signals().head_yaw) < 1.f, "facing forward is 0 yaw");
        check(std::fabs(p.signals().head_tilt) < 1.f, "level is 0 tilt");

        Settle(p, MakeFace(0.5f, 0.5f, 0.3f, 0.5f, 0.f, aspect), aspect, 2.f);
        check(p.signals().head_yaw > 20.f && p.signals().head_yaw < 40.f,
              "the nose halfway to a cheek is half of full-scale yaw");
        Settle(p, MakeFace(0.5f, 0.5f, 0.3f, -0.5f, 0.f, aspect), aspect, 2.f);
        check(p.signals().head_yaw < -20.f, "yaw is signed");

        Settle(p, MakeFace(0.5f, 0.5f, 0.3f, 0.f, 20.f, aspect), aspect, 2.f);
        check(std::fabs(p.signals().head_tilt - 20.f) < 3.f,
              "tilt comes back in the degrees that went in");
    }

    // --- movement is in face widths, not pixels ------------------------------
    // The bug this exists for: measure travel in normalised image units and a
    // gesture made close to the camera reads several times larger than the same
    // gesture made further back, so Movement is mostly reporting Proximity.
    {
        const float travel = 0.02f;   // per frame, in face widths
        float near_peak = 0.f, far_peak = 0.f;

        for (int which = 0; which < 2; ++which) {
            const float h = which ? 0.40f : 0.15f;
            const float w = (h * 0.5f) / aspect;
            mirror::Presence p;
            Settle(p, MakeFace(0.5f, 0.5f, h, 0.f, 0.f, aspect), aspect, 1.f);
            float x = 0.5f;
            float peak = 0.f;
            for (int i = 0; i < 30; ++i) {
                x += travel * w;
                p.update(MakeFace(x, 0.5f, h, 0.f, 0.f, aspect), aspect, dt);
                peak = std::max(peak, p.signals().movement);
            }
            (which ? near_peak : far_peak) = peak;
        }
        check(near_peak > 0.05f, "movement responds at all");
        check(std::fabs(near_peak - far_peak) < 0.15f,
              "the same gesture reads the same near and far");
    }

    // --- stillness, and a dropped frame -------------------------------------
    {
        mirror::Presence p;
        const mirror::FaceResult f = MakeFace(0.5f, 0.5f, 0.3f, 0.f, 0.f, aspect);
        Settle(p, f, aspect, 2.f);
        check(p.signals().movement < 0.02f, "a still face is not moving");

        Settle(p, f, aspect, 1.f);
        const float before = p.signals().proximity;
        // One frame missed, the way the detector does it -- not somebody
        // leaving the room.
        p.update(mirror::FaceResult{}, aspect, dt);
        p.update(f, aspect, dt);
        check(std::fabs(p.signals().proximity - before) < 0.05f,
              "one dropped frame barely moves the signals");
        check(!p.raw().present || true, "presence follows the tracker");

        // Actually gone: released, and it walks down rather than cutting.
        for (int i = 0; i < 60; ++i) p.update(mirror::FaceResult{}, aspect, dt);
        check(!p.signals().present, "an empty room is not present");
        check(p.signals().proximity < before,
              "and the signals are on their way down");
        for (int i = 0; i < 600; ++i) p.update(mirror::FaceResult{}, aspect, dt);
        check(p.signals().proximity < 0.02f, "and get there");
    }

    // --- reset ---------------------------------------------------------------
    {
        mirror::Presence p;
        Settle(p, MakeFace(0.5f, 0.5f, 0.4f, 0.3f, 10.f, aspect), aspect, 2.f);
        p.reset();
        check(p.signals().proximity == 0.f && p.signals().head_yaw == 0.f,
              "reset leaves nothing of the last person");
    }

    if (failures == 0) std::printf("presence_test: OK\n");
    else std::printf("presence_test: %d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
