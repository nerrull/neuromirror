#pragma once
// Where the masks live, and what the roots are confined to while they travel
// between them -- as two separate choices.
//
// The piece grew up around a cone, and the cone was doing two unrelated jobs at
// once: it decided where each face sits, and it was the surface the travelling
// root crawled over. Conflating those makes every new idea a new special case
// ("a helix" is not a topology -- it is a curve *on* a cylinder), so they are
// split here into two axes that compose freely:
//
//   HostSurface   the thing roots crawl on: cone, cylinder, sphere, torus.
//                 Supplies a frame at surface coordinates (u around, v along)
//                 and a shell SDF for confinement.
//   Pattern       where the masks go, in that surface's own (u, v): a
//                 phyllotactic spiral, a helix, rosettes, feature clusters.
//
// Any pattern works on any surface. A helix on a cylinder is a corkscrew; the
// same helix on a cone is a spiral that tightens as it descends; phyllotaxis on
// a cylinder is the spiral without the widening -- which incidentally removes
// the density gradient the cone causes, since spacing no longer grows with
// depth.
//
// Lobes are the exception and are deliberately not a surface: see coneLobes.
//
// Conventions, shared with MaskCavities.h: grow space has the seed at z = 0 and
// the structure hanging toward -z. u is an angle in radians, around the axis;
// v runs 0 (at the seed end) to 1 (far end). A mask's frame is normal (out of
// the surface), tangent (horizontal, around) and bitangent (up the surface,
// back toward the seed) -- a head placed on that frame stands upright.

#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>
#include <vector>

#include "MaskCavities.h"

namespace maskcav {

// --- extra SDF primitives ---------------------------------------------------
// (SDF_Cone and the finite SDF_Cylinder live in MaskCavities.h.)

class SDF_Sphere : public SignedDistanceFunction {
public:
    SDF_Sphere(const Vector3d& c, double r) : c_(c), r_(r) {}
    double getDist(const Vector3d& v) const override { return v.minus(c_).length() - r_; }
    std::string toString() const override { return "SDF_Sphere"; }
private:
    Vector3d c_; double r_;
};

// Torus about the z axis: a tube of radius r_ swept round a circle of radius R_.
class SDF_Torus : public SignedDistanceFunction {
public:
    SDF_Torus(const Vector3d& c, double R, double r) : c_(c), R_(R), r_(r) {}
    double getDist(const Vector3d& v) const override {
        Vector3d d = v.minus(c_);
        double q = std::sqrt(d.x * d.x + d.y * d.y) - R_;
        return std::sqrt(q * q + d.z * d.z) - r_;
    }
    std::string toString() const override { return "SDF_Torus"; }
private:
    Vector3d c_; double R_, r_;
};

// An infinite-length cylinder about z, as a *solid* (negative inside), for
// shells that should not be capped at the ends.
class SDF_CylinderZ : public SignedDistanceFunction {
public:
    SDF_CylinderZ(const Vector3d& c, double r) : c_(c), r_(r) {}
    double getDist(const Vector3d& v) const override {
        double dx = v.x - c_.x, dy = v.y - c_.y;
        return std::sqrt(dx * dx + dy * dy) - r_;
    }
    std::string toString() const override { return "SDF_CylinderZ"; }
private:
    Vector3d c_; double r_;
};

// --- the host surface -------------------------------------------------------

struct HostSurface {
    virtual ~HostSurface() = default;

    // A mask sitting on the surface at (u, v), sized by maskR.
    virtual MaskNode maskAt(double u, double v, double maskR) const = 0;

    // A thin shell straddling the surface: the region between the surface
    // offset outward and inward by thickness/2. Confining travel to it is what
    // makes roots crawl over the host instead of cutting through its middle.
    //
    // `origin` is where the host's own origin sits in the caller's frame -- the
    // grower works in a frame translated to wherever the last hop ended, so the
    // same global host has to be evaluatable on local coordinates.
    virtual std::shared_ptr<SignedDistanceFunction>
    shell(double thickness, const Vector3d& origin) const = 0;

    // Sampled distance over the surface between two mask coordinates. The
    // straight chord is the wrong number for a travel budget whenever growth is
    // confined to the shell: the chord cuts inside, the shell does not.
    double pathBetween(double u0, double v0, double u1, double v1) const {
        double du = u1 - u0;
        while (du >  M_PI) du -= 2.0 * M_PI;      // the short way round
        while (du < -M_PI) du += 2.0 * M_PI;
        const int kSteps = 24;
        double len = 0.0;
        Vector3d prev = maskAt(u0, v0, 1.0).pos;
        for (int i = 1; i <= kSteps; ++i) {
            double f = double(i) / kSteps;
            Vector3d cur = maskAt(u0 + du * f, v0 + (v1 - v0) * f, 1.0).pos;
            len += cur.minus(prev).length();
            prev = cur;
        }
        return len;
    }
};

// The original: a downward cone/frustum, widening from tipRadius at the seed to
// baseRadius at depth. taperPower bends the radius profile (see SDF_Cone).
struct ConeHost : HostSurface {
    double R0, H, tipR, taper;
    ConeHost(double baseRadius, double height, double tipRadius, double taperPower)
        : R0(baseRadius), H(height), tipR(tipRadius), taper(taperPower) {}

    MaskNode maskAt(double u, double v, double maskR) const override {
        return coneMaskAt(std::clamp(v, 0.0, 1.0), u, R0, H, maskR, tipR, taper);
    }
    std::shared_ptr<SignedDistanceFunction>
    shell(double thickness, const Vector3d& origin) const override {
        return buildConeShell(R0, H, tipR, taper, thickness, origin);
    }
};

// A column. The one thing the cone cannot be: constant radius, so the spacing
// between consecutive masks does not grow with depth and neither does the root
// mass around them.
struct CylinderHost : HostSurface {
    double R, H;
    CylinderHost(double radius, double height) : R(radius), H(height) {}

    MaskNode maskAt(double u, double v, double maskR) const override {
        const double cu = std::cos(u), su = std::sin(u);
        MaskNode m;
        m.pos = Vector3d(R * cu, R * su, -std::clamp(v, 0.0, 1.0) * H);
        m.normal = Vector3d(cu, su, 0.0);
        m.tangent = Vector3d(-su, cu, 0.0);
        m.bitangent = m.normal.cross(m.tangent).normalized();   // toward the seed
        m.r_depth = maskR * 0.55; m.r_width = maskR; m.r_height = maskR * 1.25;
        return m;
    }
    std::shared_ptr<SignedDistanceFunction>
    shell(double thickness, const Vector3d& origin) const override {
        const double hh = thickness * 0.5;
        auto outer = std::make_shared<SDF_CylinderZ>(origin, R + hh);
        auto inner = std::make_shared<SDF_CylinderZ>(origin, std::max(0.1, R - hh));
        return std::make_shared<CPlantBox::SDF_Difference>(
            std::static_pointer_cast<SignedDistanceFunction>(outer),
            std::static_pointer_cast<SignedDistanceFunction>(inner));
    }
};

// A globe hanging below the seed: v = 0 at the top (nearest the seed), v = 1 at
// the bottom. Faces on the outside of an object rather than down a column --
// the pull-back turns a face into a planet.
struct SphereHost : HostSurface {
    double R;
    explicit SphereHost(double radius) : R(radius) {}
    Vector3d centre() const { return Vector3d(0, 0, -R); }

    MaskNode maskAt(double u, double v, double maskR) const override {
        // v -> polar angle from the top of the sphere.
        const double th = std::clamp(v, 0.0, 1.0) * M_PI;
        const double st = std::sin(th), ct = std::cos(th);
        const double cu = std::cos(u), su = std::sin(u);
        MaskNode m;
        m.normal = Vector3d(st * cu, st * su, ct);
        m.pos = centre().plus(m.normal.times(R));
        // Degenerate at the poles; nudge the tangent onto x there so the frame
        // stays orthonormal rather than collapsing.
        m.tangent = (st > 1e-4) ? Vector3d(-su, cu, 0.0) : Vector3d(1, 0, 0);
        m.bitangent = m.normal.cross(m.tangent).normalized();
        m.r_depth = maskR * 0.55; m.r_width = maskR; m.r_height = maskR * 1.25;
        return m;
    }
    std::shared_ptr<SignedDistanceFunction>
    shell(double thickness, const Vector3d& origin) const override {
        const double hh = thickness * 0.5;
        auto outer = std::make_shared<SDF_Sphere>(origin.plus(centre()), R + hh);
        auto inner = std::make_shared<SDF_Sphere>(origin.plus(centre()), std::max(0.1, R - hh));
        return std::make_shared<CPlantBox::SDF_Difference>(
            std::static_pointer_cast<SignedDistanceFunction>(outer),
            std::static_pointer_cast<SignedDistanceFunction>(inner));
    }
};

// A ring: u goes round the major circle, v round the tube. Neither coordinate
// has an end, so the relay is a cycle -- there is no first mask and no last,
// which is what an installation that runs all day wants.
struct TorusHost : HostSurface {
    double R, r;
    TorusHost(double majorRadius, double minorRadius) : R(majorRadius), r(minorRadius) {}
    Vector3d centre() const { return Vector3d(0, 0, -(R + r)); }

    MaskNode maskAt(double u, double v, double maskR) const override {
        const double phi = v * 2.0 * M_PI;                 // round the tube
        const double cu = std::cos(u), su = std::sin(u);
        const double cp = std::cos(phi), sp = std::sin(phi);
        MaskNode m;
        m.normal = Vector3d(cp * cu, cp * su, sp);
        Vector3d core(R * cu, R * su, 0.0);
        m.pos = centre().plus(core).plus(m.normal.times(r));
        m.tangent = Vector3d(-su, cu, 0.0);                // along the major circle
        m.bitangent = m.normal.cross(m.tangent).normalized();
        m.r_depth = maskR * 0.55; m.r_width = maskR; m.r_height = maskR * 1.25;
        return m;
    }
    std::shared_ptr<SignedDistanceFunction>
    shell(double thickness, const Vector3d& origin) const override {
        const double hh = thickness * 0.5;
        auto outer = std::make_shared<SDF_Torus>(origin.plus(centre()), R, r + hh);
        auto inner = std::make_shared<SDF_Torus>(origin.plus(centre()), R, std::max(0.1, r - hh));
        return std::make_shared<CPlantBox::SDF_Difference>(
            std::static_pointer_cast<SignedDistanceFunction>(outer),
            std::static_pointer_cast<SignedDistanceFunction>(inner));
    }
};

// --- patterns ---------------------------------------------------------------
// Where the masks go, in the host's (u, v). Angles in radians; v in [0, 1].

using UV = std::pair<double, double>;

// The classic phyllotactic spiral: a constant angular step, evenly spaced along.
inline std::vector<UV> patternPhyllotaxis(int n, double startFrac, double endFrac,
                                          double angleStepRad, double distStepFrac) {
    const double dStep = distStepFrac > 0.0 ? distStepFrac
                                            : (n > 0 ? (endFrac - startFrac) / n : 0.0);
    std::vector<UV> out;
    out.reserve(std::max(n, 0));
    for (int i = 0; i < n; ++i)
        out.emplace_back(i * angleStepRad, std::min(1.0, startFrac + dStep * (i + 0.5)));
    return out;
}

// A regular corkscrew: `turns` full revolutions over the run. The rhythm is
// predictable, so a mask arrives where the eye already expects it.
inline std::vector<UV> patternHelix(int n, double startFrac, double endFrac, double turns) {
    const double dStep = n > 0 ? (endFrac - startFrac) / n : 0.0;
    std::vector<UV> out;
    out.reserve(std::max(n, 0));
    for (int i = 0; i < n; ++i)
        out.emplace_back(n > 0 ? i * turns * 2.0 * M_PI / n : 0.0,
                         std::min(1.0, startFrac + dStep * (i + 0.5)));
    return out;
}

// Rosettes: `perGroup` masks bunched around a common centre, the centres
// stepping by angleStepRad. The layout with a middle scale -- mask, rosette,
// whole -- so a camera pulling back has three places to stop, each a legible
// object. `spread` is the bunch size as a fraction of the gap between centres.
inline std::vector<UV> patternRosettes(int n, double startFrac, double endFrac,
                                       int perGroup, double spread, double angleStepRad) {
    perGroup = std::max(1, perGroup);
    const int groups = (std::max(n, 0) + perGroup - 1) / perGroup;
    const double dStep = groups > 0 ? (endFrac - startFrac) / groups : 0.0;
    std::vector<UV> out;
    out.reserve(std::max(n, 0));
    for (int g = 0; g < groups && (int)out.size() < n; ++g) {
        const double v0 = startFrac + dStep * (g + 0.5), u0 = g * angleStepRad;
        for (int k = 0; k < perGroup && (int)out.size() < n; ++k) {
            // Rotated per group, so consecutive rosettes do not present the
            // same face to the camera.
            const double a = 2.0 * M_PI * k / perGroup + g;
            out.emplace_back(u0 + spread * 0.9 * std::cos(a),
                             std::clamp(v0 + spread * dStep * 0.5 * std::sin(a), 0.01, 1.0));
        }
    }
    return out;
}

// Semantic placement: two numbers about a face become its angle and its depth,
// so faces that resemble each other land together and the clusters are the data
// rather than the geometry.
//
// `features` is (a, b) in [0,1] per mask. Empty falls back to a seeded stand-in
// of gaussian clusters -- the point of which is to see whether clustered
// placement reads at all, and for that a plausible distribution is as good as a
// real one. Wiring the fitted identity coefficients in later changes only where
// these pairs come from.
inline std::vector<UV> patternFeatureClusters(int n, double startFrac, double endFrac,
                                              const std::vector<UV>& features,
                                              unsigned seed, int clusters) {
    std::vector<UV> f = features;
    if ((int)f.size() < n) {
        // xorshift rather than <random>: a preset carried to another machine
        // has to lay out the same way.
        unsigned s = seed ? seed : 1u;
        auto next = [&]() {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5;
            return (s & 0xffffff) / double(0x1000000);
        };
        auto gauss = [&](double mu, double sd) {
            const double u = std::max(1e-9, next()), v = next();
            return std::clamp(mu + sd * std::sqrt(-2.0 * std::log(u))
                                       * std::cos(2.0 * M_PI * v), 0.0, 1.0);
        };
        clusters = std::max(1, clusters);
        const int take = (std::max(n, 1) + clusters - 1) / clusters;
        while ((int)f.size() < n) {
            const double ca = next(), cb = next();
            for (int k = 0; k < take && (int)f.size() < n; ++k)
                f.emplace_back(gauss(ca, 0.09), gauss(cb, 0.09));
        }
    }
    std::vector<UV> out;
    out.reserve(std::max(n, 0));
    for (int i = 0; i < n; ++i)
        out.emplace_back(f[size_t(i)].first * 2.0 * M_PI,
                         startFrac + (endFrac - startFrac) * f[size_t(i)].second);
    return out;
}

// --- lobes: a placement with no host at all ---------------------------------
//
// Swellings down a spine, a rosette of faces in each. Deliberately not a
// HostSurface: there is no sheet for the roots to crawl on, and confining them
// to one would flatten exactly the bulge that makes a lobe a lobe. Growth here
// is bounded only by the mask cavities, so the roots fill the volume between
// the faces and the lobes read as mass rather than as a wrapped surface.
//
// Frames point out of the lobe centre, so each face looks away from its own
// cluster and the rosette reads from outside.
inline std::vector<MaskNode> lobePlacement(int n, double spineRadius, double height,
                                           double lobeRadius, int perLobe, double maskR,
                                           double angleStepRad) {
    perLobe = std::max(1, perLobe);
    const int lobes = (std::max(n, 0) + perLobe - 1) / perLobe;
    std::vector<MaskNode> out;
    out.reserve(std::max(n, 0));
    for (int g = 0; g < lobes && (int)out.size() < n; ++g) {
        const double t = (g + 0.5) / std::max(1, lobes);
        const double a0 = g * angleStepRad;
        // The spine itself wanders round the axis rather than running straight,
        // so the lobes do not stack into a single silhouette.
        const Vector3d c(spineRadius * std::cos(a0), spineRadius * std::sin(a0), -t * height);
        for (int k = 0; k < perLobe && (int)out.size() < n; ++k) {
            // Spread the faces over the lobe by the same spiral used everywhere
            // else, so a lobe of four and a lobe of nine both look placed.
            const double y = 1.0 - 2.0 * (k + 0.5) / perLobe;
            const double rr = std::sqrt(std::max(0.0, 1.0 - y * y));
            const double phi = k * angleStepRad + g;
            MaskNode m;
            m.normal = Vector3d(rr * std::cos(phi), rr * std::sin(phi), y).normalized();
            m.pos = c.plus(m.normal.times(lobeRadius));
            m.tangent = (std::fabs(m.normal.z) < 0.98)
                          ? Vector3d(-m.normal.y, m.normal.x, 0.0).normalized()
                          : Vector3d(1, 0, 0);
            m.bitangent = m.normal.cross(m.tangent).normalized();
            m.r_depth = maskR * 0.55; m.r_width = maskR; m.r_height = maskR * 1.25;
            out.push_back(m);
        }
    }
    return out;
}

}  // namespace maskcav
