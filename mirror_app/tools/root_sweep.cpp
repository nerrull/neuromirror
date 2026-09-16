// root_sweep — grow the mask relay headlessly and report what it did.
//
// Dialling the root scene in from the panel means watching a grow, deciding it
// looked wrong, and changing a number: slow, and the thing that most often
// goes wrong is invisible. A hop whose day budget runs out reveals its mask and
// starts dwelling exactly like a hop that arrived — so a system that "reaches"
// twelve masks on screen may in fact have reached four and been teleported
// through the rest. RootSim::hops() is where that difference is recorded, and
// this is the harness that reads it.
//
// No Metal, no window, no renderer: it links mirror_sim and CPlantBox only, so
// a parameter sweep is a shell loop rather than an afternoon.
//
//   root_sweep [key=value ...]
//
// Keys are the SimParams field names from visitSimParams (species, N, R0, Hh,
// dwellDays, maxHopDays, ...), plus:
//   seeds=<n>   grow the same parameters under n consecutive seeds and
//               aggregate — one lucky seed is not a dialled-in look.
//   quiet=1     one summary line per run, no per-hop table.
#include "root_sim.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <type_traits>
#include <vector>

using rootsim::SimParams;

namespace {

void applyOverride(SimParams& p, const std::string& keyIn, const std::string& val) {
    // "species" is what the panel and the presets call it; visitSimParams calls
    // the field by its C++ name. Accept both rather than make the sweep the one
    // place in the app that spells it differently.
    const std::string key = (keyIn == "species") ? "speciesXml" : keyIn;
    bool hit = false;
    rootsim::visitSimParams(p, [&](const char* name, auto& field) {
        if (key != name) return;
        hit = true;
        using T = std::decay_t<decltype(field)>;
        if constexpr (std::is_same_v<T, std::string>)       field = val;
        else if constexpr (std::is_same_v<T, bool>)         field = (atoi(val.c_str()) != 0);
        else if constexpr (std::is_same_v<T, int>)          field = atoi(val.c_str());
        else if constexpr (std::is_same_v<T, unsigned>)     field = (unsigned)strtoul(val.c_str(), nullptr, 10);
        else                                                field = (T)atof(val.c_str());
    });
    if (!hit) fprintf(stderr, "root_sweep: unknown key '%s'\n", key.c_str());
}

// What one grow produced, in the terms the look is judged in.
struct Run {
    int   hops = 0, reached = 0;
    int   touched = 0;         // masks with root material actually against them
    std::vector<int> nest;     // root nodes within a nest radius of each mask
    float worstTouch = 0.f;    // furthest a mask ended up from the nearest root
    float worstDist = 0.f, worstOverThr = 0.f;
    float days = 0.f;          // total sim days
    float length = 0.f;        // total root length, cm — the legibility number
    int   nodes = 0;
    float extent = 0.f;        // furthest node from the cone axis
    bool  finished = false;
};

Run grow(const SimParams& p, int maxSteps) {
    Run r;
    rootsim::RootSim sim;
    if (!sim.reset(p)) { fprintf(stderr, "root_sweep: cannot load %s\n", p.speciesXml.c_str()); return r; }
    int steps = 0;
    while (!sim.done() && steps < maxSteps) { sim.step(); ++steps; }
    r.finished = sim.done();

    for (const auto& h : sim.hops()) {
        ++r.hops;
        if (!h.forced) ++r.reached;
        else {
            r.worstDist = std::max(r.worstDist, h.reachDist);
            r.worstOverThr = std::max(r.worstOverThr,
                                      h.threshold > 0 ? h.reachDist / h.threshold : 0.f);
        }
        r.days += h.days;
    }

    std::vector<float> nodes; std::vector<int> segs; std::vector<float> radii;
    sim.geometry(nodes, segs, radii);
    r.nodes = (int)nodes.size() / 3;
    for (size_t i = 0; i + 1 < segs.size(); i += 2) {
        const float* a = &nodes[(size_t)segs[i] * 3];
        const float* b = &nodes[(size_t)segs[i + 1] * 3];
        float dx = b[0] - a[0], dy = b[1] - a[1], dz = b[2] - a[2];
        r.length += std::sqrt(dx * dx + dy * dy + dz * dz);
    }
    for (int i = 0; i < r.nodes; ++i) {
        float x = nodes[(size_t)i * 3], z = nodes[(size_t)i * 3 + 2];
        r.extent = std::max(r.extent, std::sqrt(x * x + z * z));
    }

    // The visual test, as opposed to the bookkeeping one: when the whole thing
    // has finished growing, is there root against each mask? A hop can be
    // recorded as "reached" from a couple of mask-widths away — reachMult is
    // deliberately loose, so the dwell starts before the tip is on top of the
    // face — and the dwell may or may not close that gap. This measures what
    // ends up on screen instead of what the state machine decided.
    for (const auto& m : sim.revealedMasks()) {
        float best = 1e30f;
        for (int i = 0; i < r.nodes; ++i) {
            const float* n = &nodes[(size_t)i * 3];
            float dx = n[0] - m.pos[0], dy = n[1] - m.pos[1], dz = n[2] - m.pos[2];
            best = std::min(best, dx * dx + dy * dy + dz * dz);
        }
        best = std::sqrt(best);
        // Against the mask's own size: touching means within the shell the
        // face occupies, not within some absolute number of centimetres.
        const float reach = 1.5f * std::max(m.rWidth, m.rHeight);
        if (best <= reach) ++r.touched;
        r.worstTouch = std::max(r.worstTouch, best / std::max(1e-3f, reach));

        // The nest, as the eye reads it: root within a few mask-widths of the
        // face. Hop totals are the wrong measure -- most of a hop's material is
        // strung out along the way and lands nowhere near the mask.
        const float nestR = 4.0f * std::max(m.rWidth, m.rHeight);
        int inNest = 0;
        for (int i = 0; i < r.nodes; ++i) {
            const float* n = &nodes[(size_t)i * 3];
            float dx = n[0] - m.pos[0], dy = n[1] - m.pos[1], dz = n[2] - m.pos[2];
            if (dx * dx + dy * dy + dz * dz <= nestR * nestR) ++inNest;
        }
        r.nest.push_back(inNest);
    }
    return r;
}

void printHops(const SimParams& p, int maxSteps) {
    rootsim::RootSim sim;
    if (!sim.reset(p)) return;
    int steps = 0;
    while (!sim.done() && steps < maxSteps) { sim.step(); ++steps; }
    printf("  %-4s %-8s %8s %8s %8s %8s %8s %8s %8s %8s\n",
           "hop", "arrival", "path", "budget", "travel", "dwell", "days", "nodes",
           "dist", "thresh");
    for (const auto& h : sim.hops())
        printf("  %-4d %-8s %8.2f %8.1f %8.1f %8.1f %8.1f %8d %8.2f %8.2f%s\n",
               h.mask, h.forced ? "FORCED" : "reached", h.path, h.budgetDays,
               h.travelDays, h.dwellDays, h.days, h.nodes, h.reachDist, h.threshold,
               h.outOfReach ? "  BEYOND THIS ROOT'S REACH" : "");
}

// Where the growth actually is after `steps`, relative to the first mask.
// "The roots start in the wrong place" is a claim about geometry, and this is
// the only way to check it that does not involve squinting at a render.
void probe(const SimParams& p, int steps) {
    rootsim::RootSim sim;
    if (!sim.reset(p)) { fprintf(stderr, "probe: reset failed\n"); return; }
    for (int i = 0; i < steps; ++i) sim.step();

    const auto& planned = sim.plannedMasks();
    if (planned.empty()) return;
    const auto& m0 = planned[0];
    printf("mask0 pos (%.2f %.2f %.2f) r(%.2f %.2f %.2f)\n",
           m0.pos[0], m0.pos[1], m0.pos[2], m0.rDepth, m0.rWidth, m0.rHeight);
    if (planned.size() > 1)
        printf("mask1 pos (%.2f %.2f %.2f)  |m1-m0| = %.2f\n",
               planned[1].pos[0], planned[1].pos[1], planned[1].pos[2],
               std::sqrt(std::pow(planned[1].pos[0] - m0.pos[0], 2.f) +
                         std::pow(planned[1].pos[1] - m0.pos[1], 2.f) +
                         std::pow(planned[1].pos[2] - m0.pos[2], 2.f)));
    printf("revealed after %d steps: %d\n", steps, (int)sim.revealedMasks().size());

    std::vector<float> nodes; std::vector<int> segs; std::vector<float> radii;
    sim.geometry(nodes, segs, radii);
    const int n = (int)nodes.size() / 3;
    printf("nodes: %d\n", n);
    float near = 1e30f, far = 0.f;
    for (int i = 0; i < n; ++i) {
        const float* q = &nodes[(size_t)i * 3];
        const float d = std::sqrt(std::pow(q[0] - m0.pos[0], 2.f) +
                                  std::pow(q[1] - m0.pos[1], 2.f) +
                                  std::pow(q[2] - m0.pos[2], 2.f));
        near = std::min(near, d); far = std::max(far, d);
    }
    if (n) printf("node distance from mask0: nearest %.2f, furthest %.2f\n", near, far);
    // The first segment's heading against mask 0's normal (out through the
    // mouth): 1 is dead along it.
    if (n >= 2) {
        float d[3], l = 0.f;
        for (int k = 0; k < 3; ++k) { d[k] = nodes[3 + k] - nodes[k]; l += d[k] * d[k]; }
        l = std::sqrt(l);
        const float dot = l > 0.f ? (d[0] * m0.normal[0] + d[1] * m0.normal[1] + d[2] * m0.normal[2]) / l : 0.f;
        printf("first segment . mask0 normal = %.3f (start %.2f %.2f %.2f)\n", dot, nodes[0], nodes[1], nodes[2]);
    }
    for (int i = 0; i < std::min(n, 6); ++i)
        printf("  node %d (%.2f %.2f %.2f)\n", i,
               nodes[(size_t)i * 3], nodes[(size_t)i * 3 + 1], nodes[(size_t)i * 3 + 2]);

    // The first root's own path (node 0, then each node's first outgoing
    // segment -- CPlantBox numbers a root's nodes before its laterals'), as
    // distance along and off the chord from where it started to mask 1, and
    // its render y. "Is there a hump" is a question about this line.
    if (planned.size() > 1 && n >= 2) {
        // Where the root mass sits around mask 0, in the mask's own frame:
    // distance in cavity-ellipsoid units (1 = on the r_width/r_height/
    // r_depth surface), and along the normal (+ = in front of the face).
    // A pile-up just outside 1 is the cavity repulsion stacking roots on
    // its own boundary.
    {
        int hist[12] = {0};
        int front[8] = {0}, back[8] = {0};
        for (int i = 0; i < n; ++i) {
            const float* q = &nodes[(size_t)i * 3];
            float d[3]; for (int k = 0; k < 3; ++k) d[k] = q[k] - m0.pos[k];
            const float u = d[0]*m0.tangent[0] + d[1]*m0.tangent[1] + d[2]*m0.tangent[2];
            const float v = d[0]*m0.bitangent[0] + d[1]*m0.bitangent[1] + d[2]*m0.bitangent[2];
            const float w = d[0]*m0.normal[0] + d[1]*m0.normal[1] + d[2]*m0.normal[2];
            const float e = std::sqrt((u*u)/(m0.rWidth*m0.rWidth) + (v*v)/(m0.rHeight*m0.rHeight) + (w*w)/(m0.rDepth*m0.rDepth));
            if (e < 3.f) ++hist[(int)(e / 0.25f)];
            const float dist = std::sqrt(d[0]*d[0]+d[1]*d[1]+d[2]*d[2]);
            if (dist < 8.f) { if (w >= 0) ++front[(int)dist]; else ++back[(int)dist]; }
        }
        printf("nodes by cavity-ellipsoid distance (0.25 bins, 0..3):");
        for (int b = 0; b < 12; ++b) printf(" %d", hist[b]);
        printf("\nnodes by distance from mask0 (1-unit bins), in front / behind the face:\n");
        for (int b = 0; b < 8; ++b) printf("  %d-%d: %5d / %5d\n", b, b + 1, front[b], back[b]);
    }

    // BFS over the segment graph from node 0; the path to the node that
        // ends nearest mask 1 is the first root's line (the laterals branch
        // off it and never get closer to the mask than the tip that arrived).
        std::vector<std::vector<int>> adj(n);
        for (size_t i = 0; i + 1 < segs.size(); i += 2) {
            adj[segs[i]].push_back(segs[i + 1]);
            adj[segs[i + 1]].push_back(segs[i]);
        }
        std::vector<int> parent(n, -2);
        // Node 0 is the seed with no segment of its own; the root starts at 1.
        const int root0 = (n > 1 && adj[0].empty()) ? 1 : 0;
        std::vector<int> queue{root0};
        parent[root0] = -1;
        for (size_t qi = 0; qi < queue.size(); ++qi)
            for (int nb : adj[queue[qi]])
                if (parent[nb] == -2) { parent[nb] = queue[qi]; queue.push_back(nb); }
        int end = 0; float bestD = 1e30f;
        for (int i : queue) {
            const float* q = &nodes[(size_t)i * 3];
            float d = 0.f;
            for (int k = 0; k < 3; ++k) d += (q[k] - planned[1].pos[k]) * (q[k] - planned[1].pos[k]);
            if (d < bestD) { bestD = d; end = i; }
        }
        std::vector<int> path;
        for (int c = end; c >= 0; c = parent[c]) path.push_back(c);
        std::reverse(path.begin(), path.end());
        const float* a = &nodes[0];
        const float* b = planned[1].pos;
        float ab[3], L = 0.f;
        for (int k = 0; k < 3; ++k) { ab[k] = b[k] - a[k]; L += ab[k] * ab[k]; }
        L = std::sqrt(L);
        for (int k = 0; k < 3; ++k) ab[k] /= std::max(L, 1e-6f);
        printf("first root, chord to mask 1 (length %.2f): along  off  y  (dist to mask0 centre)\n", L);
        int count = 0;
        for (int cur : path) {
            const float* q = &nodes[(size_t)cur * 3];
            float d[3], along = 0.f, off2 = 0.f, dm = 0.f;
            for (int k = 0; k < 3; ++k) { d[k] = q[k] - a[k]; along += d[k] * ab[k]; }
            for (int k = 0; k < 3; ++k) { const float o = d[k] - along * ab[k]; off2 += o * o;
                                          dm += (q[k] - m0.pos[k]) * (q[k] - m0.pos[k]); }
            printf("  %3d  %7.2f %6.2f %7.2f  (%.2f)\n", count, along, std::sqrt(off2), q[1], std::sqrt(dm));
            ++count;
        }
    }
}

}  // namespace

int main(int argc, char** argv) {
    SimParams p;
    p.paramDir = ROOTSIM_PARAM_DIR;
    int seeds = 1, maxSteps = 200000, probeSteps = 0;
    bool quiet = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        const size_t eq = a.find('=');
        if (eq == std::string::npos) continue;
        std::string k = a.substr(0, eq), v = a.substr(eq + 1);
        if (k == "seeds")    { seeds = atoi(v.c_str()); continue; }
        if (k == "maxSteps") { maxSteps = atoi(v.c_str()); continue; }
        if (k == "quiet")    { quiet = atoi(v.c_str()) != 0; continue; }
        if (k == "probe")    { probeSteps = atoi(v.c_str()); continue; }
        applyOverride(p, k, v);
    }

    if (probeSteps > 0) { probe(p, probeSteps); return 0; }

    int totalHops = 0, totalReached = 0, totalTouched = 0, unfinished = 0;
    float sumLen = 0.f, sumDays = 0.f, worst = 0.f, worstTouch = 0.f;
    int   sumNodes = 0;
    const unsigned seed0 = p.seed;
    for (int s = 0; s < seeds; ++s) {
        SimParams ps = p;
        ps.seed = seed0 + (unsigned)s * 101u;
        Run r = grow(ps, maxSteps);
        totalHops += r.hops; totalReached += r.reached; totalTouched += r.touched;
        worstTouch = std::max(worstTouch, r.worstTouch);
        sumLen += r.length; sumDays += r.days; sumNodes += r.nodes;
        worst = std::max(worst, r.worstOverThr);
        if (!r.finished) ++unfinished;
        if (!quiet && !r.nest.empty()) {
            int lo = r.nest[0], hi = r.nest[0];
            double sum = 0;
            printf("  nest per mask:");
            for (int n : r.nest) {
                printf(" %d", n);
                lo = std::min(lo, n); hi = std::max(hi, n); sum += n;
            }
            printf("\n  nest spread: %d..%d  (x%.2f), mean %.0f\n",
                   lo, hi, lo > 0 ? double(hi) / lo : 0.0, sum / r.nest.size());
        }
        if (!quiet) {
            printf("seed %u: %d/%d reached, %d/%d touched (worst x%.2f), "
                   "%.0f days, %.0f cm, %d nodes%s\n",
                   ps.seed, r.reached, r.hops, r.touched, r.hops, r.worstTouch,
                   r.days, r.length, r.nodes,
                   r.finished ? "" : "  (DID NOT FINISH)");
            if (seeds == 1) printHops(ps, maxSteps);
        }
    }
    printf("%-40s N=%2d dwell=%4.1f hop=%5.1f pull=%4.2f reach=%4.2f shell=%4.1f "
           "| reached %3d/%3d worst x%.2f | touched %3d/%3d worst x%.2f "
           "| %7.0f cm %7d nodes %6.0f days%s\n",
           p.speciesXml.c_str(), p.N, p.dwellDays, p.maxHopDays, p.weight,
           p.reachMult, p.coneShellThickness,
           totalReached, totalHops, worst,
           totalTouched, totalHops, worstTouch,
           sumLen / std::max(1, seeds), sumNodes / std::max(1, seeds),
           sumDays / std::max(1, seeds),
           unfinished ? "  (UNFINISHED RUNS)" : "");
    return (totalHops && totalReached == totalHops) ? 0 : 1;
}
