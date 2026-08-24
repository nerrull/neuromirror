// RootScene — the 3D lit root scene. Owns a MetalRootRenderer, an orbit camera,
// and (for now) a procedurally generated branching structure standing in for the
// live CPlantBox growth (Task: sdfsim wiring). advance() spins the camera and
// drives the fog/pulse/wisp clocks; render() encodes the two Metal passes into the
// caller's command buffer and returns the fogged colour texture to present.
#pragma once
#ifndef __OBJC__
#error "root_scene.h is ObjC++ only"
#endif

#import <Metal/Metal.h>
#include "metal_root_renderer.h"
#include "root_sim.h"
#include "cloth.h"

#include <cmath>
#include <memory>
#include <string>
#include <vector>

class MetalContext;

class RootScene {
public:
    explicit RootScene(const MetalContext& ctx, int w = 1280, int h = 720);

    bool valid() const { return rr_ && rr_->valid(); }

    void ensureSize(int w, int h);
    void advance(double dt);
    id<MTLTexture> render(id<MTLCommandBuffer> cb);

    double clock() const { return t_; }
    int    width()  const { return rr_ ? rr_->width() : 0; }
    int    height() const { return rr_ ? rr_->height() : 0; }

    MetalRootRenderer& renderer() { return *rr_; }

    // A new random seed for the growth. Reseeds the *simulation* when one is
    // running -- the synthetic branching structure below is a fallback for when
    // CPlantBox's parameter files are missing, not something to drop on top of
    // a live grow.
    void reseed(uint32_t seed);

    // Rebuild + re-upload the face mask mesh (call after changing faceScale /
    // showFace / face placement).
    void rebuildFace();

    // --- live face fitting ---------------------------------------------------
    // Replace the static canonical_face_model.obj with a mesh fitted to whoever
    // is in front of the sensor (see face_fit.h). `verts` is 3 floats/vertex in
    // the fitter's model units; `tris` is its topology, and may be passed empty
    // on subsequent calls to keep the previous one.
    //
    // The normalisation is captured once, from the first mesh seen, and reused:
    // re-normalising per frame would rescale the mask every time the person
    // opened their mouth, since an expression changes the mesh's extent. So the
    // mask holds still and the face moves inside it, which is the intent.
    void setFittedFace(const std::vector<float>& verts, const std::vector<int>& tris);

    // A different face on every mask, sampled from the morphable basis.
    //
    // Test data, and there is no photo set in the repo to fit instead -- but
    // sampling the basis is the better test anyway: it is the same generator
    // the fitter projects onto, the identities are reproducible from a seed,
    // and nobody's face is in the repository. `amount` scales the sampled
    // coefficients: 0 is twelve copies of the neutral mask, 1 is about the
    // spread a room of strangers covers.
    //
    // Returns the per-face identity coefficients, so a layout that places by
    // resemblance can be driven by the same numbers the faces were built from.
    std::vector<std::vector<float>> setTestIdentities(int n, unsigned seed, float amount);
    void clearTestIdentities();
    void clearFittedFace();
    bool usingFittedFace() const { return fitted_face_; }

    // Per-vertex RGB for the fitted mesh (3 floats/vertex, [0,1]), sampled from
    // the neural mirror by FaceFitter::sampleTexture. Empty reverts the mask to
    // its flat material colour.
    //
    // This is deliberately a *stored* colour rather than a live texture lookup.
    // The mirror and the roots never run at the same time -- only one sim runs
    // at a time by design -- so by the time the root scene is drawing, the
    // mirror has stopped and there is no live neural texture left to sample.
    // Capturing it at the handoff is what lets the mask keep the face.
    void setFaceColors(const std::vector<float>& rgb);
    bool hasFaceColors() const { return !faceColors_.empty(); }

    // --- camera ------------------------------------------------------------
    // Frame the scene from its own bounds rather than from constants: the cone
    // is sized by R0/Hh, so any change to those left hardcoded framing pointing
    // at the wrong part of it. `focusMask` >= 0 centres on one revealed mask
    // and frames tight to its radius, orbiting on its own angle -- reusing the
    // whole-scene arc would swing a mask out of frame, since that arc is
    // centred on the piece and not on the mask.
    bool  autoFrame = true;
    int   focusMask = -1;      // -1 = whole scene
    // A cluster of masks rather than one: masks [g*size, (g+1)*size) of the
    // rosette/lobe grouping. The middle shot between a face and the whole piece.
    int   focusGroup = -1;
    int   focusGroupSize = 3;
    float zoom      = 1.0f;

    // Frame on the masks, not on every root node.
    //
    // The roots trail: a couple of laterals hanging a long way below the last
    // nest drag the bounding box down and the whole piece shrinks into the
    // middle of the frame to accommodate two threads nobody is looking at. The
    // masks are what the shot is about, so they are what it is framed on --
    // their centroid, and an extent that covers them with a margin. Roots
    // outside that are allowed to leave the frame.
    // On a single mask, put the camera on that mask's own normal.
    //
    // Without it the "face alone" shot inherits whatever azimuth the whole-piece
    // orbit was on, which on a cylinder or a sphere routinely means looking at
    // the back of the head through the far wall of the structure. A face is a
    // thing with a front; framing it means standing in front of it.
    // The face the shot is built around. While it is set the camera target
    // stays on that mask and only the radius changes, so a pull-back expands
    // the world around a face that never leaves the centre of frame -- which is
    // the move the piece is made of, and not something a cut between framings
    // can imitate.
    // Defaults to 0: RootSim now places mask 0 at one fixed, known transform
    // (see root_sim.cpp's anchor-first placement in reset()) specifically so
    // there is always an unambiguous "the anchor" to build a camera -- and,
    // per the cloth work, a collider frame -- against. -1 still opts back out
    // to the old "whole scene" framing for callers that want it.
    int   anchorMask   = 0;
    // Seconds for the camera to converge on a new shot. 0 snaps, which is what
    // the stills want; anything above about 0.3 reads as a move.
    float camEase      = 0.f;
    bool  faceOnFocus  = true;
    bool  frameOnMasks = true;
    // Frame on the layout rather than on what has been revealed so far.
    bool  frameOnPlanned = true;
    // Margin around the mask bound, as a fraction of its extent.
    float frameMargin  = 0.35f;
    int   maskCount() const { return (int)revealedMasks().size(); }
    // Centre/radius covering a set of revealed masks; false when none of them
    // have been revealed yet.
    bool  maskBound(const std::vector<int>& idx, float centre[3], float& radius) const;

    // Restart the live CPlantBox growth (no-op if the sim failed to load).
    void regrow();
    // A fresh plant for a fresh visitor: the same structure, back to ungrown.
    //
    // Distinct from regrow() only in that it keeps the cached growth-step
    // estimate, because the parameters have not changed -- and recomputing
    // that estimate means running a whole throwaway growth to completion,
    // which is the per-visitor cost 9bc816a cached away in the first place.
    // regrow() stays the one to call when the parameters really did change.
    void replant();
    // The growth parameters, editable in place; call regrow() to apply. Held
    // here rather than rebuilt at each call site so a species change and a
    // seed change go through the same door.
    rootsim::SimParams& simParams() { return simParams_; }
    const rootsim::SimParams& simParams() const { return simParams_; }
    // How many sim steps a full growth run takes for the current simParams_,
    // for pacing the live beat schedule against (see RootCameraSequence::
    // begin()). Computed once by actually growing a throwaway sim to
    // completion, then cached -- it used to be recomputed the same way on
    // every entry into the Roots phase (i.e. every visitor), which meant
    // paying for an entire extra full growth simulation, discarded, once per
    // show loop. Invalidated by regrow(), the only thing that changes what
    // this number should be.
    int growthStepEstimate() const;
    // Bumped by regrow(); the plant's geometry (and therefore anything
    // derived from it, e.g. RootCameraSequence's neighbour hood) is only
    // actually different after that. Callers that cache work keyed on the
    // current growth can skip redoing it while this hasn't changed instead of
    // redoing it on every visitor.
    int growGeneration() const { return growGeneration_; }
    // Species available to the sim: display name and parameter file, mirroring
    // the reference GUI's list.
    static const std::vector<std::pair<std::string, std::string>>& species();
    int  speciesIndex() const;
    void setSpeciesIndex(int i);

    // --- presets -----------------------------------------------------------
    // There is no scene-specific preset file any more. Growth parameters are
    // declared to the parameter registry like everything else and saved with
    // the `roots` bank, so one file is the whole of a root look rather than the
    // subset that happened to be in the panel plus the subset that happened to
    // be in visitSimParams. See ui_params.h.
    bool simActive() const { return useSim_; }
    // The revealed masks, in render space. Exposed so the frames the faces are
    // placed on can be checked as numbers -- their orientation is not reliably
    // readable off a render at the scale they occupy.
    const std::vector<rootsim::SimMask>& revealedMasks() const;
    // Every mask the layout will place, revealed or not -- what the camera
    // frames on, so the shot does not step every time one lands.
    const std::vector<rootsim::SimMask>& plannedMasks() const;
    bool simDone()   const;

    // Grow one system, then cache it and tile a gridN x gridN field of instances
    // (varied yaw/scale) to exercise LOD + frustum culling. Stops the live path.
    // Hold the growth where it is without tearing anything down: the opening
    // beat of the pull-back is a face that has not grown yet.
    bool  simPaused = false;

    // --- the mask deal-out --------------------------------------------------
    // Draw every mask the layout will place, not only the ones a root has
    // reached, and slide them out of the first mask into position.
    //
    // The piece opens on one face; the rest of the structure arriving is a
    // move in its own right, before anything grows. `maskDeal` is how far out
    // they have travelled: 0 puts all of them on top of the first mask, 1 puts
    // each at its own place. Position only -- each mask keeps its own frame the
    // whole way, so they face outward as they arrive rather than swinging round.
    bool  showPlannedMasks = false;
    float maskDeal = 1.f;
    // Copies of the structure standing around this one need faces too: the
    // instance path carries capsules only, so the masks have to be emitted into
    // the shared face mesh, transformed the same way the geometry was.
    struct NeighbourPlacement { float translate[3]; float rotYaw; float scale; };
    std::vector<NeighbourPlacement> neighbours;

    // Where the growth currently is, in render space; false when nothing is
    // growing. For a camera that follows the tip instead of the structure.
    bool  growthTip(float out[3]) const;
    // The hop in flight: the mask it is heading for, and whether it got there.
    int   currentMask() const;
    bool  arrivedAtMask() const;
    void buildField(int gridN, float spacing);
    // Copies of the grown system standing around this one, as cached instances.
    // Unlike buildField this keeps the live system and its faces -- it is the
    // last beat of the pull-back, where the piece turns out to be one of many.
    // `centre` is the middle of the ring in world space -- the structure hangs
    // below the origin, so a ring about the origin puts neighbours level with
    // nothing. `keepClearAz` is the camera's azimuth: placements within a wedge
    // of it are skipped, or a neighbour lands between the camera and the piece
    // and fills the frame with a wall.
    void addNeighbours(int count, float ringRadius, unsigned seed,
                       const float centre[3], float keepClearAz);

    // --- the cloth: pond -> face press/release, ported from TransitionScene ---
    //
    // One mask, one placement (see the file header and root_sim.cpp's
    // anchor-first reset()): the cloth presses against and drapes off the
    // *same* anchor mask RootScene already places and shades, in the anchor's
    // own fixed (tangent, bitangent, normal) frame -- an affine placement,
    // not TransitionScene's perspective one, because that frame is fixed and
    // known rather than solved per frame from a moving camera. See
    // root_scene.mm's advanceCloth/rasteriseClothField/packClothMesh.
    struct ClothTiming {
        float hold    = 0.5f;   // flat film, nothing happening
        float press   = 1.6f;   // the mask advancing through the sheet plane
        float settle  = 8.0f;   // fully through, the fabric taut over it
        float release = 0.7f;   // pins letting go, corners first
        float fall    = 1.8f;   // draping off and away
    };
    ClothTiming clothTiming;

    // How far, in the anchor's own local units, the cloth's average depth has
    // to recede past the mask's own front surface before it counts as
    // "cleared" -- see TransitionScene::clothCleared(), same intent.
    float clothClearDistance = 1.5f;
    float sideForceDelay = 17.0f;
    float sideForceMag   = 4.0f;
    bool  clothCleared() const { return clothClearanceVal_ >= clothClearDistance; }
    float clothClearance() const { return clothClearanceVal_; }

    bool  showCloth     = true;
    // The sheet, as a multiple of the frustum cross-section it has to cover.
    //
    // The sheet *is* the pond: the opening frame of the press has to be the
    // mirror's own image, edge to edge, which means the sheet is sized by the
    // camera looking at it and not by the mask in the middle of it. Sizing it
    // off the mask instead (an earlier version of this port did) is what makes
    // it fail to reach the corners and, because a face then spans half the
    // sheet's width against a pinned border a face-width away, what turns the
    // press into a radial spike burst rather than a drape.
    //
    // So: exactly TransitionScene's own sizing, against RootScene's camera
    // rather than a fixed one -- see ensureClothSheet. 1.08 is its oversize
    // too, and the margin has to stay small for a second reason: the uv runs
    // the film across the sheet's *whole* extent, so everything past 0..1
    // clamps to the film's edge pixels, and a large overhang is a wide smeared
    // border rather than more pond.
    float clothOversize = 1.08f;
    // How far the anchor mask comes *proud* of the sheet's rest plane at the
    // end of the press, in the anchor's local units, as a fraction of its own
    // placed half-width.
    //
    // The mask's resting cavity placement leaves its frontmost point barely
    // through that plane (a tenth of a unit on a face nearly four across), so
    // pressing only as far as "where it already belongs" tents the film by
    // almost nothing and the face never reads through it. This is a transient
    // offset on the same single resting placement -- not a second resting
    // depth -- so it costs nothing to keep in sync: it ramps in over the press,
    // holds through the settle, and unwinds over the release as the mask
    // retreats to exactly its cavity placement and the film slides off.
    float clothPressProud = 0.22f;
    float clothGravityBack = 6.0f;   // along -normal, behind the mask
    float clothGravityDown = 0.0f;   // along -bitangent (world down, for the anchor pose)
    float clothFriction = 0.07f;
    float clothSkin     = 0.012f;
    float clothStretch    = 0.80f;
    float clothStretchMax = 1.90f;
    float clothPlastic    = 2.0f;
    float clothDamping    = 0.985f;
    int   clothSubsteps   = 2;
    int   clothIterations = 24;
    int   clothSheetRes   = 72;

    // The film -- MirrorScene's own live output, or the frozen mirror during
    // Roots proper. Set every frame by the caller; see RootScene::render(),
    // which hands it straight to the renderer's cloth pass.
    void setPondTexture(id<MTLTexture> pond) { pondTex_ = pond; }

    // Begin the hold->press->settle->release->fall timeline from t=0, with a
    // fresh, fully-pinned flat sheet -- the RootScene analogue of
    // TransitionScene::restart(). Call once, on the phase edge that used to
    // call trans.restart().
    void restartCloth();
    // Retire the cloth without playing it: the mask is simply already
    // uncovered. This is what entering Roots directly has to do -- the
    // operator jumping straight to the root scene is asking for the state
    // *after* the press, not for the press again -- and it is also the honest
    // way to express "there is no film here", rather than leaving a sheet
    // active and relying on nothing ever drawing it.
    void skipCloth();
    double clothClock() const { return clothT_; }
    float clothPress() const;      // 0..1, how far the mask has come through
    float clothRelease() const;    // 0..1, how far the release front has run
    bool  clothDone() const;
    const char* clothPhaseName() const;
    const Cloth& cloth() const { return cloth_; }

    bool  showFace  = true;
    float faceScale = 0.85f;
    // How deep the face sits inside its cavity, in multiples of the cavity's
    // half-depth along the mask normal. The roots dwell around the cavity, so
    // the further back the face sits the more of it the nest closes over; 0
    // centres it on the cavity and a negative value pushes it proud of the
    // surface. 0.5 is the original placement.
    float faceRecess = 0.5f;
    int   simStepsPerFrame = 2;   // growth steps advanced per rendered frame

    // Camera / lighting (mirrors mask_relay_gui's controls).
    float azimuth   = 0.6f;
    float elevation = 0.35f;
    float radius    = 42.0f;
    // Field of view. Held as a focal length because that is the number that
    // means something: "17.5 mm" says wide-angle to anyone who has held a
    // camera, where "0.6 radians of vertical half-angle" says nothing. The
    // sensor is 35 mm full frame (24 mm tall, so 12 mm half-height), and
    // fov = atan(12 / focal). The raw angle is still there for when a specific
    // one is wanted.
    static constexpr float kSensorHalfMM = 12.0f;
    float focalMM   = 17.5f;   // == the old fov of 0.6 rad, to the pixel
    bool  useFocal  = true;
    float fov       = 0.6f;
    float effectiveFov() const {
        return useFocal ? std::atan(kSensorHalfMM / std::max(focalMM, 1.0f)) : fov;
    }
    // A short lens with the barrel distortion a short lens actually has. Without
    // the distortion, shortening the focal length only widens a rectilinear
    // crop, which reads as stepping backwards rather than as changing lens.
    void setWideAngle(bool on);
    // Negative Y: the system hangs below the seed at the origin. autoFrame
    // replaces this from the geometry's own bounds every advance(); it is the
    // starting frame for the first render and for the fixed-camera shot paths.
    float target[3] = {0.f, -8.f, 0.f};
    float lightDir[3] = {0.4f, 0.8f, 0.35f};
    bool  autoOrbit = true;
    float orbitRate = 0.15f;   // rad/s

private:
    void buildSyntheticRoots(uint32_t seed);
    void uploadFaceFromMasks();      // build face verts from the live sim's masks

    // --- cloth internals (see the public section above) --------------------
    void refreshClothAnchor();       // cache the anchor mask's frame for this frame
    void ensureClothSheet();         // (re)build cloth_/clothField_ on a size change
    void measureClothFaceDepth();    // faceVerts_' own local z extent, per press
    float anchorFrontLocalZ() const; // the mask's frontmost point, anchor-local
    void rasteriseClothField();      // the anchor's placed face -> the collider depth map
    void updateClothClearance();
    void packClothMesh();            // cloth_ -> interleaved buffer -> rr_->uploadClothMesh
    void advanceCloth(double dt);

    Cloth     cloth_;
    MaskField clothField_;
    id<MTLTexture> pondTex_ = nil;
    double clothT_ = 0.0;
    bool   clothActive_ = false;     // false until restartCloth() is called
    float  clothPressOffset_ = 0.f;  // current retraction of the anchor along -normal
    float  clothClearanceVal_ = -1e9f;
    int    clothBuiltRes_ = 0;
    float  clothBuiltOversize_ = 0.f;
    // The sheet's half-extents, in the anchor's local frame. Rectangular, and
    // aspect-correct: the film is a screen-shaped image and a square sheet
    // would stretch it. Frozen for the whole run of one press (see
    // ensureClothSheet) so a camera move cannot rebuild -- and so reset -- a
    // sheet that is mid-fall.
    float  clothHalfX_ = 1.f, clothHalfY_ = 1.f;
    bool   clothExtentFrozen_ = false;
    // Where the sheet's own centre sits, on the anchor's plane. The point the
    // camera is actually looking through, not the anchor's position.
    //
    // These are the same point only when the camera has settled on the anchor,
    // and live it routinely has not: g_root_authored_camera is off by default,
    // so applyFraming drives the camera, and applyFraming *eases* -- target
    // converges exponentially from wherever the previous phase left it (the
    // default is {0,-8,0}). A sheet centred on the anchor while the camera is
    // still looking below and beside it reads as the film sitting up and to
    // one side, with the far corner running off the end of its own uv and
    // smearing the film's edge pixels. Following the view axis instead makes
    // the sheet cover the frame by construction, whatever the camera is doing
    // and wherever the anchor ends up.
    simd_float3 clothCentre_ = simd_make_float3(0, 0, 0);
    // The face model's own local z extent, measured from the mesh actually
    // uploaded rather than estimated. Feeds both the press retraction (how far
    // behind the sheet the mask starts) and the clearance signal (where the
    // mask's front surface is), which the first version of this port
    // approximated with two constants -- one of which put the clearance out by
    // enough that clothCleared() never fired at all.
    float  clothFaceZMin_ = 0.f, clothFaceZMax_ = 0.f;
    // The anchor mask's frame, refreshed once per advance() -- fixed by
    // construction (root_sim.cpp's anchor-first reset()) but read from the sim
    // rather than hardcoded, so a future change to the anchor pose does not
    // silently desync the cloth from the mask it is meant to collide with.
    simd_float3 clothAnchorPos_ = simd_make_float3(0, 0, 0);
    simd_float3 clothAnchorN_   = simd_make_float3(0, 0, 1);
    simd_float3 clothAnchorT_   = simd_make_float3(1, 0, 0);
    simd_float3 clothAnchorB_   = simd_make_float3(0, 1, 0);
    float clothAnchorRW_ = 2.6f, clothAnchorRH_ = 2.6f, clothAnchorRD_ = 2.6f;

    std::unique_ptr<MetalRootRenderer> rr_;
    std::unique_ptr<rootsim::RootSim>  sim_;
    rootsim::SimParams simParams_;
    mutable int growthStepEstimate_ = -1;   // -1 = not computed yet; see growthStepEstimate()
    int growGeneration_ = 0;                // see growGeneration()
    bool useSim_ = false;
    // Whether CPlantBox is usable at all. Distinct from useSim_, which also
    // goes false when a cached instance field takes over the renderer -- and
    // reseeding after that must not silently fall back to the stand-in.
    bool simAvailable_ = false;
    std::vector<float> faceVerts_;   // face model, local, normalised (3/vert)
    std::vector<int>   faceTris_;    // triangle indices
    // The canonical model, kept so clearFittedFace() can go back to it without
    // re-reading the .obj.
    std::vector<float> canonVerts_;
    // Per-mask meshes, when the masks are not all the same face. Empty means
    // every mask draws faceVerts_, which is the live/fitted case.
    std::vector<std::vector<float>> maskVerts_;
    float idleCentre_[3] = {0.f, 0.f, 0.f};
    float idleExtent_ = 10.f;
    float focusAngle_ = 0.f;
    void  updateBounds(const std::vector<float>& nodes);
    void  applyFraming(double dt = 0.0);
    bool  camPrimed_ = false;   // false until the first frame has snapped
    bool  facesUploaded_ = false;
    std::vector<int>   canonTris_;
    std::vector<float> faceColors_;   // per-vertex RGB, empty = flat material
    bool  fitted_face_ = false;
    bool  fit_norm_set_ = false;     // normalisation captured from the first fit
    float fit_centre_[3] = {0, 0, 0};
    float fit_scale_ = 1.0f;
    double t_ = 0.0;
};
