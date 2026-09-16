#include "root_sim.h"

#include "RootSystem.h"
#include "SegmentAnalyser.h"
#include "MaskCavities.h"
#include "MaskHosts.h"
#include "RootAttractors.h"

#include <algorithm>
#include <cmath>
#include <limits>

using namespace CPlantBox;
using namespace maskcav;

namespace rootsim {

// The base tropism every hop blends its attraction with. CPlantBox's own
// Gravitropism pulls toward grow -z (render down), so a root fresh out of a
// mask headed for the floor first and only then bent toward its target.
// Here "down" is the structure's own axis instead: out of the first mask,
// toward the rest of them -- the direction the whole chain runs -- so the
// residual pull and the seed heading both already point where the relay is
// going. Same objective shape as Gravitropism (0 when the candidate heading
// is along `dir`, 1 when against it).
class AxisTropism : public Tropism {
public:
    AxisTropism(std::shared_ptr<Organism> plant, double n, double sigma, Vector3d dir)
        : Tropism(plant, n, sigma), dir_(dir.normalized()) {}
    std::shared_ptr<Tropism> copy(std::shared_ptr<Organism> plant) override {
        auto nt = std::make_shared<AxisTropism>(*this);
        nt->plant = plant;
        return nt;
    }
    double tropismObjective(const Vector3d& pos, const Matrix3d& old, double a, double b,
                            double dx, const std::shared_ptr<Organ> o = nullptr) override {
        return 0.5 * (1.0 - old.times(Vector3d::rotAB(a, b)).times(dir_));
    }
private:
    Vector3d dir_;
};

// CPlantBox starts every base root heading straight down (Organ::getiHeading0
// hard-codes (0,0,-1) for a parentless root, then rotates it by the
// protected `partialIHeading`), and there is no setter. This is the one way
// in without patching the submodule: a derived type may name a protected
// member of its base through a pointer-to-member, and that member is
// mutable. Used once per hop, right after initialize(), to point the seed's
// root out through the mouth it is leaving (see initHop).
struct OrganHeading : CPlantBox::Organ {
    static void set(CPlantBox::Organ& o, const Vector3d& dir) {
        // getiHeading0: heading = ons((0,0,-1)) * partial, so partial =
        // ons^-1 * dir puts the root's first segment along `dir`.
        Vector3d down(0, 0, -1);
        o.*(&OrganHeading::partialIHeading) = Matrix3d::ons(down).inverse().times(dir.normalized());
    }
};

// The dwell's attractors: a hemisphere behind the mask, not just a ring
// around it. Ring 0 is the old rim (rimAttractors: the cavity's outline,
// rim_margin outside it, in the mask's own plane); each ring behind it is
// smaller and further back along -normal, down to a single point at the
// pole, so the nest the roots are drawn into is a cup the head sits in.
// The depth radius is the lateral mean, so the cup is round rather than
// squashed to the cavity's own (shallow) r_depth. `behind` shifts the whole
// thing back (SimParams::nestBehind). With attractors consumed on contact
// (nestHitRadius) there have to be enough of them for the wrap to keep
// finding somewhere new to go.
std::vector<Attractor> nestAttractors(const MaskNode& m, int rings, int perRing,
                                      double behind, double strength, double radius,
                                      double rim_margin) {
    std::vector<Attractor> out;
    rings = std::max(1, rings); perRing = std::max(3, perRing);
    const double rw = m.r_width * rim_margin, rh = m.r_height * rim_margin;
    const double rd = 0.5 * (rw + rh);
    const Vector3d c = m.pos.minus(m.normal.times(behind));
    for (int i = 0; i < rings; ++i) {
        const double lat = (M_PI / 2.0) * double(i) / double(rings);   // 0 = rim, -> pole
        const double cl = std::cos(lat), sl = std::sin(lat);
        for (int j = 0; j < perRing; ++j) {
            const double ang = 2.0 * M_PI * (double(j) + 0.5 * (i & 1)) / perRing;
            Vector3d p = c.plus(m.tangent.times(std::cos(ang) * rw * cl))
                          .plus(m.bitangent.times(std::sin(ang) * rh * cl))
                          .minus(m.normal.times(rd * sl));
            out.push_back(Attractor{p, strength, radius});
        }
    }
    out.push_back(Attractor{c.minus(m.normal.times(rd)), strength, radius});
    return out;
}

// CPlantBox grow space -> render space (Y-up).
//
// CPlantBox grows roots toward -z, so grow -z is "down" and the mask cone hangs
// from an apex at z=0 down to its wide base at z=-height. This maps grow -z to
// render -y, which puts the roots below the seed and the cone's wide base at the
// bottom of the frame -- which is what a root system looks like.
//
// render_relay_gui.cpp's version of this maps grow -z to render +y instead, and
// looks right there only because its blit flips the image vertically on the way
// to the screen ("1.0 - v_uv.y" in blitFS). Copying it here, where nothing
// flips, grew the whole system upward. Note this is a rotation about x and not
// the axis swap (x, z, y): the swap has determinant -1, and mirroring a scene
// whose subject is human faces is not a free choice.
static Vector3d toYup(const Vector3d& v) { return Vector3d(v.x, v.z, -v.y); }

// How far the travelling root actually has to go, in grow space.
//
// The straight chord between two masks is the wrong number whenever travel is
// confined to the cone shell: the chord dips inside the cone, and the shell
// pushes the path back out onto the surface, which is longer -- much longer for
// a big angular step, where the chord cuts across and the path wraps around.
// Sampling the surface between the two points in (depth, angle) parameter space
// and summing the segments is a good enough geodesic for a time budget.
static double conePathLength(const Vector3d& a, const Vector3d& b, double R0,
                             double Hh, double tipR, double taper) {
    auto param = [&](const Vector3d& v, double& t, double& phi) {
        t = std::clamp(-v.z / std::max(1.0, Hh), 0.0, 1.0);
        phi = std::atan2(v.y, v.x);
    };
    auto surface = [&](double t, double phi) {
        double r = tipR + (R0 - tipR) * std::pow(std::max(t, 1e-6), taper);
        return Vector3d(r * std::cos(phi), r * std::sin(phi), -t * Hh);
    };
    double ta, pa, tb, pb;
    param(a, ta, pa); param(b, tb, pb);
    // The short way round, so a hop across the seam is not measured the long way.
    double dphi = pb - pa;
    while (dphi >  M_PI) dphi -= 2.0 * M_PI;
    while (dphi < -M_PI) dphi += 2.0 * M_PI;

    const int kSteps = 24;
    double len = 0.0;
    Vector3d prev = surface(ta, pa);
    for (int i = 1; i <= kSteps; ++i) {
        double f = double(i) / kSteps;
        Vector3d cur = surface(ta + (tb - ta) * f, pa + dphi * f);
        len += cur.minus(prev).length();
        prev = cur;
    }
    return len;
}

static double minDist(const std::vector<Vector3d>& nodes, const Vector3d& p) {
    double best = std::numeric_limits<double>::max();
    for (const auto& n : nodes) best = std::min(best, n.minus(p).length());
    return best;
}

// How deep into the mask's own volume the closest root node is: the mask
// ellipsoid, inflated by `inflate`, evaluated in the mask's frame. < 1 means a
// node is inside it, which is what "arrived" should mean.
//
// This used to be a distance to a *point* against one scalar threshold, which
// is the wrong shape twice over. A mask is 1.4 cm deep and 3.3 cm tall, so a
// sphere big enough to be reachable across the tall axis reaches nearly two and
// a half centimetres clear of the face along the normal -- and every hop
// declared arrival at whatever distance it happened to trip that sphere, so no
// two dwells started from the same place.
static double maskVolumeK(const std::vector<Vector3d>& nodes, const MaskNode& m,
                          double inflate) {
    const double rd = std::max(1e-3, m.r_depth  * inflate);
    const double rw = std::max(1e-3, m.r_width  * inflate);
    const double rh = std::max(1e-3, m.r_height * inflate);
    double best = std::numeric_limits<double>::max();
    for (const auto& n : nodes) {
        Vector3d d = n.minus(m.pos);
        double a = d.times(m.normal) / rd;
        double b = d.times(m.tangent) / rw;
        double c = d.times(m.bitangent) / rh;
        best = std::min(best, std::sqrt(a * a + b * b + c * c));
    }
    return best;
}

struct FrozenHop {
    std::vector<Vector3d> nodes;   // grow-global (offset applied)
    std::vector<Vector2i> segs;
    std::vector<double>   radii;
};

struct RootSim::Impl {
    SimParams p;
    std::string paramPath;
    double tipRadius = 0.0;
    double maskR = 2.6;               // the mask size unit, see SimMask::faceUnit

    // The anchor-first placement (see reset()): a rigid transform, computed once
    // per reset from mask 0's own natural frame, applied to every mask's render-
    // space placement and to the render-space skeleton/tip. Identity until
    // reset() computes it, so an empty sim (masks never built) is a no-op.
    //
    // Stored as the rows of the rotation matrix (so applyAnchor's dot products
    // read directly as "row i . v") plus a translation applied to points only.
    Vector3d anchorRowT{1, 0, 0}, anchorRowB{0, 1, 0}, anchorRowN{0, 0, 1};
    Vector3d anchorTrans{0, 0, 0};

    Vector3d applyAnchorRot(const Vector3d& v) const {
        return Vector3d(anchorRowT.times(v), anchorRowB.times(v), anchorRowN.times(v));
    }
    Vector3d applyAnchorPoint(const Vector3d& v) const {
        return applyAnchorRot(v).plus(anchorTrans);
    }

    // The host the masks sit on, and that travel is confined to. Null for a
    // placement that has no surface (lobes) -- travel is then bounded only by
    // the mask cavities.
    std::shared_ptr<HostSurface> host;
    std::vector<std::pair<double, double>> maskUV;   // per mask, when there is a host
    // masks[0] stands on the host's axis rather than on its surface (see
    // reset()): its maskUV entry is then not a surface coordinate, and the
    // hop that leaves it starts in front of its mouth rather than just
    // behind it.
    bool anchorAxis = false;

    // The first hop that actually grows a RootSystem: 1 with
    // growFromFirstMask (mask 0 is revealed bare, hop 0 never runs), else 0.
    // frozen[k] is that hop's own finished nodes, in order, so hop h's
    // buffer is frozen[h - firstGrowingHop] once finished, or the live one
    // while h == hop and nothing later has started yet.
    int firstGrowingHop = 0;

    Vector3d toRender(const Vector3d& v) const { return applyAnchorPoint(toYup(v)); }

    // The travelling root's own growth law, read off the species file once:
    // elongation rate, maximal length, and the function relating the two. The
    // hop budget is derived from these -- see travelDaysFor.
    double tapRate = 1.0, tapLmax = 0.0;      // subType 1, the travelling root
    double latRate = 1.0, latLmax = 0.0;      // subType 2, what carries on past it
    std::shared_ptr<GrowthFunction> tapGrowth;

    std::vector<MaskNode> masks;      // grow space
    std::vector<MaskNode> revealed;   // grow space
    // Per mask, what setMaskExtent adds to r_width/r_height/r_depth (x, y, z;
    // grow units) for the keep-out and the nest ring only -- see padded().
    std::vector<Vector3d> swing;
    std::vector<SimMask>  revealedRender;
    std::vector<SimMask>  plannedRender;    // every mask, from reset
    std::vector<SimMask>  plannedGrow;      // ...and the same in grow space
    std::vector<FrozenHop> frozen;

    // Current hop state.
    std::shared_ptr<RootSystem> rs;
    std::shared_ptr<Tropism>    base;
    int    hop = 0;
    Vector3d offset{0, 0, 0};
    Vector3d localTarget{0, 0, 0};
    MaskNode localTargetNode;
    std::vector<MaskNode> localRevealed;
    // This hop's attractors, shared with its tropisms so step() can drop
    // the ones a root has reached (p.nestHitRadius).
    maskcav::AttractorSet hopAttrs;
    double hopLen = 0.0, hopPath = 0.0, hopTravelDays = 0.0, hopMaxDays = 0.0;
    double evenAgeDays = 0.0;         // commonAge(), which walks every mask
    double day = 0.0, reachedDay = -1.0;
    bool   reached = false;
    bool   doneFlag = false;
    bool   ok = false;
    HopReport report;                 // the hop in flight
    std::vector<HopReport> reports;

    // Live snapshot (grow-global) refreshed each step.
    std::vector<Vector3d> liveNodes;
    std::vector<Vector2i> liveSegs;
    std::vector<double>   liveRadii;

    // Days this species needs to carry a tip `len` centimetres from the seed.
    //
    // The reason a hop misses its mask is almost never that it was pointed the
    // wrong way -- it is that it was given sixty days to cover a distance this
    // plant cannot cover in sixty days, or cannot cover at all. Two facts about
    // the parameter sets drive that, and both are per species:
    //
    //   * roots elongate on a negative exponential toward lmax, so days are
    //     wildly non-linear in distance -- for Anagallis (lmax 33 cm, r 4
    //     cm/day) twenty centimetres is eight days and thirty is nineteen;
    //   * the tap root stops at lmax, and past that the front is carried on by
    //     a first-order lateral, at the lateral's own much slower rate. That
    //     hand-off is why Anagallis, whose tap root gives out at 33 cm, still
    //     arrives at a mask 36 cm away and not at one 39 cm away.
    //
    // So: the tap root for as far as it goes, laterals for the remainder.
    double travelDaysFor(double len) const {
        const double rTap = std::max(1e-3, tapRate);
        if (tapLmax <= 0.0) return len / rTap;              // no ceiling declared
        const double byTap = std::min(len, 0.9 * tapLmax);  // the asymptote is not reachable
        double days = tapGrowth ? tapGrowth->getAge(byTap, rTap, tapLmax, nullptr)
                                : byTap / rTap;
        if (!std::isfinite(days) || days < 0.0) days = byTap / rTap;
        const double rest = len - byTap;
        if (rest > 0.0) days += rest / std::max(1e-3, latRate);
        return days;
    }

    // Past this the mask is not reachable at all, however many days it is
    // given: the tap root and one lateral together do not span it.
    bool beyondReach(double len) const {
        if (tapLmax <= 0.0) return false;
        return len > 0.9 * tapLmax + 0.9 * latLmax;
    }

    // The mouth point on a mask: pos, offset along the mask's own frame by
    // the mouth's normalised-mesh-frame position (SimParams::faceMouthU/V/N),
    // scaled the same way the cavity radii are (faceScale x faceUnit == fs,
    // see reset()'s cavity-sizing block).
    // The face itself is drawn recessed into the cavity (p.faceRecess of the
    // half-depth behind pos), so the mouth starts from there, not from pos.
    Vector3d mouthPoint(const MaskNode& m) const {
        const double fs = std::max(0.05, (double)p.faceScale) * maskR;
        return m.pos.minus(m.normal.times(m.r_depth * (double)p.faceRecess))
                    .plus(m.tangent.times((double)p.faceMouthU * fs))
                    .plus(m.bitangent.times((double)p.faceMouthV * fs))
                    .plus(m.normal.times((double)p.faceMouthN * fs));
    }

    // Where the travelling root starts a hop: just behind the mask it is
    // leaving, or the seed for the first one.
    Vector3d hopStart(int h) const {
        // Hop 0 travels to mask 0 from the seed -- or, growing out of the
        // first mask, does not exist (reset() reveals mask 0 and starts at
        // hop 1). The latter case is only ever asked by commonAge(), and the
        // answer that gives it a zero-length hop is the mask itself.
        if (h == 0) {
            if (!p.growFromFirstMask || masks.empty()) return Vector3d(0, 0, 0);
            return masks[0].pos;
        }
        int from = h - 1;
        if (p.treeRelay) {
            // Out of whichever revealed mask is nearest, rather than out of the
            // one just left: the system branches instead of threading, and no
            // hop is ever longer than the gap to its closest neighbour.
            double best = std::numeric_limits<double>::max();
            for (int i = 0; i < h; ++i) {
                double d = masks[i].pos.minus(masks[h].pos).length();
                if (d < best) { best = d; from = i; }
            }
        }
        const MaskNode& m = masks[from];
        const Vector3d mouth = mouthPoint(m);
        // Behind the mouth, inside the head. The on-axis anchor's root grows
        // out through the mouth hole along the normal (initHop); every other
        // hop's heads off toward its target from back here, so the face it
        // leaves is never crossed in front.
        const double behind = (from == 0 && anchorAxis) ? (double)p.anchorSpawn
                                                        : (double)p.spawnBehind;
        return mouth.minus(m.normal.times(std::max(0.0, behind)));
    }

    // Which mask a hop leaves from -- the same choice as hopStart, for the
    // surface-path estimate that needs its (u, v).
    int hopFrom(int h) const {
        if (h <= 0 || !p.treeRelay) return h - 1;
        int from = h - 1;
        double best = std::numeric_limits<double>::max();
        for (int i = 0; i < h; ++i) {
            double d = masks[i].pos.minus(masks[h].pos).length();
            if (d < best) { best = d; from = i; }
        }
        return from;
    }

    // The distance a hop has to cover: over the cone surface when travel is
    // confined to the shell, the straight line otherwise.
    double hopPathFor(int h) const {
        Vector3d a = hopStart(h);
        Vector3d b = masks[h].pos.plus(Vector3d(0, 0, (double)p.targetLift));
        const int from = hopFrom(h);
        // Over the host when travel is confined to it and both ends have
        // surface coordinates; the chord otherwise, which is all a hop out of
        // the seed, or out of an on-axis anchor -- neither on the surface --
        // can be measured by.
        if (p.coneSurfaceTravel && host && from >= 0 && !(from == 0 && anchorAxis) &&
            from < (int)maskUV.size() && h < (int)maskUV.size())
            return host->pathBetween(maskUV[from].first, maskUV[from].second,
                                     maskUV[h].first, maskUV[h].second);
        return b.minus(a).length();
    }

    // One age for every hop to finish at, so the nests match.
    //
    // The reference is the longest travel the mask layout implies, taken from
    // the growth law on the *chord* rather than on the surface path the budget
    // uses. The budget has to be safe, so it takes the long way round; this is
    // an estimate of what travel will really cost, and the tip does not take
    // the long way -- the shell has thickness and it cuts the corner. Measured
    // against the chord the growth law is close enough to read off: 6.1 days
    // predicted against 6.0 actual for maize's last hop, 12.9 against 12.8 for
    // kale. Against the surface path it is two to three times too big, and
    // padding every hop out to that trebles the root mass of the whole system.
    //
    // Plus the dwell, which every hop gets in full either way: this only ever
    // makes a hop wait longer, never shorter.
    double commonAge() const {
        double worst = 0.0;
        for (int h = 0; h < (int)masks.size(); ++h) {
            Vector3d a = hopStart(h);
            Vector3d b = masks[h].pos.plus(Vector3d(0, 0, (double)p.targetLift));
            worst = std::max(worst, std::min((double)p.maxHopDays,
                                             travelDaysFor(b.minus(a).length())));
        }
        return worst + std::max(0.0, (double)p.maxDwellDays());
    }

    void rebuildTropism(double mainW, double latW, bool travel, double dwellThreshold) {
        // Every hop now starts at its source mask's *mouth* (hopStart), which
        // sits inside that mask's own keep-clear tube (the anchor, leaving
        // straight out its front) or close enough to its own cavity ellipsoid
        // (a surface mask, leaving just behind the mouth) that the geometry
        // would otherwise call the freshly spawned root "already inside a
        // disallowed region" -- which the tropism then spends the whole
        // travel fighting instead of steering toward the next mask. So the
        // hop's own source mask -- localRevealed[hopFrom(hop)], since masks
        // are revealed in index order and localRevealed mirrors that -- is
        // left out of the confinement geometry entirely (cavity and tube
        // both) for that one travel, leaving the root free to clear the
        // mouth outward along the normal before any cavity repulsion (this
        // mask's or another's) applies. Dwell (travel=false) always gets the
        // full geometry back, including this mask's own cavity.
        //
        // Mask 0 -- the visitor's own face, the one the chain grows out of --
        // has no cavity and no tube at any point, for any hop: the roots
        // grow out of it, so nothing should ever push them back off it.
        // Only masks 1..n keep the roots out.
        int noCavity = -1;
        if (travel) {
            const int from = hopFrom(hop);
            if (from >= 0 && from < (int)localRevealed.size())
                noCavity = from;
        }
        std::vector<MaskNode> geomMasks;
        for (size_t k = 1; k < localRevealed.size(); ++k)
            if ((int)k != noCavity) geomMasks.push_back(localRevealed[k]);
        auto geom = buildCavityGeometry(geomMasks, p.R0, p.Hh, false, 2.0,
                                        tipRadius, p.viewCylLen, 0.9, p.taperPower, -1);
        // The travel shell: intersecting the cavity-avoidance geometry with a
        // thin shell around the cone makes the root crawl over the surface
        // rather than cut through the middle. It only constrains the radial
        // axis, which is orthogonal to the direction of travel, so it does not
        // fight the tangential pull toward the target.
        //
        // The first hop out of the on-axis anchor (mask 0, anchorAxis) has no
        // surface coordinate at all -- it sits on the axis, not on the cone's
        // surface (see hopStart/hopPathFor, which already treat it as a
        // chord, not a surface path) -- so there is no surface for it to
        // crawl between and the shell is skipped for it: with the shell on,
        // it was pinning that hop to the cone's lateral surface and bending
        // it off the straight line down to mask 1, even though the cavity
        // exemption above already leaves both masks' ellipsoids out of the
        // way. Every other hop (surface mask to surface mask, or the anchor's
        // own dwell once it is reached) still gets the shell.
        //
        // The global cone apex sits at -offset in this hop's local coordinates.
        std::shared_ptr<SignedDistanceFunction> growGeom = geom;
        const bool firstAxisHop = anchorAxis && hopFrom(hop) == 0;
        if (p.coneSurfaceTravel && travel && host && !firstAxisHop) {
            auto sh = host->shell(p.coneShellThickness, offset.times(-1.0));
            growGeom = std::make_shared<CPlantBox::SDF_Intersection>(geom, sh);
        }
        rs->setGeometry(growGeom);
        std::vector<Attractor> attrs;
        if (travel) {
            double reach = std::max((double)p.travelPullReach * hopLen, (double)p.R0);
            attrs.push_back(Attractor{localTarget, 1.0, reach});
        } else {
            attrs = nestAttractors(padded(hop, localTargetNode), p.nestRings, p.nestPerRing,
                                   (double)p.nestBehind, 1.0, 3.0, 1.15);
        }
        hopAttrs = maskcav::makeAttractorSet(std::move(attrs));
        if (dwellThreshold >= 0.0) {
            rs->setTropism(combinedAttractionSplitTimed(
                rs, base, hopAttrs, p.mainTravelTrials, 6.0, p.sigma,
                mainW, p.lateralWeight, latW, dwellThreshold, growGeom), -1);
        } else {
            rs->setTropism(combinedAttractionSplit(
                rs, base, hopAttrs, p.mainTravelTrials, 6.0, p.sigma,
                mainW, latW, growGeom, growGeom), -1);
        }
    }

    // MaskNode (grow space) -> SimMask (render space).
    SimMask toSimMask(const MaskNode& m) const {
        Vector3d pos = toYup(m.pos), n = toYup(m.normal);
        // The mask frame carries through toYup unchanged. MaskCavities builds
        // the bitangent as "up the cone surface", i.e. toward the apex at grow
        // z=0, and toYup now sends that to render +y -- so a head placed along
        // this frame stands upright with no correction. (It used to need a
        // 180-degree rotation about the normal here, purely to undo the
        // vertical flip the old toYup baked in.)
        Vector3d t = toYup(m.tangent);
        Vector3d b = toYup(m.bitangent);
        // Anchor-first placement, composed after toYup (see reset()): a single
        // rigid transform so mask 0 always lands at the same fixed pose,
        // whatever host/pattern/seed produced its natural first sample.
        pos = applyAnchorPoint(pos);
        n = applyAnchorRot(n);
        t = applyAnchorRot(t);
        b = applyAnchorRot(b);
        SimMask sm;
        sm.pos[0] = (float)pos.x; sm.pos[1] = (float)pos.y; sm.pos[2] = (float)pos.z;
        sm.normal[0] = (float)n.x; sm.normal[1] = (float)n.y; sm.normal[2] = (float)n.z;
        sm.tangent[0] = (float)t.x; sm.tangent[1] = (float)t.y; sm.tangent[2] = (float)t.z;
        sm.bitangent[0] = (float)b.x; sm.bitangent[1] = (float)b.y; sm.bitangent[2] = (float)b.z;
        sm.rDepth = (float)m.r_depth; sm.rWidth = (float)m.r_width; sm.rHeight = (float)m.r_height;
        sm.faceUnit = (float)maskR;
        return sm;
    }

    void pushRevealedRender(const MaskNode& m) { revealedRender.push_back(toSimMask(m)); }

    // Mask `idx`'s node with its motion swing added to the radii: what the
    // roots are kept out of and the nest is rung around. Everything that is
    // about the face itself (drawing, the mouth, arrival) uses the bare node.
    MaskNode padded(int idx, const MaskNode& base) const {
        MaskNode m = base;
        if (idx >= 0 && idx < (int)swing.size()) {
            m.r_width  += swing[size_t(idx)].x;
            m.r_height += swing[size_t(idx)].y;
            m.r_depth  += swing[size_t(idx)].z;
        }
        return m;
    }

    void initHop(int h) {
        Vector3d maskGlobal = masks[h].pos;
        // The travel target sits a little above the mask so the main root
        // arrives and dwells above the face, framing it, while the dwell rim
        // still wraps the mask itself. +grow z is render +y, so a positive lift
        // is up on screen.
        Vector3d targetGlobal = maskGlobal.plus(Vector3d(0, 0, (double)p.targetLift));

        rs = std::make_shared<RootSystem>();
        rs->readParameters(paramPath, "plant", true, false);
        // No laterals until the main root has cleared the mouth (see
        // SimParams::basalClear): the basal zone is the spawn depth plus
        // the clearance, with no spread.
        if (p.basalClear >= 0.f) {
            const int from = hopFrom(h);
            const double depth = (from == 0 && anchorAxis) ? std::max(0.f, p.anchorSpawn)
                                                           : std::max(0.f, p.spawnBehind);
            if (auto tap = rs->getRootRandomParameter(1)) {
                tap->lb = std::max(tap->lb, depth + (double)p.basalClear);
                tap->lbs = 0.0;
            }
        }
        rs->setSeed(p.seed + (unsigned)h);
        rs->initialize(false);
        // The seed's initial heading, rather than CPlantBox's default straight
        // down (which had the first segments heading for the floor before the
        // tropism could turn them). The on-axis anchor's root leaves along
        // its normal -- out through the mouth, which is the chain axis (see
        // hopStart). Every other hop starts behind the face it leaves and
        // heads straight for its target from there: along the normal it
        // would burst out the front of a face whose next mask is behind it.
        {
            const int from = hopFrom(h);
            Vector3d out = chainAxis();
            if (from == 0 && anchorAxis) out = masks[0].normal;
            else {
                const Vector3d d = targetGlobal.minus(hopStart(h));
                if (d.length() > 1e-6) out = d.normalized();
            }
            for (auto& o : rs->getBaseRoots()) OrganHeading::set(*o, out);
        }
        auto seedNodes = rs->getNodes();
        Vector3d localSeed = seedNodes.empty() ? Vector3d(0, 0, 0) : seedNodes[0];
        // Where this hop's root actually starts. It used to come from a
        // `prevPos` member updated at the end of the previous hop, which had
        // two bugs in it: growing out of the first mask left it at the world
        // origin (nothing had finished yet), so the opening root sprouted from
        // the seed point sixteen centimetres away from the face it was supposed
        // to be leaving; and tree relay only ever changed the *estimated* path,
        // never the spawn, so a branching relay still grew from the last mask.
        // hopStart() is the single answer to "where does hop h begin".
        offset = hopStart(h).minus(localSeed);
        localTarget = targetGlobal.minus(offset);

        // Masks are revealed in index order, so revealed[k] is masks[k].
        localRevealed.clear();
        for (size_t k = 0; k < revealed.size(); ++k) {
            MaskNode lm = padded((int)k, revealed[k]); lm.pos = revealed[k].pos.minus(offset);
            localRevealed.push_back(lm);
        }
        localTargetNode = masks[h];
        localTargetNode.pos = maskGlobal.minus(offset);

        base = std::make_shared<AxisTropism>(rs, 1.0, p.sigma, chainAxis());
        hopLen = localTarget.minus(localSeed).length();
        hopPath = hopPathFor(h);

        // Every hop travels. There used to be a "seed hop" here -- hop 0,
        // growing out of the first mask, wrapped it for a dwell before
        // anything left -- but the face the piece opens on is meant to stay
        // bare, with one root leaving it: reset() reveals mask 0 and starts
        // the relay at hop 1.
        rebuildTropism(p.weight, p.lateralWeight, true, -1.0);

        // The travel budget: what the distance costs this species, allowing for
        // the fact that the root does not travel in a straight line, capped by
        // hop days so a hop that cannot arrive still ends. Everything past the
        // budget is dwell, so the whole hop is budget + dwell.
        const double reachLen = hopPath * std::max(1.0, (double)p.travelSlack);
        const double need = travelDaysFor(reachLen);
        hopTravelDays = std::min((double)p.maxHopDays, need);
        hopMaxDays = hopTravelDays + std::max(0.0, (double)p.dwellDaysFor(h));
        if (p.evenNests) hopMaxDays = std::max(hopMaxDays, evenAgeDays);

        day = 0.0; reachedDay = -1.0; reached = false;
        report = HopReport{};
        report.mask = h;
        report.chord = (float)hopLen;
        report.path  = (float)hopPath;
        report.budgetDays = (float)hopTravelDays;
        report.needDays   = (float)need;
        report.outOfReach = beyondReach(hopPath);
        report.reachDist  = 1e9f;   // normalised mask-volume depth; see maskVolumeK
        snapshotLive();
    }

    // Where the chain runs: from the first mask toward the centroid of the
    // others (grow space; a direction, so no offset). The anchor's own
    // normal when there is nothing else to point at.
    Vector3d chainAxis() const {
        if (masks.size() < 2) return masks.empty() ? Vector3d(0, 0, -1) : masks[0].normal;
        Vector3d c(0, 0, 0);
        for (size_t i = 1; i < masks.size(); ++i) c = c.plus(masks[i].pos);
        c = c.times(1.0 / double(masks.size() - 1));
        Vector3d d = c.minus(masks[0].pos);
        return d.length() > 1e-6 ? d.normalized() : masks[0].normal;
    }

    void snapshotLive() {
        SegmentAnalyser ana(*rs);
        auto radii = ana.getParameter("radius");
        liveNodes.clear();
        liveNodes.reserve(ana.nodes.size());
        for (const auto& n : ana.nodes) liveNodes.push_back(n.plus(offset));
        liveSegs = ana.segments;
        liveRadii = radii;
    }

    void finalizeHop() {
        SegmentAnalyser ana(*rs);
        auto radii = ana.getParameter("radius");
        FrozenHop fh;
        fh.nodes.reserve(ana.nodes.size());
        for (const auto& n : ana.nodes) fh.nodes.push_back(n.plus(offset));
        fh.segs = ana.segments;
        fh.radii = radii;
        frozen.push_back(std::move(fh));
        report.days = (float)day;
        report.dwellDays = reached ? (float)(day - reachedDay) : 0.f;
        report.nodes = (int)frozen.back().nodes.size();
        reports.push_back(report);

        liveNodes.clear(); liveSegs.clear(); liveRadii.clear();
        hop++;
        if (hop >= p.N) { doneFlag = true; rs.reset(); }
        else initHop(hop);
    }

    void step() {
        if (doneFlag || !ok) return;
        double dt = std::max(0.02, (double)p.growthDt);
        rs->simulate(dt, false);
        day += dt;

        // A nest attractor is spent once a root has reached it: the pull was
        // there to bring roots to that spot, and roots already there would
        // otherwise keep circling it. Travel's single target is left alone
        // -- arrival is maskVolumeK's business below.
        if (reached && hopAttrs && !hopAttrs->empty() && p.nestHitRadius > 0.f) {
            const auto nodes = rs->getNodes();
            const double r = (double)p.nestHitRadius;
            auto& at = *hopAttrs;
            at.erase(std::remove_if(at.begin(), at.end(), [&](const Attractor& a) {
                for (const auto& n : nodes)
                    if (a.pos.minus(n).length() <= r) return true;
                return false;
            }), at.end());
        }

        // Out of travel budget: reveal the mask and dwell where we are,
        // rather than stall the whole relay on one mask nobody can reach.
        bool forced = !reached && day > hopTravelDays;
        if (!reached) {
            // Arrival is a geometric fact -- the tip is in the mask's volume --
            // and the day budget is only the give-up rule for a mask that
            // cannot be reached at all.
            double k = maskVolumeK(rs->getNodes(), localTargetNode, p.reachMult);
            report.reachDist = (float)std::min((double)report.reachDist, k);
            report.threshold = 1.f;
            if (k < 1.0 || forced) {
                reached = true; reachedDay = day;
                report.forced = (k >= 1.0);
                report.travelDays = (float)day;
                localRevealed.push_back(padded(hop, localTargetNode));
                revealed.push_back(masks[hop]);
                pushRevealedRender(masks[hop]);
                rebuildTropism(p.dwellWeightFor(hop), p.dwellLateralFor(hop), false, reachedDay);
            }
        }
        snapshotLive();
        // The dwell in full, and then -- with even nests on -- however much
        // longer it takes to reach the age the other hops will reach.
        double dwellEnd = reachedDay + p.dwellDaysFor(hop);
        if (p.evenNests) dwellEnd = std::max(dwellEnd, evenAgeDays);
        if ((reached && day > dwellEnd) || day >= hopMaxDays)
            finalizeHop();
    }
};

RootSim::RootSim() : impl_(new Impl()) {}
RootSim::~RootSim() = default;

bool RootSim::reset(const SimParams& p) {
    impl_->p = p;
    impl_->paramPath = p.paramDir + p.speciesXml;
    impl_->tipRadius = 0.22 * p.R0;
    impl_->masks.clear();
    impl_->revealed.clear();
    impl_->revealedRender.clear();
    impl_->plannedRender.clear();
    impl_->plannedGrow.clear();
    impl_->frozen.clear();
    impl_->liveNodes.clear(); impl_->liveSegs.clear(); impl_->liveRadii.clear();
    impl_->reports.clear();
    impl_->hop = 0;
    impl_->doneFlag = false;
    impl_->ok = false;

    const double goldenRad = M_PI * (3.0 - std::sqrt(5.0));
    const double maskR = impl_->maskR;
    // Host and pattern, composed. Anything unrecognised falls back to the cone
    // and the spiral rather than to an empty scene: a preset from a later build
    // naming a host this one does not have should still grow something.
    const double angStep = p.angleStepGoldenMult * goldenRad;
    impl_->host.reset();
    impl_->maskUV.clear();
    impl_->anchorAxis = false;

    if (p.host == "lobes") {
        // No host surface: the roots fill the volume between the faces instead
        // of crawling a sheet, which is the whole point of a lobe.
        impl_->masks = lobePlacement(p.N, p.R0 * 0.55, p.Hh, p.tubeRadius,
                                     p.groupSize, maskR, angStep);
    } else {
        if (p.host == "cylinder")    impl_->host = std::make_shared<CylinderHost>(p.R0, p.Hh);
        else if (p.host == "sphere") impl_->host = std::make_shared<SphereHost>(p.R0);
        else if (p.host == "torus")  impl_->host = std::make_shared<TorusHost>(p.R0, p.tubeRadius);
        else impl_->host = std::make_shared<ConeHost>(p.R0, p.Hh, impl_->tipRadius, p.taperPower);

        if (p.pattern == "helix")
            impl_->maskUV = patternHelix(p.N, p.startFrac, p.endFrac, p.helixTurns);
        else if (p.pattern == "rosette")
            impl_->maskUV = patternRosettes(p.N, p.startFrac, p.endFrac,
                                            p.groupSize, p.groupSpread, angStep);
        else if (p.pattern == "feature")
            impl_->maskUV = patternFeatureClusters(p.N, p.startFrac, p.endFrac, {},
                                                   p.seed, p.featureClusters);
        else
            impl_->maskUV = patternPhyllotaxis(p.N, p.startFrac, p.endFrac,
                                               angStep, p.distStepFrac);

        impl_->masks.clear();
        impl_->masks.reserve(impl_->maskUV.size());
        for (const auto& uv : impl_->maskUV)
            impl_->masks.push_back(impl_->host->maskAt(uv.first, uv.second, maskR));

        // The anchor on the axis, facing down it. The cone and the cylinder
        // hang from the seed at grow z=0 down -z, so "down the axis" is
        // -z, at the height the pattern's first sample would have had; the
        // chain then runs down from the face's front rather than round the
        // surface from its chin. The frame is right-handed like coneMaskAt's
        // (tangent x bitangent = normal), so the face is not mirrored. The
        // sphere and the torus have no such axis and keep their first sample.
        impl_->anchorAxis = p.anchorOnAxis && !impl_->masks.empty() &&
                            (p.host == "cone" || p.host == "cylinder" ||
                             (p.host != "sphere" && p.host != "torus"));
        if (impl_->anchorAxis) {
            MaskNode& a = impl_->masks[0];
            const double t0 = std::clamp((double)p.startFrac, 0.0, 1.0);
            a.pos       = Vector3d(0.0, 0.0, -t0 * p.Hh);
            a.normal    = Vector3d(0.0, 0.0, -1.0);
            a.tangent   = Vector3d(1.0, 0.0, 0.0);
            a.bitangent = a.normal.cross(a.tangent).normalized();   // (0,-1,0)
        }
    }
    if (impl_->masks.empty()) return false;

    // The cavity is the face: every mask's ellipsoid radii are the drawn
    // face's half-extents in the mask's frame plus the margin, whatever the
    // host's maskAt gave it (a fixed oval that was 1.5x the default face and
    // did not follow faceScale -- the nest wrapped air). Everything the nest
    // is built from reads these: the cavity, the keep-clear tube's radius,
    // the rim attractors, the spawn point at the mouth and the arrival test.
    {
        const double fs = std::max(0.05, (double)p.faceScale) * maskR;
        const double m = 1.0 + std::max(0.0, (double)p.cavityMargin);
        for (MaskNode& mn : impl_->masks) {
            mn.r_width  = std::max(0.2, fs * (double)p.faceHalfW * m);
            mn.r_height = std::max(0.2, fs * (double)p.faceHalfH * m);
            mn.r_depth  = std::max(0.2, fs * (double)p.faceHalfD * m);
        }
        impl_->swing.assign(impl_->masks.size(), Vector3d(0, 0, 0));
    }

    // Anchor-first placement.
    //
    // masks[0] is "the anchor" -- placed by the host/pattern's own first
    // sample, wherever that happens to fall (a UV of (0, startFrac) on
    // whatever host is configured). That is not a chosen transform, it is
    // whatever the pattern math produced, and it moves whenever N, the host,
    // the pattern, or the seed changes -- which is exactly the placement the
    // directive wants inverted: RootScene needs mask 0 at one fixed, known
    // pose so cloth/collision geometry can be built against it without
    // knowing anything about the growth layout.
    //
    // Fixed anchor pose (a look decision, not a derived one): render-space
    // origin, normal facing +z, bitangent (up-the-face) along +y. This reads
    // square-on to RootScene's default camera (azimuth ~0.6 rad, elevation
    // ~0.35 rad -- eye sits mostly along +x/+y/+z from the target, so a mask
    // facing +z presents its front rather than its edge or its back) and
    // keeps the face upright, matching how appendFaceVertexData expects a
    // mask's own frame to already be "correct side up".
    //
    // T is the unique rigid transform mapping mask 0's own natural (toYup'd)
    // frame onto that fixed pose: since both frames are orthonormal, the
    // rotation is just "rows = the natural frame's axes" (a transpose/inverse
    // of an orthonormal matrix is its transpose), and the translation carries
    // the natural position to the origin. Composed *after* toYup, per the
    // plan -- CPlantBox's own grow-space math (Tropism, SDF hosts, cavity
    // avoidance) is completely untouched by this; only the render-space
    // output (every mask's frame, the skeleton, and the tip) is transformed.
    //
    // With the anchor on the axis (anchorOnAxis) the whole cone hangs off
    // the anchor's normal, so "normal to +z" would lay the structure down
    // along z, level -- and then nothing later in the piece hangs: the Turn
    // has no vertical to turn to and the hood is a field of structures on
    // their sides. So the on-axis anchor is pitched: its normal goes to
    // (0, -sin a, cos a) with a = anchorPitchDeg, facing down-and-toward +z,
    // and the chain hangs (90 - a) degrees off vertical, leaning toward the
    // camera that stands down that normal. Its bitangent goes to
    // (0, cos a, sin a), so from that camera (the renderer's up is world +y)
    // the face is upright. Composed as a rotation about x on top of the
    // frame-to-axes map: rows t0, c b0 - s n0, s b0 + c n0.
    {
        const Vector3d n0 = toYup(impl_->masks[0].normal);
        const Vector3d t0 = toYup(impl_->masks[0].tangent);
        const Vector3d b0 = toYup(impl_->masks[0].bitangent);
        const Vector3d p0 = toYup(impl_->masks[0].pos);
        const double a = impl_->anchorAxis
            ? std::clamp((double)p.anchorPitchDeg, 0.0, 85.0) * M_PI / 180.0 : 0.0;
        const double c = std::cos(a), s = std::sin(a);
        impl_->anchorRowT = t0;
        impl_->anchorRowB = b0.times(c).minus(n0.times(s));
        impl_->anchorRowN = b0.times(s).plus(n0.times(c));
        impl_->anchorTrans = Vector3d(0, 0, 0);   // applyAnchorPoint needs it zeroed first
        impl_->anchorTrans = Vector3d(0, 0, 0).minus(impl_->applyAnchorRot(p0));
    }

    // Probe the parameter file: readParameters throws if the XML is missing.
    // The probe also carries the one thing the hop budget needs out of the
    // species file -- how the main root (subType 1, the tap root in every one
    // of these parameter sets) elongates.
    try {
        auto probe = std::make_shared<RootSystem>();
        probe->readParameters(impl_->paramPath, "plant", true, false);
        probe->initialize(false);
        if (auto tap = probe->getRootRandomParameter(1)) {
            impl_->tapRate   = tap->r;
            impl_->tapLmax   = tap->lmax;
            impl_->tapGrowth = tap->f_gf;
            impl_->latRate   = tap->r;
            impl_->latLmax   = 0.0;
        }
        if (auto lat = probe->getRootRandomParameter(2)) {
            impl_->latRate = lat->r;
            impl_->latLmax = lat->lmax;
        }
    } catch (...) {
        return false;
    }
    impl_->ok = true;
    for (const auto& m : impl_->masks) {
        impl_->plannedRender.push_back(impl_->toSimMask(m));
        SimMask g;
        auto put = [](float out[3], const Vector3d& v) {
            out[0] = (float)v.x; out[1] = (float)v.y; out[2] = (float)v.z;
        };
        put(g.pos, m.pos); put(g.normal, m.normal); put(g.tangent, m.tangent);
        put(g.bitangent, m.bitangent);
        g.rDepth = (float)m.r_depth; g.rWidth = (float)m.r_width; g.rHeight = (float)m.r_height;
        g.faceUnit = (float)impl_->maskR;
        impl_->plannedGrow.push_back(g);
    }
    impl_->evenAgeDays = impl_->commonAge();

    // Growing out of the first mask: mask 0 is revealed here, bare, with no
    // hop of its own -- no root travels to it and none dwells on it -- and
    // the relay starts at hop 1, leaving it. A zero-day report stands in for
    // the hop it did not take, so hops() still has one entry per mask.
    impl_->hop = 0;
    impl_->firstGrowingHop = p.growFromFirstMask ? 1 : 0;
    if (p.growFromFirstMask) {
        impl_->revealed.push_back(impl_->masks[0]);
        impl_->pushRevealedRender(impl_->masks[0]);
        HopReport r;
        r.mask = 0;
        impl_->reports.push_back(r);
        impl_->hop = 1;
        if (impl_->hop >= p.N) { impl_->doneFlag = true; return true; }
    }
    impl_->initHop(impl_->hop);
    return true;
}

void RootSim::step() { impl_->step(); }
bool RootSim::valid() const { return impl_->ok; }
bool RootSim::done()  const { return impl_->doneFlag; }

void RootSim::geometry(std::vector<float>& nodesXYZ,
                       std::vector<int>&   segs,
                       std::vector<float>& radii) const {
    nodesXYZ.clear(); segs.clear(); radii.clear();
    int base = 0;
    auto emit = [&](const std::vector<Vector3d>& ns, const std::vector<Vector2i>& ss,
                    const std::vector<double>& rs) {
        for (const auto& n : ns) {
            Vector3d y = impl_->applyAnchorPoint(toYup(n));
            nodesXYZ.push_back((float)y.x); nodesXYZ.push_back((float)y.y); nodesXYZ.push_back((float)y.z);
        }
        for (const auto& s : ss) { segs.push_back(s.x + base); segs.push_back(s.y + base); }
        for (double r : rs) radii.push_back((float)r);
        base += (int)ns.size();
    };
    for (const auto& fh : impl_->frozen) emit(fh.nodes, fh.segs, fh.radii);
    emit(impl_->liveNodes, impl_->liveSegs, impl_->liveRadii);
}

const std::vector<SimMask>& RootSim::revealedMasks() const { return impl_->revealedRender; }

int RootSim::currentMask() const {
    if (impl_->doneFlag || !impl_->ok) return -1;
    return impl_->hop;
}

bool RootSim::arrivedAtMask() const {
    return !impl_->doneFlag && impl_->ok && impl_->reached;
}

bool RootSim::tip(float out[3]) const {
    const auto& live = impl_->liveNodes;
    if (live.empty() || impl_->doneFlag) return false;
    // Furthest from the hop's own start, rather than the last node in the
    // array: SegmentAnalyser's order is not growth order, and the laterals are
    // in there too.
    const Vector3d from = impl_->hopStart(impl_->hop);
    double best = -1.0;
    Vector3d bestNode = live.front();
    for (const auto& n : live) {
        const double d = n.minus(from).length();
        if (d > best) { best = d; bestNode = n; }
    }
    const Vector3d y = impl_->applyAnchorPoint(toYup(bestNode));
    out[0] = (float)y.x; out[1] = (float)y.y; out[2] = (float)y.z;
    return true;
}

const std::vector<SimMask>& RootSim::plannedMasks() const { return impl_->plannedRender; }
const std::vector<SimMask>& RootSim::plannedMasksGrow() const { return impl_->plannedGrow; }

const std::vector<HopReport>& RootSim::hops() const { return impl_->reports; }

int RootSim::hopCount() const { return impl_->ok ? (int)impl_->masks.size() : 0; }

bool RootSim::hopMaxLateralDeviation(int h, const float a[3], const float b[3], float& maxDev) const {
    if (!impl_->ok || h < 0) return false;
    const int idx = h - impl_->firstGrowingHop;
    if (idx < 0 || idx >= (int)impl_->frozen.size()) return false;
    const Vector3d A(a[0], a[1], a[2]), B(b[0], b[1], b[2]);
    Vector3d dir = B.minus(A);
    const double len = dir.length();
    if (len < 1e-9) return false;
    dir = dir.times(1.0 / len);
    double worst = 0.0;
    for (const auto& n : impl_->frozen[size_t(idx)].nodes) {
        const Vector3d p = impl_->toRender(n);
        const Vector3d v = p.minus(A);
        const double proj = v.times(dir);
        const Vector3d perp = v.minus(dir.times(proj));
        worst = std::max(worst, perp.length());
    }
    maxDev = (float)worst;
    return true;
}

bool RootSim::maskMouthPoint(int m, float out[3]) const {
    if (!impl_->ok || m < 0 || m >= (int)impl_->masks.size()) return false;
    const Vector3d y = impl_->toRender(impl_->mouthPoint(impl_->masks[size_t(m)]));
    out[0] = (float)y.x; out[1] = (float)y.y; out[2] = (float)y.z;
    return true;
}

void RootSim::setFaceMouth(float u, float v, float n, bool reseed) {
    if (!impl_->ok) return;
    impl_->p.faceMouthU = u; impl_->p.faceMouthV = v; impl_->p.faceMouthN = n;
    // day is 0 until the first step(): the seed is all that exists.
    if (reseed && !impl_->doneFlag && impl_->day <= 0.0) impl_->initHop(impl_->hop);
}

void RootSim::setMaskExtent(int m, float halfW, float halfH, float halfD) {
    if (!impl_->ok || m < 0 || m >= (int)impl_->masks.size()) return;
    if (impl_->swing.size() != impl_->masks.size())
        impl_->swing.assign(impl_->masks.size(), Vector3d(0, 0, 0));
    const SimParams& p = impl_->p;
    const double fs = std::max(0.05, (double)p.faceScale) * impl_->maskR;
    const double mg = 1.0 + std::max(0.0, (double)p.cavityMargin);
    const double k = std::max(0.0, (double)p.motionCavity);
    const MaskNode& mn = impl_->masks[size_t(m)];
    impl_->swing[size_t(m)] = Vector3d(
        k * std::max(0.0, fs * (double)halfW * mg - mn.r_width),
        k * std::max(0.0, fs * (double)halfH * mg - mn.r_height),
        k * std::max(0.0, fs * (double)halfD * mg - mn.r_depth));
    if (!impl_->doneFlag && impl_->day <= 0.0) impl_->initHop(impl_->hop);
}

RootSim::HopSpawn RootSim::hopSpawn(int h) const {
    HopSpawn info;
    if (!impl_->ok || h < 0 || h >= (int)impl_->masks.size()) return info;
    info.fromMask = impl_->hopFrom(h);

    const Vector3d spawn = impl_->toRender(impl_->hopStart(h));
    info.spawn[0] = (float)spawn.x; info.spawn[1] = (float)spawn.y; info.spawn[2] = (float)spawn.z;

    if (info.fromMask >= 0 && info.fromMask < (int)impl_->masks.size()) {
        const Vector3d mouth = impl_->toRender(impl_->mouthPoint(impl_->masks[size_t(info.fromMask)]));
        info.mouth[0] = (float)mouth.x; info.mouth[1] = (float)mouth.y; info.mouth[2] = (float)mouth.z;
    }

    // The actual node buffer CPlantBox placed for this hop, node 0 -- not a
    // recomputed point. Finished hops read it from `frozen`; the hop in
    // flight (h == impl_->hop, nothing frozen for it yet) from the live
    // snapshot; anything not yet started has none.
    const int idx = h - impl_->firstGrowingHop;
    const std::vector<Vector3d>* nodes = nullptr;
    if (idx >= 0 && idx < (int)impl_->frozen.size())
        nodes = &impl_->frozen[size_t(idx)].nodes;
    else if (h == impl_->hop && !impl_->doneFlag && !impl_->liveNodes.empty())
        nodes = &impl_->liveNodes;
    if (nodes && !nodes->empty()) {
        info.started = true;
        const Vector3d n0 = impl_->toRender(nodes->front());
        info.firstNode[0] = (float)n0.x; info.firstNode[1] = (float)n0.y; info.firstNode[2] = (float)n0.z;
    }
    return info;
}

}  // namespace rootsim
