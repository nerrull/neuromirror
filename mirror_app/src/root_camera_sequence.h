// RootCameraSequence — the pull-back, as a moving camera rather than five
// stills. Five beats, and the anchor face is the centre of frame in every one
// of the first four:
//
//   1  the face alone      nothing has grown yet, tight on the mask
//   2  the roots arrive    growth runs; the camera does not move, so the beat
//                          ends framed exactly where beat 1 began
//   3  the structure       the pull-back: the other masks come into frame
//                          while the anchor face stays put
//   4  the others          copies of the piece standing around this one,
//                          meandered among for as long as the caller keeps
//                          stepping -- there is no fixed beat 5, beat 4 just
//                          loops until the host asks for the outro
//   5  the outro           the camera holds exactly where it is while the
//                          host fades the screen to black; not a framing of
//                          its own, just a freeze so the fade has something
//                          still to fade from
//
// This is the beat script that used to live entirely inside --rootmovie's
// offline exporter (one call, a known total duration, a frame counter). It is
// pulled out here so the same math can also drive the live root scene, where
// there is no known total duration -- only phaseTime(), seconds since the
// show entered this phase -- and beat 4 has to keep going for as long as the
// phase does rather than stopping at a frame count.
//
// Every duration and rate below is authored (RootBeatParams), not derived,
// so the panel can dial the piece's pacing without a rebuild -- see
// ui_params's `show/roots/beat N` sections.
//
// Usage: begin() once per entry into the phase (it reads the layout and picks
// an anchor + a neighbour hood, so calling it again mid-shot would restart
// the move); step() once per rendered frame after that, with the seconds
// elapsed since begin() (phaseTime), this frame's dt, the current beat
// params, and whether the host wants the outro to start. step() writes
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

// Every knob a beat schedule needs, authored rather than derived -- panel
// controls under `show/roots/beat N` write straight into one of these each
// frame (cheap; step() takes it fresh every call, so there is no restart
// hazard in changing a value mid-shot the way Timeline::setScript used to
// have).
struct RootBeatParams {
    float beat1_seconds = 2.3f;   // face alone -- floor; see beat1_clear_tail_seconds
    // Fog only exists in the Roots renderer, so it would otherwise pop the
    // instant Roots starts -- right where TransitionScene's cloth has just
    // fallen away. The host (main.mm) ramps fog visibility from clear down
    // to the phase's intensity over this many seconds at the start of beat 1
    // instead of assigning it flat; see the Roots render branch.
    float beat1_fog_fade_seconds = 2.0f;
    // Beat 1 now also waits on TransitionScene's own cloth-clearance signal
    // (see TransitionScene::clothCleared()) rather than running a flat
    // duration: it holds beat1_seconds as a floor, then this many seconds
    // more once the cloth has actually cleared, so beat 2 never starts while
    // the film is still visibly falling. See step()'s `clothCleared` param.
    float beat1_clear_tail_seconds = 10.0f;
    float beat2_seconds = 3.1f;   // masks deal
    float beat3_seconds = 8.6f;   // growth follows the tip
    // Beat 4 (meander) has no duration of its own -- it loops until the host
    // asks for the outro.

    // The base pacing is still derived from the sim's own step count (see
    // begin()), so the growth always finishes roughly on the beat boundary
    // regardless of how many hops the layout happens to need; these just
    // bound how fast that derived rate is allowed to run, in sim steps per
    // second, so an unusually large layout cannot blow past a believable
    // growth speed.
    float beat2_rate_min = 20.f, beat2_rate_max = 400.f;
    float beat3_rate_min = 40.f, beat3_rate_max = 1200.f;

    // Beat 4 picks a fresh camera speed within this range at each waypoint,
    // which is what keeps the meander from reading as one metronomic drift --
    // it is the reciprocal of the eye/look smoothing time constant, so higher
    // is snappier. `max_angular_speed` is a hard cap (rad/s) on how fast
    // azimuth/elevation are allowed to change frame to frame, independent of
    // the chosen speed, so a waypoint change can never read as a whip-pan.
    float beat4_cam_speed_min = 0.25f, beat4_cam_speed_max = 0.9f;
    float beat4_max_angular_speed = 0.9f;
    // Beats 3 and 4 are now paced by Wwise's "fire reverb drop" markers (the
    // FirePlucker bed's own cue stream, rung through into Roots -- see
    // main.mm's Phase::Roots audio case) rather than a flat duration: beat 3
    // holds on each arrived mask until a marker switches it back to growing
    // the next one, and beat 4 holds at each waypoint until a marker sends it
    // to the next. Both still fall back to a plain timer if no marker shows
    // up for this long -- markers require Wwise's SDK and a bank actually
    // built with cue-carrying source audio, neither of which is guaranteed
    // on every dev machine (see wwise_audio.h's "Without the SDK"), and a
    // beat that can never advance without one would be a worse trade than an
    // occasional early, timer-forced cut.
    float beat3_focus_fallback_seconds = 6.0f;
    // How long the camera holds at each waypoint before flying to the next,
    // when no marker arrives to trigger the move itself.
    float beat4_dwell_seconds = 4.5f;

    // How long the outro (beat 5) takes to fade the camera's hold to black,
    // once the host asks for it.
    float outro_seconds = 2.0f;
};

class RootCameraSequence {
public:
    enum class Beat { Face = 0, Deal, Growth, Meander, Outro };

    // Read the planned layout, pick the anchor and framings, and lay out a
    // neighbour hood for beat 4.
    void begin(RootScene& roots, const RootBeatParams& bp) {
        // neighboursGen_ is deliberately NOT reset here -- it tracks whether
        // the neighbour hood matches the plant's current generation, not
        // whether this particular visit has built it yet; see its use in
        // step()'s Meander branch.
        eyePrimed_       = false;
        waypoint_        = -1;   // forces a fresh camSpeed_ pick on waypoint 0
        beat_            = Beat::Face;
        outroFade_       = 0.f;
        clothClearAt_    = -1.0;
        growingInBeat3_  = true;   // nothing reached yet -- start growing, not focused
        focusEnteredAt_  = -1.0;
        waypointEnteredAt_ = -1.0;

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
        prevAz_ = az0_;
        prevEl_ = el0_;

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

        // Growth pacing, per beat rather than one rate throughout, clamped
        // into the panel's authored ranges and converted to steps/second
        // rather than steps/frame so it holds regardless of the caller's
        // actual frame rate. The first hop is the one the audience actually
        // watches -- it is the root coming out of the face they have been
        // looking at -- so it gets the whole of beat 2, and the remaining
        // hops share beat 3.
        const int simSteps = roots.growthStepEstimate();
        const int hops = std::max(1, (int)planned.size() - 1);
        const int firstHopSteps = std::max(1, simSteps / hops);
        const float b2s = std::max(1e-3f, bp.beat2_seconds);
        const float b3s = std::max(1e-3f, bp.beat3_seconds);
        const float slowRate = float(firstHopSteps) / b2s;
        const float fastRate = float(std::max(0, simSteps - firstHopSteps)) / b3s;
        slowStepsPerSec_ = std::clamp(slowRate, bp.beat2_rate_min, bp.beat2_rate_max);
        fastStepsPerSec_ = std::clamp(fastRate, bp.beat3_rate_min, bp.beat3_rate_max);
    }

    // Advance one rendered frame. `phaseTime` is seconds since begin() (i.e.
    // since the show entered this phase); `dt` is this frame's delta.
    // `wantOutro` is the host's own call on when the outro should start (it
    // owns the timing so the fade can be made to finish exactly when the
    // phase itself is about to end -- see main.mm). `clothCleared` is a
    // level, mirroring `wantOutro`'s convention: TransitionScene's own
    // cloth-clearance signal, true once the film has visibly fallen clear of
    // the mask. The first phaseTime it is seen true is when beat 1's
    // clear-tail timer (RootBeatParams::beat1_clear_tail_seconds) starts.
    // `markerHit` is a level for this one frame only: true the frame a "fire
    // reverb drop" cue (a FirePlucker marker; see main.mm's marker poll) came
    // in, which is what beats 3 and 4 switch on -- see their branches below.
    // Writes the camera/growth-pacing fields on `roots` directly.
    void step(RootScene& roots, double phaseTime, double dt,
             const RootBeatParams& bp, bool wantOutro, bool clothCleared,
             bool markerHit) {
        if (!valid_) return;

        const float fdt = float(std::max(0.0, dt));
        if (clothCleared && clothClearAt_ < 0.0) clothClearAt_ = phaseTime;
        const double b1 = (clothClearAt_ >= 0.0)
            ? std::max((double)bp.beat1_seconds, clothClearAt_ + (double)bp.beat1_clear_tail_seconds)
            : 1e30;   // never advances past beat 1 until the cloth has cleared at least once
        const double b2 = b1 + bp.beat2_seconds;
        const double b3 = b2 + bp.beat3_seconds;
        const double t = phaseTime;

        // The outro is a hold, not a framing: once it is wanted, the camera
        // stops being recomputed and simply stays where beat 4 (or wherever
        // it was) left it, while the fade ramps. Ramping both ways lets a
        // face reappearing mid-outro cancel it smoothly instead of snapping.
        const float outroRate = 1.f / std::max(1e-3f, bp.outro_seconds);
        if (wantOutro || beat_ == Beat::Outro) {
            beat_ = Beat::Outro;
            outroFade_ = std::clamp(outroFade_ + (wantOutro ? outroRate : -outroRate) * fdt,
                                    0.f, 1.f);
            if (!wantOutro && outroFade_ <= 0.f) beat_ = Beat::Meander;
            else return;   // camera/sim untouched -- exactly the last frame's hold
        }

        roots.autoFrame = false;
        roots.autoOrbit = false;
        roots.showPlannedMasks = true;

        float radius = tightR_;
        float target[3] = {anchor_.pos[0], anchor_.pos[1], anchor_.pos[2]};
        float az = az0_, el = el0_;
        bool  authoredEye = false;
        bool  clampAngular = false;

        auto smoothstep = [](double u) {
            u = std::clamp(u, 0.0, 1.0);
            return u * u * (3.0 - 2.0 * u);
        };

        if (t < b1) {
            beat_ = Beat::Face;
            roots.simPaused = true;
            roots.maskDeal = 0.f;
            radius = tightR_;
        } else if (t < b2) {
            beat_ = Beat::Deal;
            roots.simPaused = true;
            const float u = (float)smoothstep((t - b1) / std::max(1e-6, b2 - b1));
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
        } else if (t < b3) {
            beat_ = Beat::Growth;
            roots.maskDeal = 1.f;
            radius = structR_ * 0.55f;

            float tp[3];
            const int cm = roots.currentMask();
            const auto& pm = roots.plannedMasks();
            const bool arrived = roots.arrivedAtMask() && cm >= 0 && cm < (int)pm.size();
            if (arrived) {
                for (int k = 0; k < 3; ++k) target[k] = pm[size_t(cm)].pos[k];
            } else if (roots.growthTip(tp)) {
                for (int k = 0; k < 3; ++k) target[k] = tp[k];
            } else {
                for (int k = 0; k < 3; ++k) target[k] = track_[k];
            }

            // Marker-driven focus/grow toggle (see RootBeatParams' comment
            // on beat3_focus_fallback_seconds). Arriving at a mask freezes
            // growth and holds the camera there -- "focusing on a mask" --
            // until a fire reverb drop marker sends it on to grow the next
            // one. A marker that arrives before the camera has actually
            // settled on the mask is dropped rather than queued, so a drop
            // landing mid-swing cannot cut the hold short; the next one
            // still switches it once the camera has caught up.
            if (growingInBeat3_ && arrived) {
                growingInBeat3_ = false;
                focusEnteredAt_ = t;
            }
            if (!growingInBeat3_) {
                const float dx = follow_[0] - target[0], dy = follow_[1] - target[1],
                            dz = follow_[2] - target[2];
                const bool settled = std::sqrt(dx * dx + dy * dy + dz * dz)
                                      < 0.05f * std::max(1.f, tightR_);
                const bool fallback = focusEnteredAt_ >= 0.0 &&
                    (t - focusEnteredAt_) > (double)bp.beat3_focus_fallback_seconds;
                if (settled && (markerHit || fallback)) growingInBeat3_ = true;
            }
            roots.simPaused = !growingInBeat3_;
            roots.simStepsPerFrame = std::max(1, (int)std::lround(slowStepsPerSec_ * dt));

            {
                const float kk = 1.f - std::exp(-fdt / 0.7f);
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
            beat_ = Beat::Meander;
            roots.simPaused = false;
            roots.maskDeal = 1.f;
            roots.simStepsPerFrame = std::max(1, (int)std::lround(fastStepsPerSec_ * dt));
            // addNeighbours() re-bakes nine full copies of the plant's current
            // geometry into fresh GPU buffers -- expensive, and, since the
            // plant itself does not change between visitors (regrow() is a
            // manual operator action, not something a phase entry does), it
            // would produce byte-for-byte the same nine instances every time.
            // Gated on the plant's generation rather than "have I done this
            // for this visitor yet" so it is only redone when the geometry it
            // reads has actually changed.
            if (neighboursGen_ != roots.growGeneration()) {
                roots.addNeighbours((int)hood_.size(), structR_ * 0.85f, 99u, track_, az0_);
                roots.renderer().instanceCullPx = 0.5f;
                roots.renderer().lodBias = 0.5f;
                roots.renderer().subpixelCull = false;
                neighboursGen_ = roots.growGeneration();
            }

            const auto& pm = roots.plannedMasks();

            // A waypoint's own goal/standoff-eye pair, as a function of its
            // index -- pulled out to a lambda because the marker-advance
            // check below needs it twice: once for "have we settled on the
            // current one" and again for "here is the new one" the moment it
            // switches, same frame.
            auto waypointShot = [&](int wp, float outGoal[3], float outWantEye[3]) {
                const Neighbour& cyl = hood_[size_t((wp * 3 + 1) % hood_.size())];
                const auto& m = pm[size_t((wp * 3 + 2) % pm.size())];
                outGoal[0] = cyl.x + (m.pos[0] - track_[0]) * cyl.scale;
                outGoal[1] = m.pos[1] * cyl.scale;
                outGoal[2] = cyl.z + (m.pos[2] - track_[2]) * cyl.scale;
                float nx = outGoal[0] - cyl.x, nz = outGoal[2] - cyl.z;
                const float nl = std::sqrt(nx * nx + nz * nz);
                if (nl > 1e-3f) { nx /= nl; nz /= nl; } else { nx = 1.f; nz = 0.f; }
                const float standoff = structR_ * 0.75f;
                outWantEye[0] = outGoal[0] + nx * standoff;
                outWantEye[1] = outGoal[1] + structR_ * 0.12f;
                outWantEye[2] = outGoal[2] + nz * standoff;
            };
            auto pickSpeed = [&](int wp) {
                // Deterministic from the waypoint index, so the sequence
                // replays identically on a rerun regardless of how many
                // markers it actually took to get here.
                std::mt19937 rng(1000u + (unsigned)wp);
                std::uniform_real_distribution<float> U(bp.beat4_cam_speed_min,
                                                         std::max(bp.beat4_cam_speed_min,
                                                                  bp.beat4_cam_speed_max));
                camSpeed_ = U(rng);
            };

            if (waypoint_ < 0) {
                waypoint_ = 0;
                waypointEnteredAt_ = t;
                pickSpeed(waypoint_);
            }

            if (!eyePrimed_) {
                const float pr = structR_ * 0.55f;
                eye_[0] = track_[0] + pr * std::cos(el0_) * std::sin(az0_);
                eye_[1] = track_[1] + pr * std::sin(el0_);
                eye_[2] = track_[2] + pr * std::cos(el0_) * std::cos(az0_);
                for (int k = 0; k < 3; ++k) look_[k] = track_[k];
                eyePrimed_ = true;
            }

            float goal[3], wantEye[3];
            waypointShot(waypoint_, goal, wantEye);

            // Marker-driven waypoint advance -- the beat 4 half of the same
            // "fire reverb drop" pacing as beat 3, with the same settle gate
            // (a drop landing mid-flight is dropped, not queued) and the same
            // plain-timer fallback for when no marker is coming at all.
            {
                const float dxe = eye_[0] - wantEye[0], dye = eye_[1] - wantEye[1],
                            dze = eye_[2] - wantEye[2];
                const float dxl = look_[0] - goal[0], dyl = look_[1] - goal[1],
                            dzl = look_[2] - goal[2];
                const bool settledEye = std::sqrt(dxe * dxe + dye * dye + dze * dze)
                                         < 0.08f * std::max(1.f, structR_ * 0.75f);
                const bool settledLook = std::sqrt(dxl * dxl + dyl * dyl + dzl * dzl)
                                          < 0.08f * std::max(1.f, structR_);
                const double dwell = std::max(1e-3, (double)bp.beat4_dwell_seconds);
                const bool fallback = waypointEnteredAt_ >= 0.0 &&
                    (t - waypointEnteredAt_) > dwell;
                if (settledEye && settledLook && (markerHit || fallback)) {
                    ++waypoint_;
                    waypointEnteredAt_ = t;
                    pickSpeed(waypoint_);
                    waypointShot(waypoint_, goal, wantEye);
                }
            }

            // camSpeed_ is the reciprocal of the smoothing time constant, so a
            // higher authored speed is a snappier follow.
            const float speed = std::max(1e-3f, camSpeed_);
            const float ke = 1.f - std::exp(-fdt * speed);
            const float kl = 1.f - std::exp(-fdt * speed * 0.5f);
            for (int k = 0; k < 3; ++k) eye_[k] += (wantEye[k] - eye_[k]) * ke;
            for (int k = 0; k < 3; ++k) look_[k] += (goal[k] - look_[k]) * kl;

            const float dx = eye_[0] - look_[0], dy = eye_[1] - look_[1], dz = eye_[2] - look_[2];
            const float dist = std::max(1e-3f, std::sqrt(dx * dx + dy * dy + dz * dz));
            for (int k = 0; k < 3; ++k) target[k] = look_[k];
            radius = dist;
            az = std::atan2(dx, dz);
            el = std::asin(std::clamp(dy / dist, -1.f, 1.f));
            authoredEye = true;
            clampAngular = true;
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
            const float kk = 1.f - std::exp(-fdt / trackTau_);
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
            if (t >= b1 && t < b2)
                radius = std::max(radius, std::min(need, structR_ * 1.6f));

            az += 0.035f * std::sin(6.2831853f * 0.055f * (float)t)
                + 0.015f * std::sin(6.2831853f * 0.017f * (float)t + 2.1f);
            el += 0.020f * std::sin(6.2831853f * 0.041f * (float)t + 1.0f);
        }

        // Beat 4's authored fly-between is the one place a waypoint change
        // could otherwise read as a whip-pan; everywhere else az/el already
        // move continuously on their own.
        if (clampAngular) {
            const float maxStep = std::max(0.f, bp.beat4_max_angular_speed) * fdt;
            auto wrapDelta = [](float d) {
                while (d > 3.14159265f) d -= 6.2831853f;
                while (d < -3.14159265f) d += 6.2831853f;
                return d;
            };
            float dAz = std::clamp(wrapDelta(az - prevAz_), -maxStep, maxStep);
            float dEl = std::clamp(el - prevEl_, -maxStep, maxStep);
            az = prevAz_ + dAz;
            el = prevEl_ + dEl;
        }
        prevAz_ = az;
        prevEl_ = el;

        roots.target[0] = target[0];
        roots.target[1] = target[1];
        roots.target[2] = target[2];
        roots.radius    = radius;
        roots.azimuth   = az;
        roots.elevation = el;
    }

    bool valid() const { return valid_; }
    Beat beat() const { return beat_; }
    // 0..1, how far into the outro's screen-fade the sequence is. The host
    // (main.mm) is the one that actually owns the screen-wide fade uniform;
    // this is just this beat's opinion of where that fade should be.
    float outroFade() const { return outroFade_; }

private:
    struct Neighbour { float x, z, yaw, scale; };

    bool valid_ = false;
    Beat beat_ = Beat::Face;
    float outroFade_ = 0.f;
    const float trackTau_ = 1.1f;

    rootsim::SimMask anchor_{};
    float tightR_ = 0.f, structR_ = 0.f;
    float centroid_[3] = {0.f, 0.f, 0.f};
    float az0_ = 0.f, el0_ = 0.f;
    float prevAz_ = 0.f, prevEl_ = 0.f;
    double slowStepsPerSec_ = 0.0, fastStepsPerSec_ = 0.0;
    double clothClearAt_ = -1.0;   // first phaseTime clothCleared was seen true, -1 until then

    std::vector<Neighbour> hood_;
    int neighboursGen_ = -1;   // plant generation the current instances were built for; see step()

    float track_[3]  = {0.f, 0.f, 0.f};
    float follow_[3] = {0.f, 0.f, 0.f};
    float eye_[3]    = {0.f, 0.f, 0.f};
    float look_[3]   = {0.f, 0.f, 0.f};
    bool  eyePrimed_ = false;
    int   waypoint_  = -1;
    // Beat 3's marker-driven focus/grow toggle -- see step()'s `t < b3`
    // branch. True = growing toward the next mask; false = held on the one
    // just arrived at, waiting for a settled marker (or the fallback timer)
    // to let it go on.
    bool   growingInBeat3_ = true;
    double focusEnteredAt_ = -1.0;      // phaseTime the current focus began, -1 if not focused
    // Beat 4's marker-driven waypoint advance -- phaseTime the camera began
    // easing towards the current waypoint, for the fallback timer.
    double waypointEnteredAt_ = -1.0;
    float camSpeed_  = 0.5f;
};
