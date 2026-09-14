// RootSequence — the root scene's timeline, as one linear state machine that
// drives the camera and the growth pacing:
//
//   Face    the anchor mask alone, tight, square to camera. The sim is held;
//           the viewer is still driving the mask (main.mm's setFittedFace).
//           Runs through Phase::Transition -- the cloth press happens on this
//           framing -- and ends only once the cloth has cleared.
//   Grow    the sim runs, one target face after another, and the camera
//           travels out with each hop: it looks down the normal of the face
//           the root is heading for, at that face (leaning toward the tip
//           while the root travels), close enough to hold just that face,
//           the tip and the face the root left. Each hop is one smooth move
//           that ends square on the face the root has just reached; the
//           whole structure is not framed until the Turn.
//   Turn    the finished chain is turned to hang: the camera rotates about
//           the structure's centre to a low elevation, framing the whole of
//           it, so the axis reads vertical on screen.
//   Orbit   the other structures -- baked variations of this plant, wearing
//           previous visitors' faces -- stand around this one on a fan
//           behind it. They all appear at once, dark, on entry, and the
//           camera starts its slow orbit of everything at once. Then each
//           Wwise marker (or the timer where no marker comes) lights the
//           next unlit structure, nearest first: its top mask comes on and
//           its pulse front starts there, and the rest of its masks light
//           in order as the front reaches them (the roots light behind the
//           front too -- see RootDrawU::pulseStart). Ends into the Outro
//           once every structure is fully lit *and* the orbit has run its
//           authored seconds. The visitor leaving changes nothing: the
//           piece runs to the end.
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
// reveal mode -- flags planned masks visible, and in Orbit places the other
// structures and steps them lit. Nothing else on the scene.
// jumpTo() is the operator's cut to the start of any stage (see its comment):
// it does to the scene what the skipped stages would have, at once.
#pragma once
#ifndef __OBJC__
#error "root_sequence.h is ObjC++ only"
#endif

#include "root_scene.h"
#include "root_sim.h"

#include <algorithm>
#include <cmath>
#include <utility>
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
    // Per-hop framing. For the hop in flight the camera looks straight down
    // the outward normal of the mask the root is heading for, at that mask,
    // from the distance that holds it, the growth tip and the mask the root
    // left (so the root's origin stays in frame) with grow_margin around
    // them. Target and radius ease with cam_ease_seconds and the angles with
    // the same ease under the angular clamp, so each hop is one travel-out
    // move that ends square on the face just reached -- the first hop's
    // swing off the Face pose (down the anchor's normal) is the same ease.
    // Nothing frames the whole structure until the Turn.
    //
    // While the root travels, the target point sits this far from the mask
    // toward the tip (0 pins the mask centre, 1 follows the tip); once the
    // root has arrived it is the mask.
    float grow_hop_lead      = 0.3f;
    // Margin around the target mask / tip / previous mask, as a fraction of
    // their extent.
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

    // --- Reveal (the lighting, inside Orbit) --------------------------------
    // Spacing of the other structures: structure k stands
    // reveal_spacing x this structure's radius x sqrt(k+1) from its centre
    // (a sunflower, so the hood packs evenly at any count). The radius is the
    // masks' bound, which the tall cone makes mostly height; at 1.2 the
    // structures interleaved and read as one tangle from the Turn-end
    // camera, and at ~2.2 each stands clear of the next while the hood is
    // still one grove inside the fog's range. A step (the next structure's
    // top mask lit and its pulse front started) happens on a Wwise marker,
    // or after this many seconds without one (markers need the SDK and a
    // bank built with cue-carrying audio, neither of which every dev
    // machine has).
    float reveal_spacing          = 2.2f;
    float reveal_fallback_seconds = 2.5f;
    // The rest of a structure's masks light as its pulse front reaches them
    // (the node distance the root arrived at each mask, against pulse speed
    // x seconds since the front started). This many seconds' extra delay on
    // each, for a front that reads as arriving a little after the numbers
    // say it has.
    float reveal_pulse_lag        = 0.f;
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
    // The framing itself. The fitted radius (every kept structure inside the
    // frustum with frame_margin) x orbit_zoom: under 1 lets the outer ones
    // run off the frame's edge so the near ones fill it -- the strict fit
    // stood so far back that the hood was a clump in the middle of the fog.
    // orbit_target_lift raises (or lowers) the point the orbit looks at, in
    // world units, off the kept set's mean.
    float orbit_zoom          = 0.55f;
    float orbit_target_lift   = 0.f;

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
    enum class Stage { Face = 0, Grow, Turn, Orbit, Outro, Done };

    // Per-frame inputs from the host, all levels for this one frame:
    //   wantOutro     skip the rest of the orbit and go out now. Only
    //                 honoured in Orbit -- the arc up to there is the piece
    //                 and runs whether or not the visitor stays. The live
    //                 show never sets it (Roots runs to Done regardless of
    //                 absence; see main.mm's Signals block); --seqshot does,
    //                 to get to the outro without waiting out the orbit.
    //   clothCleared  RootScene::clothCleared() -- the first clock it is seen
    //                 true is when Face's clear-tail timer starts.
    //   markerHit     a "fire reverb drop" cue (a FirePlucker marker) came in
    //                 this frame. The Orbit's lighting trigger: the next
    //                 structure's top mask.
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
    // whether this visit has built it yet; see enterOrbit().
    void begin(RootScene& roots, const RootSequenceParams& P) {
        stage_        = Stage::Face;
        stageT0_      = 0.0;
        clothClearAt_ = -1.0;
        fade_         = 0.f;
        moshFired_    = false;
        litNext_      = 0;
        revealLastT_  = 0.0;
        panAz_ = panEl_ = 0.f;
        prevAz_ = prevEl_ = 0.f;
        prevValid_ = false;
        // A hood still placed from a previous run on the same plant (the
        // operator re-entering the phase without a replant) starts hidden
        // and dark again, so the Orbit has something to reveal. No-ops when
        // the hood is already gone, which is the show's own case.
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
        // Tight on the face: 3.8 x its drawn half-height (faceScale x the
        // mask's unit, the mesh normalised to 1 tall). In the face's own
        // size rather than the cavity's, which now hugs the face and would
        // otherwise have moved this framing with the cavity margin.
        tightR_ = std::max(0.05f, roots.faceScale) * anchor_.faceUnit * 3.8f;

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
        // through the press and stays that way until Grow moves off.
        azelFromDir(anchor_.normal, az0_, el0_);

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
        growTimeout_ = perFace * float(hops) * std::max(1.f, P.grow_timeout_mult);

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

        // wantOutro only ever shortens the Orbit -- see Inputs.
        if (in.wantOutro && stage_ == Stage::Orbit)
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
            if (clock >= end) enter(Stage::Grow, clock);
            break;
        }
        case Stage::Grow: {
            stepGrowth(roots, fdt);

            // The hop in flight: the mask the root is heading for (or, once
            // the sim is done and the stage is about to end, the last one),
            // the mask it left, and the tip.
            const auto& pm = roots.plannedMasks();
            int cm = roots.currentMask();
            if (cm < 0 || cm >= (int)pm.size()) cm = (int)pm.size() - 1;
            const rootsim::SimMask& tm = pm[size_t(cm)];
            const rootsim::SimMask& fm = pm[size_t(std::max(0, cm - 1))];
            float tip[3];
            const bool haveTip = roots.growthTip(tip);

            // Down the target mask's own normal: the move ends looking
            // square at the face the root has just reached, and the next
            // hop's move starts from there.
            float wantAz, wantEl;
            azelFromDir(tm.normal, wantAz, wantEl);
            easeAngle(curAz_, wantAz, kEase);
            easeTo(curEl_, wantEl, kEase);

            // At the mask, leaning toward the tip while the root is still on
            // its way, so the travel is followed and the arrival settles.
            float wantT[3] = {tm.pos[0], tm.pos[1], tm.pos[2]};
            if (haveTip && !roots.arrivedAtMask()) {
                const float lead = std::clamp(P.grow_hop_lead, 0.f, 1.f);
                for (int k = 0; k < 3; ++k) wantT[k] += (tip[k] - tm.pos[k]) * lead;
            }
            for (int k = 0; k < 3; ++k) easeTo(curT_[k], wantT[k], kEase);

            // The radius that holds the target mask, the tip and the mask
            // the root left, at this frame's angles and target -- in as
            // well as out, so the camera comes in on each new face.
            Bound pts[3];
            int np = 0;
            pts[np++] = {{tm.pos[0], tm.pos[1], tm.pos[2]}, std::max(tm.rWidth, tm.rHeight)};
            pts[np++] = {{fm.pos[0], fm.pos[1], fm.pos[2]}, std::max(fm.rWidth, fm.rHeight)};
            if (haveTip) pts[np++] = {{tip[0], tip[1], tip[2]}, 0.f};
            const float need = fitRadius(roots, curT_, curAz_, curEl_, pts, np, P.grow_margin);
            easeTo(curR_, std::max(need, tightR_), kEase);

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
            if (u >= 1.f) { enter(Stage::Orbit, clock); enterOrbit(roots, P, clock); }
            break;
        }
        case Stage::Orbit:
        case Stage::Outro: {
            // The hood is standing, dark; the lighting runs on markers while
            // the camera orbits. Orbit everything: azimuth advancing,
            // elevation, target and radius eased in to the orbit's own
            // framing from the Turn-end pose. The orbit keeps running
            // through the outro -- the datamosh reads camera motion, and a
            // camera that froze the moment it fired would have nothing to
            // smear -- and so does the lighting, so a structure caught
            // mid-front is not left half dark.
            stepGrowth(roots, fdt);
            stepLighting(roots, P, in, clock);
            const float wantEl = P.orbit_elevation_deg * kDeg;
            curAz_ += P.orbit_rate * fdt;
            easeAngle(curEl_, wantEl, kEase);
            float wantT[3];
            orbitTarget(P, wantT);
            for (int k = 0; k < 3; ++k) easeTo(curT_[k], wantT[k], kEase);
            easeTo(curR_, orbitRadius(roots, curAz_, wantEl, P), kEase);

            if (stage_ == Stage::Orbit) {
                // Both: the orbit's seconds, and every structure lit to its
                // last mask -- a hood still lighting is not over.
                if (tIn >= (double)P.orbit_seconds && allLit(roots)) enter(Stage::Outro, clock);
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

    // Cut to the start of a stage, for the operator dialling in a look on a
    // frame the show would otherwise take minutes to reach (the panel's
    // `show/roots` jump row; pause holds the frame once it lands). Everything
    // the earlier stages would have done to the scene is done here at once,
    // and everything a later stage did is undone:
    //
    //   Face    the plant back to its seed (RootScene::resetGrowth -- faces
    //           and cloth kept), camera on the Face pose.
    //   Grow    the cloth retired if it is still up, the plant reseeded, hop
    //           1 about to start off the Face pose.
    //   Turn    the whole chain grown now (RootScene::finishGrowth), camera
    //           on the pose Grow ends on, the Turn about to begin.
    //   Orbit   ...and the hood placed (all structures visible, dark), the
    //           camera snapped to the orbit's own framing (the pose the show
    //           eases into over cam_ease_seconds), and the lighting running
    //           from the first structure on markers / the fallback timer
    //           exactly as in the show.
    //   Outro   as Orbit with every structure lit; the datamosh fires on
    //           the next step().
    //
    // Every pose is snapped: no ease, no angular clamp on the cut. `clock` is
    // the host's sequence clock, as for step(); the stage's own time starts
    // from it. Nothing happens when the sequence is not valid.
    void jumpTo(Stage s, RootScene& roots, const RootSequenceParams& P, double clock) {
        if (!valid_ || s == Stage::Done) return;
        jumpState(s, roots, P, clock);
        // The pose onto the scene now, not at the next step(): a jump made
        // while the host holds the scene (pause) has to show.
        roots.target[0] = curT_[0];
        roots.target[1] = curT_[1];
        roots.target[2] = curT_[2];
        roots.radius    = std::max(0.1f, curR_);
        roots.azimuth   = curAz_;
        roots.elevation = std::clamp(curEl_, -1.5f, 1.5f);
    }
private:
    void jumpState(Stage s, RootScene& roots, const RootSequenceParams& P, double clock) {

        // Nothing before Done is faded or moshing; the head pan and the
        // angular clamp start over from the cut.
        roots.renderer().cancelDatamosh();
        fade_ = 0.f;
        moshFired_ = false;
        panAz_ = panEl_ = 0.f;
        prevValid_ = false;
        roots.autoFrame = false;

        // Going back to before the chain exists, or restarting Grow, is a
        // reseed; so is coming back from a placed hood to a stage before
        // Orbit, since the Orbit re-places the hood only for a new
        // generation and the plant is the cheap part of that.
        const bool reseed = s == Stage::Face ||
                            (s == Stage::Grow && stage_ != Stage::Face) ||
                            (s <= Stage::Turn && neighboursGen_ == roots.growGeneration());
        if (reseed) roots.resetGrowth();

        // The Face pose is where every stage starts from.
        curAz_ = az0_; curEl_ = el0_; curR_ = tightR_;
        for (int k = 0; k < 3; ++k) curT_[k] = anchor_.pos[k];
        growStepAcc_ = 0.f;
        clothClearAt_ = -1.0;

        if (s == Stage::Face) {
            roots.simPaused = true;
            enter(Stage::Face, clock);
            return;
        }
        // Grow onward: the film is over.
        if (roots.clothActive()) roots.skipCloth();
        if (s == Stage::Grow) { enter(Stage::Grow, clock); return; }

        // Turn onward: the chain is complete and the camera is where Grow
        // left it.
        roots.finishGrowth();
        roots.simPaused = true;
        growEndPose(roots, P);
        turnFromAz_ = curAz_; turnFromEl_ = curEl_; turnFromR_ = curR_;
        for (int k = 0; k < 3; ++k) turnFromT_[k] = curT_[k];
        if (s == Stage::Turn) { enter(Stage::Turn, clock); return; }

        // Orbit onward: the Turn's end pose (the hood is placed from it),
        // the hood standing dark with its lighting about to start, then the
        // camera snapped onto the orbit's framing -- the same fit step()
        // eases into, so the jump shows the frame the show settles on.
        turnEndPose(roots, P);
        enter(s == Stage::Orbit ? Stage::Orbit : Stage::Outro, clock);
        enterOrbit(roots, P, clock);
        curEl_ = P.orbit_elevation_deg * kDeg;
        orbitTarget(P, curT_);
        curR_ = orbitRadius(roots, curAz_, curEl_, P);
        if (s == Stage::Outro) {
            // Everything lit, no fronts: the outro's own frame.
            for (int k = 0; k < (int)roots.neighbours.size(); ++k) roots.setStructureLit(k, true);
            litNext_ = (int)litOrder_.size();
        }
    }
public:

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

    // Orbit's entry, from the Turn-end pose: the hood placed (once per
    // plant generation -- placement re-bakes every structure into fresh GPU
    // buffers and only needs redoing when what it reads has changed, and
    // replant() bumps the generation having dropped the last visitor's
    // hood; the variations behind it are cached one level down, in
    // RootScene, and survive the replant), every structure visible and
    // dark, the lighting order drawn and its clock started, and what the
    // orbit frames decided.
    void enterOrbit(RootScene& roots, const RootSequenceParams& P, double clock) {
        if (neighboursGen_ != roots.growGeneration()) placeHood(roots, P);
        // A hood already standing (a jump back into Orbit) starts over: all
        // of it visible and dark.
        for (int k = 0; k < (int)roots.neighbours.size(); ++k) {
            roots.setStructureVisible(k, true);
            roots.setStructureLit(k, false);
        }
        // The lighting order: nearest structure first, so what lights first
        // is what is in front. Fixed by the placement, so a rerun lights the
        // same structures in the same order.
        litOrder_.clear();
        for (int k = 0; k < (int)roots.neighbours.size(); ++k) litOrder_.push_back(k);
        std::sort(litOrder_.begin(), litOrder_.end(), [&](int a, int b) {
            return dist3(roots.neighbours[size_t(a)].centre, centroid_) <
                   dist3(roots.neighbours[size_t(b)].centre, centroid_);
        });
        litNext_     = 0;
        revealLastT_ = clock;
        orbitBound(roots, P);
    }
    // Place the other structures about this one from the current pose, all
    // hidden and dark (enterOrbit shows them).
    void placeHood(RootScene& roots, const RootSequenceParams& P) {
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
    }
    // The lighting, one frame: a marker (or the fallback timer) lights the
    // next structure in litOrder_ -- its top mask on, its roots allowed lit,
    // its pulse front started at the renderer's pulse clock -- and then
    // every started structure's remaining masks light, in order, as its
    // front reaches the node distance the root arrived at them
    // (NeighbourPlacement::maskDist), reveal_pulse_lag seconds later. With
    // pulses that do not travel (speed 0) there is no front to wait for:
    // the whole structure lights on its marker.
    void stepLighting(RootScene& roots, const RootSequenceParams& P, const Inputs& in,
                      double clock) {
        const int n = (int)litOrder_.size();
        const bool fire = in.markerHit ||
                          (clock - revealLastT_) >= std::max(0.1, (double)P.reveal_fallback_seconds);
        const float speed = roots.renderer().pulse.speed;
        if (fire && litNext_ < n) {
            const int k = litOrder_[size_t(litNext_)];
            if (speed > 1e-3f) {
                roots.setStructureRootsLit(k, true);
                roots.setStructurePulseStart(k, roots.pulseClock());
                roots.setStructureMaskLit(k, 0, true);
            } else {
                roots.setStructureLit(k, true);
            }
            ++litNext_;
            revealLastT_ = clock;
        }
        if (speed <= 1e-3f) return;
        const float now = roots.pulseClock();
        for (int k = 0; k < (int)roots.neighbours.size(); ++k) {
            const auto& np = roots.neighbours[size_t(k)];
            if (np.pulseStart < 0.f) continue;
            const float head = speed * (now - np.pulseStart - std::max(0.f, P.reveal_pulse_lag));
            for (int j = 1; j < np.maskCount(); ++j) {
                if (np.maskLit[size_t(j)]) continue;
                const float at = j < (int)np.maskDist.size() ? np.maskDist[size_t(j)]
                                                             : float(j) * roots.renderer().pulse.hopOffset;
                if (head >= at) roots.setStructureMaskLit(k, j, true);
            }
        }
    }
    // Every structure lit to its last mask (a hood of none is).
    static bool allLit(const RootScene& roots) {
        for (const auto& np : roots.neighbours)
            if (!np.allMasksLit()) return false;
        return true;
    }
    // The orbit's own framing: its target (the kept set's mean, lifted) and
    // the radius that fits the kept set from (az, el) x orbit_zoom, capped.
    void orbitTarget(const RootSequenceParams& P, float out[3]) const {
        out[0] = orbitC_[0];
        out[1] = orbitC_[1] + P.orbit_target_lift;
        out[2] = orbitC_[2];
    }
    float orbitRadius(const RootScene& roots, float az, float el,
                      const RootSequenceParams& P) const {
        return std::min(orbitFitRadius(roots, az, el, P) * std::max(0.05f, P.orbit_zoom),
                        std::max(1.f, P.orbit_max_radius));
    }
    // The pose Grow's last hop settles on once the root has arrived: square
    // on the last mask, at it, far enough out to hold it, the mask before it
    // and the tip. Snapped into cur*, for jumpTo.
    void growEndPose(const RootScene& roots, const RootSequenceParams& P) {
        const auto& pm = roots.plannedMasks();
        if (pm.empty()) return;
        const rootsim::SimMask& tm = pm.back();
        const rootsim::SimMask& fm = pm[pm.size() >= 2 ? pm.size() - 2 : 0];
        azelFromDir(tm.normal, curAz_, curEl_);
        for (int k = 0; k < 3; ++k) curT_[k] = tm.pos[k];
        Bound pts[3];
        int np = 0;
        pts[np++] = {{tm.pos[0], tm.pos[1], tm.pos[2]}, std::max(tm.rWidth, tm.rHeight)};
        pts[np++] = {{fm.pos[0], fm.pos[1], fm.pos[2]}, std::max(fm.rWidth, fm.rHeight)};
        float tip[3];
        if (roots.growthTip(tip)) pts[np++] = {{tip[0], tip[1], tip[2]}, 0.f};
        curR_ = std::max(fitRadius(roots, curT_, curAz_, curEl_, pts, np, P.grow_margin), tightR_);
    }
    // The pose the Turn ends on: the Grow azimuth, the authored low
    // elevation, the whole structure framed about its centre. Snapped.
    void turnEndPose(const RootScene& roots, const RootSequenceParams& P) {
        const Bound whole = {{centroid_[0], centroid_[1], centroid_[2]}, structR_};
        curAz_ = turnFromAz_;
        curEl_ = P.turn_end_elevation_deg * kDeg;
        for (int k = 0; k < 3; ++k) curT_[k] = centroid_[k];
        curR_ = fitRadius(roots, centroid_, curAz_, curEl_, &whole, 1, P.frame_margin);
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
        float t[3];
        orbitTarget(P, t);
        return fitRadius(roots, t, az, el, orbitBs_.data(), (int)orbitBs_.size(),
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
    float growStepsPerSec_ = 100.f;
    float growStepAcc_ = 0.f;              // fractional steps owed, see stepGrowth
    float growTimeout_ = 30.f;

    // Where the Turn started from, captured at its entry.
    float turnFromAz_ = 0.f, turnFromEl_ = 0.f, turnFromR_ = 0.f;
    float turnFromT_[3] = {0.f, 0.f, 0.f};
    // The hood's centre and how far out its furthest structure stands, for
    // Orbit (see orbitBound).
    float orbitC_[3] = {0.f, 0.f, 0.f};
    std::vector<Bound> orbitBs_;

    int neighboursGen_ = -1;   // plant generation the placed structures were built for
    // The Orbit's lighting order -- structures, nearest first -- the next
    // one to light, and the clock the last one lit at, for the fallback
    // timer.
    std::vector<int> litOrder_;
    int    litNext_     = 0;
    double revealLastT_ = 0.0;

    // The camera, before the head pan and the angular clamp.
    float curAz_ = 0.f, curEl_ = 0.f, curR_ = 1.f;
    float curT_[3] = {0.f, 0.f, 0.f};
    float panAz_ = 0.f, panEl_ = 0.f;
    float prevAz_ = 0.f, prevEl_ = 0.f;
    bool  prevValid_ = false;
};
