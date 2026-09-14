// mask_frame_test -- is a face drawn on a root mask square to the nest the
// sim grows round it?
//
// Two things have to hold for that, and each half of this test checks one:
//
//   1. The sim's frames. The nest is grown in CPlantBox's grow space against
//      the MaskNode frame (the cavity ellipsoid, the rim attractors, the
//      arrival test all read normal/tangent/bitangent with
//      r_depth/r_width/r_height along them); the face is drawn in render
//      space from SimMask's frame (RootScene's appendFaceVertexData maps the
//      face's local x/y/z onto tangent/bitangent/normal). Those are the same
//      frame only if plannedMasks() is one rigid transform of
//      plannedMasksGrow(): every frame orthonormal and right-handed, and one
//      proper rotation carrying every grow-space axis and every position
//      offset onto its render-space one.
//
//   2. The bank's faces. A capture is the fitter's posed mesh -- rotated by
//      the visitor's head pose at the cut -- so worn on a mask it sits
//      tilted by that pose inside a nest that is square. This half fits the
//      rotation of every capture on disk against the basis's neutral mesh
//      (what SquareCaptureToNeutral removes when the bank loads) and reports
//      it, then checks the squared mesh fits to within a degree. The
//      captures are data, not code, so their pose is printed rather than
//      failed; what is asserted is that squaring them works.
//
// Needs the CPlantBox parameter dir (ROOTSIM_PARAM_DIR) for 1 and
// external/face_basis.bin for 2; each half skips cleanly without its input.
#include "face_basis.h"
#include "face_capture.h"
#include "root_sim.h"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

int g_fail = 0;
void check(bool ok, const char* what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) ++g_fail;
}

struct V3 { double x, y, z; };
V3 v3(const float a[3]) { return {a[0], a[1], a[2]}; }
V3 sub(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
double dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
V3 cross(V3 a, V3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
double len(V3 a) { return std::sqrt(dot(a, a)); }
// R = render_frame * grow_frame^T, columns being the frame axes: the
// rotation carrying grow-space vectors onto render-space ones for one mask.
struct M3 { double m[9]; };
M3 frameToFrame(const rootsim::SimMask& g, const rootsim::SimMask& r) {
    const V3 gA[3] = {v3(g.tangent), v3(g.bitangent), v3(g.normal)};
    const V3 rA[3] = {v3(r.tangent), v3(r.bitangent), v3(r.normal)};
    M3 R{};
    // R = sum_k rA[k] gA[k]^T
    for (int k = 0; k < 3; ++k) {
        const double rv[3] = {rA[k].x, rA[k].y, rA[k].z};
        const double gv[3] = {gA[k].x, gA[k].y, gA[k].z};
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j) R.m[i * 3 + j] += rv[i] * gv[j];
    }
    return R;
}
V3 apply(const M3& R, V3 v) {
    return {R.m[0] * v.x + R.m[1] * v.y + R.m[2] * v.z,
            R.m[3] * v.x + R.m[4] * v.y + R.m[5] * v.z,
            R.m[6] * v.x + R.m[7] * v.y + R.m[8] * v.z};
}
double det(const M3& R) {
    const double* m = R.m;
    return m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) +
           m[2] * (m[3] * m[7] - m[4] * m[6]);
}

void simFrames() {
    printf("sim frames\n");
    rootsim::SimParams p;
    p.paramDir = ROOTSIM_PARAM_DIR;
    rootsim::RootSim sim;
    if (!sim.reset(p) || !sim.valid()) {
        printf("  skip: no sim (parameter dir %s)\n", ROOTSIM_PARAM_DIR);
        return;
    }
    const auto& grow = sim.plannedMasksGrow();
    const auto& rend = sim.plannedMasks();
    check(grow.size() == rend.size() && !grow.empty(), "one grow frame per render frame");
    if (grow.size() != rend.size() || grow.empty()) return;

    const double tol = 1e-4;
    double worstOrtho = 0.0, worstHand = 0.0;
    for (size_t i = 0; i < rend.size(); ++i) {
        for (const auto* m : {&grow[i], &rend[i]}) {
            const V3 t = v3(m->tangent), b = v3(m->bitangent), n = v3(m->normal);
            worstOrtho = std::max({worstOrtho, std::fabs(len(t) - 1), std::fabs(len(b) - 1),
                                   std::fabs(len(n) - 1), std::fabs(dot(t, b)), std::fabs(dot(b, n)),
                                   std::fabs(dot(n, t))});
            worstHand = std::max(worstHand, len(sub(cross(t, b), n)));
        }
    }
    printf("  frames: max unit/orthogonality error %.2e, max |t x b - n| %.2e\n", worstOrtho, worstHand);
    check(worstOrtho < tol, "every frame orthonormal (grow and render)");
    check(worstHand < tol, "every frame right-handed: tangent x bitangent = normal");

    // One rotation for the lot, read off mask 0, then checked on every mask
    // and on every position offset from mask 0.
    const M3 R = frameToFrame(grow[0], rend[0]);
    printf("  R (grow -> render) det %.6f\n", det(R));
    check(std::fabs(det(R) - 1.0) < tol, "the anchor's grow->render map is a proper rotation");
    double worstAxis = 0.0, worstPos = 0.0, worstRadii = 0.0;
    for (size_t i = 0; i < rend.size(); ++i) {
        worstAxis = std::max({worstAxis,
                              len(sub(apply(R, v3(grow[i].tangent)), v3(rend[i].tangent))),
                              len(sub(apply(R, v3(grow[i].bitangent)), v3(rend[i].bitangent))),
                              len(sub(apply(R, v3(grow[i].normal)), v3(rend[i].normal)))});
        const V3 dg = sub(v3(grow[i].pos), v3(grow[0].pos));
        const V3 dr = sub(v3(rend[i].pos), v3(rend[0].pos));
        worstPos = std::max(worstPos, len(sub(apply(R, dg), dr)));
        worstRadii = std::max({worstRadii, (double)std::fabs(grow[i].rDepth - rend[i].rDepth),
                               (double)std::fabs(grow[i].rWidth - rend[i].rWidth),
                               (double)std::fabs(grow[i].rHeight - rend[i].rHeight)});
    }
    printf("  same rotation on every mask: axes %.2e, positions %.2e cm, radii %.2e\n",
           worstAxis, worstPos, worstRadii);
    check(worstAxis < tol, "every mask's render axes are R x its grow axes (cavity axes == face axes)");
    check(worstPos < 1e-3, "every mask's render position is R x its grow position (+ one translation)");
    check(worstRadii < tol, "cavity radii carried unchanged (depth/width/height along normal/tangent/bitangent)");
}

void bankPose() {
    printf("bank pose\n");
    mirror::FaceBasis basis;
    std::string err;
    const std::string path = std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_basis.bin";
    if (!basis.load(path, err)) { printf("  skip: %s\n", err.c_str()); return; }
    const std::vector<float>& neutral = basis.neutral();

    // The neutral itself: which way it faces, so "square" means what the
    // mask frame means (x across, y up, z out of the face).
    {
        const size_t n = neutral.size() / 3;
        double lo[3] = {1e9, 1e9, 1e9}, hi[3] = {-1e9, -1e9, -1e9};
        for (size_t i = 0; i < n; ++i)
            for (int k = 0; k < 3; ++k) {
                lo[k] = std::min(lo[k], (double)neutral[i * 3 + k]);
                hi[k] = std::max(hi[k], (double)neutral[i * 3 + k]);
            }
        printf("  neutral extent x %.1f  y %.1f  z %.1f (a face: y tallest, z shallowest)\n",
               hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]);
        check(hi[1] - lo[1] > hi[0] - lo[0] && hi[0] - lo[0] > hi[2] - lo[2],
              "the neutral is upright and faces along z");
    }

    // Squaring is exact on a known rotation: pose the neutral by 12 degrees
    // about a skew axis and see it come back.
    {
        mirror::FaceCapture c;
        c.verts = neutral;
        const double a = 12.0 * M_PI / 180.0, ax[3] = {0.6, 0.8, 0.0};
        const double cs = std::cos(a), sn = std::sin(a);
        double R[9];
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j) {
                const double K = (i == 0 && j == 1) ? -ax[2] : (i == 0 && j == 2) ? ax[1]
                               : (i == 1 && j == 0) ? ax[2] : (i == 1 && j == 2) ? -ax[0]
                               : (i == 2 && j == 0) ? -ax[1] : (i == 2 && j == 1) ? ax[0] : 0.0;
                R[i * 3 + j] = (i == j ? cs : 0.0) + sn * K + (1 - cs) * ax[i] * ax[j];
            }
        const size_t n = c.verts.size() / 3;
        double cv[3] = {0, 0, 0};
        for (size_t i = 0; i < n; ++i) for (int k = 0; k < 3; ++k) cv[k] += c.verts[i * 3 + k] / double(n);
        for (size_t i = 0; i < n; ++i) {
            const double p[3] = {c.verts[i * 3] - cv[0], c.verts[i * 3 + 1] - cv[1], c.verts[i * 3 + 2] - cv[2]};
            for (int r = 0; r < 3; ++r)
                c.verts[i * 3 + size_t(r)] = float(R[r * 3] * p[0] + R[r * 3 + 1] * p[1] + R[r * 3 + 2] * p[2] + cv[r]);
        }
        const float removed = mirror::SquareCaptureToNeutral(c, neutral);
        double worst = 0.0;
        for (size_t i = 0; i < c.verts.size(); ++i) worst = std::max(worst, (double)std::fabs(c.verts[i] - neutral[i]));
        printf("  synthetic 12 deg pose: %.3f deg removed, residual %.2e\n", removed, worst);
        check(std::fabs(removed - 12.0) < 0.05 && worst < 1e-3, "a known pose is recovered exactly");
    }

    // What is on disk: each capture's pose against the neutral (what the
    // hood was wearing), and that squaring leaves under a degree.
    const std::vector<std::string> ids = mirror::ListCaptures();
    printf("  %zu captures in %s\n", ids.size(), mirror::CaptureDir().c_str());
    float maxPose = 0.f, maxLeft = 0.f;
    int n = 0;
    for (const std::string& id : ids) {
        mirror::FaceCapture c;
        if (!mirror::LoadCapture(id, c, err)) { printf("  %s: %s\n", id.c_str(), err.c_str()); continue; }
        if (c.verts.size() != neutral.size()) { printf("  %s: %zu verts, basis %zu -- skipped\n", id.c_str(), c.vertexCount(), neutral.size() / 3); continue; }
        const float pose = mirror::SquareCaptureToNeutral(c, neutral);
        const float left = mirror::SquareCaptureToNeutral(c, neutral);
        printf("  %s: posed %5.1f deg, %.2f deg left after squaring\n", id.c_str(), pose, left);
        maxPose = std::max(maxPose, pose);
        maxLeft = std::max(maxLeft, left);
        ++n;
    }
    if (n) {
        printf("  worst pose on disk %.1f deg; worst residual after squaring %.2f deg\n", maxPose, maxLeft);
        check(maxLeft < 1.0, "every capture squares to within a degree");
    }
}

// Does a hop actually leave from its source mask's *mouth* -- not the mask
// centre, not dropped to the chin (the old spawnRim*r_height offset)?
//
// Right after reset() the sim has already called initHop() for the hop in
// flight (growFromFirstMask reveals mask 0 bare and starts the relay at hop
// 1) but has not simulated a single step, so the live root's first node is
// still exactly at hopStart(hop) -- geometry()'s only node, since frozen[]
// is empty this early. That is compared against the mouth point computed the
// same way root_sim.cpp's hopStart() does: pos + tangent*mouthU +
// bitangent*mouthV + normal*mouthN, scaled by faceScale x faceUnit, read off
// plannedMasks()[0] (the source mask; hopFrom(1) == 0 with treeRelay off).
void spawnAtMouth(bool anchorOnAxis) {
    printf("spawn at mouth (anchorOnAxis=%s)\n", anchorOnAxis ? "true" : "false");
    rootsim::SimParams p;
    p.paramDir = ROOTSIM_PARAM_DIR;
    p.anchorOnAxis = anchorOnAxis;
    p.treeRelay = false;
    p.growFromFirstMask = true;
    // Deliberately off-centre and non-zero on every axis, so an
    // implementation that silently drops a term (or falls back to the mask
    // centre) shows up as a large miss rather than an accidental match.
    p.faceMouthU = 0.04f;   p.faceMouthV = -0.32f;  p.faceMouthN = 0.06f;
    p.spawnBehind = 0.05f;  p.anchorSpawn = 0.5f;
    rootsim::RootSim sim;
    if (!sim.reset(p) || !sim.valid()) {
        printf("  skip: no sim (parameter dir %s)\n", ROOTSIM_PARAM_DIR);
        return;
    }
    check(sim.currentMask() == 1, "hop 1 is the one in flight right after reset");
    const auto& planned = sim.plannedMasks();
    check(!planned.empty(), "at least one planned mask");
    if (sim.currentMask() != 1 || planned.empty()) return;
    const rootsim::SimMask& src = planned[0];   // hopFrom(1) == 0

    std::vector<float> nodes, radii; std::vector<int> segs;
    sim.geometry(nodes, segs, radii);
    check(nodes.size() >= 3, "the in-flight hop has already placed its seed node");
    if (nodes.size() < 3) return;
    const V3 spawn = {nodes[0], nodes[1], nodes[2]};

    const V3 pos = v3(src.pos), n = v3(src.normal), t = v3(src.tangent), b = v3(src.bitangent);
    const double fs = double(p.faceScale) * double(src.faceUnit);
    const V3 mouth = {pos.x + t.x * p.faceMouthU * fs + b.x * p.faceMouthV * fs + n.x * p.faceMouthN * fs,
                       pos.y + t.y * p.faceMouthU * fs + b.y * p.faceMouthV * fs + n.y * p.faceMouthN * fs,
                       pos.z + t.z * p.faceMouthU * fs + b.z * p.faceMouthV * fs + n.z * p.faceMouthN * fs};
    const V3 d = sub(spawn, mouth);
    const double dn = dot(d, n), dt = dot(d, t), db = dot(d, b);
    printf("  spawn - mouth: along normal %.4f cm, tangent %.4f cm, bitangent %.4f cm (r_height %.2f)\n",
           dn, dt, db, (double)src.rHeight);

    const double eps = 0.02;
    check(std::fabs(dt) < eps, "no tangential offset from the mouth");
    check(std::fabs(db) < eps, "not dropped to the chin (no r_height-sized bitangent offset)");
    if (anchorOnAxis) {
        check(dn > -eps && dn < (double)p.anchorSpawn + eps,
              "anchor: spawn is within anchorSpawn in front of the mouth");
    } else {
        check(dn > -((double)p.spawnBehind + eps) && dn < eps,
              "non-anchor: spawn is within spawnBehind behind the mouth");
    }
}

}  // namespace

int main() {
    simFrames();
    spawnAtMouth(/*anchorOnAxis=*/true);
    spawnAtMouth(/*anchorOnAxis=*/false);
    bankPose();
    printf("mask_frame_test: %s\n", g_fail ? "FAIL" : "OK");
    return g_fail ? 1 : 0;
}
