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
    bool  growFromFirstMask = true;
    float angleStepGoldenMult = 1.0f;
    float distStepFrac = 0.0f;
    float dwellDays    = 18.0f;
    float weight       = 0.9f;     // main-root travel attraction
    float mainTravelTrials = 14.0f;
    float lateralWeight = 0.20f;
    float dwellWeight        = 0.92f;
    float dwellLateralWeight = 0.92f;
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
    float spawnBehind  = 0.0f;
    // Where on the mask the next root leaves from, along the face's own up
    // axis, in units of its half-height. 0 is dead behind the face, where the
    // mask hides the root until it has already crawled clear -- which reads as
    // a root arriving from off-screen rather than one growing out of the face
    // you are looking at. 1 puts it at the chin, in view from the first
    // segment.
    float spawnRim     = 1.0f;
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
    f("angleStepGoldenMult", p.angleStepGoldenMult);
    f("distStepFrac", p.distStepFrac);
    f("dwellDays", p.dwellDays);
    f("weight", p.weight);      f("mainTravelTrials", p.mainTravelTrials);
    f("lateralWeight", p.lateralWeight);
    f("dwellWeight", p.dwellWeight);
    f("dwellLateralWeight", p.dwellLateralWeight);
    f("sigma", p.sigma);        f("viewCylLen", p.viewCylLen);
    f("maxHopDays", p.maxHopDays); f("travelSlack", p.travelSlack);
    f("evenNests", p.evenNests);
    f("reachMult", p.reachMult);
    f("travelPullReach", p.travelPullReach);
    f("coneSurfaceTravel", p.coneSurfaceTravel);
    f("coneShellThickness", p.coneShellThickness);
    f("growthDt", p.growthDt);
    f("targetLift", p.targetLift); f("spawnBehind", p.spawnBehind);
    f("spawnRim", p.spawnRim);
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
    float rDepth, rWidth, rHeight;
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

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace rootsim
