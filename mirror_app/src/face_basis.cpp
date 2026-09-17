#include "face_basis.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <array>
#include <cstdint>
#include <unordered_map>

namespace mirror {

namespace {

// Every read is checked. The header declares the array sizes, so a truncated or
// corrupt file would otherwise have us allocate and read past what is there.
struct Reader {
    std::FILE* f = nullptr;
    bool ok = true;

    template <typename T>
    bool read(T* dst, size_t count) {
        if (!ok) return false;
        ok = std::fread(dst, sizeof(T), count, f) == count;
        return ok;
    }
    bool readVec(std::vector<float>& v, size_t count) {
        v.resize(count);
        return count == 0 || read(v.data(), count);
    }
};

void accumulate(const std::vector<float>& modes, const std::vector<float>& coeff,
                size_t n_modes, size_t stride, std::vector<float>& out) {
    const size_t use = coeff.size() < n_modes ? coeff.size() : n_modes;
    for (size_t m = 0; m < use; ++m) {
        const float c = coeff[m];
        if (c == 0.0f) continue;      // expression vectors are mostly zero
        const float* src = &modes[m * stride];
        for (size_t i = 0; i < stride; ++i) out[i] += c * src[i];
    }
}

}  // namespace

bool FaceBasis::load(const std::string& path, std::string& err) {
    err.clear();
    Reader r;
    r.f = std::fopen(path.c_str(), "rb");
    if (!r.f) {
        err = "face_basis: cannot open " + path +
              " (generate it with tools/export_face_basis.py)";
        return false;
    }

    char magic[4] = {0};
    int hdr[8] = {0};
    r.read(magic, 4);
    r.read(hdr, 8);
    if (!r.ok || std::memcmp(magic, "FBAS", 4) != 0) {
        std::fclose(r.f);
        err = "face_basis: " + path + " is not a face-basis file";
        return false;
    }
    if (hdr[0] != 1) {
        std::fclose(r.f);
        err = "face_basis: unsupported version " + std::to_string(hdr[0]);
        return false;
    }
    n_verts_ = hdr[1];
    n_tris_  = hdr[2];
    n_id_    = hdr[3];
    n_ex_    = hdr[4];
    const int n_lm = hdr[5];
    nvf_ = hdr[6] != 0;
    if (n_verts_ <= 0 || n_tris_ < 0 || n_id_ < 0 || n_ex_ < 0 || n_lm != kLandmarks) {
        std::fclose(r.f);
        err = "face_basis: implausible header in " + path;
        n_verts_ = 0;
        return false;
    }

    const size_t nv3 = size_t(n_verts_) * 3, lm3 = size_t(kLandmarks) * 3;
    r.readVec(neutral_, nv3);
    tris_.resize(size_t(n_tris_) * 3);
    r.read(tris_.data(), tris_.size());
    r.readVec(id_, size_t(n_id_) * nv3);
    r.readVec(ex_, size_t(n_ex_) * nv3);
    r.readVec(lm_neutral_, lm3);
    r.readVec(lm_id_, size_t(n_id_) * lm3);
    r.readVec(lm_ex_, size_t(n_ex_) * lm3);

    ex_names_.clear();
    for (int i = 0; i < n_ex_ && r.ok; ++i) {
        int len = 0;
        if (!r.read(&len, 1)) break;
        if (len < 0 || len > 256) { r.ok = false; break; }
        std::string s(size_t(len), '\0');
        if (len && !r.read(&s[0], size_t(len))) break;
        ex_names_.push_back(std::move(s));
    }

    const bool ok = r.ok && int(ex_names_.size()) == n_ex_;
    std::fclose(r.f);
    if (!ok) {
        err = "face_basis: " + path + " is truncated";
        n_verts_ = 0;
        return false;
    }

    // Triangle indices come from the exporter, but a stray index would index
    // out of the vertex buffer on the GPU, which is not a debuggable failure.
    for (int i : tris_) {
        if (i < 0 || i >= n_verts_) {
            err = "face_basis: triangle index out of range in " + path;
            n_verts_ = 0;
            return false;
        }
    }
    punchHoles();
    return true;
}

// The exporter's mesh is a closed skin: the eyes and the mouth are filled
// in. Drawn on a root mask, that reads as a solid casting; a face with the
// eyes and the mouth open to the dark behind it is what the piece wants (and
// the root leaves mask 0 through the mouth, so the mouth had better be a
// hole). A triangle is cut when its centroid, or any of its vertices, falls
// inside dlib's eye loops (36-41, 42-47) or inner-lip loop (60-67) -- the
// centroid because the eye openings are spanned by a few large triangles
// whose vertices all sit on the lid ring, the vertices so the mouth's edge
// runs along the mesh's own loop rather than through half-kept triangles.
// Then the cut grows outward from the rim through every neighbour that faces
// away from the viewer (normal z < kRollFacing, 0): the lips and the lids
// are modelled as a roll, several dense rings curling inward from the skin
// to the loop, and a hole cut at the loop alone left the inside of that
// roll standing as a band of dark, backward-facing slivers around every
// hole. The growth stops at the first ring that faces forward -- the lip's
// own edge stays (a threshold of 0.2 took the whole roll, a third of the
// mesh, and trimmed the lips visibly). Finally any triangle
// left with two of its three edges on the rim is a flap, and goes too.
// Tested frontally (xy, z is toward the viewer) with the jaw open -- the
// neutral mouth is closed and its inner-lip loop has no area.
void FaceBasis::punchHoles() {
    if (tris_.empty() || lm_neutral_.size() != size_t(kLandmarks) * 3) return;
    std::vector<float> expr(size_t(std::max(0, n_ex_)), 0.f);
    const int jaw = expressionIndex("jawOpen");
    if (jaw >= 0) expr[size_t(jaw)] = 1.f;
    std::vector<float> verts, lm;
    reconstruct({}, expr, verts);
    reconstructLandmarks({}, expr, lm);
    if (verts.size() != size_t(n_verts_) * 3 || lm.size() != size_t(kLandmarks) * 3) return;

    static const int kLoops[3][2] = { {36, 41}, {42, 47}, {60, 67} };
    auto inside = [&](float x, float y) {
        for (const auto& L : kLoops) {
            bool in = false;
            for (int i = L[0], j = L[1]; i <= L[1]; j = i++) {
                const float xi = lm[size_t(i) * 3], yi = lm[size_t(i) * 3 + 1];
                const float xj = lm[size_t(j) * 3], yj = lm[size_t(j) * 3 + 1];
                if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) in = !in;
            }
            if (in) return true;
        }
        return false;
    };
    const size_t nt = tris_.size() / 3;
    std::vector<char> cut(nt, 0);
    for (size_t t = 0; t < nt; ++t) {
        float cx = 0.f, cy = 0.f;
        bool hole = false;
        for (int k = 0; k < 3; ++k) {
            const float x = verts[size_t(tris_[t * 3 + k]) * 3];
            const float y = verts[size_t(tris_[t * 3 + k]) * 3 + 1];
            cx += x / 3.f; cy += y / 3.f;
            hole = hole || inside(x, y);
        }
        cut[t] = (hole || inside(cx, cy)) ? 1 : 0;
    }

    // Edge -> the (at most two) triangles sharing it, for the flap pass.
    std::unordered_map<uint64_t, std::array<int, 2>> edges;
    auto key = [](int a, int b) {
        if (a > b) std::swap(a, b);
        return (uint64_t(uint32_t(a)) << 32) | uint32_t(b);
    };
    for (size_t t = 0; t < nt; ++t)
        for (int k = 0; k < 3; ++k) {
            auto& e = edges[key(tris_[t * 3 + k], tris_[t * 3 + (k + 1) % 3])];
            if (!e[0] && !e[1]) e = {-1, -1};
            (e[0] < 0 ? e[0] : e[1]) = int(t);
        }
    constexpr float kRollFacing = 0.f;
    auto facingZ = [&](size_t t) {
        const float* a = &verts[size_t(tris_[t * 3]) * 3];
        const float* b = &verts[size_t(tris_[t * 3 + 1]) * 3];
        const float* c = &verts[size_t(tris_[t * 3 + 2]) * 3];
        const float ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2];
        const float vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
        const float nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
        const float len = std::sqrt(nx * nx + ny * ny + nz * nz);
        return len > 1e-9f ? nz / len : 0.f;
    };
    for (bool again = true; again;) {
        again = false;
        for (size_t t = 0; t < nt; ++t) {
            if (cut[t]) continue;
            int rim = 0;
            for (int k = 0; k < 3; ++k) {
                const auto& e = edges[key(tris_[t * 3 + k], tris_[t * 3 + (k + 1) % 3])];
                const int other = e[0] == int(t) ? e[1] : e[0];
                if (other >= 0 && cut[size_t(other)]) ++rim;
            }
            if (rim >= 2 || (rim >= 1 && facingZ(t) < kRollFacing)) { cut[t] = 1; again = true; }
        }
    }

    std::vector<int> kept;
    kept.reserve(tris_.size());
    for (size_t t = 0; t < nt; ++t)
        if (!cut[t]) kept.insert(kept.end(), {tris_[t * 3], tris_[t * 3 + 1], tris_[t * 3 + 2]});
    n_tris_ = int(kept.size() / 3);
    tris_ = std::move(kept);
}

void FaceBasis::reconstruct(const std::vector<float>& alpha,
                            const std::vector<float>& expr,
                            std::vector<float>& out) const {
    const size_t nv3 = size_t(n_verts_) * 3;
    out.assign(neutral_.begin(), neutral_.end());
    if (out.size() != nv3) return;
    accumulate(id_, alpha, size_t(n_id_), nv3, out);
    accumulate(ex_, expr, size_t(n_ex_), nv3, out);
}

void FaceBasis::reconstructIdentity(const std::vector<float>& alpha,
                                    std::vector<float>& out) const {
    const size_t nv3 = size_t(n_verts_) * 3;
    out.assign(neutral_.begin(), neutral_.end());
    if (out.size() != nv3) return;
    accumulate(id_, alpha, size_t(n_id_), nv3, out);
}

void FaceBasis::addExpression(const std::vector<float>& base, const std::vector<float>& expr,
                              std::vector<float>& out) const {
    const size_t nv3 = size_t(n_verts_) * 3;
    out.assign(base.begin(), base.end());
    if (out.size() != nv3) return;
    accumulate(ex_, expr, size_t(n_ex_), nv3, out);
}

int FaceBasis::expressionIndex(const std::string& name) const {
    for (size_t i = 0; i < ex_names_.size(); ++i)
        if (ex_names_[i] == name) return (int)i;
    return -1;
}

void FaceBasis::reconstructLandmarks(const std::vector<float>& alpha,
                                     const std::vector<float>& expr,
                                     std::vector<float>& out) const {
    const size_t lm3 = size_t(kLandmarks) * 3;
    out.assign(lm_neutral_.begin(), lm_neutral_.end());
    if (out.size() != lm3) return;
    accumulate(lm_id_, alpha, size_t(n_id_), lm3, out);
    accumulate(lm_ex_, expr, size_t(n_ex_), lm3, out);
}

int jawOpenModeIndex(const FaceBasis& basis, bool* usedFallback) {
    if (usedFallback) *usedFallback = false;
    const int idx = basis.expressionIndex("jawOpen");
    if (idx >= 0) return idx;
    if (usedFallback) *usedFallback = true;

    const std::vector<float>& lmEx = basis.lmExpression();
    const int n = basis.expressionModes();
    const size_t lm3 = size_t(FaceBasis::kLandmarks) * 3;
    int best = -1;
    float bestGap = 0.f;
    for (int k = 0; k < n; ++k) {
        if (lmEx.size() < size_t(k + 1) * lm3) break;
        const float* m = &lmEx[size_t(k) * lm3];
        float upperY = 0.f, lowerY = 0.f;
        for (int i : {61, 62, 63}) upperY += m[size_t(i) * 3 + 1];
        for (int i : {65, 66, 67}) lowerY += m[size_t(i) * 3 + 1];
        upperY /= 3.f;
        lowerY /= 3.f;
        const float gap = std::fabs(upperY - lowerY);
        if (gap > bestGap) {
            bestGap = gap;
            best = k;
        }
    }
    return best;
}

MouthOpenModes mouthOpenModes(const FaceBasis& basis, bool* usedFallback) {
    MouthOpenModes m;
    m.jaw = jawOpenModeIndex(basis, usedFallback);
    auto add = [&](std::vector<int>& to, const char* name) {
        const int i = basis.expressionIndex(name);
        if (i >= 0) to.push_back(i);
    };
    add(m.width, "mouthStretch_L");  add(m.width, "mouthStretch_R");
    add(m.lips, "mouthUpperUp_L");   add(m.lips, "mouthUpperUp_R");
    add(m.lips, "mouthLowerDown_L"); add(m.lips, "mouthLowerDown_R");
    for (const char* n : {"mouthClose", "mouthPucker", "mouthFunnel", "mouthPress_L", "mouthPress_R",
                          "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper"})
        add(m.closers, n);
    return m;
}

void applyMouthOpen(const MouthOpenModes& modes, const MouthOpen& open, std::vector<float>& expr) {
    const float ramp = std::clamp(open.ramp, 0.f, 1.f);
    if (ramp <= 0.f) return;
    auto raise = [&](int i, float to) {
        if (i < 0 || to <= 0.f) return;
        if ((int)expr.size() <= i) expr.resize(size_t(i) + 1, 0.f);
        expr[size_t(i)] = std::max(expr[size_t(i)], to);
    };
    raise(modes.jaw, ramp * open.jaw);
    for (int i : modes.width) raise(i, ramp * open.width);
    for (int i : modes.lips)  raise(i, ramp * open.lips);
    for (int i : modes.closers)
        if (i < (int)expr.size()) expr[size_t(i)] *= 1.f - ramp;
}

}  // namespace mirror
