// RootCameraSequence — the pull-back, as a moving camera rather than five
// stills. Four beats, and the anchor face is the centre of frame in every one
// of them:
//
//   1  the face alone      nothing has grown yet, tight on the mask
//   2  the roots arrive    growth runs; the camera does not move, so the beat
//                          ends framed exactly where beat 1 began
//   3  the structure       the pull-back: the other masks come into frame
//                          while the anchor face stays put
//   4  the others          copies of the piece standing around this one,
//                          meandered among for as long as the caller keeps
//                          stepping -- there is no beat 5, beat 4 just loops
//
// This is the beat script that used to live entirely inside --rootmovie's
// offline exporter (one call, a known total duration, a frame counter). It is
// pulled out here so the same math can also drive the live root scene, where
// there is no known total duration -- only phaseTime(), seconds since the
// show entered this phase -- and beat 4 has to keep going for as long as the
// phase does rather than stopping at a frame count.
//
// Usage: begin() once per entry into the phase (it reads the layout and picks
// an anchor + a neighbour hood, so calling it again mid-shot would restart
// the move); step() once per rendered frame after that, with the seconds
// elapsed since begin() (phaseTime) and this frame's dt. step() writes
// target/radius/azimuth/elevation/maskDeal/simPaused/simStepsPerFrame and
// forces autoFrame/autoOrbit off, since it is now the thing deciding those.
#pragma once
#ifndef __OBJC__
#error "root_camera_sequence.h is ObjC++ only"
#endif

#include "root_scene.h"
#include "root_sim.h"

#include <algorithm>
#include <cmath>
#include <random>
#include <vector>

class RootCameraSequence {
public:
    // Read the planned layout, pick the anchor and framings, and lay out a
    // neighbour hood for beat 4. `beatSeconds` is how long beats 1-3 take
    // together before beat 4 takes over and starts meandering; 18s matches
    // --rootmovie's own default so the live shot and the exported one read
    // the same.
    void begin(RootScene& roots, double beatSeconds = 18.0) {
        beatSeconds_    = beatSeconds;
        neighboursAdded_ = false;
        eyePrimed_       = false;
        waypoint_        = 0;

        const auto& planned = roots.plannedMasks();
        if (planned.empty()) { valid_ = false; return; }
        valid_ = true;
        anchor_ = planned.front();

        tightR_ = std::max(anchor_.rWidth, anchor_.rHeight) * 2.6f;
        structR_ = tightR_;
        centroid_[0] = centroid_[1] = centroid_[2] = 0.f;
        for (const auto& m : planned) {
            const float dx = m.pos[0] - anchor_.pos[0], dy = m.pos[1] - anchor_.pos[1],
                        dz = m.pos[2] - anchor_.pos[2];
            structR_ = std::max(structR_, std::sqrt(dx * dx + dy * dy + dz * dz)
                                              + std::max(m.rWidth, m.rHeight));
            for (int k = 0; k < 3; ++k) centroid_[k] += m.pos[k] / float(planned.size());
        }
        structR_ *= 1.45f;

        // Straight down the anchor's normal, so the face is square to camera
        // and stays that way while the world grows around it.
        const float alen = std::sqrt(anchor_.normal[0] * anchor_.normal[0] +
                                     anchor_.normal[1] * anchor_.normal[1] +
                                     anchor_.normal[2] * anchor_.normal[2]);
        az0_ = std::atan2(anchor_.normal[0], anchor_.normal[2]);
        el0_ = std::asin(std::clamp(anchor_.normal[1] / std::max(1e-5f, alen), -1.f, 1.f));

        track_[0] = follow_[0] = anchor_.pos[0];
        track_[1] = follow_[1] = anchor_.pos[1];
        track_[2] = follow_[2] = anchor_.pos[2];

        // Neighbour placements, decided up front so beat 4 can fly between
        // them. They are cylinders like the subject, so "the nearest one" and
        // "its normal" are well defined at any point on the path.
        hood_.clear();
        {
            std::mt19937 rng(99u);
            std::uniform_real_distribution<float> U(0.f, 1.f);
            const int count = 9;
            const float ring = structR_ * 0.85f;
            for (int i = 0; i < count; ++i) {
                const float a = 6.2831853f * (float(i) / count) + (U(rng) - 0.5f) * 0.45f;
                const float rr = ring * (0.85f + 0.5f * U(rng));
                hood_.push_back({track_[0] + std::sin(a) * rr, track_[2] + std::cos(a) * rr,
                                 U(rng) * 6.2831853f, 0.8f + 0.45f * U(rng)});
            }
        }

        // Growth pacing, per beat rather than one rate throughout, converted
        // to steps/second rather than steps/frame so it holds regardless of
        // the caller's actual frame rate. The first hop is the one the
        // audience actually watches -- it is the root coming out of the face
        // they have been looking at -- so it gets the whole of beat 2, and
        // the remaining hops share beat 3.
        int simSteps = 0;
        {
            rootsim::SimParams probe = roots.simParams();
            rootsim::RootSim sim;
            if (sim.reset(probe))
                while (!sim.done() && simSteps < 200000) { sim.step(); ++simSteps; }
        }
        const int hops = std::max(1, (int)planned.size() - 1);
        const int firstHopSteps = std::max(1, simSteps / hops);
        // Reference cadence the original per-frame rates were tuned against;
        // only used to convert those rates into steps/second.
        constexpr double kRefFps = 30.0;
        const int frames = std::max(2, (int)std::lround(beatSeconds_ * kRefFps));
        const int beat2Frames = std::max(1, (int)((b2_ - b1_) * frames));
        const int beat3Frames = std::max(1, (int)((b3_ - b2_) * frames));
        const int slowRate = std::max(1, (int)std::ceil(double(firstHopSteps) / beat2Frames));
        const int fastRate = std::max(1, (int)std::ceil(double(simSteps - firstHopSteps) / beat3Frames));
        slowStepsPerSec_ = slowRate * kRefFps;
        fastStepsPerSec_ = fastRate * kRefFps;
    }

    // Advance one rendered frame. `phaseTime` is seconds since begin() (i.e.
    // since the show entered this phase); `dt` is this frame's delta. Writes
    // the camera/growth-pacing fields on `roots` directly.
    void step(RootScene& roots, double phaseTime, double dt) {
        if (!valid_) return;

        // Beats 1-3 read off a fraction of beatSeconds_; once phaseTime has
        // passed it, t just stays at 1 -- which is what keeps beat 4 running
        // for as long as the caller keeps stepping instead of ending there.
        const double t  = std::clamp(phaseTime / beatSeconds_, 0.0, 1.0);
        const double ts = phaseTime;

        float radius = tightR_;
        float target[3] = {anchor_.pos[0], anchor_.pos[1], anchor_.pos[2]};
        float az = az0_, el = el0_;
        bool  authoredEye = false;

        // The sequence is now the thing deciding the camera; the live/auto
        // framing would otherwise fight it inside roots.advance().
        roots.autoFrame = false;
        roots.autoOrbit = false;
        roots.showPlannedMasks = true;

        auto smoothstep = [](double u) {
            u = std::clamp(u, 0.0, 1.0);
            return u * u * (3.0 - 2.0 * u);
        };

        if (t < b1_) {
            // Beat 1: one face. The rest of the structure is stacked behind it.
            roots.simPaused = true;
            roots.maskDeal = 0.f;
            radius = tightR_;
        } else if (t < b2_) {
            // Beat 2: the masks slide out of it into their places while the
            // camera opens to hold them. Still nothing growing.
            roots.simPaused = true;
            const float u = (float)smoothstep((t - b1_) / (b2_ - b1_));
            roots.maskDeal = u;
            float spread = tightR_;
            for (const auto& m : roots.plannedMasks()) {
                const float dx = m.pos[0] - anchor_.pos[0], dy = m.pos[1] - anchor_.pos[1],
                            dz = m.pos[2] - anchor_.pos[2];
                spread = std::max(spread, std::sqrt(dx * dx + dy * dy + dz * dz) * u
                                              + std::max(m.rWidth, m.rHeight));
            }
            radius = std::max(tightR_, spread * 1.05f);
            for (int k = 0; k < 3; ++k)
                target[k] = anchor_.pos[k] + (centroid_[k] - anchor_.pos[k]) * u;
        } else if (t < b3_) {
            // Beat 3: follow the tip.
            roots.simPaused = false;
            roots.maskDeal = 1.f;
            roots.simStepsPerFrame = std::max(1, (int)std::lround(slowStepsPerSec_ * dt));
            radius = structR_ * 0.55f;

            float tp[3];
            const int cm = roots.currentMask();
            const auto& pm = roots.plannedMasks();
            if (roots.arrivedAtMask() && cm >= 0 && cm < (int)pm.size()) {
                for (int k = 0; k < 3; ++k) target[k] = pm[size_t(cm)].pos[k];
            } else if (roots.growthTip(tp)) {
                for (int k = 0; k < 3; ++k) target[k] = tp[k];
            } else {
                for (int k = 0; k < 3; ++k) target[k] = track_[k];
            }
            {
                const float kk = 1.f - std::exp(-float(dt) / 0.7f);
                for (int k = 0; k < 3; ++k) follow_[k] += (target[k] - follow_[k]) * kk;
                for (int k = 0; k < 3; ++k) target[k] = follow_[k];
            }
            const float rx = target[0], rz = target[2];
            const float rl = std::sqrt(rx * rx + rz * rz);
            if (rl > 1e-3f) az = std::atan2(rx, rz);
            el = 0.10f;
        } else {
            // Beat 4: out among the others, meandering -- indefinitely. The
            // waypoint index is not clamped, only wrapped by % into the hood
            // and mask lists, so time in this beat just keeps cycling through
            // new combinations rather than stopping on the last one.
            roots.simPaused = false;
            roots.maskDeal = 1.f;
            roots.simStepsPerFrame = std::max(1, (int)std::lround(fastStepsPerSec_ * dt));
            if (!neighboursAdded_) {
                roots.addNeighbours((int)hood_.size(), structR_ * 0.85f, 99u, track_, az0_);
                roots.renderer().instanceCullPx = 0.5f;
                roots.renderer().lodBias = 0.5f;
                roots.renderer().subpixelCull = false;
                neighboursAdded_ = true;
            }

            const auto& pm = roots.plannedMasks();
            const double dwell = std::max(1e-3, (1.0 - b3_) * beatSeconds_ / 4.0);
            const double elapsedBeat4 = phaseTime - b3_ * beatSeconds_;
            waypoint_ = std::max(0, (int)std::floor(elapsedBeat4 / dwell));
            const Neighbour& cyl = hood_[size_t((waypoint_ * 3 + 1) % hood_.size())];
            const auto& m = pm[size_t((waypoint_ * 3 + 2) % pm.size())];

            float goal[3] = {cyl.x + (m.pos[0] - track_[0]) * cyl.scale,
                             m.pos[1] * cyl.scale,
                             cyl.z + (m.pos[2] - track_[2]) * cyl.scale};
            float nx = goal[0] - cyl.x, nz = goal[2] - cyl.z;
            const float nl = std::sqrt(nx * nx + nz * nz);
            if (nl > 1e-3f) { nx /= nl; nz /= nl; } else { nx = 1.f; nz = 0.f; }
            const float standoff = structR_ * 0.75f;
            float wantEye[3] = {goal[0] + nx * standoff,
                                goal[1] + structR_ * 0.12f,
                                goal[2] + nz * standoff};

            if (!eyePrimed_) {
                const float pr = structR_ * 0.55f;
                eye_[0] = track_[0] + pr * std::cos(el0_) * std::sin(az0_);
                eye_[1] = track_[1] + pr * std::sin(el0_);
                eye_[2] = track_[2] + pr * std::cos(el0_) * std::cos(az0_);
                for (int k = 0; k < 3; ++k) look_[k] = track_[k];
                eyePrimed_ = true;
            }
            const float ke = 1.f - std::exp(-float(dt) / 2.6f);
            const float kl = 1.f - std::exp(-float(dt) / 1.3f);
            for (int k = 0; k < 3; ++k) eye_[k] += (wantEye[k] - eye_[k]) * ke;
            for (int k = 0; k < 3; ++k) look_[k] += (goal[k] - look_[k]) * kl;

            const float dx = eye_[0] - look_[0], dy = eye_[1] - look_[1], dz = eye_[2] - look_[2];
            const float dist = std::max(1e-3f, std::sqrt(dx * dx + dy * dy + dz * dz));
            for (int k = 0; k < 3; ++k) target[k] = look_[k];
            radius = dist;
            az = std::atan2(dx, dz);
            el = std::asin(std::clamp(dy / dist, -1.f, 1.f));
            authoredEye = true;
        }

        // Track the revealed group's centroid, for the beats that use it.
        {
            const auto& rev = roots.revealedMasks();
            float want[3] = {anchor_.pos[0], anchor_.pos[1], anchor_.pos[2]};
            if (!rev.empty()) {
                float c[3] = {0, 0, 0};
                for (const auto& m : rev)
                    for (int k = 0; k < 3; ++k) c[k] += m.pos[k];
                for (int k = 0; k < 3; ++k) want[k] = c[k] / float(rev.size());
            }
            const float kk = 1.f - std::exp(-float(dt) / trackTau_);
            for (int k = 0; k < 3; ++k) track_[k] += (want[k] - track_[k]) * kk;
        }

        if (!authoredEye) {
            const auto& pm = roots.plannedMasks();
            float need = 0.f;
            for (const auto& m : pm) {
                const float dx = m.pos[0] - target[0], dy = m.pos[1] - target[1],
                            dz = m.pos[2] - target[2];
                need = std::max(need, std::sqrt(dx * dx + dy * dy + dz * dz)
                                          + std::max(m.rWidth, m.rHeight));
            }
            need *= 1.35f * roots.maskDeal;
            if (t >= b1_ && t < b2_)
                radius = std::max(radius, std::min(need, structR_ * 1.6f));

            az += 0.035f * std::sin(6.2831853f * 0.055f * (float)ts)
                + 0.015f * std::sin(6.2831853f * 0.017f * (float)ts + 2.1f);
            el += 0.020f * std::sin(6.2831853f * 0.041f * (float)ts + 1.0f);
        }

        roots.target[0] = target[0];
        roots.target[1] = target[1];
        roots.target[2] = target[2];
        roots.radius    = radius;
        roots.azimuth   = az;
        roots.elevation = el;
    }

    bool valid() const { return valid_; }

private:
    struct Neighbour { float x, z, yaw, scale; };

    bool valid_ = false;
    double beatSeconds_ = 18.0;
    const double b1_ = 0.13, b2_ = 0.30, b3_ = 0.78;
    const float trackTau_ = 1.1f;

    rootsim::SimMask anchor_{};
    float tightR_ = 0.f, structR_ = 0.f;
    float centroid_[3] = {0.f, 0.f, 0.f};
    float az0_ = 0.f, el0_ = 0.f;
    double slowStepsPerSec_ = 0.0, fastStepsPerSec_ = 0.0;

    std::vector<Neighbour> hood_;
    bool neighboursAdded_ = false;

    float track_[3]  = {0.f, 0.f, 0.f};
    float follow_[3] = {0.f, 0.f, 0.f};
    float eye_[3]    = {0.f, 0.f, 0.f};
    float look_[3]   = {0.f, 0.f, 0.f};
    bool  eyePrimed_ = false;
    int   waypoint_  = 0;
};
