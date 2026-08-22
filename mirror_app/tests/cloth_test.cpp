// Headless validation of the cloth solver (no Metal/GPU). Steps the sim and
// checks: hole carved, rim pinned, stays finite, rim stays put, and the free
// sheet actually falls behind the mask (-z). Build: see CMake target cloth_test.
#include "cloth.h"
#include <cstdio>

int main() {
    Cloth c;
    c.build(/*nx*/64, /*ny*/64, /*w*/2.0f, /*h*/2.0f, /*hrx*/0.35f, /*hry*/0.45f);

    int nActive = c.activeCount(), nPin = c.pinnedCount();
    printf("built: %dx%d  active=%d  pinned=%d  edges=%zu  tris=%zu\n",
           c.nx, c.ny, nActive, nPin, c.edges.size(), c.tris.size() / 3);

    bool ok = true;
    if (nActive <= 0 || nActive >= c.nx * c.ny) { printf("FAIL: hole not carved\n"); ok = false; }
    if (nPin <= 0) { printf("FAIL: no rim pinned\n"); ok = false; }

    // snapshot pinned targets, then simulate
    auto pin0 = c.pin;
    for (int f = 0; f < 300; ++f) c.step(1.0f / 120.0f);

    if (!c.finite()) { printf("FAIL: non-finite after sim\n"); ok = false; }

    float rimDrift = 0.f;
    for (size_t k = 0; k < c.pos.size(); ++k)
        if (c.pinned[k]) rimDrift = std::max(rimDrift, simd_distance(c.pos[k], pin0[k]));
    if (rimDrift > 1e-4f) { printf("FAIL: rim drifted %.5f\n", rimDrift); ok = false; }

    float fell = c.minZ();
    printf("after 300 steps: finite=%d  rimDrift=%.2e  minZ=%.3f (should be < 0)\n",
           c.finite(), rimDrift, fell);
    if (fell > -0.05f) { printf("FAIL: sheet did not fall behind the mask\n"); ok = false; }

    // --- the border-pinned sheet: press, release, wrap ---------------------
    //
    // The gesture the transition actually plays. Three things are checked, in
    // the order they have to happen: the mask pressing into a fully held sheet
    // tents it *forward* (nothing else can push a sheet toward the camera);
    // the release runs corners first; and once released the sheet ends up
    // behind the mask, having gone over it rather than through it.
    Cloth s;
    s.buildSheet(/*nx*/48, /*ny*/48, /*w*/2.0f, /*h*/2.0f, /*borderCells*/1);
    if (s.activeCount() != 48 * 48) { printf("FAIL: sheet is not solid\n"); ok = false; }
    if (s.pinnedCount() != 48 * 48 - 46 * 46) { printf("FAIL: border not pinned\n"); ok = false; }

    // A dome standing 0.25 proud of the sheet plane, as the collider.
    MaskField mfTrue;
    mfTrue.resize(64, 64, 1.0f, 1.0f);
    for (int j = 0; j < mfTrue.h; ++j)
        for (int i = 0; i < mfTrue.w; ++i) {
            const float x = (i / float(mfTrue.w - 1) - 0.5f) * 2.f;
            const float y = (0.5f - j / float(mfTrue.h - 1)) * 2.f;
            const float r2 = x * x / (0.35f * 0.35f) + y * y / (0.45f * 0.45f);
            if (r2 > 1.f) continue;
            float z = 0.25f * std::sqrt(1.f - r2);
            // A nose. The dome on its own is far too smooth to reproduce what
            // this is testing: a feature only cuts the chords if it is sharp
            // relative to a cloth cell, and the cell here is 0.043. The real
            // mask has exactly this -- a nose tip and a chin, made sharper still
            // by the transition's depth exaggeration -- and a test built on the
            // dome alone reports zero error and proves nothing.
            const float nr = std::sqrt(x * x + (y + 0.05f) * (y + 0.05f));
            if (nr < 0.09f) z = std::max(z, 0.42f * (1.f - nr / 0.09f));
            mfTrue.cover[size_t(j) * mfTrue.w + i] = 1;
            mfTrue.z[size_t(j) * mfTrue.w + i] = z;
        }

    // What the eye actually sees is the *triangles* between the vertices
    // collision is resolved at, and those are flat. Over a convex feature every
    // vertex can sit exactly on the surface while the chord joining them still
    // cuts through it, and the collider pokes out of the sheet in a blob the
    // size of a cell -- which is precisely what MaskField::dilate exists to
    // stop. So the press is run twice, and the check is on the chords, not the
    // vertices: measuring vertices alone reports this bug as zero error.
    auto pressAndMeasure = [&](bool dilated, float& vertexPen, float& triPen) {
        Cloth c;
        c.buildSheet(48, 48, 2.0f, 2.0f, 1);
        MaskField mf = mfTrue;
        if (dilated) {
            const float texel = 2.0f / float(mf.w - 1);
            const float cell  = 2.0f / float(c.nx - 1);
            mf.dilate(int(std::ceil(cell / texel)));
        }
        mf.buildNormals();   // contact resolves along these, not along z
        c.collider = &mf;
        c.gravity = v3(0.f, 0.f, 0.f);       // press only: no fall yet
        for (int f = 0; f < 120; ++f) c.step(1.0f / 120.0f);

        vertexPen = triPen = 0.f;
        for (size_t k = 0; k < c.pos.size(); ++k) {
            float zs = 0.f, cv = 0.f;
            if (!mfTrue.sample(c.pos[k].x, c.pos[k].y, zs, cv) || cv < 0.99f) continue;
            vertexPen = std::max(vertexPen, zs - c.pos[k].z);
        }
        for (size_t t = 0; t + 2 < c.tris.size(); t += 3) {
            const simd_float3 m = (c.pos[c.tris[t]] + c.pos[c.tris[t+1]] +
                                   c.pos[c.tris[t+2]]) / 3.f;
            float zs = 0.f, cv = 0.f;
            if (!mfTrue.sample(m.x, m.y, zs, cv) || cv < 0.99f) continue;
            triPen = std::max(triPen, zs - m.z);
        }
        float mx = 0.f;
        for (size_t k = 0; k < c.pos.size(); ++k) mx = std::max(mx, c.pos[k].z);
        if (!c.finite()) { printf("FAIL: non-finite after press\n"); ok = false; }
        if (mx < 0.2f) { printf("FAIL: sheet did not tent over the mask\n"); ok = false; }
        return mx;
    };

    float vpRaw = 0.f, tpRaw = 0.f, vpDil = 0.f, tpDil = 0.f;
    const float maxZraw = pressAndMeasure(false, vpRaw, tpRaw);
    const float maxZ    = pressAndMeasure(true,  vpDil, tpDil);
    printf("press: maxZ=%.3f (collider peaks at 0.420)\n", maxZ);
    printf("  undilated: vertexPen=%.4f  triPen=%.4f\n", vpRaw, tpRaw);
    printf("  dilated:   vertexPen=%.4f  triPen=%.4f\n", vpDil, tpDil);
    (void)maxZraw;
    // The bug this encodes: vertices are clean either way, so only the chords
    // tell them apart.
    if (vpRaw > 1e-3f) { printf("FAIL: vertices penetrated even undilated (%.4f)\n", vpRaw); ok = false; }
    // Guard against the check going vacuous: if the collider is ever smoothed to
    // the point where the undilated sheet no longer cuts it, this test has
    // stopped testing anything and should say so rather than pass.
    if (tpRaw < 0.005f) { printf("FAIL: collider too smooth to exercise the chords "
                                 "(triPen %.4f) -- the test proves nothing\n", tpRaw); ok = false; }
    if (tpRaw < 2.f * tpDil) { printf("FAIL: dilation did not materially help "
                                      "(%.4f -> %.4f)\n", tpRaw, tpDil); ok = false; }
    if (tpDil > 0.004f) { printf("FAIL: chords still cut the collider (%.4f)\n", tpDil); ok = false; }

    // Back to the single sheet the rest of the checks run on.
    MaskField mf = mfTrue;
    {
        const float texel = 2.0f / float(mf.w - 1);
        const float cell  = 2.0f / float(s.nx - 1);
        mf.dilate(int(std::ceil(cell / texel)));
        mf.buildNormals();
    }
    s.collider = &mf;
    s.gravity = v3(0.f, 0.f, 0.f);
    for (int f = 0; f < 120; ++f) s.step(1.0f / 120.0f);

    // Corners first. At a release parameter just past the front's width the
    // corners must be free while the middles of the edges are still held.
    s.setRelease(0.25f);
    float wCorner = 0.f, wMid = 0.f;
    wCorner = s.pinW[s.idx(0, 0)];
    wMid    = s.pinW[s.idx(s.nx / 2, 0)];
    printf("release 0.25: corner w=%.2f  edge-mid w=%.2f\n", wCorner, wMid);
    if (!(wCorner < 0.05f && wMid > 0.95f)) { printf("FAIL: release is not corners-first\n"); ok = false; }

    s.setRelease(1.2f);                      // everything let go
    s.gravity = v3(0.f, -1.0f, -3.5f);
    for (int f = 0; f < 400; ++f) s.step(1.0f / 120.0f);
    if (!s.finite()) { printf("FAIL: non-finite after fall\n"); ok = false; }

    // Went over the mask, not through it: no vertex may sit behind the dome
    // surface where the dome covers it.
    float worst = 0.f;
    for (size_t k = 0; k < s.pos.size(); ++k) {
        float zs = 0.f, cov = 0.f;
        if (!mf.sample(s.pos[k].x, s.pos[k].y, zs, cov)) continue;
        if (cov < 0.99f) continue;           // silhouette texels ease, by design
        worst = std::max(worst, zs - s.pos[k].z);
    }
    printf("after fall: minZ=%.3f  deepest penetration=%.4f\n", s.minZ(), worst);
    if (s.minZ() > -0.05f) { printf("FAIL: sheet did not fall away\n"); ok = false; }
    if (worst > 0.02f) { printf("FAIL: sheet passed through the mask (%.4f)\n", worst); ok = false; }

    printf(ok ? "cloth_test: PASS\n" : "cloth_test: FAIL\n");
    return ok ? 0 : 1;
}
