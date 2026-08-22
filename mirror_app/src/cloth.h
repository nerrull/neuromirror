// Position-based-dynamics cloth on a rectangular grid with a hole cut out.
//
// The hole's rim vertices are *pinned* to the back rim of the mask (a ring in
// the z=0 plane); gravity points behind the mask (-z), so the sheet — the
// hydro-dip film / neural texture — sags backward and falls away, unveiling the
// face that sits in the hole.
//
// Header-only + SIMD (Apple <simd/simd.h>, hardware float3 vectors) so the
// solver builds and is testable with plain clang++, no Metal/GPU needed.
//
// Ported from neuromirror/cloth_cpp/src/cloth.h essentially unchanged -- it was
// already GPU-free and self-contained, which is exactly why it moved without a
// rewrite. `pinTo` is the one addition: cloth_cpp pinned the rim to a fixed
// ellipse because its face never moved, and here the face is fitted per person
// and turns with the head, so the rim has to be re-pinned to wherever the mesh
// actually is. See transition_scene.h.
#pragma once

#include <simd/simd.h>
#include <vector>
#include <cstdint>
#include <cmath>
#include <algorithm>

// simd_float3 is an ext-vector type: no aggregate brace-init in C++, so wrap the
// maker for concise construction.
static inline simd_float3 v3(float x, float y, float z) { return simd_make_float3(x, y, z); }

// The collider, as a depth map rather than a mesh.
//
// The transition's camera is fixed front-on and never moves, so "the mask" is
// fully described, for collision purposes, by the z of its front surface at
// each (x, y) -- there is no view from which the sheet could reach its back.
// That turns sheet<->face collision from a mesh query (the thing cloth_cpp
// listed as expensive and skipped) into one bilinear texture fetch per vertex,
// which is what makes the drape affordable at all.
//
// The grid is centred on the origin and spans +/-(halfX, halfY) in world units,
// with y up -- the same convention the sheet is built in. Texels the mask does
// not cover carry cover = 0 and are never sampled, so the silhouette is a real
// edge and not a ramp down to z = 0.
struct MaskField {
    int w = 0, h = 0;
    float halfX = 1.f, halfY = 1.f;
    std::vector<float>   z;        // front surface z per texel, world units
    std::vector<uint8_t> cover;    // 1 where the mask drew
    std::vector<float>   nx, ny;   // surface normal xy per texel (nz from them)

    bool valid() const { return w > 1 && h > 1 && z.size() == size_t(w) * size_t(h); }

    void resize(int W, int H, float hx, float hy) {
        w = W; h = H; halfX = hx; halfY = hy;
        z.assign(size_t(W) * size_t(H), 0.f);
        cover.assign(size_t(W) * size_t(H), 0);
        nx.assign(size_t(W) * size_t(H), 0.f);
        ny.assign(size_t(W) * size_t(H), 0.f);
    }
    void clear() {
        std::fill(z.begin(), z.end(), 0.f);
        std::fill(cover.begin(), cover.end(), (uint8_t)0);
        std::fill(nx.begin(), nx.end(), 0.f);
        std::fill(ny.begin(), ny.end(), 0.f);
    }

    // The surface normal, from the height field's own gradient. Built once per
    // frame after the field is final, because contact needs it at every solver
    // iteration and finite-differencing it there would be five fetches per
    // vertex per iteration instead of one.
    //
    // Central differences where both neighbours are covered, one-sided where
    // only one is, flat at the silhouette where neither is -- a rim texel has no
    // gradient to speak of and guessing one there sends the fabric sideways off
    // the edge.
    void buildNormals() {
        if (!valid()) return;
        const float dx = 2.f * halfX / float(w - 1);
        const float dy = 2.f * halfY / float(h - 1);
        for (int j = 0; j < h; ++j)
            for (int i = 0; i < w; ++i) {
                const size_t k = size_t(j) * size_t(w) + size_t(i);
                if (!cover[k]) { nx[k] = ny[k] = 0.f; continue; }
                auto grad = [&](int a, int b, float d) -> float {
                    const bool ca = a >= 0 && cover[size_t(a)];
                    const bool cb = b >= 0 && cover[size_t(b)];
                    if (ca && cb) return (z[size_t(b)] - z[size_t(a)]) / (2.f * d);
                    if (cb)       return (z[size_t(b)] - z[k]) / d;
                    if (ca)       return (z[k] - z[size_t(a)]) / d;
                    return 0.f;
                };
                const int im = i > 0 ? int(k) - 1 : -1, ip = i < w - 1 ? int(k) + 1 : -1;
                const int jm = j > 0 ? int(k) - w : -1, jp = j < h - 1 ? int(k) + w : -1;
                // y runs down the texels and up in the world, so the vertical
                // difference is negated on the way out.
                nx[k] = -grad(im, ip, dx);
                ny[k] =  grad(jm, jp, dy);
            }
    }

    // Grow the surface by `r` texels, taking the max.
    //
    // Collision is resolved at cloth *vertices*, but what the eye sees is the
    // triangles between them, and those are flat. Over a convex feature -- a
    // nose, a chin -- every vertex can sit exactly on the surface while the
    // chord joining them still cuts through it, and the mask pokes out of the
    // film in a blob the size of a cell. Measured on the real mask: vertex
    // penetration 0.0000 and triangle penetration 0.0266, against a skin of
    // 0.012.
    //
    // Pushing each vertex clear of the highest point its own cell could span
    // fixes it at the source, and that is a max-filter over the collider at the
    // cell's radius. Coverage spreads with it, so the rim gets the same
    // treatment as the middle -- otherwise the vertex just outside the
    // silhouette is pushed by nothing and the chord cuts across the edge, which
    // is the other half of where this shows up.
    //
    // Separable, two passes, and it only feeds contact -- the mask is still
    // drawn from its own geometry. The sheet stands off by about a cell, which
    // is what a cloth with thickness does anyway.
    void dilate(int r) {
        if (r <= 0 || !valid()) return;
        const size_t n = z.size();
        std::vector<float> tz(n, 0.f);
        std::vector<uint8_t> tc(n, 0);
        auto sweep = [&](const std::vector<float>& sz, const std::vector<uint8_t>& sc,
                         std::vector<float>& dz, std::vector<uint8_t>& dc, bool horiz) {
            for (int j = 0; j < h; ++j)
                for (int i = 0; i < w; ++i) {
                    float best = 0.f; bool any = false;
                    for (int d = -r; d <= r; ++d) {
                        const int si = horiz ? i + d : i;
                        const int sj = horiz ? j : j + d;
                        if (si < 0 || si >= w || sj < 0 || sj >= h) continue;
                        const size_t k = size_t(sj) * size_t(w) + size_t(si);
                        if (!sc[k]) continue;
                        if (!any || sz[k] > best) { best = sz[k]; any = true; }
                    }
                    const size_t o = size_t(j) * size_t(w) + size_t(i);
                    dz[o] = best; dc[o] = any ? 1 : 0;
                }
        };
        sweep(z, cover, tz, tc, true);
        sweep(tz, tc, z, cover, false);
    }

    // Surface z under (x, y), plus how much of the bilinear footprint the mask
    // actually covers. The coverage is returned rather than thresholded so the
    // caller can ease the push in across the silhouette: a hard 0/1 there makes
    // the rim vertices pop between free-fall and full contact every step, and
    // the sheet's edge chatters.
    bool sample(float x, float y, float& zOut, float& covOut,
                simd_float3* nOut = nullptr) const {
        if (!valid()) return false;
        const float fx = (x + halfX) / (2.f * halfX) * float(w - 1);
        const float fy = (halfY - y) / (2.f * halfY) * float(h - 1);
        if (!(fx >= 0.f && fy >= 0.f && fx <= float(w - 1) && fy <= float(h - 1))) return false;
        const int i0 = int(fx), j0 = int(fy);
        const int i1 = std::min(i0 + 1, w - 1), j1 = std::min(j0 + 1, h - 1);
        const float tx = fx - float(i0), ty = fy - float(j0);
        float sz = 0.f, sw = 0.f, sc = 0.f, snx = 0.f, sny = 0.f;
        auto acc = [&](int i, int j, float wt) {
            const size_t k = size_t(j) * size_t(w) + size_t(i);
            if (!cover[k]) return;
            sc += wt; sw += wt; sz += wt * z[k];
            snx += wt * nx[k]; sny += wt * ny[k];
        };
        acc(i0, j0, (1 - tx) * (1 - ty)); acc(i1, j0, tx * (1 - ty));
        acc(i0, j1, (1 - tx) * ty);       acc(i1, j1, tx * ty);
        if (sw <= 1e-6f) return false;
        zOut = sz / sw; covOut = sc;
        if (nOut) *nOut = simd_normalize(v3(snx / sw, sny / sw, 1.f));
        return true;
    }
};

struct Cloth {
    // `rest` is the length the constraint currently wants; `rest0` the length
    // the sheet was built with. They differ once the film takes a set -- see
    // `plastic` below.
    struct Edge { int a, b; float rest, rest0; };

    int nx = 0, ny = 0;                 // grid resolution
    std::vector<simd_float3> pos;       // current positions
    std::vector<simd_float3> prev;      // previous (Verlet)
    std::vector<simd_float3> nrm;       // per-vertex normals (for shading)
    std::vector<uint8_t> active;        // 0 = removed (inside the hole)
    std::vector<uint8_t> pinned;        // 1 = this vertex is a pin site
    std::vector<float> pinW;            // how held it is now: 1 fixed, 0 free
    std::vector<float> releaseAt;       // release parameter, 0 = lets go first
    std::vector<simd_float3> pin;       // pin target position
    std::vector<Edge> edges;            // distance constraints
    std::vector<uint32_t> tris;         // render index buffer (active quads)

    simd_float3 gravity = v3(0.f, -0.3f, -9.8f);   // -z: behind the mask
    float damping = 0.99f;              // velocity retention (1 = none)
    int iterations = 24;                // constraint solve passes / step

    // Extension is compliant, compression is not.
    //
    // A sheet that resists both equally cannot lie on anything: pressed onto a
    // solid it bridges the high points instead of conforming, because reaching
    // into a hollow costs it length it does not have. Letting it *lengthen*
    // cheaply is what turns bridging into wrapping -- and a film being
    // stretched over a face is the thing this whole gesture is depicting, so
    // the compliance is the effect rather than a concession to it.
    //
    // Compression stays stiff on purpose: that is what keeps the canvas taut
    // rather than gathering, and it costs no folds, because cloth folds by
    // buckling out of plane, not by shortening along an edge.
    float stretchGive = 0.80f;          // 0 = inextensible, 1 = free
    float stretchMax  = 1.90f;          // hard ceiling, multiples of rest0

    // How fast a held stretch becomes the sheet's new shape, per second. A
    // film pulled over a form and held there does not spring back when let go,
    // and without this the release dumps every bit of stored tension in one
    // frame -- the sheet snaps off the face and the whole picture jumps, which
    // is the single most violent thing this sim can do.
    float plastic = 2.0f;

    // Collision. `collider` is borrowed, not owned -- the caller rebuilds it
    // each frame from wherever the mask currently is.
    const MaskField* collider = nullptr;
    float skin = 0.012f;                // stand-off, so the sheet does not z-fight
    float friction = 0.35f;             // tangential grip on contact, 0 = ice

    int idx(int i, int j) const { return j * nx + i; }

    // Build an (nx*ny) sheet of world size (w x h) centered at origin in z=0.
    // An elliptical ring of radii (hrx, hry) is pinned to the mask's back rim.
    // ``carve`` cuts a hole inside the ring (rim pinned); otherwise the sheet is
    // solid and an interior ring is pinned (the center hides behind the face).
    void build(int nx_, int ny_, float w, float h, float hrx, float hry, bool carve = true) {
        nx = nx_; ny = ny_;
        const int N = nx * ny;
        pos.assign(N, v3(0,0,0)); prev.assign(N, v3(0,0,0)); nrm.assign(N, v3(0,0,0));
        active.assign(N, 1); pinned.assign(N, 0); pin.assign(N, v3(0,0,0));
        pinW.assign(N, 0.f); releaseAt.assign(N, 1.f);
        edges.clear(); tris.clear();

        for (int j = 0; j < ny; ++j)
            for (int i = 0; i < nx; ++i) {
                float x = (i / float(nx - 1) - 0.5f) * w;
                float y = (j / float(ny - 1) - 0.5f) * h;
                int k = idx(i, j);
                pos[k] = prev[k] = v3(x, y, 0.f);
                float e = (x * x) / (hrx * hrx) + (y * y) / (hry * hry);
                if (carve && e < 1.f) active[k] = 0;   // carve the hole
            }

        if (carve) {
            // rim = active vertex touching the hole -> pin to the hole boundary
            auto inHole = [&](int i, int j) {
                return i >= 0 && i < nx && j >= 0 && j < ny && !active[idx(i, j)];
            };
            for (int j = 0; j < ny; ++j)
                for (int i = 0; i < nx; ++i) {
                    int k = idx(i, j);
                    if (!active[k]) continue;
                    if (inHole(i-1,j) || inHole(i+1,j) || inHole(i,j-1) || inHole(i,j+1) ||
                        inHole(i-1,j-1) || inHole(i+1,j-1) || inHole(i-1,j+1) || inHole(i+1,j+1)) {
                        float x = pos[k].x, y = pos[k].y;
                        float s = std::sqrt((x*x)/(hrx*hrx) + (y*y)/(hry*hry));
                        if (s > 1e-6f) { x /= s; y /= s; }
                        pinned[k] = 1; pinW[k] = 1.f;
                        pin[k] = pos[k] = prev[k] = v3(x, y, 0.f);
                    }
                }
        } else {
            // solid sheet: pin the ~1-cell-thick ring nearest the ellipse boundary
            float band = 1.5f * std::max(w / (nx - 1) / hrx, h / (ny - 1) / hry);
            for (int j = 0; j < ny; ++j)
                for (int i = 0; i < nx; ++i) {
                    int k = idx(i, j);
                    float x = pos[k].x, y = pos[k].y;
                    float s = std::sqrt((x*x)/(hrx*hrx) + (y*y)/(hry*hry));
                    if (std::fabs(s - 1.f) < band) {
                        pinned[k] = 1; pinW[k] = 1.f;
                        pin[k] = pos[k] = prev[k] = v3(x, y, 0.f);
                    }
                }
        }

        buildTopology();
    }

    // A solid sheet held at its *border* instead of around an interior ring.
    //
    // This is the layout the press/release/wrap gesture needs and the ring
    // cannot express. Pinning an ellipse around the mask makes the mask the
    // thing the fabric hangs from, so the reveal can only ever be that ellipse
    // -- an oval hole, whatever shape the face inside it is. Holding the border
    // instead makes the sheet a stretched canvas: the mask is free to press
    // into it from behind, the fabric tents over the real silhouette, and what
    // is finally uncovered is the mask's own outline because nothing else ever
    // cut a shape.
    //
    // `borderCells` is how many rings of the grid are held. One is enough to
    // fix the sheet; two reads as a stiffer frame.
    //
    // Release order runs corners first: `releaseAt` is 0 at the corners and 1
    // at the middle of each edge, by elliptical radius (a corner sits at
    // sqrt(2) where an edge midpoint sits at 1). Corners are where a stretched
    // canvas carries the most tension, so letting them go first is both what
    // the gesture wants and what the sheet would actually do.
    void buildSheet(int nx_, int ny_, float w, float h, int borderCells = 1) {
        nx = nx_; ny = ny_;
        const int N = nx * ny;
        pos.assign(N, v3(0,0,0)); prev.assign(N, v3(0,0,0)); nrm.assign(N, v3(0,0,0));
        active.assign(N, 1); pinned.assign(N, 0); pin.assign(N, v3(0,0,0));
        pinW.assign(N, 0.f); releaseAt.assign(N, 1.f);
        edges.clear(); tris.clear();

        const int b = std::max(1, borderCells);
        const float hw = 0.5f * w, hh = 0.5f * h;
        const float kCorner = std::sqrt(2.f);
        for (int j = 0; j < ny; ++j)
            for (int i = 0; i < nx; ++i) {
                const float x = (i / float(nx - 1) - 0.5f) * w;
                const float y = (j / float(ny - 1) - 0.5f) * h;
                const int k = idx(i, j);
                pos[k] = prev[k] = pin[k] = v3(x, y, 0.f);
                if (i < b || i >= nx - b || j < b || j >= ny - b) {
                    pinned[k] = 1;
                    pinW[k] = 1.f;
                    const float r = std::sqrt((x * x) / (hw * hw) + (y * y) / (hh * hh));
                    releaseAt[k] = std::clamp((kCorner - r) / (kCorner - 1.f), 0.f, 1.f);
                }
            }
        buildTopology();
    }

    // Move the release front. `r` runs 0 (everything held) to 1 (everything
    // let go); `feather` is how wide the front is, so a pin eases out of the
    // hold instead of snapping free -- an instant unpin dumps the vertex's
    // stored tension into one step and the whole sheet cracks like a whip.
    void setRelease(float r, float feather = 0.18f) {
        const float f = std::max(1e-3f, feather);
        for (size_t k = 0; k < pinW.size(); ++k) {
            if (!pinned[k]) continue;
            pinW[k] = std::clamp(1.f + (releaseAt[k] - r) / f, 0.f, 1.f);
        }
    }

    // Every pin back to fully held, at its build position.
    void reholdAll() {
        for (size_t k = 0; k < pinW.size(); ++k)
            if (pinned[k]) { pinW[k] = 1.f; pos[k] = prev[k] = pin[k]; }
    }

    // Push any vertex that has ended up behind the mask back out in front of
    // it. Run inside the constraint loop, so the distance solve and the contact
    // negotiate rather than the last one written winning.
    //
    // `withFriction` is off for those inner calls and on for one final call per
    // step. Friction is a *per step* loss: bleeding the same fraction of the
    // tangential velocity once per solver iteration compounds it two dozen
    // times over (0.35 becomes 1 - 0.65^24, which is total), and the sheet
    // welds itself to the mask the instant it touches -- it gathers on the brow
    // and never comes off.
    void resolveCollisions(bool withFriction) {
        if (!collider || !collider->valid()) return;
        for (size_t k = 0; k < pos.size(); ++k) {
            if (!active[k] || pinW[k] >= 1.f) continue;
            float zs = 0.f, cov = 0.f;
            simd_float3 n = v3(0.f, 0.f, 1.f);
            if (!collider->sample(pos[k].x, pos[k].y, zs, cov, &n)) continue;
            const float target = zs + skin;
            if (pos[k].z >= target) continue;
            // Out along the surface normal, not along the view axis.
            //
            // This is what lets the sheet ever come *off*. Pushing along +z
            // makes contact a constraint on z alone, so a pull from behind --
            // which is the only pull there is once gravity points straight back
            // -- is cancelled outright and the fabric is pinned wherever it
            // landed. The mask cannot shake it off either: the placement
            // compensates perspective, so the mask's silhouette does not change
            // as it comes through and draped fabric is simply carried along.
            //
            // Against the real normal the same backward pull keeps its
            // tangential component, so the fabric slides down the brow and off
            // the cheeks the way a cloth slides off a form pushed through it.
            // The normal comes from the height field's own gradient and is flat
            // at the silhouette, which is what stops a rim vertex from being
            // flicked sideways off the edge.
            pos[k] += n * ((target - pos[k].z) * n.z * cov);
            // Inelastic contact. Moving the position and leaving `prev` behind
            // turns the push into velocity, and this runs once per solver
            // iteration -- two dozen times a step -- so that velocity compounds
            // until the sheet launches itself at the camera. Carrying `prev`
            // along means the sheet lands on the mask instead of bouncing off
            // it, which is also what a wet film does. Only the normal component
            // is killed: the tangential one is the sliding, and damping it here
            // as well is what `friction` is for.
            prev[k] += n * (simd_dot(pos[k] - prev[k], n) * cov);
            if (withFriction && friction > 0.f) {
                // Grip: bleed the tangential velocity where the sheet touches,
                // which is what makes it *drape* over the brow and the nose
                // rather than sliding off them like a sheet off glass.
                const float g = friction * cov;
                const simd_float3 d = pos[k] - prev[k];
                const simd_float3 tang = d - n * simd_dot(d, n);
                prev[k] += tang * g;
            }
        }
    }

    // Shared by build() and buildSheet(): the constraint graph and the index
    // buffer over whatever `active` currently says.
    void buildTopology() {
        // distance constraints: structural (4-nbr), shear (diagonals), bend (2-away)
        auto add = [&](int ai, int aj, int bi, int bj) {
            if (ai < 0 || ai >= nx || aj < 0 || aj >= ny ||
                bi < 0 || bi >= nx || bj < 0 || bj >= ny) return;
            int a = idx(ai, aj), b = idx(bi, bj);
            if (!active[a] || !active[b]) return;
            const float r = simd_distance(pos[a], pos[b]);
            edges.push_back({a, b, r, r});
        };
        for (int j = 0; j < ny; ++j)
            for (int i = 0; i < nx; ++i) {
                if (!active[idx(i, j)]) continue;
                add(i, j, i+1, j);   add(i, j, i, j+1);         // structural
                add(i, j, i+1, j+1); add(i+1, j, i, j+1);       // shear
                add(i, j, i+2, j);   add(i, j, i, j+2);         // bend
            }

        // triangles for quads whose 4 corners are all active
        for (int j = 0; j < ny - 1; ++j)
            for (int i = 0; i < nx - 1; ++i) {
                int a = idx(i, j), b = idx(i+1, j), c = idx(i, j+1), d = idx(i+1, j+1);
                if (!(active[a] && active[b] && active[c] && active[d])) continue;
                tris.insert(tris.end(), {(uint32_t)a,(uint32_t)c,(uint32_t)b,
                                         (uint32_t)b,(uint32_t)c,(uint32_t)d});
            }
    }

    // Move the pinned ring onto a new set of target positions, supplied in the
    // same order the pins were created. cloth_cpp had no need for this: its face
    // was a baked asset at a fixed place, so the rim ellipse was decided at build
    // time and never moved. A fitted face is a different shape per person and
    // turns with the head, so the rim has to follow it or the sheet detaches
    // from the mask it is supposed to be hanging off.
    //
    // Positions only -- the rest lengths stay as built, so re-pinning stretches
    // the sheet toward the new rim rather than rebuilding the constraint graph.
    void pinTo(const std::vector<simd_float3>& targets) {
        size_t t = 0;
        for (size_t k = 0; k < pos.size() && t < targets.size(); ++k) {
            if (!pinned[k]) continue;
            pin[k] = pos[k] = prev[k] = targets[t++];
            pinW[k] = 1.f;
        }
    }

    // The pinned vertices in build order, so a caller can see how many targets
    // pinTo() wants and where they currently sit.
    std::vector<int> pinIndices() const {
        std::vector<int> out;
        for (size_t k = 0; k < pos.size(); ++k) if (pinned[k]) out.push_back(int(k));
        return out;
    }

    // Let a held stretch become the sheet's shape. Called once per step, before
    // the solve, so the constraints spend the step chasing the relaxed length
    // rather than the built one.
    void relax(float dt) {
        if (plastic <= 0.f) return;
        const float a = std::min(1.f, plastic * dt);
        for (Edge& e : edges) {
            const float len = simd_distance(pos[e.a], pos[e.b]);
            if (len <= e.rest) continue;          // only a stretch sets, never a fold
            e.rest += (len - e.rest) * a;
            e.rest = std::min(e.rest, e.rest0 * stretchMax);
        }
    }

    // Back to the built lengths, for a replay.
    void resetRest() { for (Edge& e : edges) e.rest = e.rest0; }

    // One Verlet step + constraint projection. dt in seconds.
    void step(float dt) {
        const float dt2 = dt * dt;
        relax(dt);
        for (size_t k = 0; k < pos.size(); ++k) {
            if (!active[k] || pinW[k] >= 1.f) continue;
            simd_float3 tmp = pos[k];
            pos[k] += (pos[k] - prev[k]) * damping + gravity * dt2;
            prev[k] = tmp;
        }
        // Gauss-Seidel projection. Alternating the sweep direction each iteration
        // cancels the ordering bias that otherwise makes the sheet far stiffer
        // along one grid axis -- which on a regular grid seeds axis-aligned
        // buckling (the sheet gathers on one axis and stays taut on the other).
        const int M = (int)edges.size();
        for (int it = 0; it < iterations; ++it) {
            bool fwd = (it & 1) == 0;
            for (int n = 0; n < M; ++n) {
                const Edge& e = edges[fwd ? n : M - 1 - n];
                simd_float3 d = pos[e.b] - pos[e.a];
                float len = simd_length(d);
                if (len < 1e-8f) continue;
                // The length the edge is actually asked to reach. Shorter than
                // rest: pull it straight back. Longer: give most of the way,
                // up to a ceiling that always holds.
                float want = e.rest;
                if (len > e.rest) {
                    want = e.rest + (len - e.rest) * stretchGive;
                    const float ceiling = e.rest0 * stretchMax;
                    if (want > ceiling) want = ceiling;
                }
                // Inverse mass from the pin weight rather than a pinned flag,
                // so a pin easing out of its hold hands its share of the
                // correction over gradually instead of at one frame's edge.
                float mA = 1.f - pinW[e.a];
                float mB = 1.f - pinW[e.b];
                float s = mA + mB;
                if (s <= 0.f) continue;
                simd_float3 corr = d * ((len - want) / len);
                pos[e.a] += corr * (mA / s);
                pos[e.b] -= corr * (mB / s);
            }
            resolveCollisions(/*withFriction=*/false);
        }
        resolveCollisions(/*withFriction=*/true);
        // Hold the pins, in proportion to how held they still are. At weight 1
        // this is the old hard clamp exactly.
        for (size_t k = 0; k < pos.size(); ++k) {
            if (!pinned[k] || pinW[k] <= 0.f) continue;
            const float a = pinW[k];
            pos[k]  += (pin[k] - pos[k])  * a;
            prev[k] += (pin[k] - prev[k]) * a;
        }
    }

    // Per-vertex normals from the triangle mesh (call before rendering).
    void computeNormals() {
        for (auto& n : nrm) n = v3(0.f, 0.f, 0.f);
        for (size_t t = 0; t + 2 < tris.size(); t += 3) {
            uint32_t a = tris[t], b = tris[t+1], c = tris[t+2];
            simd_float3 fn = simd_cross(pos[b] - pos[a], pos[c] - pos[a]);
            nrm[a] += fn; nrm[b] += fn; nrm[c] += fn;
        }
        for (size_t k = 0; k < nrm.size(); ++k) {
            float l = simd_length(nrm[k]);
            nrm[k] = l > 1e-8f ? nrm[k] / l : v3(0.f, 0.f, 1.f);
        }
    }

    // Diagnostics for the headless test.
    int activeCount() const { int c = 0; for (auto a : active) c += a; return c; }
    int pinnedCount() const { int c = 0; for (auto p : pinned) c += p; return c; }
    bool finite() const {
        for (const auto& p : pos)
            if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z)) return false;
        return true;
    }
    float minZ() const {
        float m = 0;
        for (size_t k = 0; k < pos.size(); ++k) if (active[k]) m = std::min(m, pos[k].z);
        return m;
    }
};
