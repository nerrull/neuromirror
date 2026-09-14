// RootScene — the 3D lit root scene. Owns a MetalRootRenderer, an orbit camera,
// and (for now) a procedurally generated branching structure standing in for the
// live CPlantBox growth (Task: sdfsim wiring). advance() spins the camera and
// drives the fog/pulse clocks; render() encodes the two Metal passes into the
// caller's command buffer and returns the fogged colour texture to present.
#pragma once
#ifndef __OBJC__
#error "root_scene.h is ObjC++ only"
#endif

#import <Metal/Metal.h>
#include "metal_root_renderer.h"
#include "root_sim.h"
#include "cloth.h"
#include "face_capture.h"

#include <algorithm>
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
    // dt of 0 is a held frame: none of the clocks (fog drift, pulses, the
    // datamosh's postTime) move, the cloth is not stepped -- a zero-dt cloth
    // step would still run its constraint projection and go on relaxing --
    // and the sim runs only if simPaused is off. Everything that reads the
    // scene's *parameters* (lighting, framing, fog anchors, the face upload,
    // the cloth's pack) still runs, so a panel change shows on the held
    // frame. main.mm's pause uses this.
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
    //
    // This, setFaceColors and clearFittedFace only ever touch mask 0 -- the
    // anchor, the current visitor. Every other mask wears a face from the
    // bank (below), or mask 0's face when its slot is empty.
    void setFittedFace(const std::vector<float>& verts, const std::vector<int>& tris);

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

    // --- the face bank -----------------------------------------------------
    // Previous visitors, on the other masks. `bank` is what main.mm loaded
    // from captures/ (face_capture.h), *newest first* and without the sitting
    // now on mask 0. It is dealt out per the plan's "face bank":
    //
    //   - masks 1..N-1 (the chain the root grows through) wear bank[0..N-2];
    //   - what is left is dealt N per structure, newest first, to the other
    //     structures Reveal stands around this one: floor(older / N) of
    //     them, at most `maxStructures`. A bank too young for even one is
    //     shown `minStructures` structures instead, repeating what there is.
    //
    // A slot the bank cannot fill repeats what exists -- and with an empty
    // bank that is mask 0's own face, which is also how the operator tests
    // with no bank at all. Each capture is normalised on its own, by the
    // same rule setFittedFace applies to a visitor's first mesh (centroid,
    // largest absolute coordinate), so a bank face and the live one come out
    // the same size without the live normalisation having to exist yet --
    // this is called from the Transition edge, before the visitor is tracked.
    // N is simParams().N, the masks the plant will place. `forceStructures`
    // > 0 is the operator's count (RootSequenceParams::reveal_structures):
    // exactly that many, each mask dealt the next capture round the bank
    // again when it runs out; 0 lets the bank's depth decide, between
    // minStructures and maxStructures.
    // TODO(face-bank): repeat is a placeholder until the bank is deep enough.
    void assignBankFaces(const std::vector<mirror::FaceCapture>& bank,
                         int maxStructures, int minStructures, int forceStructures = 0);
    void clearBankFaces();
    // Which bank face each of the other structures' masks wears: structure k,
    // mask j -> structureFaces()[k].captureIdx[j], an index into the `bank`
    // passed to assignBankFaces (-1 = none, draw mask 0's face). The
    // assignment is independent of how the structures' geometry is made --
    // today the neighbour copies, later baked variations -- and stays the
    // same data either way.
    struct StructureFaces { std::vector<int> captureIdx; };
    const std::vector<StructureFaces>& structureFaces() const { return structureFaces_; }
    // How many other structures the bank says to show; 0 until
    // assignBankFaces has run (RootSequence then falls back to its own cap).
    int structureCount() const { return (int)structureFaces_.size(); }
    // The chain's slots, same indexing: mask i -> chainFaces()[i] (-1 = mask
    // 0's face; slot 0 is always -1, it is the live face).
    const std::vector<int>& chainFaces() const { return chainFaces_; }

    // A different face on every mask, sampled from the morphable basis.
    //
    // Test data, and there is no photo set in the repo to fit instead -- but
    // sampling the basis is the better test anyway: it is the same generator
    // the fitter projects onto, the identities are reproducible from a seed,
    // and nobody's face is in the repository. `amount` scales the sampled
    // coefficients: 0 is twelve copies of the neutral mask, 1 is about the
    // spread a room of strangers covers.
    //
    // Fills the bank the same way assignBankFaces does (mask 0 gets the
    // first identity, masks 1..n-1 the rest), with no colours, so the
    // devtools shots exercise exactly the per-mask path the show uses.
    // Returns the per-face identity coefficients, so a layout that places by
    // resemblance can be driven by the same numbers the faces were built from.
    std::vector<std::vector<float>> setTestIdentities(int n, unsigned seed, float amount);
    void clearTestIdentities() { clearBankFaces(); }

    // --- camera ------------------------------------------------------------
    // In the show, RootSequence (root_sequence.h) owns the camera outright and
    // turns autoFrame off. What is left here is the one fallback framing the
    // operator/devtools paths (the roots tab outside Transition/Roots,
    // --growshot, --abshot, --clothshot) still need: the whole planned layout
    // from the current angles, or one mask tight and square to its normal.
    // Off, the camera is whatever azimuth/elevation/radius/target say.
    bool  autoFrame = true;
    // >= 0 frames that planned mask alone -- tight to its own extent, camera
    // straight down its normal: a face is a thing with a front, and framing
    // it means standing in front of it. -1 frames the whole planned layout
    // on its centroid (the masks, not every root node: a couple of laterals
    // trailing below the last nest would otherwise drag the bound down and
    // shrink the piece into the middle of the frame).
    int   focusMask = -1;
    float zoom      = 1.0f;
    // The mask the cloth presses against and the key can aim at. RootSim
    // places mask 0 at one fixed, known transform (see root_sim.cpp's
    // anchor-first placement in reset()) specifically so there is always an
    // unambiguous "the anchor" to build a collider frame against.
    int   anchorMask   = 0;
    // Seconds for autoFrame to converge on a new shot. 0 snaps, which is what
    // the stills want; anything above about 0.3 reads as a move.
    float camEase      = 0.f;
    // Margin around the whole-layout bound, as a fraction of its extent.
    float frameMargin  = 0.35f;
    int   maskCount() const { return (int)revealedMasks().size(); }

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
    // for pacing the live timeline against (see RootSequence::begin()).
    // Computed once by actually growing a throwaway sim to completion, then
    // cached -- it used to be recomputed the same way on
    // every entry into the Roots phase (i.e. every visitor), which meant
    // paying for an entire extra full growth simulation, discarded, once per
    // show loop. Invalidated by regrow(), the only thing that changes what
    // this number should be.
    int growthStepEstimate() const;
    // Bumped by regrow(); the plant's geometry (and therefore anything
    // derived from it, e.g. RootSequence's neighbour hood) is only
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
    // Run the growth to completion now, synchronously, and upload the result
    // -- the whole chain in one call, for RootSequence::jumpTo (an operator
    // wanting the Turn or a later stage without waiting out Grow). Nothing
    // else about the scene changes; the cloth, faces and hood are left as
    // they are.
    void finishGrowth();
    // The plant back to its seed, keeping everything that is not the plant:
    // the faces (this sitting's on mask 0 and the bank's on the rest), the
    // cloth state and the baked variations. What goes is what replant()
    // drops of the *growth*: the uploaded segments, the placed hood, the
    // flagged masks. Bumps the growth generation so a Reveal after it
    // re-places the hood. For RootSequence::jumpTo going back to Face/Grow.
    void resetGrowth();

    // Hold the growth where it is without tearing anything down: the opening
    // stage of the piece is a face that has not grown yet.
    bool  simPaused = false;

    // --- which planned masks are drawn --------------------------------------
    // A mask is drawn once the root has reached it (the sim's own reveal), or
    // once something has flagged it visible -- RootSequence's WhenFramed
    // reveal mode does that the first frame a planned mask's bound is inside
    // the frustum. A flag never clears on its own; replant() drops them all
    // with the rest of the last visitor.
    void setMaskVisible(int i);
    bool maskVisible(int i) const;   // reached *or* flagged

    // --- the other structures (Reveal) ---------------------------------------
    // "Variations": throwaway growths of the current simParams_ at seeds
    // seed+1..seed+K, run to completion and kept as geometry + planned masks,
    // so the structures standing around this one are previous plants rather
    // than copies of it. Baked synchronously the first time they are asked
    // for -- a stall of a few seconds, once per parameter change and never in
    // the installed show -- and cached like growthStepEstimate(): regrow()
    // drops them, replant() keeps them.
    void ensureVariations(int K);
    int  variationCount() const { return (int)variations_.size(); }
    // One placed structure. The instance path carries capsules only, so its
    // masks are emitted into the shared face mesh, transformed the same way
    // its geometry was (scale, yaw about Y, translate -- addInstance's order).
    // `centre`/`radius` are its masks' bound in world space, for framing.
    struct NeighbourPlacement {
        float translate[3]; float rotYaw; float scale;
        int   variation;      // index into the baked variations
        int   instance;       // the renderer's instance index
        float centre[3]; float radius;
        bool  visible;        // drawn at all (capsules and masks)
        bool  lit;            // its roots shaded as normal, else dark (env.unlitLevel)
        // ...and each of its masks, one flag per mask of its variation's
        // layout. The Reveal lights the top mask on a marker and the rest as
        // the structure's pulse front reaches them; see setStructureMaskLit
        // and setStructurePulseStart.
        std::vector<char> maskLit;
        // Per mask, the node distance (the pulses' own arc length, world
        // units, hop-offset seeded -- MetalRootRenderer::addInstance) at
        // which the root arrived at it: the first node the instance has
        // inside the mask's own reach. What the front is measured against
        // to light mask j; the anchor's is 0.
        std::vector<float> maskDist;
        // The pulse clock the structure's front started at, < 0 until it has.
        float pulseStart;
        int  maskCount() const { return (int)maskLit.size(); }
        bool allMasksLit() const {
            for (char c : maskLit) if (!c) return false;
            return true;
        }
    };
    std::vector<NeighbourPlacement> neighbours;
    // The Reveal shows the hood dark and then lights it mask by mask.
    // Structure k is neighbours[k]; the live structure and its chain are
    // always drawn and lit. setStructureLit is the whole structure -- its
    // roots and every mask -- and setStructureMaskLit one face of it (the
    // roots untouched). Each call re-emits the face mesh, so call on a
    // change, not per frame; setAllStructuresVisible re-emits once for the
    // lot. Out-of-range k/j is ignored.
    void setStructureVisible(int k, bool visible);
    void setAllStructuresVisible(bool visible);
    void setStructureLit(int k, bool lit);
    void setStructureMaskLit(int k, int j, bool lit);
    // The roots alone (the instance's lit), the masks untouched: with a
    // pulse front started the capsules light behind the front, so this is
    // "let it light as the front passes" rather than "on now".
    void setStructureRootsLit(int k, bool lit);
    // Start (t = the renderer's pulse clock, pulseClock()) or clear (t < 0)
    // structure k's pulse front -- MetalRootRenderer::setInstancePulseStart.
    // No face rebuild: the front is the shader's.
    void setStructurePulseStart(int k, float t);
    float pulseClock() const;

    // Where the growth currently is, in render space; false when nothing is
    // growing. For a camera that follows the tip instead of the structure.
    bool  growthTip(float out[3]) const;
    // The hop in flight: the mask it is heading for, and whether it got there.
    int   currentMask() const;
    bool  arrivedAtMask() const;
    // Grow one system, then cache it and tile a gridN x gridN field of instances
    // (varied yaw/scale) to exercise LOD + frustum culling. Stops the live path.
    void buildField(int gridN, float spacing);
    // The other structures standing around this one, as cached instances of
    // the baked variations (structure k wears variation k % K and, through
    // the face mesh, structureFaces()[k]). Unlike buildField this keeps the
    // live system and its faces -- it is the Reveal stage of the piece, where
    // it turns out to be one of many. Placed as a fan behind the subject, as
    // seen from the camera that reveals them: structure k stands `spacing` x
    // `structR` x sqrt(k+1) out from `centre` (this structure's own centre --
    // it hangs below the origin, so a ring about the origin would put
    // neighbours level with nothing), on the plane of it, at the azimuth that
    // puts it at a chosen angle across the camera's view. The view angles
    // are a golden-ratio sequence over the far half of the frame, kept out
    // of the band the subject itself covers, so each structure that pops in
    // is beside the ones before it rather than behind them or behind the
    // subject -- and none is between the lens and the piece. `camAz`, `camR`
    // and `tanH` are that camera: its azimuth, its distance from `centre`
    // and its horizontal frustum half-extent at unit depth. Every structure
    // starts hidden and dark; setStructureVisible/Lit bring them in. Bakes
    // the variations first if they are not there yet.
    void addNeighbours(int count, int variations, float spacing, float structR,
                       const float centre[3], float camAz, float camR, float tanH);

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
    // The window in which the film is a flat, fully-pinned rectangle covering
    // the frame. Two things must hold for the whole of it, and both are
    // properties of the film rather than of any one caller, so they are decided
    // here rather than by whoever happens to be driving the phase:
    //
    //   - the camera does not move. A flat film pinned across the frame stays
    //     registered to that frame only while the camera that framed it stays
    //     put; any motion either magnifies the pond (a sheet sized for the
    //     entry pose seen from closer in) or uncovers the edges. TransitionScene
    //     had a literally fixed camera and that was not incidental -- it is
    //     what "the opening frame is the pond" costs.
    //   - the roots are not on screen. The pond is up; nothing behind it has
    //     been revealed yet.
    //
    // Ends at the release, which is exactly when the film stops covering the
    // frame and starts being an object in a moving world.
    bool  clothPinned() const { return clothActive_ && clothRelease() <= 0.f; }
    double clothClock() const { return clothT_; }
    float clothPress() const;      // 0..1, how far the mask has come through
    float clothRelease() const;    // 0..1, how far the release front has run
    bool  clothDone() const;      // the authored schedule has run out
    bool  clothRetired() const;   // ...and the film has actually left -- see the .mm
    // How far the film's mean depth has to recede past the mask before it stops
    // being drawn, in sheet half-heights. Scale-invariant on purpose: the sheet
    // is sized from the display aspect and the camera distance, so a threshold
    // in world units would mean something different on a different screen.
    // 10 is measured, not guessed: traced against the film's actual occupancy
    // of the frame (CLOTHSHOT_TRACE), it still covers 8.5% of the screen at 2.4
    // half-heights and does not reach zero until about 9.6. A receding plane
    // never leaves the frustum by receding -- perspective keeps it covering --
    // so it only goes by crumpling, and that takes far longer than the depth
    // reading alone suggests.
    float clothGoneDistance = 10.0f;
    // Whether a film is currently being simulated and drawn at all -- false
    // before the first restartCloth(), and again once the fall has finished
    // or skipCloth() has retired it.
    bool  clothActive() const { return clothActive_; }
    const char* clothPhaseName() const;
    const Cloth& cloth() const { return cloth_; }

    bool  showFace  = true;
    // The face mesh's draw scale, x the mask's own unit (SimMask::faceUnit).
    // Also the size of the cavity the roots nest around: syncFaceParams()
    // copies it (and the mesh's half-extents) into simParams_ at every sim
    // reset, so the plant grows a nest that hugs the face it will show. A
    // change mid-growth redraws the faces at once but the nests already
    // grown keep their size -- regrow() to refit them.
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
    // The key's authored, "home" direction -- see lightDir's own doc for how
    // it differs from what actually reaches the renderer once room
    // responsivity is on.
    float lightDir[3] = {0.4f, 0.8f, 0.35f};

    // --- room responsivity ---------------------------------------------------
    // The key light stops being purely authored once these are on: its
    // intensity follows the room's own ambient level (fed in once a frame by
    // main.mm from mic_level.h, since RootScene has no business owning a
    // CoreAudio tap itself) and its angle swings toward wherever the tracked
    // visitor is standing in frame. `lightDir` above stays the *home*
    // direction the panel authors and the angle swings around -- render()
    // uses the swung direction, not lightDir directly, so a still room with
    // no one tracked renders exactly what lightDir says.
    void setAmbientLevel(float level01) { ambientLevel_ = std::clamp(level01, 0.f, 1.f); }
    // `x`,`y` normalised [0,1] from the top-left, matching FaceResult::
    // centre_x/y -- the tracker's own convention, so main.mm can pass that
    // straight through with no remapping.
    void setTrackedPosition(float x, float y, bool valid) {
        trackedX_ = x; trackedY_ = y; trackedValid_ = valid;
    }
    // ...and read back, for RootSequence's head pan -- the same position the
    // key light swings on, so the two agree on where the visitor is.
    bool trackedPosition(float& x, float& y) const {
        x = trackedX_; y = trackedY_; return trackedValid_;
    }
    bool  micLightResponsive  = true;
    // The key's intensity at silence; at ambientLevel==1 it reaches
    // micBaseKeyIntensity * (1 + micIntensityGain). Held separately from
    // env.keyIntensity's own default (renderer().env.keyIntensity) rather
    // than reading it back, since this *is* what sets that field once
    // responsivity is on -- reading it back would be reading its own output.
    float micBaseKeyIntensity = 1.0f;
    float micIntensityGain    = 1.4f;
    bool  trackLightAngle     = true;

    // --- where the key light is ----------------------------------------------
    // How the key's direction is decided. The light stays *directional* in
    // every mode -- one direction per frame, which is what root_geom/root_face/
    // root_leaf all shade against -- so this is about aiming and framing it,
    // not about introducing a positional light with per-pixel falloff.
    enum class LightMode {
        // lightDir is the direction, authored in the panel. The historical
        // behaviour, and still the one an operator dials by hand.
        Direction = 0,
        // Aim from a world point instead. The direction becomes
        // normalize(lightPos - focus), which is far easier to place by eye than
        // an azimuth/elevation pair -- you put the lamp somewhere and the rays
        // point where you'd expect. Still one direction for the whole scene.
        Position,
        // Straight down the camera's own view axis, offset by lightOffsetAz/El.
        // A key that stays put relative to the shot, so it keeps raking across
        // frame the same way however the camera moves.
        CameraRelative,
    };
    LightMode lightMode = LightMode::Direction;
    // Position mode's lamp, in world space. Defaults above and behind the
    // structure.
    float lightPos[3] = {6.f, 14.f, -10.f};
    // CameraRelative mode's offset from the view axis, radians. A key exactly
    // on the view axis is a flat frontal light with nothing to model the form.
    float lightOffsetAz = 1.05f;
    float lightOffsetEl = 0.55f;

    // What Position mode aims *at*.
    enum class LightFocus {
        SceneCentre = 0,   // the whole structure's bounds
        AnchorMask,        // the face the piece is built around
        CameraTarget,      // whatever the shot is currently looking at
    };
    LightFocus lightFocus = LightFocus::SceneCentre;

    // Where the light ended up this frame, for the panel to display -- the
    // authored numbers do not answer "where is it actually" in Position or
    // CameraRelative mode.
    const float* resolvedLightDir() const { return renderLightDir_; }
    const float* resolvedLightFocus() const { return lightFocusPt_; }
    // Radians the key is allowed to swing off lightDir toward an edge-of-frame
    // visitor; azimuth gets the full range, elevation 60% of it (a person
    // standing high or low in frame is a smaller cue than side to side).
    float trackAngleRange     = 0.5f;

private:
    void buildSyntheticRoots(uint32_t seed);
    void uploadFaceFromMasks();      // build face verts from the live sim's masks
    // faceScale and the face mesh's half-extents into simParams_ -- what the
    // sim sizes every mask's cavity from (root_sim.h, SimParams::faceScale).
    // Called before every sim reset and by rebuildFace(), so the probes that
    // copy simParams_ (growthStepEstimate, ensureVariations) see them too.
    void syncFaceParams();

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
    // and live it may not have: outside the show's own phases applyFraming
    // drives the camera, and applyFraming *eases* -- target converges
    // exponentially from wherever the previous phase left it (the default is
    // {0,-8,0}). A sheet centred on the anchor while the camera is
    // still looking below and beside it reads as the film sitting up and to
    // one side, with the far corner running off the end of its own uv and
    // smearing the film's edge pixels. Following the view axis instead makes
    // the sheet cover the frame by construction, whatever the camera is doing
    // and wherever the anchor ends up.
    simd_float3 clothCentre_ = simd_make_float3(0, 0, 0);
    // The rectangle, in the sheet's own local coordinates, that the film maps
    // onto -- uv 0..1 spans exactly this and the sheet may extend well past it.
    //
    // Kept separate from the sheet's extent because the two answer different
    // questions and can want different answers. uv is fixed by what the film
    // *is*: the pond filled the frame at the moment of the cut, so uv 0..1 has
    // to be the frustum at that moment or the cut is visible. The extent is
    // fixed by what the sheet has to *cover*: every view the camera will reach
    // while the sheet is still pinned. Tying uv to the extent (which is what
    // dividing through by `oversize` did) makes those the same number, and
    // then a camera that pulls back during the press can only be covered by
    // giving up the registration at entry. Split, both hold: the sheet reaches
    // as far as it must and the film still lands where it did.
    float  clothFilmU_ = 0.f, clothFilmV_ = 0.f;        // centre, local
    float  clothFilmHalfX_ = 1.f, clothFilmHalfY_ = 1.f;
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
    float clothAnchorFU_ = 2.6f;     // the anchor's faceUnit (SimMask), the face's draw scale / faceScale

    std::unique_ptr<MetalRootRenderer> rr_;
    std::unique_ptr<rootsim::RootSim>  sim_;
    rootsim::SimParams simParams_;
    mutable int growthStepEstimate_ = -1;   // -1 = not computed yet; see growthStepEstimate()
    // The baked variations -- see ensureVariations. Emptied by regrow().
    struct Variation {
        std::vector<float> nodes, radii;
        std::vector<int>   segs;
        std::vector<rootsim::SimMask> masks;   // its planned layout
        float centre[3] = {0.f, 0.f, 0.f};     // the masks' bound, local
        float radius = 1.f;
    };
    std::vector<Variation> variations_;
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
    // The face bank, as uploaded: one normalised mesh + its own colours per
    // capture handed to assignBankFaces, in the bank's own order. Its own
    // triangles too -- every capture is fitter-basis topology, and the live
    // face (faceTris_) may still be the canonical model's when nobody has
    // been tracked yet.
    struct BankFace {
        std::vector<float> verts;
        std::vector<int>   tris;
        std::vector<float> colors;   // 3/vertex, empty = flat material
    };
    std::vector<BankFace> bankFaces_;
    // Which bank face each planned mask draws; see chainFaces().
    std::vector<int> chainFaces_;
    std::vector<StructureFaces> structureFaces_;
    // Mask `slot` of structure `structure` (-1 = this one, the live chain)
    // resolved to the face it draws: a bank face, or mask 0's when the slot
    // is empty or out of range.
    struct FaceRef {
        const std::vector<float>* verts;
        const std::vector<int>*   tris;
        const std::vector<float>* colors;
    };
    FaceRef faceFor(int structure, int slot) const;
    // The fitted-mesh normalisation rule (see setFittedFace): centroid and
    // 1 / largest absolute coordinate about it.
    static void faceNormalisation(const std::vector<float>& verts, float centre[3], float& scale);
    // Planned masks flagged visible ahead of the root reaching them -- see
    // setMaskVisible. Indexed like plannedMasks(); shorter means "not flagged".
    std::vector<char> maskFlagged_;
    float idleCentre_[3] = {0.f, 0.f, 0.f};
    float idleExtent_ = 10.f;
    void  updateBounds(const std::vector<float>& nodes);
    void  applyFraming(double dt = 0.0);
    bool  camPrimed_ = false;   // false until the first frame has snapped
    // The pose applyFraming is easing *towards*, published so the cloth can
    // size its sheet against where the camera is going and not only against
    // where it is. A sheet is a physical object -- it cannot be resized once
    // it is draping -- so the only way it can be guaranteed to cover the frame
    // for the whole of the pinned phase is to be built for the widest view it
    // will meet during that phase. Only meaningful while autoFrame is on;
    // the authored sequence assigns the camera outright with no ease, so
    // there is nothing to anticipate and camDesValid_ stays false.
    bool  camDesValid_ = false;
    float camDesRadius_ = 0.f;
    float camDesTarget_[3] = {0.f, 0.f, 0.f};
    float camDesAz_ = 0.f, camDesEl_ = 0.f;
    bool  facesUploaded_ = false;
    std::vector<int>   canonTris_;
    std::vector<float> faceColors_;   // per-vertex RGB, empty = flat material
    bool  fitted_face_ = false;
    bool  fit_norm_set_ = false;     // normalisation captured from the first fit
    float fit_centre_[3] = {0, 0, 0};
    float fit_scale_ = 1.0f;
    double t_ = 0.0;

    // --- room responsivity state (see the public setters above) ------------
    float ambientLevel_ = 0.f;
    float trackedX_ = 0.5f, trackedY_ = 0.5f;
    bool  trackedValid_ = false;
    // lightDir swung by the tracked position; computed once per advance() and
    // read by render() instead of lightDir directly. Starts equal to
    // lightDir's own default so a render before the first advance() is not
    // pointed at zero.
    float renderLightDir_[3] = {0.4f, 0.8f, 0.35f};
    // The point the key aims at, resolved from lightFocus each advance().
    float lightFocusPt_[3] = {0.f, -8.f, 0.f};
    // Resolve lightMode/lightFocus into renderLightDir_ and lightFocusPt_.
    // Called once per advance(), after the camera has been framed --
    // CameraTarget focus and CameraRelative aiming both read the camera, so
    // they have to run after whatever moved it.
    void updateLighting();
};
