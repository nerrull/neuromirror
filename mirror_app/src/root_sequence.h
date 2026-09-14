// RootSequence — the root scene's timeline, as one linear state machine that
// drives the camera and the growth pacing:
//
//   Face    the anchor mask alone, tight, square to camera. The sim is held;
//           the viewer is still driving the mask (main.mm's setFittedFace).
//           Runs through Phase::Transition -- the cloth press happens on this
//           framing -- and ends only once the cloth has cleared.
//   Grow    the sim runs, one target face after another. The camera swings
//           round to look along the structure's axis (tilted so the faces
//           read three-quarter) and is pushed back by the growing tip: the
//           radius only ever grows, so the pull-back is the growth's own.
//   Turn    the finished chain is turned to hang: the camera rotates about
//           the structure's centre to a low elevation, framing the whole of
//           it, so the axis reads vertical on screen.
//   Reveal  the other structures -- baked variations of this plant, wearing
//           previous visitors' faces -- stand around this one on a
//           fan behind it. Each pops in dark on a Wwise marker and lights on
//           the next (or on a timer where no marker comes); the camera keeps
//           the Turn's angles and backs off to keep what has come in framed.
//           Ends when the last of them is lit.
//   Orbit   a slow orbit of everything, until it has run its time or the
//           visitor has left.
//   Outro   the datamosh, then the screen fade. Done when the fade lands.
//
// This replaces RootCameraSequence (Face -> Deal -> Growth -> Meander), which
// was built for an offline exporter and grafted onto the live show; the mask
// deal-out, the marker-gated focus/grow toggle and the waypoint meander made
// the phase choppy and hard to control. See plans/ROOT_TIMELINE.md for the
// brief this implements.
//
// Every duration, rate and angle is authored (RootSequenceParams) and taken
// fresh on every step(), so a panel slider dragged mid-shot retimes what is
// running rather than requiring a restart -- see ui_params' `show/roots`.
//
// Usage: begin() once per entry into Transition/Roots (it reads the layout
// and picks the anchor, so calling it again mid-shot would restart the
// piece); step() once per rendered frame after that. step() writes
// roots.target/radius/azimuth/elevation, roots.simPaused and
// roots.simStepsPerFrame, forces roots.autoFrame off, -- in WhenFramed
// reveal mode -- flags planned masks visible, and in Reveal places the other
// structures and steps them visible/lit. Nothing else on the scene.
#pragma once
#ifndef __OBJC__
#error "root_sequence.h is ObjC++ only"
#endif

#include "root_scene.h"
#include "root_sim.h"

#include <algorithm>
#include <cmath>
#include <vector>

// Every knob the timeline needs, authored rather than derived -- the panel's
// `show/roots` section writes straight into one of these each frame.
struct RootSequenceParams {
    // --- Face --------------------------------------------------------------
    // Floor on the face-alone stage. It never ends before the cloth has
    // cleared (TransitionScene-style clearance, see RootScene::clothCleared)
    // plus face_clear_tail_seconds more, so growth never starts while the
    // film is still visibly falling.
    float face_seconds            = 2.3f;
    float face_clear_tail_seconds = 10.0f;
    // Fog only exists in the Roots renderer, so it would otherwise pop the
    // instant compositing begins. The host (main.mm's applyFogFade) ramps
    // visibility from clear to the phase's intensity over this many seconds
    // from the start of Face.
    float fog_fade_seconds        = 2.0f;

    // --- Grow --------------------------------------------------------------
    // Seconds per target face. The sim rate is derived from the plant's own
    // step count (RootScene::growthStepEstimate) so the growth lands on the
    // stage boundary whatever the layout, then clamped into [min, max]
    // steps/s so an unusually large layout cannot run past a believable
    // growth speed. The show's plant is ~190 steps over 5 hops, so at 10 s a
    // face the rate is under 4 steps/s: the floor has to sit below that (it
    // was 20, and with the steps rounded up to one per frame the whole chain
    // grew in the three seconds of the swing).
    float grow_face_seconds  = 10.0f;
    float grow_rate_min      = 1.f;
    float grow_rate_max      = 1200.f;
    // Where the camera stands for the growth, as an angle off the structure's
    // axis toward the anchor's normal, degrees. The axis A runs from the
    // anchor to the centroid of the chain -- the direction the growth heads
    // in -- and the camera direction is A swung toward the normal by this:
    // 0 is dead on the axis (the chain grows straight at the lens, the faces
    // edge-on), 90 is square to the axis. Measured off the *axis* and not off
    // the normal, because what the stage is about is the chain coming toward
    // the lens: on the cone the axis runs ~115 degrees off the anchor's
    // normal, so a tilt of 45 off the normal left the camera 70 off the axis
    // with the chain running mostly sideways -- and at the start of the
    // swing, straight away. 60 puts half the growth toward the lens (cos 60)
    // with the anchor read at ~55 off its normal; lower, and the chain
    // foreshortens into one cluster (at 45 the finished chain is a blob
    // seen end-on from underneath), higher and it runs across the frame.
    float grow_view_tilt_deg = 60.f;
    // The swing from the Face pose to the Grow pose at Grow entry. The
    // growth itself is held until the swing is grow_swing_gate of the way
    // through, so the first hop is seen from the Grow pose and not from
    // square-on, where it heads away from the lens.
    float grow_swing_seconds = 3.0f;
    float grow_swing_gate    = 0.7f;
    // Margin around the anchor / tip / target-mask bound, as a fraction of
    // its extent, when computing the pushed-back radius.
    float grow_margin        = 0.35f;
    // Guard: Grow ends at grow_face_seconds x (N-1) x this even if the sim
    // has not reported done().
    float grow_timeout_mult  = 1.5f;
    // 0 = OnArrival (a mask appears when the root reaches it, the sim's own
    // reveal); 1 = WhenFramed (a planned mask is drawn as soon as its bound
    // is inside the frustum, and stays drawn).
    int   reveal_mode        = 0;

    // --- camera easing (Grow onward) ---------------------------------------
    // Time constant of the exponential ease on radius and target.
    float cam_ease_seconds   = 1.2f;
    // Hard cap on how fast azimuth/elevation may change, rad/s, so no stage
    // boundary can read as a whip-pan.
    float cam_max_angular_speed = 1.2f;

    // --- Turn --------------------------------------------------------------
    float turn_seconds           = 6.0f;
    float turn_end_elevation_deg = 5.0f;
    // Margin around the whole-structure (and, in Orbit, all-structures)
    // bound, as a fraction of its extent.
    float frame_margin           = 0.25f;

    // --- Reveal ------------------------------------------------------------
    // Spacing of the other structures: structure k stands
    // reveal_spacing x this structure's radius x sqrt(k+1) from its centre
    // (a sunflower, so the hood packs evenly at any count). The radius is the
    // masks' bound, which the tall cone makes mostly height, so at ~1.2 the
    // structures stand close enough to interleave a little -- a grove, not a
    // ring of exhibits. A step happens on a Wwise marker, or after this many
    // seconds without one (markers need the SDK and a bank built with
    // cue-carrying audio, neither of which every dev machine has).
    float reveal_spacing          = 1.2f;
    float reveal_fallback_seconds = 2.5f;
    // How many other structures stand around this one. reveal_structures
    // is the operator's say: 0 leaves it to the face bank (one structure per
    // N older captures, at least min, at most max -- see the plan's "face
    // bank"), anything else is exactly that many, wearing the bank's faces
    // round again when it is short.
    int   reveal_structures       = 0;
    int   reveal_min_structures   = 3;
    int   reveal_max_structures   = 12;

    // --- Orbit -------------------------------------------------------------
    float orbit_rate          = 0.08f;   // rad/s
    // High enough that the lens passes *over* the outer structures rather
    // than through them: the hood is a disc the camera orbits at about its
    // own radius, so at a low elevation the eye is inside the outer ring.
    float orbit_elevation_deg = 25.f;
    float orbit_seconds       = 40.f;
    // What the orbit frames: every structure standing within this fraction
    // of the furthest one's distance, and never fewer than the nearest four
    // (the outermost are allowed to leave the frame -- fitting a dozen
    // strictly puts the camera so far out that the fog swallows all of it;
    // a young bank's three placeholders are all kept), and then the camera
    // never further than
    // orbit_max_radius from the hood's centre whatever the fit asks. The cap
    // is in world units because the fog is: with the phase's visibility at
    // 45 and the clearing at ~0.55 of the radius, a centre 150 out sits about
    // 1.5 visibilities into the fog, and what is nearer the lens still reads.
    float orbit_bound_frac    = 0.7f;
    float orbit_max_radius    = 150.f;

    // --- Outro -------------------------------------------------------------
    float datamosh_seconds = 3.0f;
    float fade_seconds     = 2.0f;

    // --- head pan ----------------------------------------------------------
    // The tracked face's position in frame nudges the camera by up to this
    // many degrees of azimuth/elevation, eased with head_pan_tau. Off during
    // Face, where the viewer is driving the mask rather than the camera.
    bool  head_pan_enabled = true;
    float head_pan_deg     = 5.f;
    float head_pan_tau     = 0.6f;
};

class RootSequence {
public:
    enum class Stage { Face = 0, Grow, Turn, Reveal, Orbit, Outro, Done };

    // Per-frame inputs from the host, all levels for this one frame:
    //   wantOutro     the host's own call on when the outro should start (the
    //                 visitor-absence signal; see main.mm's Roots branch).
    //   clothCleared  RootScene::clothCleared() -- the first clock it is seen
    //                 true is when Face's clear-tail timer starts.
    //   markerHit     a "fire reverb drop" cue (a FirePlucker marker) came in
    //                 this frame. Reveal's step trigger.
    //   tracked*      the tracked face's centre, [0,1] from the top-left
    //                 (FaceResult::centre_x/y), for the head pan.
    struct Inputs {
        bool  wantOutro    = false;
        bool  clothCleared = false;
        bool  markerHit    = false;
        bool  trackedValid = false;
        float trackedX = 0.5f, trackedY = 0.5f;
    };

    // Read the planned layout and pick the anchor and the structure's
    // geometry. `neighboursGen_` is deliberately NOT reset here -- it tracks
    // whether the neighbour hood matches the plant's current generation, not
    // whether this visit has built it yet; see the Reveal branch of step().
    void begin(RootScene& roots, const RootSequenceParams& P) {
        stage_        = Stage::Face;
        stageT0_      = 0.0;
        clothClearAt_ = -1.0;
        fade_         = 0.f;
        moshFired_    = false;
        growWantR_    = 0.f;
        revealStep_   = 0;
        revealLastT_  = 0.0;
        panAz_ = panEl_ = 0.f;
        prevAz_ = prevEl_ = 0.f;
        prevValid_ = false;
        revealWantR_ = 0.f;
        // A hood still placed from a previous run on the same plant (the
        // operator re-entering the phase without a replant) starts hidden
        // and dark again, so Reveal has something to reveal. No-ops when the
        // hood is already gone, which is the show's own case.
        for (int k = 0; k < (int)roots.neighbours.size(); ++k) {
            roots.setStructureVisible(k, false);
            roots.setStructureLit(k, false);
        }
        // The last visit's outro must not be running on this one's first
        // frame. The datamosh is timed on the renderer's own clock, which
        // only advances while the scene renders: a visit cut short while the
        // mosh still had time left (the show's absence edge landing before
        // the fade did) came back with that time still owing, and the
        // feedback buffer still holding the last smeared frame of the
        // previous visitor. Face has to be clean.
        roots.renderer().cancelDatamosh();

        const auto& planned = roots.plannedMasks();
        if (planned.empty()) { valid_ = false; return; }
        valid_ = true;
        anchor_ = planned.front();
        anchorExt_ = std::max(anchor_.rWidth, anchor_.rHeight);
        tightR_ = anchorExt_ * 2.6f;

        // The structure: its centre and a sphere about that centre covering
        // every mask plus that mask's own size. Roots trail past the masks,
        // but the masks are what the shot is about.
        centroid_[0] = centroid_[1] = centroid_[2] = 0.f;
        for (const auto& m : planned)
            for (int k = 0; k < 3; ++k) centroid_[k] += m.pos[k] / float(planned.size());
        structR_ = anchorExt_;
        for (const auto& m : planned)
            structR_ = std::max(structR_, dist3(m.pos, centroid_) + std::max(m.rWidth, m.rHeight));

        // Straight down the anchor's normal, so the face is square to camera
        // through the press and stays that way until Grow swings away.
        azelFromDir(anchor_.normal, az0_, el0_);

        // The Grow pose. The structure's axis A runs from the anchor to the
        // centroid of the layout -- the direction the chain grows in. The
        // camera stands on A swung toward the anchor's normal by
        // grow_view_tilt_deg, in the plane of the two: on the axis the chain
        // would grow straight at the lens with the faces edge-on, square to
        // it the faces would read but the growth would run across the frame
        // (or, from the Face pose, straight away), and the tilt is the
        // compromise. Measured off the axis so that whatever the layout, the
        // growth has cos(tilt) of itself coming toward the lens.
        float A[3] = {centroid_[0] - anchor_.pos[0], centroid_[1] - anchor_.pos[1],
                      centroid_[2] - anchor_.pos[2]};
        float n[3] = {anchor_.normal[0], anchor_.normal[1], anchor_.normal[2]};
        normalize3(n);
        if (!normalize3(A)) { A[0] = n[0]; A[1] = n[1]; A[2] = n[2]; }
        // The component of the normal perpendicular to the axis is the
        // swing's direction; if the two are (anti)parallel there is no
        // preferred way to swing and the camera sits on the axis.
        const float nA = n[0] * A[0] + n[1] * A[1] + n[2] * A[2];
        float perp[3] = {n[0] - nA * A[0], n[1] - nA * A[1], n[2] - nA * A[2]};
        float d[3] = {A[0], A[1], A[2]};
        if (normalize3(perp)) {
            const float t = std::clamp(P.grow_view_tilt_deg, 0.f, 90.f) * kDeg;
            const float ct = std::cos(t), st = std::sin(t);
            for (int k = 0; k < 3; ++k) d[k] = A[k] * ct + perp[k] * st;
        }
        azelFromDir(d, growAz_, growEl_);

        // Growth pacing: the whole run's steps spread over the N-1 target
        // faces at grow_face_seconds each, in steps per *second* so it holds
        // at any frame rate. The steps are dealt out as a fractional
        // accumulator (growStepAcc_), so a rate under one step per frame is
        // honoured rather than rounded up to one -- at show speed the plant
        // takes a few thousand steps over a minute, well under 60/s.
        const int simSteps = roots.growthStepEstimate();
        const int hops = std::max(1, (int)planned.size() - 1);
        const float perFace = std::max(1e-3f, P.grow_face_seconds);
        growStepsPerSec_ = std::clamp(float(simSteps) / float(hops) / perFace,
                                      P.grow_rate_min, std::max(P.grow_rate_min, P.grow_rate_max));
        growStepAcc_ = 0.f;
        growTimeout_ = perFace * float(hops) * std::max(1.f, P.grow_timeout_mult)
                     + P.grow_swing_seconds * std::clamp(P.grow_swing_gate, 0.f, 1.f);

        // The camera starts on the Face pose, snapped: there is nothing to
        // ease from yet.
        curAz_ = az0_; curEl_ = el0_; curR_ = tightR_;
        for (int k = 0; k < 3; ++k) curT_[k] = anchor_.pos[k];
    }

    // Advance one rendered frame. `clock` is seconds since begin(); `dt` is
    // this frame's delta.
    void step(RootScene& roots, double clock, double dt, const RootSequenceParams& P,
              const Inputs& in) {
        if (!valid_ || stage_ == Stage::Done) return;

        const float fdt = float(std::max(0.0, dt));
        const double tIn = clock - stageT0_;   // seconds into the current stage
        roots.autoFrame = false;

        // The host's outro request wins over whatever stage is running: the
        // visitor has gone, and every stage after Face is a thing shown to
        // someone. (In Face the sequence is still inside Transition, whose
        // own timeline handles absence.)
        if (in.wantOutro && stage_ != Stage::Face && stage_ != Stage::Outro)
            enter(Stage::Outro, clock);

        // Ease constants, shared by the stages below.
        const float kEase = 1.f - std::exp(-fdt / std::max(1e-3f, P.cam_ease_seconds));
        auto easeTo = [&](float& v, float want, float k) { v += (want - v) * k; };
        auto easeAngle = [&](float& a, float want, float k) { a += wrapPi(want - a) * k; };

        switch (stage_) {
        case Stage::Face: {
            roots.simPaused = true;
            curAz_ = az0_; curEl_ = el0_; curR_ = tightR_;
            for (int k = 0; k < 3; ++k) curT_[k] = anchor_.pos[k];
            if (in.clothCleared && clothClearAt_ < 0.0) clothClearAt_ = clock;
            const double end = (clothClearAt_ >= 0.0)
                ? std::max((double)P.face_seconds, clothClearAt_ + (double)P.face_clear_tail_seconds)
                : 1e30;   // never leaves Face until the cloth has cleared at least once
            if (clock >= end) {
                enter(Stage::Grow, clock);
                growWantR_ = tightR_;
            }
            break;
        }
        case Stage::Grow: {
            // The swing: Face pose to Grow pose, smoothstepped, angles only.
            // Radius and target ease exponentially below like everywhere
            // else, so the swing reads as one move rather than two.
            const double swingU = tIn / std::max(1e-3, (double)P.grow_swing_seconds);
            const float u = smoothstep(swingU);
            curAz_ = az0_ + wrapPi(growAz_ - az0_) * u;
            curEl_ = el0_ + (growEl_ - el0_) * u;

            // The growth, once the swing is mostly done: from the Face pose
            // the first hop heads straight away from the lens, and the
            // point of the swing is that it is seen coming on instead.
            const bool growing = swingU >= (double)std::clamp(P.grow_swing_gate, 0.f, 1.f);
            stepGrowth(roots, growing ? fdt : 0.f);

            // Where the growth is: the current target mask and the tip.
            const auto& pm = roots.plannedMasks();
            const int cm = roots.currentMask();
            const bool haveMask = cm >= 0 && cm < (int)pm.size();
            const rootsim::SimMask& tm = haveMask ? pm[size_t(cm)] : pm.back();

            // Target: the anchor, drifting toward the midpoint of anchor and
            // current target mask, so it slides off-centre slowly rather
            // than staying pinned while the frame widens around it.
            float wantT[3];
            for (int k = 0; k < 3; ++k) wantT[k] = 0.5f * (anchor_.pos[k] + tm.pos[k]);
            for (int k = 0; k < 3; ++k) easeTo(curT_[k], wantT[k], kEase);

            // Pushed by the tip: the radius that fits anchor, tip and target
            // mask at this frame's angles and target, and it never comes
            // back in.
            Bound pts[3];
            int np = 0;
            pts[np++] = {{anchor_.pos[0], anchor_.pos[1], anchor_.pos[2]}, anchorExt_};
            float tip[3];
            if (roots.growthTip(tip)) pts[np++] = {{tip[0], tip[1], tip[2]}, 0.f};
            if (haveMask) pts[np++] = {{tm.pos[0], tm.pos[1], tm.pos[2]}, std::max(tm.rWidth, tm.rHeight)};
            const float need = fitRadius(roots, curT_, curAz_, curEl_, pts, np, P.grow_margin);
            growWantR_ = std::max(growWantR_, need);
            easeTo(curR_, growWantR_, kEase);

            if (roots.simDone() || tIn >= (double)growTimeout_) {
                enter(Stage::Turn, clock);
                turnFromAz_ = curAz_; turnFromEl_ = curEl_; turnFromR_ = curR_;
                for (int k = 0; k < 3; ++k) turnFromT_[k] = curT_[k];
            }
            break;
        }
        case Stage::Turn: {
            // Rotate about the structure's centre from the Grow pose to the
            // hanging pose: azimuth unchanged, elevation down to
            // turn_end_elevation_deg, the whole structure framed. Everything
            // blends on one smoothstep so the move has a single shape.
            stepGrowth(roots, fdt);
            const float u = smoothstep(tIn / std::max(1e-3, (double)P.turn_seconds));
            const Bound whole = {{centroid_[0], centroid_[1], centroid_[2]}, structR_};
            const float endEl = P.turn_end_elevation_deg * kDeg;
            const float endR  = fitRadius(roots, centroid_, turnFromAz_, endEl, &whole, 1, P.frame_margin);
            curAz_ = turnFromAz_;
            curEl_ = turnFromEl_ + (endEl - turnFromEl_) * u;
            curR_  = turnFromR_ + (endR - turnFromR_) * u;
            for (int k = 0; k < 3; ++k) curT_[k] = turnFromT_[k] + (centroid_[k] - turnFromT_[k]) * u;
            if (u >= 1.f) { enter(Stage::Reveal, clock); revealLastT_ = clock; }
            break;
        }
        case Stage::Reveal: {
            // The other structures, placed hidden and dark on entry, then
            // stepped in: step 2k shows structure k dark, step 2k+1 lights it.
            // A step fires on a marker, or after reveal_fallback_seconds
            // without one. The camera holds the Turn's end pose (the head pan
            // still applies below). Gated on the plant's generation rather
            // than "have I done this for this visitor yet": placement re-bakes
            // every structure into fresh GPU buffers and only needs redoing
            // when what it reads has changed -- and replant() bumps the
            // generation, having dropped the last visitor's hood. The
            // variations behind the placement are cached one level down, in
            // RootScene, and survive the replant.
            stepGrowth(roots, fdt);
            if (neighboursGen_ != roots.growGeneration()) {
                const int fromBank = roots.structureCount() > 0 ? roots.structureCount()
                                                                : P.reveal_min_structures;
                const int count = std::clamp(P.reveal_structures > 0 ? P.reveal_structures : fromBank,
                                             1, 64);
                float tanH, tanV;
                tanHV(roots, tanH, tanV);
                roots.addNeighbours(count, std::max(1, P.reveal_max_structures),
                                    std::max(0.5f, P.reveal_spacing), structR_, centroid_,
                                    curAz_, curR_, tanH);
                roots.renderer().instanceCullPx = 0.5f;
                roots.renderer().lodBias = 0.5f;
                roots.renderer().subpixelCull = false;
                neighboursGen_ = roots.growGeneration();
                revealStep_  = 0;
                revealLastT_ = clock;
                revealWantR_ = curR_;
            }
            const int total = 2 * (int)roots.neighbours.size();
            const bool fire = in.markerHit ||
                              (clock - revealLastT_) >= std::max(0.1, (double)P.reveal_fallback_seconds);
            if (fire && revealStep_ < total) {
                const int k = revealStep_ / 2;
                if ((revealStep_ & 1) == 0) roots.setStructureVisible(k, true);
                else                        roots.setStructureLit(k, true);
                ++revealStep_;
                revealLastT_ = clock;
            }
            // The camera holds the Turn's angles and target but gives ground
            // as the hood comes in: the radius that frames this structure
            // and every neighbour shown so far, each as its own bound, and
            // it never comes back in. The placement keeps the hood in the
            // Turn-end frustum where it can, but a wide hood at a tall
            // structure's framing has its outer ones past the edge, and a
            // structure that pops in out of frame has not been revealed.
            {
                std::vector<Bound> bs;
                bs.push_back({{centroid_[0], centroid_[1], centroid_[2]}, structR_});
                for (const auto& pl : roots.neighbours)
                    if (pl.visible) bs.push_back({{pl.centre[0], pl.centre[1], pl.centre[2]}, pl.radius});
                const float need = fitRadius(roots, curT_, curAz_, curEl_, bs.data(), (int)bs.size(),
                                             P.frame_margin);
                revealWantR_ = std::max(revealWantR_, need);
                easeTo(curR_, revealWantR_, kEase);
            }
            if (revealStep_ >= total) {
                enter(Stage::Orbit, clock);
                orbitBound(roots, P);
            }
            break;
        }
        case Stage::Orbit:
        case Stage::Outro: {
            // Orbit everything: azimuth advancing, elevation and radius eased
            // in to frame the whole hood. The orbit keeps running through the
            // outro -- the datamosh reads camera motion, and a camera that
            // froze the moment it fired would have nothing to smear.
            stepGrowth(roots, fdt);
            const float wantEl = P.orbit_elevation_deg * kDeg;
            curAz_ += P.orbit_rate * fdt;
            easeAngle(curEl_, wantEl, kEase);
            for (int k = 0; k < 3; ++k) easeTo(curT_[k], orbitC_[k], kEase);
            const float wantR = std::min(orbitFitRadius(roots, curAz_, wantEl, P),
                                         std::max(1.f, P.orbit_max_radius));
            easeTo(curR_, wantR, kEase);

            if (stage_ == Stage::Orbit) {
                if (tIn >= (double)P.orbit_seconds) enter(Stage::Outro, clock);
            } else {
                // The datamosh once, on entry; then the fade once the mosh
                // has had its time. The host owns the screen-wide fade
                // uniform -- fade() is this stage's opinion of where it
                // should be.
                // Triggered for the mosh's own time *and* the fade's (and a
                // moment more, so the frame the black lands on is still
                // smeared): the fade begins the moment the mosh's time is
                // up, and a trigger of only that length expired on the same
                // frame, so the picture snapped clean just as it started to
                // go. Whatever is left owing when the show cuts to Idle is
                // cancelled at the next begin().
                if (!moshFired_) {
                    roots.renderer().triggerDatamosh(std::max(0.f, P.datamosh_seconds) +
                                                     std::max(0.f, P.fade_seconds) + 0.5f);
                    moshFired_ = true;
                }
                if (tIn >= (double)P.datamosh_seconds) {
                    fade_ = std::clamp(fade_ + fdt / std::max(1e-3f, P.fade_seconds), 0.f, 1.f);
                    if (fade_ >= 1.f) enter(Stage::Done, clock);
                }
            }
            break;
        }
        case Stage::Done:
            break;
        }

        // --- head pan (Grow onward) -----------------------------------------
        // The tracked face's place in frame, as a small az/el offset on top of
        // whatever the stage decided; eased, and easing back to nothing when
        // nobody is tracked. Not during Face: the viewer is driving the mask
        // then, and a camera that also moved with them would fight the press.
        {
            float wantAz = 0.f, wantEl = 0.f;
            if (P.head_pan_enabled && in.trackedValid && stage_ != Stage::Face) {
                const float range = P.head_pan_deg * kDeg;
                wantAz = (in.trackedX - 0.5f) * 2.f * range;    // left..right
                wantEl = -(in.trackedY - 0.5f) * 2.f * range;   // top..bottom, up is +el
            }
            const float kp = 1.f - std::exp(-fdt / std::max(1e-3f, P.head_pan_tau));
            easeTo(panAz_, wantAz, kp);
            easeTo(panEl_, wantEl, kp);
        }

        float az = curAz_ + panAz_;
        float el = std::clamp(curEl_ + panEl_, -1.5f, 1.5f);

        // Angular speed clamp: every stage boundary above is already a blend
        // or an ease, but this is the one guarantee that none of them -- nor
        // a panel slider yanked mid-shot -- can read as a whip-pan.
        if (prevValid_) {
            const float maxStep = std::max(0.f, P.cam_max_angular_speed) * fdt;
            az = prevAz_ + std::clamp(wrapPi(az - prevAz_), -maxStep, maxStep);
            el = prevEl_ + std::clamp(el - prevEl_, -maxStep, maxStep);
        }
        prevAz_ = az; prevEl_ = el; prevValid_ = true;

        roots.target[0] = curT_[0];
        roots.target[1] = curT_[1];
        roots.target[2] = curT_[2];
        roots.radius    = std::max(0.1f, curR_);
        roots.azimuth   = az;
        roots.elevation = el;

        // WhenFramed reveal: a planned mask becomes visible the first frame
        // its bound is inside the frustum the camera above will render, and
        // stays visible. Only worth doing while masks are still arriving.
        if (P.reveal_mode == 1 && stage_ == Stage::Grow) {
            const auto& pm = roots.plannedMasks();
            for (int i = 0; i < (int)pm.size(); ++i) {
                if (roots.maskVisible(i)) continue;
                const auto& m = pm[size_t(i)];
                const Bound b = {{m.pos[0], m.pos[1], m.pos[2]}, std::max(m.rWidth, m.rHeight)};
                if (inFrustum(roots, roots.target, roots.radius, az, el, b))
                    roots.setMaskVisible(i);
            }
        }
    }

    bool  valid() const { return valid_; }
    Stage stage() const { return stage_; }
    bool  done()  const { return stage_ == Stage::Done; }
    // 0..1, how far into the outro's screen-fade the sequence is.
    float fade()  const { return fade_; }
    static const char* stageName(Stage s) {
        switch (s) {
            case Stage::Face:   return "face";
            case Stage::Grow:   return "grow";
            case Stage::Turn:   return "turn";
            case Stage::Reveal: return "reveal";
            case Stage::Orbit:  return "orbit";
            case Stage::Outro:  return "outro";
            case Stage::Done:   return "done";
        }
        return "?";
    }

private:
    static constexpr float kDeg = 3.14159265f / 180.f;
    struct Bound { float p[3]; float r; };

    void enter(Stage s, double clock) { stage_ = s; stageT0_ = clock; }

    // Deal this frame's sim steps: growStepsPerSec_ x dt, carried as a
    // fraction between frames so the rate is honoured below one step per
    // frame (RootScene::advance runs at least one step whenever the sim is
    // not paused, so a frame owed none pauses it). dt of 0 holds the growth.
    void stepGrowth(RootScene& roots, float dt) {
        growStepAcc_ += growStepsPerSec_ * std::max(0.f, dt);
        const int steps = (int)std::floor(growStepAcc_);
        growStepAcc_ -= float(steps);
        roots.simPaused = steps <= 0;
        roots.simStepsPerFrame = std::max(1, steps);
    }

    static float smoothstep(double u) {
        u = std::clamp(u, 0.0, 1.0);
        return float(u * u * (3.0 - 2.0 * u));
    }
    static float wrapPi(float d) {
        while (d >  3.14159265f) d -= 6.2831853f;
        while (d < -3.14159265f) d += 6.2831853f;
        return d;
    }
    static float dist3(const float a[3], const float b[3]) {
        const float dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
        return std::sqrt(dx * dx + dy * dy + dz * dz);
    }
    static bool normalize3(float v[3]) {
        const float l = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        if (l < 1e-6f) return false;
        v[0] /= l; v[1] /= l; v[2] /= l;
        return true;
    }
    // eye = target + R * (cosEl sinAz, sinEl, cosEl cosAz) -- the renderer's
    // convention -- so a direction from the target toward the eye inverts
    // straight into the two angles.
    static void azelFromDir(const float d[3], float& az, float& el) {
        float v[3] = {d[0], d[1], d[2]};
        if (!normalize3(v)) { az = 0.f; el = 0.f; return; }
        az = std::atan2(v[0], v[2]);
        el = std::asin(std::clamp(v[1], -1.f, 1.f));
    }

    // The camera's basis for a pose, in the renderer's own terms: forward
    // from eye to target, right = forward x world-up, up = right x forward.
    struct Basis { float fwd[3], rgt[3], up[3]; };
    static Basis basisFor(float az, float el) {
        Basis b;
        const float ce = std::cos(el), se = std::sin(el);
        b.fwd[0] = -ce * std::sin(az); b.fwd[1] = -se; b.fwd[2] = -ce * std::cos(az);
        // cross(fwd, (0,1,0)) = (-fwd.z, 0, fwd.x)
        b.rgt[0] = -b.fwd[2]; b.rgt[1] = 0.f; b.rgt[2] = b.fwd[0];
        if (!normalize3(b.rgt)) { b.rgt[0] = 1.f; b.rgt[1] = 0.f; b.rgt[2] = 0.f; }
        b.up[0] = b.rgt[1] * b.fwd[2] - b.rgt[2] * b.fwd[1];
        b.up[1] = b.rgt[2] * b.fwd[0] - b.rgt[0] * b.fwd[2];
        b.up[2] = b.rgt[0] * b.fwd[1] - b.rgt[1] * b.fwd[0];
        return b;
    }
    // The frustum's half-extents at unit depth. `fov` on RootScene is the
    // vertical *half*-angle (the renderer builds its projection as
    // 1/tan(fov)), and the horizontal one follows from the aspect.
    static void tanHV(const RootScene& roots, float& tanH, float& tanV) {
        tanV = std::tan(std::clamp(roots.effectiveFov(), 0.05f, 1.4f));
        const float aspect = float(std::max(1, roots.width())) / float(std::max(1, roots.height()));
        tanH = tanV * aspect;
    }

    // The radius a camera at (az, el) about `target` needs for every bound
    // to sit inside the frustum, each grown by `margin` of its own extent.
    //
    // In camera coordinates relative to the target a bound is at (x, y, z)
    // with z positive beyond the target; its depth from the eye is R + z,
    // and it fits horizontally when (|x| + r)(1 + margin) <= (R + z) tanH,
    // which solves for R directly. The largest R over both axes and every
    // bound is the answer.
    static float fitRadius(const RootScene& roots, const float target[3], float az, float el,
                           const Bound* pts, int n, float margin) {
        float tanH, tanV;
        tanHV(roots, tanH, tanV);
        const Basis b = basisFor(az, el);
        const float grow = 1.f + std::max(0.f, margin);
        float R = 0.f;
        for (int i = 0; i < n; ++i) {
            const float q[3] = {pts[i].p[0] - target[0], pts[i].p[1] - target[1],
                                pts[i].p[2] - target[2]};
            const float x = q[0] * b.rgt[0] + q[1] * b.rgt[1] + q[2] * b.rgt[2];
            const float y = q[0] * b.up[0]  + q[1] * b.up[1]  + q[2] * b.up[2];
            const float z = q[0] * b.fwd[0] + q[1] * b.fwd[1] + q[2] * b.fwd[2];
            const float r = std::max(0.f, pts[i].r);
            R = std::max(R, (std::fabs(x) + r) * grow / tanH - z);
            R = std::max(R, (std::fabs(y) + r) * grow / tanV - z);
            // ...and never so close that the bound's near side is behind the
            // eye, whatever the angles say.
            R = std::max(R, r * grow - z + 0.1f);
        }
        return R;
    }
    // Whether a bound is wholly inside the frustum of a given pose. The same
    // geometry as fitRadius, read the other way round.
    static bool inFrustum(const RootScene& roots, const float target[3], float radius,
                          float az, float el, const Bound& pt) {
        float tanH, tanV;
        tanHV(roots, tanH, tanV);
        const Basis b = basisFor(az, el);
        const float q[3] = {pt.p[0] - target[0], pt.p[1] - target[1], pt.p[2] - target[2]};
        const float x = q[0] * b.rgt[0] + q[1] * b.rgt[1] + q[2] * b.rgt[2];
        const float y = q[0] * b.up[0]  + q[1] * b.up[1]  + q[2] * b.up[2];
        const float z = q[0] * b.fwd[0] + q[1] * b.fwd[1] + q[2] * b.fwd[2];
        const float depth = radius + z;
        if (depth <= pt.r) return false;
        return std::fabs(x) + pt.r <= depth * tanH && std::fabs(y) + pt.r <= depth * tanV;
    }

    // What the orbit frames, decided once on entry: the live structure and
    // the neighbours standing within orbit_bound_frac of the furthest one's
    // distance from it (the placement is laid out about the live structure,
    // so that is the yardstick) -- never fewer than the nearest four, since
    // a young bank's three placeholders are the whole hood. The outermost
    // may leave the frame; fitting a dozen strictly puts the camera so far
    // out that the fog swallows all of it. The orbit's centre is the mean
    // of what is framed: the ones that would have stood in front of the
    // camera were put behind, which loads the far side, and an orbit about
    // the live structure alone leaves that load at the frame's edge.
    void orbitBound(const RootScene& roots, const RootSequenceParams& P) {
        orbitBs_.clear();
        orbitBs_.push_back({{centroid_[0], centroid_[1], centroid_[2]}, structR_});
        float far = 0.f;
        std::vector<float> ds;
        for (const auto& pl : roots.neighbours) {
            ds.push_back(dist3(pl.centre, centroid_));
            far = std::max(far, ds.back());
        }
        std::sort(ds.begin(), ds.end());
        float keep = far * std::clamp(P.orbit_bound_frac, 0.1f, 1.f) + 1e-3f;
        if (!ds.empty()) keep = std::max(keep, ds[std::min(ds.size(), size_t(4)) - 1] + 1e-3f);
        for (const auto& pl : roots.neighbours)
            if (dist3(pl.centre, centroid_) <= keep)
                orbitBs_.push_back({{pl.centre[0], pl.centre[1], pl.centre[2]}, pl.radius});
        for (int k = 0; k < 3; ++k) orbitC_[k] = 0.f;
        for (const auto& b : orbitBs_)
            for (int k = 0; k < 3; ++k) orbitC_[k] += b.p[k] / float(orbitBs_.size());
    }
    // The radius that frames the kept set from (az, el): every structure as
    // its own bound rather than one sphere over the lot -- the hood is a
    // disc, as tall as one structure and many across, and a sphere over a
    // disc is fitted on a height it does not have.
    float orbitFitRadius(const RootScene& roots, float az, float el,
                         const RootSequenceParams& P) const {
        return fitRadius(roots, orbitC_, az, el, orbitBs_.data(), (int)orbitBs_.size(),
                         P.frame_margin);
    }

    bool   valid_ = false;
    Stage  stage_ = Stage::Face;
    double stageT0_ = 0.0;         // clock at the current stage's entry
    double clothClearAt_ = -1.0;   // first clock clothCleared was seen true, -1 until then
    float  fade_ = 0.f;
    bool   moshFired_ = false;

    rootsim::SimMask anchor_{};
    float anchorExt_ = 1.f, tightR_ = 1.f, structR_ = 1.f;
    float centroid_[3] = {0.f, 0.f, 0.f};
    float az0_ = 0.f, el0_ = 0.f;          // the Face pose, down the anchor's normal
    float growAz_ = 0.f, growEl_ = 0.f;    // the Grow pose, along the axis + tilt
    float growStepsPerSec_ = 100.f;
    float growStepAcc_ = 0.f;              // fractional steps owed, see stepGrowth
    float growTimeout_ = 30.f;
    float growWantR_ = 0.f;                // the pushed-back radius, monotonic
    float revealWantR_ = 0.f;              // Reveal's framing radius, monotonic

    // Where the Turn started from, captured at its entry.
    float turnFromAz_ = 0.f, turnFromEl_ = 0.f, turnFromR_ = 0.f;
    float turnFromT_[3] = {0.f, 0.f, 0.f};
    // The hood's centre and how far out its furthest structure stands, for
    // Orbit (see orbitBound).
    float orbitC_[3] = {0.f, 0.f, 0.f};
    std::vector<Bound> orbitBs_;

    int neighboursGen_ = -1;   // plant generation the placed structures were built for
    // Reveal's step counter (2 per structure: shown dark, then lit) and the
    // clock the last step fired at, for the fallback timer.
    int    revealStep_  = 0;
    double revealLastT_ = 0.0;

    // The camera, before the head pan and the angular clamp.
    float curAz_ = 0.f, curEl_ = 0.f, curR_ = 1.f;
    float curT_[3] = {0.f, 0.f, 0.f};
    float panAz_ = 0.f, panEl_ = 0.f;
    float prevAz_ = 0.f, prevEl_ = 0.f;
    bool  prevValid_ = false;
};
