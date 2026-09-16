// RootSim — GL-free, incremental CPlantBox "mask relay" root growth.
//
// A faithful, restructured port of render_relay_gui.cpp's growth driver: masks
// are placed by phyllotaxis on a cone, and a root system grows hop-by-hop from
// mask to mask (travel toward the target, then dwell/wrap around it), confined by
// the cavity-avoidance geometry and steered by attraction tropism. The GL app's
// blocking per-hop while-loop is turned into a per-frame state machine so the
// Metal app can step it alongside rendering.
//
// CPlantBox types are hidden behind a pimpl so this header stays includable from
// ObjC++ (RootScene) without pulling Eigen/CPlantBox into the ObjC compile.
// Geometry and masks are returned in RENDER space (Y-up, the toYup remap applied).
#pragma once
#include <memory>
#include <string>
#include <vector>

namespace rootsim {

struct SimParams {
    int   N            = 6;        // number of masks / hops
    float R0           = 13.0f;    // cone base radius
    float Hh           = 52.0f;    // cone height
    float startFrac    = 0.15f;
    float endFrac      = 0.94f;
    float taperPower   = 1.0f;
    // Where the masks live, and where the roots crawl -- two choices, not one.
    // See sdf_viewer/MaskHosts.h: any pattern composes with any host.
    //   host    "cone" | "cylinder" | "sphere" | "torus" | "lobes"
    //   pattern "phyllotaxis" | "helix" | "rosette" | "feature"
    // Lobes ignore the pattern and are never shell-confined: there is no sheet
    // to crawl on, and confining them would flatten the bulge that makes a lobe.
    std::string host    = "cone";
    std::string pattern = "phyllotaxis";
    float helixTurns    = 2.0f;    // helix: revolutions over the whole run
    int   groupSize     = 3;       // rosette/lobes: masks per cluster
    float groupSpread   = 0.55f;   // rosette: bunch size, as a fraction of the gap
    int   featureClusters = 3;     // feature: how many families the faces fall into
    float tubeRadius    = 7.0f;    // torus: minor radius. lobes: lobe radius
    // Each hop starts from the revealed mask *nearest* the next one, rather than
    // from the one just left. The system reads as one branching organism instead
    // of a thread threading past faces -- and every hop becomes short, which is
    // what retires the reach problem on the slow species.
    bool  treeRelay     = false;
    // Start at the first mask instead of growing to it.
    //
    // The piece opens on the visitor's own face, and roots should come *out* of
    // it -- so mask 0 is revealed the moment the grow starts, with no root
    // attached, and the first hop leaves it for mask 1. Otherwise the opening
    // shot has a root already arriving at a face that has not been shown yet.
    // There is no dwell on it: the face stays bare and one root leaves it.
    bool  growFromFirstMask = true;
    // Mask 0 on the host's axis, facing down it, rather than on the surface
    // facing out like the rest. The root then leaves the face straight out
    // of its front and the chain grows down the axis -- straight at the
    // camera standing in front of the face. Cone and cylinder hosts only
    // (the ones with an axis); off, mask 0 is the pattern's own first
    // sample on the surface.
    bool  anchorOnAxis = true;
    // How steeply that face looks down, degrees below the horizontal, in
    // render space (see the anchor-first placement in reset()). The chain
    // hangs off the face's normal, so this is also how the structure hangs:
    // 90 would be straight down (and the camera in front of the face
    // straight below it, where the renderer's world-up view has no up), 0
    // is level with the structure lying along +z. 60 keeps the chain 30
    // degrees off vertical, leaning toward the camera.
    float anchorPitchDeg = 60.f;
    // Where the root leaves an on-axis anchor: inside the head, this far, cm,
    // behind the mouth along -normal (the basis face is a thin shell whose
    // centroid sits only ~0.2 behind the lips, so the mouth is the reference,
    // not the centre). The keep-clear tube in front of the face (viewCylLen)
    // and the mask's own cavity are both dropped for that one hop, since the
    // root starts inside them and grows out through the mouth.
    float anchorSpawn  = 1.5f;
    float angleStepGoldenMult = 1.0f;
    float distStepFrac = 0.0f;
    float dwellDays    = 18.0f;
    float weight       = 0.9f;     // main-root travel attraction
    float mainTravelTrials = 14.0f;
    float lateralWeight = 0.20f;
    float dwellWeight        = 0.92f;
    float dwellLateralWeight = 0.92f;
    // Root types: up to three dwell settings, dealt to the hops in turn
    // (hop 1 gets type 1, hop 2 type 2, ... round again), so the nests down
    // the chain are not all the same wrap. Type 1 is dwellDays/dwellWeight/
    // dwellLateralWeight above; types 2 and 3 have their own here, and
    // rootTypes says how many are in play (1 = every hop the same, as it
    // always was). Only the dwell differs: one species, one travel law, so
    // the pacing (commonAge, growthStepEstimate) is unchanged apart from
    // the longest dwell being the one the even-nest age is padded to.
    int   rootTypes          = 1;
    float dwell2Days         = 18.0f;
    float dwell2Weight       = 0.92f;
    float dwell2Lateral      = 0.92f;
    float dwell3Days         = 18.0f;
    float dwell3Weight       = 0.92f;
    float dwell3Lateral      = 0.92f;
    // The dwell hop h (1-based, mask h) gets; hop 0 and below is type 1.
    int   typeOf(int h) const {
        const int n = rootTypes < 1 ? 1 : (rootTypes > 3 ? 3 : rootTypes);
        return h <= 0 ? 0 : (h - 1) % n;
    }
    float dwellDaysFor(int h) const {
        const int t = typeOf(h);
        return t == 1 ? dwell2Days : t == 2 ? dwell3Days : dwellDays;
    }
    float dwellWeightFor(int h) const {
        const int t = typeOf(h);
        return t == 1 ? dwell2Weight : t == 2 ? dwell3Weight : dwellWeight;
    }
    float dwellLateralFor(int h) const {
        const int t = typeOf(h);
        return t == 1 ? dwell2Lateral : t == 2 ? dwell3Lateral : dwellLateralWeight;
    }
    // The longest dwell any hop gets -- what the even-nest age pads to.
    float maxDwellDays() const {
        float m = dwellDays;
        if (rootTypes >= 2) m = m > dwell2Days ? m : dwell2Days;
        if (rootTypes >= 3) m = m > dwell3Days ? m : dwell3Days;
        return m;
    }
    float sigma        = 0.35f;    // angular jitter
    float viewCylLen   = 8.0f;
    // Ceiling on the travel half of a hop. The budget itself is derived from
    // how far this hop has to go and how fast this species elongates (see
    // travelDaysFor in the .cpp) -- this is only the stop that keeps a hop that
    // is never going to arrive from growing the whole system into a ball.
    float maxHopDays   = 60.0f;
    // How much longer the root's actual path is than the geodesic to the mask.
    // It wanders: the tropism is a random walk with a pull, not a straight line,
    // and it has to steer around the cavities of the masks already revealed. A
    // budget that assumes a straight line runs out short of every target.
    float travelSlack  = 2.5f;
    // Same amount of root at every mask.
    //
    // Dwell is already the same everywhere, but the nest is not: laterals grow
    // during the *travel* too, and travel gets longer as the cone widens, so
    // the last mask ends up with roughly twice the root of the first. This pads
    // every hop out to one common age -- the longest travel the layout implies,
    // plus the dwell -- so the early masks wait instead of the late ones being
    // fuller. Costs days, and the days are the ones that make the system bushy,
    // so it is a choice rather than a fix.
    bool  evenNests    = true;
    float reachMult    = 1.6f;
    float travelPullReach = 1.2f;
    // "Along the surface" travel: confine the travelling root to a thin shell
    // straddling the cone the masks sit on, so it crawls over the cone between
    // masks instead of cutting through its interior. Travel only -- the dwell
    // wrapping stays unconstrained, or the nests around each mask would be
    // flattened onto the surface instead of bulging into 3D.
    bool  coneSurfaceTravel  = false;
    // cm; thicker = looser hug, more wander. Not much thinner than this,
    // though: the shell and the cavities of the masks already revealed leave a
    // corridor, and below ~8 cm it is narrow enough that the travelling root
    // gets stuck in it and never arrives.
    float coneShellThickness = 9.0f;
    float growthDt     = 0.75f;    // sim days advanced per step()
    float targetLift   = 0.0f;
    // How far behind the mouth point (see faceMouthU/V/N below), along
    // -normal, a non-anchor hop starts. The root then heads for the next mask
    // from behind the face (initHop) -- it never crosses in front of it.
    float spawnBehind  = 1.5f;
    // How far behind the face, cm along -normal, the dwell's rim ring sits.
    // 0 rings the face in its own plane, so the wrap is around the rim and
    // the nest reads as a frame; positive pulls it back behind the head,
    // where the cavity (faceHalfD deep) no longer keeps the roots out, so
    // they gather into a nest the face sits in front of.
    float nestBehind   = 0.0f;
    // A nest attractor is dropped once any root node comes within this of
    // it, cm, so the wrap moves on instead of circling a spot it has
    // reached. 0 keeps every attractor for the whole dwell.
    float nestHitRadius = 1.5f;
    // The nest's attractor hemisphere behind the mask (see nestAttractors in
    // root_sim.cpp): how many rings from the rim back to the pole, and how
    // many points around each. 1 ring is the old rim alone (plus the pole).
    int   nestRings   = 3;
    int   nestPerRing = 8;
    // The cavity a mask sits in is the face it will show, not a fixed oval.
    // RootScene draws a mask's face at faceScale x faceUnit (SimMask::
    // faceUnit, the layout's mask size) times a mesh normalised to a largest
    // coordinate of 1, so the face's half-extents in the mask's frame
    // (tangent, bitangent, normal) are faceScale x faceUnit x faceHalf*.
    // Those, plus cavityMargin around them, are what the ellipsoid, the rim
    // attractors and the arrival test are built on -- so a face scale change
    // regrows a nest that hugs the face it shows, where the old fixed radii
    // (maskR x 1.0/1.25/0.55) sat 1.5x too large for the default face and
    // never moved with it. faceScale and faceHalf* are RootScene's, copied in
    // at every reset (see RootScene::syncFaceParams): not settings of the
    // growth, so not in visitSimParams. cavityMargin is.
    float faceScale    = 0.85f;
    float faceHalfW    = 0.75f, faceHalfH = 1.0f, faceHalfD = 0.5f;
    // The mouth's own position, in the same normalised (largest coordinate 1)
    // mesh frame faceHalf* is measured in -- i.e. an offset from the mask's
    // pos along its own (tangent, bitangent, normal), in units of the same
    // mesh-local coordinates appendFaceVertexData maps onto that frame
    // (local.x -> tangent, local.y -> bitangent, local.z -> normal). Where
    // every hop actually leaves from: mouth point = pos + tangent*mouthU +
    // bitangent*mouthV + normal*mouthN (root_sim.cpp's hopStart). Computed
    // once from the neutral/basis face (FaceBasis's own landmark basis,
    // dlib-68 mouth points 48..67, in the same units as FaceBasis::neutral()
    // and normalised the same way normalizeMesh() normalises the drawn
    // mesh) -- not from whatever capture happens to be loaded, since
    // captures are only squared to the neutral by rotation, not re-measured
    // per person. RootScene's, copied in at every reset (see
    // RootScene::syncFaceParams): not a setting of the growth, so not in
    // visitSimParams, same as faceHalf*.
    float faceMouthU   = 0.0f, faceMouthV = 0.0f, faceMouthN = 0.0f;
    // How far behind the mask's pos the face is drawn, as a fraction of the
    // cavity half-depth (RootScene::faceRecess, applied in
    // appendFaceVertexData). The mouth point has to sit on the *drawn* face,
    // so the sim recesses it the same way. RootScene's, copied in at reset.
    float faceRecess   = 0.5f;
    float cavityMargin = 0.15f;
    // How much of a mask's measured motion (setMaskExtent: the swept
    // half-extents of its replayed head) is added to its keep-out and nest
    // ring. 1 keeps the roots clear of the whole swing; 0 ignores it.
    float motionCavity = 1.0f;
    unsigned seed      = 42u;
    std::string paramDir;          // CPlantBox modelparameter dir (trailing slash)
    std::string speciesXml = "Zea_mays_6_Leitner_2014.xml";
};

// Every field of SimParams that is part of a saved root look, in one list.
//
// These used to be saved through this list into a .root file, a second preset
// system beside the parameter registry -- which meant "the root preset" and
// "the root settings" were different things holding different subsets, and a
// look could not be reproduced from either alone. The registry owns them now.
//
// The list stays because it is what the round-trip test walks: the failure a
// preset system has is silent, and a field nobody declared comes back as its
// default without complaining. paramDir is excluded deliberately -- it is a
// build path, not a setting.
template <class Fn>
void visitSimParams(SimParams& p, Fn&& f) {
    f("speciesXml", p.speciesXml);
    f("N", p.N);
    f("R0", p.R0);              f("Hh", p.Hh);
    f("startFrac", p.startFrac); f("endFrac", p.endFrac);
    f("taperPower", p.taperPower);
    f("host", p.host);          f("pattern", p.pattern);
    f("helixTurns", p.helixTurns);
    f("groupSize", p.groupSize); f("groupSpread", p.groupSpread);
    f("featureClusters", p.featureClusters);
    f("tubeRadius", p.tubeRadius);
    f("treeRelay", p.treeRelay);
    f("growFromFirstMask", p.growFromFirstMask);
    f("anchorOnAxis", p.anchorOnAxis);
    f("anchorPitchDeg", p.anchorPitchDeg);
    f("anchorSpawn", p.anchorSpawn);
    f("angleStepGoldenMult", p.angleStepGoldenMult);
    f("distStepFrac", p.distStepFrac);
    f("dwellDays", p.dwellDays);
    f("weight", p.weight);      f("mainTravelTrials", p.mainTravelTrials);
    f("lateralWeight", p.lateralWeight);
    f("dwellWeight", p.dwellWeight);
    f("dwellLateralWeight", p.dwellLateralWeight);
    f("rootTypes", p.rootTypes);
    f("dwell2Days", p.dwell2Days); f("dwell2Weight", p.dwell2Weight); f("dwell2Lateral", p.dwell2Lateral);
    f("dwell3Days", p.dwell3Days); f("dwell3Weight", p.dwell3Weight); f("dwell3Lateral", p.dwell3Lateral);
    f("sigma", p.sigma);        f("viewCylLen", p.viewCylLen);
    f("maxHopDays", p.maxHopDays); f("travelSlack", p.travelSlack);
    f("evenNests", p.evenNests);
    f("reachMult", p.reachMult);
    f("travelPullReach", p.travelPullReach);
    f("coneSurfaceTravel", p.coneSurfaceTravel);
    f("coneShellThickness", p.coneShellThickness);
    f("growthDt", p.growthDt);
    f("targetLift", p.targetLift); f("spawnBehind", p.spawnBehind);
    f("nestBehind", p.nestBehind); f("nestHitRadius", p.nestHitRadius);
    f("nestRings", p.nestRings); f("nestPerRing", p.nestPerRing);
    f("cavityMargin", p.cavityMargin); f("motionCavity", p.motionCavity);
    f("seed", p.seed);
}

// What one hop did: whether the root actually arrived at the mask or was only
// declared to have arrived when its day budget ran out.
//
// The distinction is invisible on screen -- a forced hop reveals the mask and
// starts dwelling exactly like a real arrival, just somewhere else -- so it is
// the one thing a headless sweep over parameters has to be able to see.
struct HopReport {
    int   mask       = 0;
    bool  forced     = false;   // deadline, not arrival
    float reachDist  = 0.f;     // closest the root got to the target
    float threshold  = 0.f;     // what would have counted as arrival
    float chord      = 0.f;     // straight-line seed -> target
    float path       = 0.f;     // the distance travel actually has to cover
    float budgetDays = 0.f;     // days the travel was given
    float needDays   = 0.f;     // days the growth law says the path needs
    bool  outOfReach = false;   // the path is longer than this root can grow
    float travelDays = 0.f;     // days until reached/forced
    float dwellDays  = 0.f;     // days spent wrapping the mask after arrival
    float days       = 0.f;     // days the whole hop took, dwell included
    int   nodes      = 0;       // how much root this hop actually put on screen
};

// A revealed face mask in render (Y-up) space, for the face mid-geometry pass.
struct SimMask {
    float pos[3];
    float normal[3];
    float tangent[3];
    float bitangent[3];
    // The cavity's half-extents along normal / tangent / bitangent -- the
    // face's own, plus the margin (SimParams::cavityMargin).
    float rDepth, rWidth, rHeight;
    // The mask's size unit: the face mesh is drawn at faceScale x this
    // (RootScene::appendFaceVertexData), and the radii above were built from
    // the same product, so face and cavity agree by construction.
    float faceUnit;
};

class RootSim {
public:
    RootSim();
    ~RootSim();

    // (Re)start growth. Returns false if the parameter file cannot be loaded.
    bool reset(const SimParams& p);

    // Advance the live growth by one sim step (growthDt days). No-op once done.
    void step();

    bool valid() const;
    bool done()  const;

    // Current geometry in render space: nodesXYZ 3/node, segs 2/seg, radii 1/seg.
    void geometry(std::vector<float>& nodesXYZ,
                  std::vector<int>&   segs,
                  std::vector<float>& radii) const;

    // Masks revealed so far (render space), for the face pass.
    const std::vector<SimMask>& revealedMasks() const;

    // Every mask the layout will ever place, revealed or not.
    //
    // The camera needs these, not the revealed ones. Framing on what has been
    // revealed so far means the bound grows by a step every time a mask lands,
    // so the shot is a staircase -- and smoothing a staircase just smears it
    // into a pump. The layout is fixed at reset; the camera can know the whole
    // of it from the first frame and move once.
    const std::vector<SimMask>& plannedMasks() const;
    // The same layout in CPlantBox's own grow space (z-up, no anchor-first
    // transform): the frames the cavities, the rim attractors and the
    // arrival test are built from. Diagnostics only -- tests/mask_frame_test
    // checks that plannedMasks() is exactly one rigid transform of these, so
    // a face drawn from the render frame sits square in the nest grown
    // round the grow frame.
    const std::vector<SimMask>& plannedMasksGrow() const;

    // The hop in flight: which mask it is heading for, and whether it has got
    // there. A camera that follows the growth wants to follow the tip while it
    // travels and then settle on the mask while it is being wrapped, rather
    // than keep chasing a tip that is now circling.
    int  currentMask() const;      // -1 once nothing is growing
    bool arrivedAtMask() const;

    // The leading tip of the hop in flight, in render space: the live node
    // furthest from where this hop started. False once nothing is growing.
    // What a camera follows when it is following the growth rather than the
    // structure.
    bool tip(float out[3]) const;

    // One entry per hop that has finished. Diagnostics, not scene data.
    const std::vector<HopReport>& hops() const;

    // --- debug: where a hop starts, and where CPlantBox actually put it -----
    //
    // hopStart()/mouthPoint() (see the .cpp) are pure functions of the fixed
    // mask layout, not of anything the growth has done yet -- so "planned"
    // and "actual" read the same number for a hop that has not started. What
    // can differ is firstNode: the position of node 0 in the buffer CPlantBox
    // actually simulated for that hop (SegmentAnalyser's own nodes, the same
    // ones geometry() draws), which `started` is false for until initHop(h)
    // has run. Render space throughout, i.e. after toYup + the anchor-first
    // transform -- the same space plannedMasks() and geometry() report in.
    struct HopSpawn {
        int   fromMask     = -1;     // hopFrom(h): which mask this hop leaves
        bool  started      = false;  // firstNode is only meaningful if true
        float spawn[3]     = {0, 0, 0};      // hopStart(h)
        float mouth[3]     = {0, 0, 0};      // mouthPoint(masks[fromMask])
        float firstNode[3] = {0, 0, 0};      // node 0 of this hop's own buffer
    };
    HopSpawn hopSpawn(int h) const;
    int hopCount() const;

    // mouthPoint() for mask m alone (every mask has one, not only the ones a
    // hop leaves from -- the green markers want all of them).
    bool maskMouthPoint(int m, float out[3]) const;

    // Re-point the mouth (SimParams::faceMouthU/V/N) after reset(). The face
    // a mask wears is the visitor's own and moves with them through the Face
    // stage, while reset() fixed the mouth off the neutral basis at replant
    // -- so the scene measures the drawn mesh and hands the result back here.
    // With `reseed`, the hop in flight is re-seeded from the new mouth if
    // nothing has grown yet (its start is set once, at initHop); without it
    // only the point moves (the markers, and hops not yet started).
    void setFaceMouth(float u, float v, float n, bool reseed);

    // The room mask m's replayed head sweeps: half-extents in the mesh's
    // normalised units (FaceTrackPlayer::motionHalfExtents), the same units
    // as SimParams::faceHalf*. Where they exceed the face's own, the mask's
    // keep-out ellipsoid and nest ring grow to match (x motionCavity) -- the
    // drawn face, the mouth and the arrival test keep the face's own radii.
    // After reset(); re-seeds the hop in flight if nothing has grown yet.
    void setMaskExtent(int m, float halfW, float halfH, float halfD);

    // Diagnostic for the "no shell on hop 1" check: the largest distance any
    // node of hop h's own finished buffer strays from the infinite line
    // through a->b (render space). False until that hop has finished (its
    // nodes are only fixed once frozen).
    bool hopMaxLateralDeviation(int h, const float a[3], const float b[3], float& maxDev) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace rootsim
