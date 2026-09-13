#include "root_scene.h"
#include "metal_context.h"
#include "face_basis.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <random>
#include <sstream>
#include <dirent.h>
#include <sys/stat.h>
#include <map>
#include <vector>

// ---------------------------------------------------------------------------
// Face model loading + placement (ports of render_relay_gui.cpp helpers, but in
// render world space directly — no CPlantBox toYup remap needed here).
// ---------------------------------------------------------------------------
namespace {
struct F3 { float x, y, z; };
inline F3 sub(F3 a, F3 b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
inline F3 add(F3 a, F3 b) { return {a.x+b.x, a.y+b.y, a.z+b.z}; }
inline F3 mul(F3 a, float s) { return {a.x*s, a.y*s, a.z*s}; }
inline float dot(F3 a, F3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
inline F3 cross(F3 a, F3 b) { return {a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x}; }
inline F3 norm(F3 v) { float l = std::sqrt(dot(v,v)); if (l < 1e-9f) l = 1.f; return {v.x/l, v.y/l, v.z/l}; }

void loadObj(const std::string& path, std::vector<float>& verts, std::vector<int>& tris) {
    std::ifstream f(path);
    if (!f.is_open()) return;
    std::string line;
    while (std::getline(f, line)) {
        std::istringstream ss(line);
        std::string tag; ss >> tag;
        if (tag == "v") {
            float x, y, z; ss >> x >> y >> z;
            verts.push_back(x); verts.push_back(y); verts.push_back(z);
        } else if (tag == "f") {
            int idx[3]; std::string tok;
            for (int i = 0; i < 3 && ss >> tok; i++) idx[i] = std::atoi(tok.c_str()) - 1;
            tris.push_back(idx[0]); tris.push_back(idx[1]); tris.push_back(idx[2]);
        }
    }
}

void normalizeMesh(std::vector<float>& v) {
    float cx = 0, cy = 0, cz = 0;
    size_t n = v.size() / 3;
    if (n == 0) return;
    for (size_t i = 0; i < n; i++) { cx += v[i*3]; cy += v[i*3+1]; cz += v[i*3+2]; }
    cx /= n; cy /= n; cz /= n;
    float m = 1e-9f;
    for (size_t i = 0; i < n; i++) {
        v[i*3] -= cx; v[i*3+1] -= cy; v[i*3+2] -= cz;
        m = std::max({m, std::fabs(v[i*3]), std::fabs(v[i*3+1]), std::fabs(v[i*3+2])});
    }
    for (auto& x : v) x /= m;
}

std::vector<int> cropOvalTris(const std::vector<float>& v, const std::vector<int>& tris,
                              float rx, float ry) {
    std::vector<int> out;
    for (size_t t = 0; t < tris.size(); t += 3) {
        float cx = 0, cy = 0;
        for (int k = 0; k < 3; k++) { cx += v[tris[t+k]*3]; cy += v[tris[t+k]*3+1]; }
        cx /= 3; cy /= 3;
        if ((cx/rx)*(cx/rx) + (cy/ry)*(cy/ry) < 1.0f)
            for (int k = 0; k < 3; k++) out.push_back(tris[t+k]);
    }
    return out;
}

// One placed mask (render world space; Y-up).
struct Mask { F3 pos, normal, tangent, bitangent; float rDepth, rWidth, rHeight; };

// Build interleaved face triangles (12 floats/vert) for a set of masks.
// `vcol`, when non-empty, is a per-vertex RGB (3 floats/vertex, same indexing as
// `fv`) that overrides the flat `color` -- this is how a mask wears a sampled
// face rather than a material tint.
// `recess` is how far the face sits back inside its cavity, in multiples of the
// cavity's own half-depth: 0.5 puts it where it has always been, 0 centres it on
// the cavity, and a negative value pushes it proud of the surface so it stands
// clear of the nest wrapped around it.
void appendFaceVertexData(std::vector<float>& out, const Mask& m,
                          const std::vector<float>& fv, const std::vector<int>& ftris,
                          float faceScale, float recess, float lightDist, const float color[3],
                          const std::vector<float>& vcol = {}, bool smoothNormals = true) {
    F3 n = m.normal, t = m.tangent, b = m.bitangent;
    F3 p = sub(m.pos, mul(n, m.rDepth * recess));
    float scale = faceScale * std::min(m.rWidth, m.rHeight);
    F3 lightPos = add(p, mul(n, lightDist));

    // Place every vertex once, then accumulate area-weighted face normals onto
    // the shared vertex indices before expanding to triangles. The alternative
    // -- one face normal written to all three vertices -- is what the mask mesh
    // used to do, and it made a few-thousand-triangle head read as a faceted
    // polyhedron no amount of shading could recover. The cross product is left
    // un-normalised on purpose: its length is twice the triangle area, which is
    // exactly the weight a vertex normal wants.
    const size_t nv = fv.size() / 3;
    std::vector<F3> wpos(nv), wnrm(nv, F3{0.f, 0.f, 0.f});
    for (size_t vi = 0; vi < nv; ++vi) {
        F3 local = {fv[vi*3], fv[vi*3+1], fv[vi*3+2]};
        wpos[vi] = add(add(add(p, mul(t, local.x * scale)), mul(b, local.y * scale)),
                       mul(n, local.z * scale));
    }
    for (size_t i = 0; i + 2 < ftris.size(); i += 3) {
        const int i0 = ftris[i], i1 = ftris[i+1], i2 = ftris[i+2];
        if (i0 < 0 || i1 < 0 || i2 < 0) continue;
        if (size_t(i0) >= nv || size_t(i1) >= nv || size_t(i2) >= nv) continue;
        const F3 fa = cross(sub(wpos[i1], wpos[i0]), sub(wpos[i2], wpos[i0]));
        wnrm[i0] = add(wnrm[i0], fa);
        wnrm[i1] = add(wnrm[i1], fa);
        wnrm[i2] = add(wnrm[i2], fa);
    }
    // A vertex whose incident triangles cancel out (degenerate fan) has no
    // meaningful normal; fall back to the mask's own facing rather than to a
    // zero vector the shader would normalise into a NaN.
    for (size_t vi = 0; vi < nv; ++vi)
        wnrm[vi] = (dot(wnrm[vi], wnrm[vi]) > 1e-20f) ? norm(wnrm[vi]) : n;

    for (size_t i = 0; i + 2 < ftris.size(); i += 3) {
        // Whole-triangle validity, not per-corner: dropping one corner of a
        // triangle would leave the other two in the stream and shear the mesh.
        bool ok = true;
        for (int k = 0; k < 3; k++) {
            const int vi = ftris[i+k];
            if (vi < 0 || size_t(vi) >= nv) { ok = false; break; }
        }
        if (!ok) continue;
        // The faceted original, kept reachable for A/B: one geometric normal
        // shared by all three corners.
        F3 flat = {0.f, 0.f, 0.f};
        if (!smoothNormals) {
            flat = cross(sub(wpos[ftris[i+1]], wpos[ftris[i]]),
                         sub(wpos[ftris[i+2]], wpos[ftris[i]]));
            flat = (dot(flat, flat) > 1e-20f) ? norm(flat) : n;
        }
        for (int k = 0; k < 3; k++) {
            const int vi = ftris[i+k];
            const F3 vp = wpos[vi], vn = smoothNormals ? wnrm[vi] : flat;
            const bool haveCol = !vcol.empty() && size_t(vi) * 3 + 2 < vcol.size();
            out.push_back(vp.x); out.push_back(vp.y); out.push_back(vp.z);
            out.push_back(vn.x); out.push_back(vn.y); out.push_back(vn.z);
            if (haveCol) {
                out.push_back(vcol[vi*3]); out.push_back(vcol[vi*3+1]);
                out.push_back(vcol[vi*3+2]);
            } else {
                out.push_back(color[0]); out.push_back(color[1]); out.push_back(color[2]);
            }
            out.push_back(lightPos.x); out.push_back(lightPos.y); out.push_back(lightPos.z);
        }
    }
}

// --- cloth helpers (see advanceCloth/rasteriseClothField/packClothMesh) ----
float smoothstep01(float x) {
    x = std::clamp(x, 0.f, 1.f);
    return x * x * (3.f - 2.f * x);
}
// The collider's resolution -- see TransitionScene's FIELD_RES for the same
// reasoning (a couple of texels per cloth cell across the face).
constexpr int kClothFieldRes = 160;
// The sheet half-width the cloth's gravity/side-force knobs were tuned at:
// TransitionScene's frustum at its fixed camera distance of 3, times its 1.08
// oversize. Nothing depends on it being exact -- it is the reference that makes
// those knobs scale-invariant, not a measurement of anything. See advanceCloth.
constexpr float kClothTunedHalfX = 2.39f;
// How far past the authored `fall` the film is allowed to keep simulating while
// it finishes leaving, before it is dropped regardless. Generous, because the
// cost of holding a sheet too long is a film that lingers and the cost of
// cutting it early is the pop this exists to prevent.
constexpr float kClothFallCeiling = 4.0f;

// Right/up basis for a mask facing `n`, using world up (0,1,0).
Mask makeMask(F3 pos, F3 n, float r) {
    n = norm(n);
    F3 up = {0, 1, 0};
    F3 t = cross(up, n);
    if (dot(t, t) < 1e-6f) t = (F3){1, 0, 0};
    t = norm(t);
    F3 bit = norm(cross(n, t));
    return {pos, n, t, bit, r, r, r};
}
}  // namespace

RootScene::RootScene(const MetalContext& ctx, int w, int h) {
    const std::string shaderDir    = std::string(MIRROR_APP_SHADER_DIR);
    const std::string sharedHeader = std::string(MIRROR_APP_SRC_DIR) + "/root_shared.h";
    rr_ = std::make_unique<MetalRootRenderer>(ctx, shaderDir, sharedHeader, w, h);
    if (!rr_->valid()) return;

    // A warm, mottled root material with soft fog, echoing mask_relay_gui's
    // default look.
    rr_->mat.baseColor[0] = 0.55f; rr_->mat.baseColor[1] = 0.42f; rr_->mat.baseColor[2] = 0.28f;
    rr_->mat.baseColor2[0] = 0.28f; rr_->mat.baseColor2[1] = 0.18f; rr_->mat.baseColor2[2] = 0.12f;
    rr_->mat.colorNoiseStrength = 0.6f;
    rr_->mat.colorNoiseScale = 0.35f;
    rr_->mat.ambient = 0.06f;
    rr_->mat.diffuse = 0.55f;
    rr_->fog.visibility = 45.0f;
    rr_->fog.noiseStrength = 0.55f;
    // The struct default (noiseContrast 1.20, 14 march steps) reads as
    // either a flat, barely-there haze or a solid wall with almost nothing
    // wispy in between: high contrast makes the noise swing hard between
    // "clear" and "opaque" rather than through a graded middle, and few march
    // steps under-integrate that swing into visible banding rather than a
    // soft density gradient. Softer contrast plus more steps trades a little
    // march cost (still well under the fog pass's own downscale budget -- see
    // Fog::downscale's comment) for the graded, wispy density that was
    // missing.
    rr_->fog.noiseContrast = 0.80f;
    rr_->fog.steps = 20;

    rr_->pulse.enabled = true;

    // Canonical face model (shared with the GL sdf_viewer assets).
    loadObj(std::string(SDF_VIEWER_DIR) + "/assets/canonical_face_model.obj",
            faceVerts_, faceTris_);
    normalizeMesh(faceVerts_);
    faceTris_ = cropOvalTris(faceVerts_, faceTris_, 0.72f, 0.98f);
    canonVerts_ = faceVerts_;
    canonTris_  = faceTris_;

    // Try the live CPlantBox growth; fall back to the procedural stand-in if the
    // parameter files aren't present.
    sim_ = std::make_unique<rootsim::RootSim>();
    simParams_.N = 5;
    regrow();
    if (useSim_) {
        // Framing is derived from the geometry's own bounds each frame (see
        // applyFraming); the constants that used to live here were tuned to one
        // particular R0/Hh and pointed at the wrong part of any other cone.
        rr_->radiusScale = 1.4f;
        rr_->radiusMin = 0.03f;
        rr_->radiusMax = 0.35f;
        // The masks are small; soften the per-face light so they read as faces
        // rather than blown-out blobs.
        rr_->face.lightIntensity = 1.8f;
        rr_->face.lightFalloff   = 0.05f;
    } else {
        buildSyntheticRoots(1u);
        rebuildFace();
    }
}

const std::vector<std::pair<std::string, std::string>>& RootScene::species() {
    // The reference GUI's list, verbatim -- these are the parameter sets that
    // are known to grow rather than every file in the directory.
    static const std::vector<std::pair<std::string, std::string>> kSpecies = {
        {"Maize (Zea mays)",      "Zea_mays_6_Leitner_2014.xml"},
        {"Soybean (Glycine max)", "Glycine_max.xml"},
        {"Pea (Pisum sativum)",   "Pisum_sativum_a_Pag\xc3\xa8s_2014.xml"},
        {"Sunflower (Heliantus)", "Heliantus_Pages_2013.xml"},
        {"Kale (Brassica)",       "Brassica_oleracea_Vansteenkiste_2014.xml"},
        {"Wheat (Triticum)",      "Triticum_aestivum_a_Bingham_2011.xml"},
        {"Lupin (Lupinus)",       "Lupinus_albus_Leitner_2014.xml"},
        {"Pimpernel (Anagallis)", "Anagallis_femina_Leitner_2010.xml"},
    };
    return kSpecies;
}

int RootScene::speciesIndex() const {
    const auto& sp = species();
    for (size_t i = 0; i < sp.size(); ++i)
        if (sp[i].second == simParams_.speciesXml) return (int)i;
    return -1;
}

void RootScene::setSpeciesIndex(int i) {
    const auto& sp = species();
    if (i >= 0 && i < (int)sp.size()) simParams_.speciesXml = sp[size_t(i)].second;
}

void RootScene::regrow() {
    if (!sim_) return;
    simParams_.paramDir = ROOTSIM_PARAM_DIR;
    useSim_ = sim_->reset(simParams_);
    simAvailable_ = simAvailable_ || useSim_;
    growthStepEstimate_ = -1;   // simParams_ may have changed; recompute lazily
    ++growGeneration_;
}

void RootScene::replant() {
    if (!sim_) return;
    simParams_.paramDir = ROOTSIM_PARAM_DIR;
    useSim_ = sim_->reset(simParams_);
    simAvailable_ = simAvailable_ || useSim_;
    // growthStepEstimate_ deliberately kept -- see the header.
    ++growGeneration_;
    // The renderer is still holding the *last* visitor's geometry, and nothing
    // else would drop it: the segment buffers are only rewritten by a growth
    // step, and the beat that follows this call holds the growth paused. So a
    // second sitting opened on a full-grown plant from the first one, visible
    // through the film during the press -- which is the one thing that must not
    // be on screen while the pond is still up. Resetting the sim is not enough;
    // the upload has to be undone too.
    if (rr_) rr_->uploadSegments({}, {}, {});
    // The beat-4 neighbour hood is exactly the same problem one layer up:
    // addNeighbours() only clears `neighbours` and the renderer's instance
    // buffers when it runs *again*, which is minutes into the new sitting
    // (Beat::Meander). Until then the previous visitor's hood -- both its
    // baked root-capsule instances (drawn straight out of rr_'s instances_)
    // and its faces (uploadFaceFromMasks() loops over `neighbours`
    // unconditionally, every frame, regardless of beat) -- was still sitting
    // there, so the very first frame of the new sitting showed the new plant
    // plus nine leftover copies of the old one: N masks x (1 + 9 neighbours)
    // faces, and all of their root structures too. Drop both here, at the
    // same place everything else about the last visitor gets dropped.
    if (rr_) rr_->clearInstances();
    neighbours.clear();
    // The last visitor's face likewise has to go, not just the plant: the
    // fit's normalisation is captured once "from the first mesh seen" (see
    // setFittedFace) and otherwise never revisited, so every visitor after
    // the first would have been normalised against someone else's face; and
    // the captured colours/mesh are what a fresh anchor mask would otherwise
    // reveal wearing until the new visitor is actually tracked.
    faceColors_.clear();
    fitted_face_ = false;
    fit_norm_set_ = false;
    faceVerts_ = canonVerts_;
    faceTris_  = canonTris_;
    // ...and the framing bounds it left behind, which are a min/max over that
    // same vanished geometry.
    idleCentre_[0] = idleCentre_[1] = idleCentre_[2] = 0.f;
    idleExtent_ = 10.f;
    // Push all of the above to the renderer now, rather than waiting for
    // whatever incidental uploadFaceFromMasks()/rebuildFace() call happens to
    // come next -- the caller's very next frame must not still be drawing the
    // last visitor's hood.
    rebuildFace();
}

int RootScene::growthStepEstimate() const {
    if (growthStepEstimate_ >= 0) return growthStepEstimate_;
    int simSteps = 0;
    rootsim::SimParams probe = simParams_;
    probe.paramDir = ROOTSIM_PARAM_DIR;
    rootsim::RootSim sim;
    if (sim.reset(probe))
        while (!sim.done() && simSteps < 200000) { sim.step(); ++simSteps; }
    growthStepEstimate_ = simSteps;
    return simSteps;
}

bool RootScene::simDone() const { return sim_ && sim_->done(); }

const std::vector<rootsim::SimMask>& RootScene::plannedMasks() const {
    static const std::vector<rootsim::SimMask> kNone;
    return sim_ ? sim_->plannedMasks() : kNone;
}

const std::vector<rootsim::SimMask>& RootScene::revealedMasks() const {
    static const std::vector<rootsim::SimMask> kNone;
    return sim_ ? sim_->revealedMasks() : kNone;
}

void RootScene::buildField(int gridN, float spacing) {
    if (!rr_ || !sim_) return;
    // Ensure the template system is fully grown.
    for (int i = 0; i < 6000 && !sim_->done(); ++i) sim_->step();
    std::vector<float> nodes, radii; std::vector<int> segs;
    sim_->geometry(nodes, segs, radii);
    if (nodes.empty() || segs.empty()) return;

    rr_->clearInstances();
    std::mt19937 rng(1234);
    std::uniform_real_distribution<float> U(0.f, 1.f);
    const float half = (gridN - 1) * 0.5f;
    for (int gz = 0; gz < gridN; gz++)
        for (int gx = 0; gx < gridN; gx++) {
            MetalRootRenderer::InstancePlacement pl;
            pl.translate[0] = (gx - half) * spacing;
            pl.translate[1] = 0.f;
            pl.translate[2] = (gz - half) * spacing;
            pl.rotYaw = U(rng) * 6.2831853f;
            pl.scale  = 0.8f + 0.4f * U(rng);
            rr_->addInstance(nodes, segs, radii, pl);
        }
    // The field is the cached instances; stop the single live system + face pass.
    rr_->uploadSegments({}, {}, {});
    rr_->uploadFaceMesh({});
    useSim_ = false;
}

void RootScene::addNeighbours(int count, float ringRadius, unsigned seed,
                              const float centre[3], float keepClearAz) {
    if (!rr_ || !sim_) return;
    std::vector<float> nodes, radii; std::vector<int> segs;
    sim_->geometry(nodes, segs, radii);
    if (nodes.empty() || segs.empty()) return;

    rr_->clearInstances();
    neighbours.clear();
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> U(0.f, 1.f);
    for (int i = 0; i < count; ++i) {
        // Two loose rings rather than a grid: a grid reads as a diagram, and
        // the depth spread is what makes the neighbours sit *around* the piece
        // instead of beside it.
        // Spread in depth as well as around: neighbours all at one distance
        // read as a row of cut-outs behind the subject rather than as a room
        // the subject is standing in.
        const float ring = ringRadius * (0.85f + 0.5f * U(rng));
        float a = 6.2831853f * (float(i) / std::max(1, count)) + (U(rng) - 0.5f) * 0.5f;
        // Push out of the wedge the camera is looking through.
        float rel = a - keepClearAz;
        while (rel >  3.14159265f) rel -= 6.2831853f;
        while (rel < -3.14159265f) rel += 6.2831853f;
        if (std::fabs(rel) < 0.6f) a += (rel < 0 ? -1.f : 1.f) * (0.6f - std::fabs(rel));
        MetalRootRenderer::InstancePlacement pl;
        pl.translate[0] = centre[0] + std::sin(a) * ring;
        pl.translate[1] = centre[1] * 0.15f + (U(rng) - 0.5f) * ringRadius * 0.25f;
        pl.translate[2] = centre[2] + std::cos(a) * ring;
        pl.rotYaw = U(rng) * 6.2831853f;
        pl.scale  = 0.75f + 0.5f * U(rng);
        rr_->addInstance(nodes, segs, radii, pl);
        neighbours.push_back({{pl.translate[0], pl.translate[1], pl.translate[2]},
                              pl.rotYaw, pl.scale});
    }
    rebuildFace();
}

bool RootScene::growthTip(float out[3]) const {
    return sim_ && sim_->tip(out);
}

int  RootScene::currentMask() const { return sim_ ? sim_->currentMask() : -1; }
bool RootScene::arrivedAtMask() const { return sim_ && sim_->arrivedAtMask(); }

// Normalised lerp between two unit vectors, and the third axis of the frame.
// Not a slerp: over the angles a mask turns through here the two are visually
// identical, and this cannot produce a NaN when the vectors are near-parallel.
static F3 nlerp3(const float a[3], const float b[3], float t) {
    float v[3] = {a[0] + (b[0] - a[0]) * t,
                  a[1] + (b[1] - a[1]) * t,
                  a[2] + (b[2] - a[2]) * t};
    const float l = std::sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
    if (l < 1e-6f) return F3{b[0], b[1], b[2]};
    return F3{v[0]/l, v[1]/l, v[2]/l};
}

static F3 orthonormal3(const F3& n, const F3& t) {
    F3 c = {n.y*t.z - n.z*t.y, n.z*t.x - n.x*t.z, n.x*t.y - n.y*t.x};
    const float l = std::sqrt(c.x*c.x + c.y*c.y + c.z*c.z);
    return (l < 1e-6f) ? F3{0.f, 1.f, 0.f} : F3{c.x/l, c.y/l, c.z/l};
}

void RootScene::uploadFaceFromMasks() {
    if (!rr_ || !sim_) return;
    if (!showFace || faceVerts_.empty() || faceTris_.empty()) { rr_->uploadFaceMesh({}); return; }
    const float maskColor[3] = {0.86f, 0.83f, 0.78f};
    std::vector<float> data;
    int mi = -1;
    const auto& masks = showPlannedMasks ? sim_->plannedMasks() : sim_->revealedMasks();
    const float* origin = sim_->plannedMasks().empty() ? nullptr
                                                       : sim_->plannedMasks().front().pos;
    for (const auto& sm : masks) {
        ++mi;
        // Per-mask identity when there is one; otherwise every mask is the
        // same face, which is the live case (one visitor at a time).
        const std::vector<float>& verts =
            (mi < (int)maskVerts_.size() && !maskVerts_[size_t(mi)].empty())
                ? maskVerts_[size_t(mi)] : faceVerts_;
        Mask m;
        const float d = std::clamp(maskDeal, 0.f, 1.f);
        const bool dealing = showPlannedMasks && origin && d < 1.f;
        const auto& first = sim_->plannedMasks().front();
        // Before the deal starts there is one face, not nine stacked in the
        // same place: the others are simply not drawn.
        if (dealing && mi > 0 && d < 1e-3f) continue;
        if (dealing) {
            m.pos = {origin[0] + (sm.pos[0] - origin[0]) * d,
                     origin[1] + (sm.pos[1] - origin[1]) * d,
                     origin[2] + (sm.pos[2] - origin[2]) * d};
            // ...and they turn as they travel, from the first mask's
            // orientation into their own, so they peel off it rather than
            // sliding out already facing the right way.
            m.normal    = nlerp3(first.normal,    sm.normal,    d);
            m.tangent   = nlerp3(first.tangent,   sm.tangent,   d);
            m.bitangent = orthonormal3(m.normal, m.tangent);
        } else {
            m.pos = {sm.pos[0], sm.pos[1], sm.pos[2]};
            m.normal = {sm.normal[0], sm.normal[1], sm.normal[2]};
            m.tangent = {sm.tangent[0], sm.tangent[1], sm.tangent[2]};
            m.bitangent = {sm.bitangent[0], sm.bitangent[1], sm.bitangent[2]};
        }
        // The cloth press: while the anchor mask is still advancing through
        // the sheet (see advanceCloth), it is retracted behind its resting
        // position along its own -normal by clothPressOffset_, reaching 0 --
        // i.e. exactly the placement this loop already computes -- by the
        // time the press finishes. Only the anchor moves; every other mask
        // (revealed later, once Roots is growing) is drawn at its own place
        // as always.
        if (mi == anchorMask && clothActive_ && clothPressOffset_ != 0.f)
            m.pos = sub(m.pos, mul(m.normal, clothPressOffset_));
        m.rDepth = sm.rDepth; m.rWidth = sm.rWidth; m.rHeight = sm.rHeight;
        appendFaceVertexData(data, m, verts, faceTris_, faceScale, faceRecess, 3.0f,
                             maskColor, faceColors_, rr_->face.smoothNormals);
    }

    // The same masks again for every neighbouring copy. Scale, yaw about Y,
    // translate -- the order addInstance bakes its nodes with, so the faces
    // land in the roots rather than beside them.
    for (const auto& pl : neighbours) {
        const float cy = std::cos(pl.rotYaw), sy = std::sin(pl.rotYaw);
        auto xf = [&](const float v[3], bool isPoint) {
            const float s = isPoint ? pl.scale : 1.f;
            const float lx = v[0] * s, ly = v[1] * s, lz = v[2] * s;
            return F3{lx * cy + lz * sy + (isPoint ? pl.translate[0] : 0.f),
                      ly            + (isPoint ? pl.translate[1] : 0.f),
                     -lx * sy + lz * cy + (isPoint ? pl.translate[2] : 0.f)};
        };
        int ni = -1;
        for (const auto& sm : sim_->plannedMasks()) {
            ++ni;
            const std::vector<float>& verts =
                (ni < (int)maskVerts_.size() && !maskVerts_[size_t(ni)].empty())
                    ? maskVerts_[size_t(ni)] : faceVerts_;
            Mask m;
            m.pos       = xf(sm.pos, true);
            m.normal    = xf(sm.normal, false);
            m.tangent   = xf(sm.tangent, false);
            m.bitangent = xf(sm.bitangent, false);
            m.rDepth = sm.rDepth * pl.scale;
            m.rWidth = sm.rWidth * pl.scale;
            m.rHeight = sm.rHeight * pl.scale;
            appendFaceVertexData(data, m, verts, faceTris_, faceScale, faceRecess, 3.0f,
                                 maskColor, faceColors_, rr_->face.smoothNormals);
        }
    }
    rr_->uploadFaceMesh(data);
}

// ---------------------------------------------------------------------------
// Cloth: the pond -> face press/release, moved in from TransitionScene.
//
// The cloth is built and simulated entirely in the anchor mask's own local
// frame (tangent -> local x, bitangent -> local y, normal -> local z) rather
// than in a fixed camera frame: step 1-2's anchor-first placement guarantees
// that frame is fixed and known (render-space origin, normal +z, bitangent
// +y -- see root_sim.cpp), so a rest sheet built flat at local z=0 already
// sits exactly in the mask's own plane, and gravity along -normal is just
// (0,0,-g) in local coordinates -- the same simplicity TransitionScene had
// from its fixed front-on camera, without depending on one. Positions are
// only ever converted to world space at the very end, in packClothMesh, for
// the GPU to draw; the collider (rasteriseClothField) is built in the same
// local frame the cloth already lives in, so collision needs no transform
// either.
// ---------------------------------------------------------------------------

void RootScene::skipCloth() {
    // Parked past the end of the timeline rather than at zero, so clothDone()
    // agrees with clothActive_ -- the phase gate in main.mm reads clothDone(),
    // and a scene that never had a film has certainly finished playing one.
    clothT_ = double(clothTiming.hold + clothTiming.press + clothTiming.settle +
                     clothTiming.release + clothTiming.fall) + 1.0;
    clothActive_ = false;
    clothPressOffset_ = 0.f;
    clothExtentFrozen_ = false;
    // Cleared past the threshold rather than left at its "never measured"
    // floor: callers gate the hand-off on clothCleared(), and a scene with no
    // film in it has by definition nothing left to get out of the way.
    clothClearanceVal_ = clothClearDistance;
    if (rr_) rr_->uploadClothMesh({});
    uploadFaceFromMasks();
}

void RootScene::restartCloth() {
    clothT_ = 0.0;
    clothActive_ = true;
    clothClearanceVal_ = -1e9f;
    clothPressOffset_ = 0.f;
    clothBuiltRes_ = 0;          // force ensureClothSheet to rebuild flat & fully pinned
    clothExtentFrozen_ = false;  // and to re-measure the frustum it has to cover
    measureClothFaceDepth();
}

float RootScene::clothPress() const {
    return std::clamp((float(clothT_) - clothTiming.hold) / std::max(1e-3f, clothTiming.press), 0.f, 1.f);
}
float RootScene::clothRelease() const {
    const float t0 = clothTiming.hold + clothTiming.press + clothTiming.settle;
    return std::clamp((float(clothT_) - t0) / std::max(1e-3f, clothTiming.release), 0.f, 1.f);
}
// When the film may stop being drawn.
//
// Not when the timeline says so. The fall is physics, and how long it takes to
// carry a crumpling sheet off the mask depends on how big the sheet is -- so a
// fixed `fall` duration deleted the film mid-air, in one frame, while it was
// still a wad sitting over the face. That is the pop: an object that was
// visibly moving simply ceased.
//
// So the schedule is a floor and the geometry is the decision. clothClearance
// is the mean depth of the sheet past the mask's own front, and it rises
// monotonically through the fall; expressed in sheet half-heights it says the
// same thing at any frustum. The ceiling is the safety net for a sheet that
// somehow never recedes (a collider that traps it, a gravity of zero), so the
// film cannot outlive the visit.
bool RootScene::clothRetired() const {
    // Distance, not schedule. The authored `fall` does not appear here at all:
    // the sim owns the fall, and the only question this answers is whether the
    // film has got far enough behind the mask to be gone. Gating on the
    // schedule first (an earlier version did) just moved the early cut later --
    // it still cut on a clock.
    const float gone = clothGoneDistance * std::max(0.05f, clothHalfY_);
    if (clothClearanceVal_ >= gone) return true;
    // The safety net, for a sheet that somehow never recedes -- a collider that
    // traps it, a gravity of zero -- so the film cannot outlive the visit.
    // Deliberately far past anything the physics needs.
    const float ceiling = clothTiming.hold + clothTiming.press + clothTiming.settle +
                          clothTiming.release + clothTiming.fall * kClothFallCeiling;
    return float(clothT_) > ceiling;
}

bool RootScene::clothDone() const {
    return float(clothT_) > clothTiming.hold + clothTiming.press + clothTiming.settle +
                            clothTiming.release + clothTiming.fall;
}
const char* RootScene::clothPhaseName() const {
    const float t = float(clothT_);
    if (t < clothTiming.hold) return "hold";
    if (t < clothTiming.hold + clothTiming.press) return "press";
    if (t < clothTiming.hold + clothTiming.press + clothTiming.settle) return "settle";
    if (t < clothTiming.hold + clothTiming.press + clothTiming.settle + clothTiming.release)
        return "release";
    return "fall";
}

// The anchor mask's frame, for this frame -- read from the sim's planned
// layout (available from reset() on, whether or not that mask has actually
// been revealed yet) rather than hardcoded, so a future change to the anchor
// pose in root_sim.cpp cannot silently desync the cloth from the mask.
// Falls back to the identity frame (origin, +z/+x/+y) -- the documented
// anchor pose -- when there is no sim to ask (the synthetic-roots fallback).
void RootScene::refreshClothAnchor() {
    const auto& pm = plannedMasks();
    if (sim_ && anchorMask >= 0 && anchorMask < (int)pm.size()) {
        const auto& m = pm[size_t(anchorMask)];
        clothAnchorPos_ = simd_make_float3(m.pos[0], m.pos[1], m.pos[2]);
        clothAnchorN_   = simd_make_float3(m.normal[0], m.normal[1], m.normal[2]);
        clothAnchorT_   = simd_make_float3(m.tangent[0], m.tangent[1], m.tangent[2]);
        clothAnchorB_   = simd_make_float3(m.bitangent[0], m.bitangent[1], m.bitangent[2]);
        clothAnchorRW_ = m.rWidth; clothAnchorRH_ = m.rHeight; clothAnchorRD_ = m.rDepth;
    } else {
        clothAnchorPos_ = simd_make_float3(0, 0, 0);
        clothAnchorN_   = simd_make_float3(0, 0, 1);
        clothAnchorT_   = simd_make_float3(1, 0, 0);
        clothAnchorB_   = simd_make_float3(0, 1, 0);
        clothAnchorRW_ = clothAnchorRH_ = clothAnchorRD_ = 2.6f;
    }
}

// The sheet is sized to the frustum cross-section at its own plane, exactly as
// TransitionScene sized it -- the difference is only that the camera it asks is
// RootScene's live one rather than a fixed rig.
//
// The distance is measured to the sheet's plane along the anchor's normal
// rather than taken as `radius` directly, so it stays correct if the camera is
// ever off the anchor's axis; through beat 1 (which is the whole of the press)
// RootCameraSequence puts it straight down that normal and the two agree.
//
// Note `radius` here is a *half*-angle: MetalRootRenderer::render builds its
// projection as 1/tan(fov), not 1/tan(fov/2). Halving it -- the more familiar
// convention -- builds a sheet a little over a third the width it needs, which
// is precisely the bug this replaces.
//
// Built once per press and then frozen: the extents are a property of the
// sheet, not of where the camera happens to be this frame, and rebuilding
// resets every vertex to the flat rest pose, which mid-fall is a visible snap.
void RootScene::ensureClothSheet() {
    const int res = std::clamp(clothSheetRes, 16, 192);
    const float over = std::max(1.0f, clothOversize);

    // Re-solved every frame for as long as the sheet is still flat and fully
    // pinned, then frozen when the press begins.
    //
    // Freezing on the very first frame (what this did before) trusts a camera
    // that has usually not arrived yet: with the authored sequence off --
    // which is the default -- applyFraming eases target and radius in from
    // whatever the previous phase left, so frame one of the press sees a
    // camera still travelling. Rebuilding costs nothing while the sheet is
    // flat, because there is no simulated state to lose: every vertex is at
    // its rest position and every pin is fully held, so a rebuild is a no-op
    // the eye can see. Once the press starts there *is* state, and a rebuild
    // would snap the whole drape back to flat -- hence the freeze.
    if (!clothExtentFrozen_) {
        const float aspect = float(std::max(1, width())) / float(std::max(1, height()));
        const float tanF = std::tan(std::clamp(effectiveFov(), 0.05f, 1.4f));

        // The frustum's footprint on the anchor's plane, for one camera pose:
        // where the view axis crosses it, and how far the frame reaches either
        // side of that in the sheet's own tangent/bitangent coordinates.
        //
        // eye = target + radius * (cosEl sinAz, sinEl, cosEl cosAz) -- the same
        // spherical convention applyFraming and the renderer use.
        struct Foot { float u, v, halfX, halfY; };
        auto footprint = [&](const float tgt[3], float rad, float az, float el) {
            const float ce = std::cos(el), se = std::sin(el);
            const simd_float3 eye = simd_make_float3(tgt[0] + rad * ce * std::sin(az),
                                                     tgt[1] + rad * se,
                                                     tgt[2] + rad * ce * std::cos(az));
            const simd_float3 at = simd_make_float3(tgt[0], tgt[1], tgt[2]);
            const float dist = std::max(0.5f,
                std::fabs(simd_dot(eye - clothAnchorPos_, clothAnchorN_)));
            // Centre the sheet where the camera actually looks through the
            // plane. Falls back to the anchor when the ray runs parallel to it,
            // which is a camera looking along the mask's own surface -- a shot
            // the press has no meaning in anyway, and not one worth a special
            // case beyond not dividing by zero.
            simd_float3 fwd = at - eye;
            const float flen = simd_length(fwd);
            simd_float3 c = clothAnchorPos_;
            if (flen > 1e-5f) {
                fwd /= flen;
                const float denom = simd_dot(fwd, clothAnchorN_);
                if (std::fabs(denom) > 1e-4f) {
                    const float t = simd_dot(clothAnchorPos_ - eye, clothAnchorN_) / denom;
                    if (t > 0.f) c = eye + fwd * t;
                }
            }
            const simd_float3 d = c - clothAnchorPos_;
            Foot f;
            f.u = simd_dot(d, clothAnchorT_);
            f.v = simd_dot(d, clothAnchorB_);
            f.halfY = dist * tanF;
            f.halfX = f.halfY * aspect;
            return f;
        };

        // The union of where the camera is and where it is going.
        //
        // The sheet is pinned and flat right now, but it will still be this
        // sheet when the ease has finished, and by then it is draping and can
        // no longer be rebuilt. Sizing against the entry pose alone is the same
        // trap as solving it against the previous frame's camera: correct at
        // the instant it was measured and wrong for everything the audience
        // actually watches. Taking the union of the two endpoints covers the
        // whole path, because applyFraming interpolates target and radius
        // monotonically between them -- the angles ease monotonically too, so
        // the crossing point sweeps between the two footprints rather than
        // outside them, and the oversize margin absorbs the small bow that a
        // simultaneous angle-and-distance change puts in that sweep.
        Foot f = footprint(target, radius, azimuth, elevation);
        float uLo = f.u - f.halfX, uHi = f.u + f.halfX;
        float vLo = f.v - f.halfY, vHi = f.v + f.halfY;
        if (camDesValid_) {
            const Foot g = footprint(camDesTarget_, camDesRadius_, camDesAz_, camDesEl_);
            uLo = std::min(uLo, g.u - g.halfX); uHi = std::max(uHi, g.u + g.halfX);
            vLo = std::min(vLo, g.v - g.halfY); vHi = std::max(vHi, g.v + g.halfY);
        }
        // The film's own rectangle is the view being cut *from* -- the current
        // pose, and exactly it, with no margin. uv 0..1 has to be the frame the
        // pond filled at the instant of the cut; anything else scales the
        // picture. The margin belongs on the extent below, where it always
        // did: the sheet reaches past the frame and that overhang runs past
        // 0..1 and clamps, which is what puts film rather than background at
        // the edge when the sheet moves.
        const float filmHalfX = std::max(0.05f, f.halfX);
        const float filmHalfY = std::max(0.05f, f.halfY);

        // Symmetric about the union's own centre, because the sheet is built
        // symmetric about its centre.
        const float cu = 0.5f * (uLo + uHi), cv = 0.5f * (vLo + vHi);
        // ...and the film rectangle expressed relative to that centre.
        clothFilmU_ = f.u - cu;
        clothFilmV_ = f.v - cv;
        clothFilmHalfX_ = filmHalfX;
        clothFilmHalfY_ = filmHalfY;
        // The extent covers the union, plus the margin. The union is the
        // envelope of the two endpoint frustums; the poses in between sweep
        // between them rather than outside, but a simultaneous change of angle
        // and distance bows that sweep slightly, and the margin is what
        // absorbs the bow. It is also what guarantees the edge of the frame is
        // never the edge of the sheet.
        const float newHalfX = std::max(0.05f, std::max(0.5f * (uHi - uLo), filmHalfX) * over);
        const float newHalfY = std::max(0.05f, std::max(0.5f * (vHi - vLo), filmHalfY) * over);
        const simd_float3 centre = clothAnchorPos_ + clothAnchorT_ * cu + clothAnchorB_ * cv;

        // Rebuild only on a real change, so a settled camera stops churning
        // the sheet every frame for nothing.
        const bool moved = simd_length(centre - clothCentre_) > 1e-3f ||
                           std::fabs(newHalfX - clothHalfX_) > 1e-3f ||
                           std::fabs(newHalfY - clothHalfY_) > 1e-3f;
        clothCentre_ = centre;
        clothHalfX_ = newHalfX;
        clothHalfY_ = newHalfY;
        if (moved) clothBuiltRes_ = 0;   // force the build below
        // The press is about to start doing physics: stop moving the ground.
        if (float(clothT_) >= clothTiming.hold) clothExtentFrozen_ = true;
    }

    if (res == clothBuiltRes_ && std::fabs(over - clothBuiltOversize_) < 1e-4f) return;
    clothBuiltRes_ = res;
    clothBuiltOversize_ = over;
    // Cells square-ish in world terms rather than square in grid terms: a 16:9
    // sheet on a square grid stretches every cell, and the stretch/plastic
    // limits are per-edge, so it would drape differently across than down.
    const int nx = res;
    const int ny = std::max(8, int(std::lround(float(res) * clothHalfY_ / std::max(1e-4f, clothHalfX_))));
    cloth_.buildSheet(nx, ny, 2.f * clothHalfX_, 2.f * clothHalfY_, /*borderCells=*/1);
    // Normals before the first render -- buildSheet leaves them zeroed, and a
    // zero normal normalises to garbage.
    cloth_.computeNormals();
    clothField_.resize(kClothFieldRes, kClothFieldRes, clothHalfX_, clothHalfY_);
}

// The face model's own local z extent, off the mesh that is actually going to
// be drawn. Cheap (one pass over a few thousand verts, once per press) and it
// removes the two constants the first version of this port guessed at.
void RootScene::measureClothFaceDepth() {
    clothFaceZMin_ = 0.f; clothFaceZMax_ = 0.f;
    if (faceVerts_.size() < 3) return;
    float lo = 1e9f, hi = -1e9f;
    for (size_t i = 2; i < faceVerts_.size(); i += 3) {
        lo = std::min(lo, faceVerts_[i]);
        hi = std::max(hi, faceVerts_[i]);
    }
    if (lo <= hi) { clothFaceZMin_ = lo; clothFaceZMax_ = hi; }
}

// The collider: the anchor's own placed face mesh (at the current press
// offset), rasterised as a depth map in the anchor's local (x, y) -- an
// affine projection (three dot products), not TransitionScene's perspective
// one, because the frame it projects into is fixed rather than a moving
// camera. See TransitionScene::Impl::rasteriseField for the pattern this
// ports.
void RootScene::rasteriseClothField() {
    clothField_.clear();
    if (faceVerts_.empty() || faceTris_.empty()) return;
    const int fw = clothField_.w, fh = clothField_.h;
    if (fw < 2 || fh < 2) return;

    const float scale = faceScale * std::max(0.05f, std::min(clothAnchorRW_, clothAnchorRH_));
    // The same base placement appendFaceVertexData uses for this mask
    // (recessed into its cavity), retracted further by the current press
    // offset -- see uploadFaceFromMasks' anchor special-case above.
    const simd_float3 base = clothAnchorPos_
        - clothAnchorN_ * (clothAnchorRD_ * faceRecess)
        - clothAnchorN_ * clothPressOffset_;

    auto toField = [&](simd_float3 w, float& fx, float& fy, float& z) {
        // Lateral offsets are measured from the sheet's own centre; the depth
        // is unchanged by the swap, because clothCentre_ is on the anchor's
        // plane by construction and so has zero component along the normal.
        const simd_float3 d = w - clothCentre_;
        const float lx = simd_dot(d, clothAnchorT_);
        const float ly = simd_dot(d, clothAnchorB_);
        z = simd_dot(d, clothAnchorN_);
        fx = (lx + clothHalfX_) / (2.f * clothHalfX_) * float(fw - 1);
        fy = (clothHalfY_ - ly) / (2.f * clothHalfY_) * float(fh - 1);
    };

    const size_t nv = faceVerts_.size() / 3;
    std::vector<simd_float3> wpos(nv);
    for (size_t i = 0; i < nv; ++i) {
        const simd_float3 local =
            simd_make_float3(faceVerts_[i * 3], faceVerts_[i * 3 + 1], faceVerts_[i * 3 + 2]);
        wpos[i] = base + clothAnchorT_ * (local.x * scale) + clothAnchorB_ * (local.y * scale)
                       + clothAnchorN_ * (local.z * scale);
    }

    for (size_t t = 0; t + 2 < faceTris_.size(); t += 3) {
        const int ia = faceTris_[t], ib = faceTris_[t + 1], ic = faceTris_[t + 2];
        if (ia < 0 || ib < 0 || ic < 0) continue;
        if (size_t(ia) >= nv || size_t(ib) >= nv || size_t(ic) >= nv) continue;
        float ax, ay, az, bx, by, bz, cx, cy, cz;
        toField(wpos[size_t(ia)], ax, ay, az);
        toField(wpos[size_t(ib)], bx, by, bz);
        toField(wpos[size_t(ic)], cx, cy, cz);

        const float area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        if (std::fabs(area) < 1e-9f) continue;
        const float inv = 1.f / area;

        int x0 = std::max(0, int(std::floor(std::min({ax, bx, cx}))));
        int x1 = std::min(fw - 1, int(std::ceil(std::max({ax, bx, cx}))));
        int y0 = std::max(0, int(std::floor(std::min({ay, by, cy}))));
        int y1 = std::min(fh - 1, int(std::ceil(std::max({ay, by, cy}))));

        for (int y = y0; y <= y1; ++y) {
            const float py = float(y) + 0.5f;
            for (int x = x0; x <= x1; ++x) {
                const float px = float(x) + 0.5f;
                float w0 = ((bx - ax) * (py - ay) - (by - ay) * (px - ax)) * inv;
                float w1 = ((px - ax) * (cy - ay) - (py - ay) * (cx - ax)) * inv;
                const float w2 = 1.f - w0 - w1;
                if (w0 < 0.f || w1 < 0.f || w2 < 0.f) continue;
                const float z = w2 * az + w1 * bz + w0 * cz;
                const size_t k = size_t(y) * size_t(fw) + size_t(x);
                if (!clothField_.cover[k] || z > clothField_.z[k]) {
                    clothField_.z[k] = z; clothField_.cover[k] = 1;
                }
            }
        }
    }

    const float texel = 2.f * clothHalfX_ / float(std::max(1, fw - 1));
    const float cell  = 2.f * clothHalfX_ / float(std::max(1, cloth_.nx - 1));
    clothField_.dilate(int(std::ceil(cell / std::max(texel, 1e-6f))));
    clothField_.buildNormals();
}

// The anchor's own front z (in its local frame) minus the cloth's mean --
// positive and growing as the sheet recedes behind the face. See
// TransitionScene::Impl::updateClothClearance, same intent.
//
// The mask's front comes from the mesh's measured z extent (see
// measureClothFaceDepth), not from an estimate: an earlier version of this port
// guessed the canonical model's half-depth at 0.2 where it is in fact 0.383,
// which on a live layout put the reported clearance about 0.4 low -- enough
// that clothCleared() never once returned true, so beat 1 sat on its
// ten-second clear tail every time instead of moving on when the film left.
void RootScene::updateClothClearance() {
    if (cloth_.pos.empty()) return;
    double zsum = 0; size_t n = 0;
    for (size_t k = 0; k < cloth_.pos.size(); ++k) {
        if (!cloth_.active[k]) continue;
        zsum += cloth_.pos[k].z;
        ++n;
    }
    if (!n) return;
    clothClearanceVal_ = anchorFrontLocalZ() - float(zsum / double(n));
}

// Where the anchor mask's frontmost point sits, in the anchor's local frame, at
// the current press offset. The single place the press geometry is spelled out:
// the collider, the clearance signal and the press schedule all read it, so the
// visible mask and the thing the cloth collides with cannot drift apart.
float RootScene::anchorFrontLocalZ() const {
    const float scale = faceScale * std::max(0.05f, std::min(clothAnchorRW_, clothAnchorRH_));
    return -(clothAnchorRD_ * faceRecess) - clothPressOffset_ + clothFaceZMax_ * scale;
}

// cloth_'s local-frame triangles -> world-space interleaved vertices (10
// floats/vertex: pos3, nrm3, uv2, aux2) for MetalRootRenderer::uploadClothMesh
// / root_cloth.metal's ClothVertex. uv/aux mirror TransitionScene's
// Impl::packCloth exactly (rest-grid uv, discrete-Laplacian curvature,
// displacement off the rest plane) -- only the position/normal conversion to
// world space (via the anchor's basis) is new, since the cloth itself is
// simulated in local coordinates (see the file comment above).
void RootScene::packClothMesh() {
    if (!rr_) return;
    // The film is a picture until it starts to leave, and an object once it
    // has. Held at 1 through hold/press/settle -- where the sheet covers the
    // frame and the audience must not be able to tell that the Mirror phase
    // ended -- then handed over to the scene's own grade across the release, by
    // which point it is falling away and being lit with the room is what it
    // wants. See RootClothU::passThrough for why this exists at all.
    rr_->cloth.passThrough = 1.f - smoothstep01(clothRelease());
    if (!showCloth || !clothActive_ || cloth_.tris.empty()) { rr_->uploadClothMesh({}); return; }

    const float cellW = 2.f * clothHalfX_ / float(std::max(1, cloth_.nx - 1));
    const int di[4] = {-1, 1, 0, 0}, dj[4] = {0, 0, -1, 1};

    std::vector<float> data;
    data.reserve(cloth_.tris.size() * 10);
    for (size_t t = 0; t + 2 < cloth_.tris.size(); t += 3) {
        for (int k = 0; k < 3; ++k) {
            const uint32_t vi = cloth_.tris[t + k];
            const int i = int(vi) % cloth_.nx, j = int(vi) / cloth_.nx;
            const simd_float3 p = cloth_.pos[vi];
            const simd_float3 n = cloth_.nrm[vi];

            simd_float3 acc = simd_make_float3(0, 0, 0);
            int cnt = 0;
            for (int d = 0; d < 4; ++d) {
                const int ii = i + di[d], jj = j + dj[d];
                if (ii < 0 || ii >= cloth_.nx || jj < 0 || jj >= cloth_.ny) continue;
                acc += cloth_.pos[size_t(cloth_.idx(ii, jj))];
                ++cnt;
            }
            float curv = 0.f;
            if (cnt > 0) {
                const simd_float3 lap = acc / float(cnt) - p;
                const float sgn = n.z < 0.f ? -1.f : 1.f;
                curv = -simd_dot(lap, n) * sgn / std::max(1e-5f, cellW);
            }

            const simd_float3 pw = clothCentre_ + clothAnchorT_ * p.x
                                  + clothAnchorB_ * p.y + clothAnchorN_ * p.z;
            const simd_float3 nw = clothAnchorT_ * n.x + clothAnchorB_ * n.y + clothAnchorN_ * n.z;
            // uv from the vertex's *rest* position against the film
            // rectangle, rather than from its grid index against the sheet.
            // The two agreed while the sheet was the frustum times a margin;
            // they stop agreeing the moment the sheet has to be bigger than
            // the frame to survive a camera move, and it is the film rectangle
            // that keeps the cut invisible. Taken from the rest grid, not from
            // the live position, so the mapping stays locked to the fabric as
            // it stretches and falls -- the same property packCloth had.
            const float rx = (i / float(cloth_.nx - 1) - 0.5f) * (2.f * clothHalfX_);
            const float ry = (j / float(cloth_.ny - 1) - 0.5f) * (2.f * clothHalfY_);
            const float u = 0.5f + (rx - clothFilmU_) / (2.f * clothFilmHalfX_);
            const float v = 0.5f - (ry - clothFilmV_) / (2.f * clothFilmHalfY_);

            data.push_back(pw.x); data.push_back(pw.y); data.push_back(pw.z);
            data.push_back(nw.x); data.push_back(nw.y); data.push_back(nw.z);
            data.push_back(u); data.push_back(v);
            data.push_back(curv); data.push_back(p.z);
        }
    }
    rr_->uploadClothMesh(data);
}

// Drives the whole hold->press->settle->release->fall timeline. No-op until
// restartCloth() has been called once; from then on this runs every frame
// RootScene::advance() runs, independently of which show phase is current --
// see main.mm's dispatch, which now renders RootScene continuously from
// Transition entry onward instead of handing off to a separate scene.
void RootScene::advanceCloth(double dt) {
    if (!clothActive_) return;
    // The film is gone once the fall is over, and "gone" has to mean not drawn.
    // Nothing else retires it: RootScene keeps rendering straight through into
    // the Roots phase now (main.mm no longer swaps scenes here), so a sheet
    // left active stays on screen -- as the crumpled bundle the fall ends in,
    // parked in front of the mask -- for the whole rest of the visit. Dropping
    // clothActive_ also freezes clothT_, so clothDone() stays true for the
    // phase gate that reads it.
    if (clothRetired()) {
        clothActive_ = false;
        clothPressOffset_ = 0.f;   // the mask at exactly its cavity placement
        if (rr_) rr_->uploadClothMesh({});
        uploadFaceFromMasks();
        return;
    }
    refreshClothAnchor();
    ensureClothSheet();
    clothT_ += dt;

    // The press: the anchor mask travels from fully retracted behind the
    // sheet to its own natural resting placement (offset 0) -- see
    // uploadFaceFromMasks' anchor special-case. Unlike TransitionScene, which
    // pressed the mask *proud* of the sheet plane by a tunable amount and
    // held it there through settle, this simplifies to "arrives exactly where
    // it already belongs": the anchor's resting position is the one
    // RootScene's own cavity placement (faceRecess) already computes, so
    // there is no second resting depth to keep in sync with it. Flagged here
    // as a deliberate simplification against the original port.
    const float pe = smoothstep01(clothPress());
    const float scale = faceScale * std::max(0.05f, std::min(clothAnchorRW_, clothAnchorRH_));
    // Where the press starts: far enough back that the mask's own frontmost
    // point is clear behind the sheet's rest plane, and no further. Measured
    // (clothFaceZMax_) rather than the constant the first version of this port
    // used, which retracted by a couple of mask depths regardless and so spent
    // most of the press travelling through empty space before touching
    // anything.
    const float restFront = -(clothAnchorRD_ * faceRecess) + clothFaceZMax_ * scale;
    // Never negative. restFront is where the mask's frontmost point rests
    // relative to the sheet's plane, and on a mesh whose depth puts that point
    // *behind* the plane it goes negative -- which would start the press with
    // the mask already through the sheet, so the collider's first act is to
    // shove a fully-pinned sheet off a solid it is interpenetrating. That does
    // not read as a press at all; it reads as the film vanishing the moment it
    // is touched.
    const float retract = std::max(0.f, restFront + 0.05f * scale);
    // ...and where it ends: proud of the plane, so the film is actually tented
    // over a face rather than grazed by one. Held through the settle, unwound
    // over the release, so the mask is back at exactly its cavity placement --
    // offset 0, the one resting depth -- by the time the film has left it.
    const float proud = clothPressProud * scale;
    clothPressOffset_ = retract * (1.f - pe) - proud * pe * (1.f - smoothstep01(clothRelease()));

    rasteriseClothField();
    cloth_.collider = &clothField_;

    if (float(clothT_) <= clothTiming.hold) {
        updateClothClearance();
        return;   // advance() packs, after the framing -- see its tail
    }

    cloth_.skin = clothSkin;
    cloth_.iterations = clothIterations;
    cloth_.stretchMax = clothStretchMax;
    cloth_.damping = clothDamping;
    const float gr = smoothstep01(clothRelease());
    cloth_.plastic     = clothPlastic  * (1.f - gr);
    cloth_.stretchGive = clothStretch  * (1.f - 0.85f * gr);
    cloth_.friction    = clothFriction * (1.f - 0.75f * gr);
    cloth_.setRelease(clothRelease() * 1.25f);

    const float g = smoothstep01(clothRelease());
    // Scaled by the sheet's own size. The knobs below were tuned against
    // TransitionScene's sheet, which spanned about 2.4 units because its camera
    // sat 3 away; this one is sized to RootScene's frustum and spans about 11,
    // so the same acceleration carries it a fifth as far *relative to itself*
    // and the fall no longer clears the mask in anything like the same number
    // of seconds. Scaling here rather than re-tuning the numbers keeps `fall`
    // meaning the same thing at any frustum -- which matters, because the sheet
    // is now sized from the display's aspect and the camera's distance, and
    // both can change without anyone revisiting these.
    const float sizeK = std::max(0.2f, clothHalfX_ / kClothTunedHalfX);
    simd_float3 grav = simd_make_float3(0.f, -clothGravityDown * g * sizeK,
                                            -clothGravityBack * g * sizeK);
    // Guaranteed clearance, same intent as TransitionScene's -- see
    // sideForceDelay/sideForceMag's doc comments there. Unlike that version,
    // this always pushes the same way (local +x): the anchor's own frame is
    // fixed and does not turn with the visitor's head the way the live-fitted
    // face mesh did, so there is no head asymmetry to key the sign off.
    // Flagged as a simplification -- the guarantee (a bounded schedule to
    // clear) still holds, only the "reads as a continuation of the mask's own
    // asymmetry" nuance is lost.
    const float relT0 = clothTiming.hold + clothTiming.press + clothTiming.settle;
    const float relElapsed = float(clothT_) - relT0;
    const float sideRamp = smoothstep01((relElapsed - sideForceDelay) / 1.0f);
    if (sideRamp > 0.f) grav.x += sideForceMag * sideRamp * sizeK;
    cloth_.gravity = grav;

    const int ss = std::max(1, clothSubsteps);
    for (int i = 0; i < ss; ++i) cloth_.step(float(dt) / float(ss));
    cloth_.computeNormals();
    updateClothClearance();
    // No pack here: advance() does it once the camera has stopped moving for
    // this frame, so the sheet is always solved against the camera that draws it.
}

std::vector<std::vector<float>> RootScene::setTestIdentities(int n, unsigned seed,
                                                             float amount) {
    maskVerts_.clear();
    std::vector<std::vector<float>> alphas;
    mirror::FaceBasis basis;
    std::string err;
    if (!basis.load(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_basis.bin", err)) {
        printf("root: no face basis for test identities (%s)\n", err.c_str());
        return alphas;
    }
    // The basis mesh is not the canonical OBJ the scene starts with -- different
    // topology and four times the vertices -- so the triangles have to come
    // across with the vertices or the faces render as shrapnel.
    faceTris_ = basis.triangles();
    if (faceTris_.empty()) return alphas;

    // One normalisation for all of them, taken from the neutral face, the way
    // setFittedFace captures it once for a live sitter: normalising each mesh
    // on its own would divide out exactly the size differences that make the
    // identities distinguishable.
    const std::vector<float> noExpr;
    std::vector<float> neutral;
    basis.reconstruct(std::vector<float>(), noExpr, neutral);
    float centre[3] = {0, 0, 0}, scale = 1.f;
    {
        const size_t nv = neutral.size() / 3;
        double c[3] = {0, 0, 0};
        for (size_t i = 0; i < nv; ++i)
            for (int k = 0; k < 3; ++k) c[k] += neutral[i * 3 + k];
        for (int k = 0; k < 3; ++k) centre[k] = float(c[k] / double(nv));
        float m = 1e-9f;
        for (size_t i = 0; i < nv; ++i)
            for (int k = 0; k < 3; ++k)
                m = std::max(m, std::fabs(neutral[i * 3 + k] - centre[k]));
        scale = 1.0f / m;
    }

    // The first modes carry most of the variance, so sampling them all at one
    // scale gives n caricatures. Falling off as 1/sqrt(i+1) is the shape a PCA
    // spectrum has, and keeps the sampled faces inside the range the model was
    // fitted over.
    const int nid = basis.identityModes();
    unsigned s = seed ? seed : 1u;
    auto next = [&]() {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        return (s & 0xffffff) / double(0x1000000);
    };
    auto gauss = [&]() {
        const double u = std::max(1e-9, next()), v = next();
        return std::sqrt(-2.0 * std::log(u)) * std::cos(2.0 * M_PI * v);
    };

    std::vector<float> verts;
    for (int i = 0; i < n; ++i) {
        std::vector<float> alpha(size_t(nid), 0.f);
        for (int k = 0; k < nid; ++k)
            alpha[size_t(k)] = float(gauss() * amount / std::sqrt(double(k) + 1.0));
        basis.reconstruct(alpha, noExpr, verts);
        for (size_t v3 = 0; v3 < verts.size() / 3; ++v3)
            for (int k = 0; k < 3; ++k)
                verts[v3 * 3 + k] = (verts[v3 * 3 + k] - centre[k]) * scale;
        maskVerts_.push_back(verts);
        alphas.push_back(std::move(alpha));
    }
    fitted_face_ = true;      // so clearTestIdentities restores the canonical mesh
    faceVerts_ = maskVerts_.empty() ? faceVerts_ : maskVerts_.front();
    rebuildFace();
    return alphas;
}

void RootScene::clearTestIdentities() {
    maskVerts_.clear();
    rebuildFace();
}

void RootScene::rebuildFace() {
    if (!rr_) return;
    // Every path that replaces faceVerts_ ends here, so this is the one place
    // the cloth's depth model can be kept honest. It used to be measured only
    // in restartCloth(), which is wrong for the live show by construction: the
    // press starts on the Transition edge and setFittedFace() then replaces
    // the mesh on every frame of it, normalised to max-abs-coordinate 1 rather
    // than to the canonical model's own extent -- so the press was being
    // driven off a depth belonging to whatever mesh happened to be loaded
    // before the visitor arrived.
    measureClothFaceDepth();
    if (useSim_) { uploadFaceFromMasks(); return; }
    if (!showFace || faceVerts_.empty() || faceTris_.empty()) {
        rr_->uploadFaceMesh({});
        return;
    }
    const float maskColor[3] = {0.86f, 0.83f, 0.78f};
    // A few masks around the trunk at staggered heights, facing outward, so the
    // orbit reveals them and they depth-composite against the roots.
    std::vector<float> data;
    const int N = 3;
    for (int i = 0; i < N; i++) {
        float ang = 2.0f * (float)M_PI * i / N + 0.4f;
        float h = 6.0f + 5.0f * i;
        F3 dir = {std::sin(ang), 0.15f, std::cos(ang)};
        F3 center = {target[0] + 5.0f * std::sin(ang),
                     target[1] + h - 6.0f,
                     target[2] + 5.0f * std::cos(ang)};
        Mask m = makeMask(center, dir, 4.5f);
        appendFaceVertexData(data, m, faceVerts_, faceTris_, faceScale, faceRecess, 3.0f,
                             maskColor, faceColors_, rr_->face.smoothNormals);
    }
    rr_->uploadFaceMesh(data);
}

void RootScene::setFittedFace(const std::vector<float>& verts,
                              const std::vector<int>& tris) {
    if (verts.size() < 9) return;
    if (!tris.empty()) faceTris_ = tris;
    if (faceTris_.empty()) return;

    // Capture the normalisation once. Centre on the mesh centroid and divide by
    // the largest absolute coordinate, matching what normalizeMesh() does to
    // the canonical model -- so the placement code, faceScale, and every
    // material knob downstream keep the ranges they were tuned against.
    if (!fit_norm_set_) {
        const size_t n = verts.size() / 3;
        double cx = 0, cy = 0, cz = 0;
        for (size_t i = 0; i < n; i++) {
            cx += verts[i * 3]; cy += verts[i * 3 + 1]; cz += verts[i * 3 + 2];
        }
        fit_centre_[0] = float(cx / n);
        fit_centre_[1] = float(cy / n);
        fit_centre_[2] = float(cz / n);
        float m = 1e-9f;
        for (size_t i = 0; i < n; i++) {
            m = std::max({m, std::fabs(verts[i * 3]     - fit_centre_[0]),
                             std::fabs(verts[i * 3 + 1] - fit_centre_[1]),
                             std::fabs(verts[i * 3 + 2] - fit_centre_[2])});
        }
        fit_scale_ = 1.0f / m;
        fit_norm_set_ = true;
    }

    faceVerts_.resize(verts.size());
    for (size_t i = 0; i < verts.size() / 3; i++) {
        faceVerts_[i * 3]     = (verts[i * 3]     - fit_centre_[0]) * fit_scale_;
        faceVerts_[i * 3 + 1] = (verts[i * 3 + 1] - fit_centre_[1]) * fit_scale_;
        faceVerts_[i * 3 + 2] = (verts[i * 3 + 2] - fit_centre_[2]) * fit_scale_;
    }
    fitted_face_ = true;
    rebuildFace();
}

void RootScene::setFaceColors(const std::vector<float>& rgb) {
    faceColors_ = rgb;
    rebuildFace();
}

void RootScene::clearFittedFace() {
    if (!fitted_face_) return;
    faceVerts_ = canonVerts_;
    faceTris_  = canonTris_;
    fitted_face_ = false;
    fit_norm_set_ = false;
    rebuildFace();
}

// Scene bounds, for framing. Recomputed whenever the geometry is re-uploaded,
// which during a grow is every frame -- it is a min/max over the node array
// that was just built anyway.
void RootScene::updateBounds(const std::vector<float>& nodes) {
    if (nodes.size() < 3) return;
    float lo[3] = {nodes[0], nodes[1], nodes[2]};
    float hi[3] = {nodes[0], nodes[1], nodes[2]};
    for (size_t i = 0; i + 2 < nodes.size(); i += 3)
        for (int c = 0; c < 3; ++c) {
            lo[c] = std::min(lo[c], nodes[i + c]);
            hi[c] = std::max(hi[c], nodes[i + c]);
        }
    for (int c = 0; c < 3; ++c) idleCentre_[c] = 0.5f * (lo[c] + hi[c]);
    idleExtent_ = std::max({hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], 1.f});
}

// Centre and radius covering a set of revealed masks, in render space. Returns
// false when the set is empty, which is the whole of the first frames of a grow
// -- the caller falls back to the node bounds then, since there is nothing else
// to look at yet.
bool RootScene::maskBound(const std::vector<int>& idx, float centre[3], float& radius) const {
    const auto& ms = frameOnPlanned && !plannedMasks().empty() ? plannedMasks()
                                                              : revealedMasks();
    int n = 0;
    float c[3] = {0, 0, 0};
    for (int i : idx) {
        if (i < 0 || i >= (int)ms.size()) continue;
        for (int k = 0; k < 3; ++k) c[k] += ms[size_t(i)].pos[k];
        ++n;
    }
    if (!n) return false;
    for (int k = 0; k < 3; ++k) c[k] /= float(n);

    // Radius to the furthest mask, plus that mask's own size so the face is
    // inside the frame rather than on its edge.
    float r = 0.f;
    for (int i : idx) {
        if (i < 0 || i >= (int)ms.size()) continue;
        const auto& m = ms[size_t(i)];
        float d = std::sqrt((m.pos[0] - c[0]) * (m.pos[0] - c[0]) +
                            (m.pos[1] - c[1]) * (m.pos[1] - c[1]) +
                            (m.pos[2] - c[2]) * (m.pos[2] - c[2]));
        r = std::max(r, d + std::max(m.rWidth, m.rHeight));
    }
    for (int k = 0; k < 3; ++k) centre[k] = c[k];
    radius = std::max(r, 1.f);
    return true;
}

void RootScene::applyFraming(double dt) {
    // Held still for the whole pinned phase -- see clothPinned(). Deliberately
    // here rather than left to the caller's camera mode: the authored sequence
    // already holds beat 1 still, but auto-framing eases toward the layout
    // every frame, and easing during the press is what magnified the pond into
    // an unreadable close-up. A flat film's registration cannot survive a
    // moving camera by any amount of sizing, so the camera is what gives way.
    // camDesValid_ is cleared with it: there is no ease in flight to anticipate.
    if (clothPinned()) { camDesValid_ = false; return; }
    // The authored sequence assigns the camera outright, so there is no ease
    // in flight and no future pose to anticipate -- see camDesValid_.
    if (!autoFrame) { camDesValid_ = false; return; }
    // The layout, not the reveals: a bound that grows a step per revealed mask
    // makes the camera climb a staircase, and easing a staircase is a pump.
    const auto& ms = frameOnPlanned && !plannedMasks().empty() ? plannedMasks()
                                                              : revealedMasks();

    std::vector<int> shot;
    if (focusMask >= 0 && focusMask < (int)ms.size()) {
        shot.push_back(focusMask);
    } else if (focusGroup >= 0) {
        const int size = std::max(1, focusGroupSize);
        for (int i = focusGroup * size; i < (focusGroup + 1) * size && i < (int)ms.size(); ++i)
            shot.push_back(i);
    } else if (frameOnMasks) {
        for (int i = 0; i < (int)ms.size(); ++i) shot.push_back(i);
    }

    // Desired framing this frame; the camera is eased toward it below rather
    // than snapped, so a change of shot is a move and not a cut.
    float desTarget[3] = {target[0], target[1], target[2]};
    float desRadius = radius, desAz = azimuth, desEl = elevation;

    float c[3], r;
    if (!shot.empty() && maskBound(shot, c, r)) {
        desTarget[0] = c[0]; desTarget[1] = c[1]; desTarget[2] = c[2];
        // A single mask is framed tight to its own size; anything wider is
        // framed on the group's bound. Both then take the margin and the zoom.
        if (shot.size() == 1) {
            // Proportional, with no additive term: a constant does not scale,
            // so "tight on the face" stopped being tight the moment the mask
            // size or the cone changed. At 2.6x the mask's half-height the head
            // fills most of the frame at the default fov.
            const auto& m = ms[size_t(shot[0])];
            desRadius = std::max(m.rWidth, m.rHeight) * 2.6f * zoom;
        } else {
            desRadius = r * (1.0f + frameMargin) * 1.9f * zoom;
        }

        // Anchored: the target does not move to the middle of the shot, it
        // stays on one face. The radius then has to reach from that face to the
        // furthest thing in the shot rather than from the shot's own centre.
        // ...except when the shot *is* the anchor, where the tight framing
        // above is already the right answer and recomputing it from the bound
        // would only loosen it.
        const bool anchorIsWholeShot = (shot.size() == 1 && shot[0] == anchorMask);
        if (anchorMask >= 0 && anchorMask < (int)ms.size()) {
            const auto& a = ms[size_t(anchorMask)];
            desTarget[0] = a.pos[0]; desTarget[1] = a.pos[1]; desTarget[2] = a.pos[2];
            float far = std::max(a.rWidth, a.rHeight) * 2.6f;
            for (int i : shot) {
                const auto& m = ms[size_t(i)];
                const float dx = m.pos[0] - a.pos[0], dy = m.pos[1] - a.pos[1],
                            dz = m.pos[2] - a.pos[2];
                far = std::max(far, std::sqrt(dx * dx + dy * dy + dz * dz)
                                        + std::max(m.rWidth, m.rHeight));
            }
            if (!anchorIsWholeShot) desRadius = far * (1.0f + frameMargin) * 1.4f * zoom;
        }
        // Stand in front of what is being framed, rather than inheriting
        // whatever angle the whole-piece orbit was on -- which, on a cylinder or
        // a sphere, routinely means looking at the back of a head through the
        // far wall of the structure. For a group it is the mean of the masks'
        // normals: the direction the cluster collectively faces.
        //
        // eye = target + radius * (cosEl*sinAz, sinEl, cosEl*cosAz), so a
        // direction inverts straight into the two angles.
        const bool focused = (focusMask >= 0 || focusGroup >= 0 || anchorMask >= 0);
        if (faceOnFocus && focused) {
            float nx = 0, ny = 0, nz = 0;
            if (anchorMask >= 0 && anchorMask < (int)ms.size()) {
                // Anchored shots keep the anchor facing us the whole way out.
                nx = ms[size_t(anchorMask)].normal[0];
                ny = ms[size_t(anchorMask)].normal[1];
                nz = ms[size_t(anchorMask)].normal[2];
            } else {
                for (int i : shot) {
                    nx += ms[size_t(i)].normal[0];
                    ny += ms[size_t(i)].normal[1];
                    nz += ms[size_t(i)].normal[2];
                }
            }
            const float len = std::sqrt(nx * nx + ny * ny + nz * nz);
            if (len > 1e-5f) {
                desEl = std::asin(std::clamp(ny / len, -1.f, 1.f));
                desAz = std::atan2(nx, nz);
            }
        }
        // Its own angle, advanced independently: the whole-scene orbit is
        // centred on the piece, so borrowing it would sweep this mask out of
        // frame and eventually behind the camera.
        if (autoOrbit && shot.size() == 1 && !faceOnFocus) azimuth = focusAngle_;
    } else {
        desTarget[0] = idleCentre_[0];
        desTarget[1] = idleCentre_[1];
        desTarget[2] = idleCentre_[2];
        desRadius = (idleExtent_ * 0.75f + 12.0f) * zoom;
    }

    // Published before the ease consumes them: ensureClothSheet needs the pose
    // the camera is heading for, not the one it is passing through.
    camDesValid_ = true;
    camDesRadius_ = desRadius;
    camDesTarget_[0] = desTarget[0];
    camDesTarget_[1] = desTarget[1];
    camDesTarget_[2] = desTarget[2];
    camDesAz_ = desAz;
    camDesEl_ = desEl;

    // Ease. Exponential convergence rather than a spring: no overshoot, frame
    // rate independent, and it never has to be told when a move ends -- a shot
    // that stops changing is a camera that stops moving.
    const float k = (camEase > 1e-4f && camPrimed_ && dt > 0.0)
                      ? 1.f - std::exp(-float(dt) / camEase) : 1.f;
    for (int i = 0; i < 3; ++i) target[i] += (desTarget[i] - target[i]) * k;
    radius += (desRadius - radius) * k;
    // Angles the short way round, or a shot on the far side of the seam
    // unwinds the long way.
    auto easeAngle = [&](float& a, float want) {
        float d = want - a;
        while (d >  (float)M_PI) d -= 2.f * (float)M_PI;
        while (d < -(float)M_PI) d += 2.f * (float)M_PI;
        a += d * k;
    };
    easeAngle(azimuth, desAz);
    easeAngle(elevation, desEl);
    camPrimed_ = true;
    // The fog's near clearing and its height gradient both follow the framing,
    // so a zoom does not change how much fog sits in front of the subject or
    // where the gradient crosses it. Both are opt-out (startAuto /
    // heightRefAuto) for a fixed camera where a hand-set value is wanted.
    if (rr_) {
        if (rr_->fog.startAuto)      rr_->fog.startDist = radius * rr_->fog.startFrac;
        if (rr_->fog.heightRefAuto)  rr_->fog.heightRef = target[1];
    }
}

void RootScene::ensureSize(int w, int h) {
    if (rr_) rr_->resize(std::max(1, w), std::max(1, h));
}

void RootScene::reseed(uint32_t seed) {
    // Reseeding used to build the synthetic stand-in unconditionally. With a
    // grow running, that uploaded a whole different structure which advance()
    // then overwrote on the next frame -- a flash of something that was never
    // part of the scene. The stand-in exists for when CPlantBox is not there
    // at all, and that is the only time it should appear.
    if (simAvailable_) {
        simParams_.seed = seed;
        regrow();
    } else {
        buildSyntheticRoots(seed);
    }
}

// A recursive branching structure standing in for CPlantBox roots: capsule
// segments that taper and split, grown both up (a canopy) and down (roots).
void RootScene::buildSyntheticRoots(uint32_t seed) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> U(-1.f, 1.f);
    std::uniform_real_distribution<float> U01(0.f, 1.f);

    std::vector<float> nodes;   // 3/node
    std::vector<int>   segs;    // 2/seg
    std::vector<float> radii;   // 1/seg

    auto addNode = [&](float x, float y, float z) -> int {
        nodes.push_back(x); nodes.push_back(y); nodes.push_back(z);
        return (int)(nodes.size() / 3) - 1;
    };

    // Recursive branch. dir is a unit-ish vector; length/radius taper with depth.
    struct Frame { int node; float px, py, pz; float dx, dy, dz; float len; float rad; int depth; };
    std::vector<Frame> stack;

    auto seedBranch = [&](float ox, float oy, float oz, float dx, float dy, float dz,
                          float len, float rad, int depth) {
        int n = addNode(ox, oy, oz);
        stack.push_back({n, ox, oy, oz, dx, dy, dz, len, rad, depth});
    };

    // Canopy up, roots down, from a shared base.
    seedBranch(0, 0, 0,  0,  1, 0, 5.5f, 0.9f, 0);
    seedBranch(0, 0, 0,  0, -1, 0, 4.5f, 0.9f, 0);

    const int MAX_DEPTH = 8;
    while (!stack.empty()) {
        Frame fr = stack.back();
        stack.pop_back();
        if (fr.depth > MAX_DEPTH) continue;

        // Normalize direction.
        float dl = std::sqrt(fr.dx*fr.dx + fr.dy*fr.dy + fr.dz*fr.dz);
        if (dl < 1e-5f) dl = 1.f;
        float dx = fr.dx/dl, dy = fr.dy/dl, dz = fr.dz/dl;

        float nx = fr.px + dx * fr.len;
        float ny = fr.py + dy * fr.len;
        float nz = fr.pz + dz * fr.len;
        int child = addNode(nx, ny, nz);
        segs.push_back(fr.node); segs.push_back(child);
        radii.push_back(fr.rad);

        if (fr.depth == MAX_DEPTH) continue;

        // 1-3 children, direction perturbed, tapering length/radius.
        int nChildren = 1 + (U01(rng) < 0.7f ? 1 : 0) + (U01(rng) < 0.3f ? 1 : 0);
        for (int c = 0; c < nChildren; c++) {
            float jitter = 0.55f;
            float cx = dx + U(rng) * jitter;
            float cy = dy + U(rng) * jitter * 0.6f;   // keep vertical bias
            float cz = dz + U(rng) * jitter;
            float childLen = fr.len * (0.78f + 0.12f * U01(rng));
            float childRad = fr.rad * 0.72f;
            stack.push_back({child, nx, ny, nz, cx, cy, cz, childLen, childRad, fr.depth + 1});
        }
    }

    rr_->uploadSegments(nodes, segs, radii);
}

void RootScene::advance(double dt) {
    t_ += dt;
    // The orbit is the other thing that moves the camera, and it moves it
    // whether or not anything is framing -- so freezing applyFraming alone
    // still left the azimuth drifting a radian through the press, which
    // uncovers the film's edges just as surely. See clothPinned().
    if (autoOrbit && !clothPinned()) azimuth += orbitRate * (float)dt;
    rr_->fog.driftTime += (float)dt * rr_->fog.driftSpeed;
    rr_->pulse.time    += (float)dt;
    rr_->postTime      += (float)dt;

    // Key intensity from the room's own level. Separate from updateLighting()
    // below, which is about *aim* and has to run after the camera has been
    // framed; brightness depends on nothing the framing touches.
    if (micLightResponsive) {
        rr_->env.keyIntensity = micBaseKeyIntensity * (1.f + micIntensityGain * ambientLevel_);
    }

    focusAngle_ += orbitRate * (float)dt;

    // Ahead of the face upload below: clothPressOffset_ (the anchor mask's
    // current retraction while the cloth press is running) has to be current
    // before uploadFaceFromMasks reads it for the anchor's placement.
    advanceCloth(dt);

    // Live growth: advance a few steps, then re-upload geometry + revealed masks.
    // Held for as long as there is any film on screen at all -- not merely
    // while it is pinned. The roots must not exist at the same time as the
    // cloth, and the fall is the longest part of the cloth being on screen, so
    // gating on the pinned window alone had the plant growing up through a
    // sheet that was still visibly falling off it. Relying on the caller's beat
    // to have paused the sim is a weaker guarantee than saying so here, since
    // auto-framing runs no beats at all.
    if (useSim_ && sim_ && !sim_->done() && !simPaused && !clothActive_) {
        for (int i = 0; i < std::max(1, simStepsPerFrame) && !sim_->done(); ++i)
            sim_->step();
        std::vector<float> nodes, radii; std::vector<int> segs;
        sim_->geometry(nodes, segs, radii);
        rr_->uploadSegments(nodes, segs, radii);
        updateBounds(nodes);
        uploadFaceFromMasks();
    }
    // The masks have to reach the renderer even while the growth is held --
    // otherwise the opening beat is an empty frame, and the deal-out (which
    // moves masks without growing anything) never updates. Rebuilt every frame
    // rather than once: it is a handful of masks, and the alternative is a
    // one-shot flag that has to know about every reason a mask might move.
    if (useSim_ && sim_ && (simPaused || clothActive_)) uploadFaceFromMasks();
    applyFraming(dt);

    // After the framing, deliberately: CameraTarget focus and CameraRelative
    // aiming both read the camera, so this has to be the thing that runs last.
    updateLighting();

    // The sheet is solved and packed *after* the framing, not before it.
    //
    // applyFraming is the last thing that moves the camera, and render() draws
    // with what it leaves behind -- so a sheet sized and centred at the top of
    // advance() is a sheet built for the previous frame's camera. That is
    // invisible on a camera standing still and obvious on one easing into
    // position, which is exactly the live default (the authored sequence is
    // off unless the operator turns it on, so applyFraming's exponential ease
    // is what actually drives the press). Measured on a reproduction of that
    // configuration, building before the ease put the film 0.34 mean absolute
    // away from the pond it is supposed to be identical to; building after it
    // brings that back to 0.006.
    if (clothActive_) { ensureClothSheet(); packClothMesh(); }
}

// Resolve the key's aim. See root_scene.h's LightMode/LightFocus for what each
// mode is for.
void RootScene::updateLighting() {
    if (!rr_) return;

    // --- what the light is aimed at -----------------------------------------
    // Falls back to the idle bounds whenever the requested focus has nothing
    // behind it yet (no masks placed, no anchor revealed).
    float centre[3] = {idleCentre_[0], idleCentre_[1], idleCentre_[2]};
    switch (lightFocus) {
        case LightFocus::AnchorMask: {
            const auto& pm = plannedMasks();
            if (anchorMask >= 0 && anchorMask < (int)pm.size()) {
                const auto& m = pm[size_t(anchorMask)];
                for (int k = 0; k < 3; ++k) centre[k] = m.pos[k];
            }
            break;
        }
        case LightFocus::CameraTarget:
            for (int k = 0; k < 3; ++k) centre[k] = target[k];
            break;
        case LightFocus::SceneCentre:
        default:
            break;
    }
    for (int k = 0; k < 3; ++k) lightFocusPt_[k] = centre[k];

    // --- the direction -------------------------------------------------------
    float base[3] = {lightDir[0], lightDir[1], lightDir[2]};
    switch (lightMode) {
        case LightMode::Position: {
            float d[3] = {lightPos[0] - centre[0],
                          lightPos[1] - centre[1],
                          lightPos[2] - centre[2]};
            const float len = std::sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]);
            // A lamp placed exactly on the focus has no direction to give;
            // keep the authored one rather than dividing by zero.
            if (len > 1e-3f) for (int k = 0; k < 3; ++k) base[k] = d[k] / len;
            break;
        }
        case LightMode::CameraRelative: {
            // The camera's own orbit angles, offset. azimuth/elevation are the
            // eye's position about the target, which is already the direction
            // "from the subject towards the camera" -- i.e. exactly the
            // convention lightDir uses, so the offset is applied directly.
            const float az = azimuth + lightOffsetAz;
            const float el = std::clamp(elevation + lightOffsetEl, -1.5f, 1.5f);
            base[0] = std::cos(el) * std::sin(az);
            base[1] = std::sin(el);
            base[2] = std::cos(el) * std::cos(az);
            break;
        }
        case LightMode::Direction:
        default:
            break;
    }

    // --- the visitor's swing, applied on top of whichever base won ----------
    // Layered rather than exclusive: "the light comes from over there" and "it
    // leans towards whoever is in the room" are independent statements, and a
    // mode that silently cancelled the tracking would be a surprise.
    const float mag = std::max(1e-4f, std::sqrt(base[0]*base[0] + base[1]*base[1] +
                                                 base[2]*base[2]));
    if (trackLightAngle && trackedValid_) {
        const float az0 = std::atan2(base[0], base[2]);
        const float el0 = std::asin(std::clamp(base[1] / mag, -1.f, 1.f));
        const float ox = (trackedX_ - 0.5f) * 2.f;   // -1..1, left..right
        const float oy = (trackedY_ - 0.5f) * 2.f;   // -1..1, top..bottom
        const float az = az0 + ox * trackAngleRange;
        const float el = std::clamp(el0 - oy * trackAngleRange * 0.6f, -1.5f, 1.5f);
        renderLightDir_[0] = mag * std::cos(el) * std::sin(az);
        renderLightDir_[1] = mag * std::sin(el);
        renderLightDir_[2] = mag * std::cos(el) * std::cos(az);
    } else {
        for (int k = 0; k < 3; ++k) renderLightDir_[k] = base[k];
    }
}

void RootScene::setWideAngle(bool on) {
    if (!rr_) return;
    if (on) {
        focalMM = 12.0f;
        rr_->post.distortK1 = -0.16f;
        rr_->post.distortK2 = -0.03f;
        // Barrel pulls the corners in, so the frame has to be re-cropped or the
        // corners sample outside the rendered image and come back as clamped
        // smear. This is the zoom that just covers k1 = -0.16 at 16:9.
        rr_->post.distortZoom = 0.88f;
        // Short lenses vignette more, and their depth of field is deep.
        rr_->post.vignette = 0.34f;
        rr_->post.dofRange = 90.0f;
    } else {
        focalMM = 17.5f;
        rr_->post.distortK1 = 0.0f;
        rr_->post.distortK2 = 0.0f;
        rr_->post.distortZoom = 1.0f;
        rr_->post.vignette = 0.22f;
        rr_->post.dofRange = 55.0f;
    }
}

id<MTLTexture> RootScene::render(id<MTLCommandBuffer> cb) {
    if (!valid()) return nil;
    rr_->setClothTexture(pondTex_);
    float ld = std::sqrt(renderLightDir_[0] * renderLightDir_[0] +
                          renderLightDir_[1] * renderLightDir_[1] +
                          renderLightDir_[2] * renderLightDir_[2]);
    if (ld < 1e-5f) ld = 1.f;
    float L[3] = {renderLightDir_[0] / ld, renderLightDir_[1] / ld, renderLightDir_[2] / ld};
    return rr_->render(cb, azimuth, elevation, radius, target, effectiveFov(), L);
}
