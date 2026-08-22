// Chrysanthemum iteration harness: stills only, framed on the parts that are
// hard to get right -- the whole plant silhouette, the stem/leaf attachments,
// and the stem->involucre->bloom junction. flower_shot frames every shot on the
// bloom (and also dumps 110 video frames), which is the wrong tool for working
// on the stem and leaves.
//   chrys_shot [outDir]
#include <GL/glew.h>
#include <GLFW/glfw3.h>

#include "RootRenderer.h"
#include "FlowerLSystem.h"

#include <array>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static void writePPM(const std::string& path, int w, int h, const std::vector<unsigned char>& rgba) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); return; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = h - 1; y >= 0; --y)
        for (int x = 0; x < w; ++x) {
            const unsigned char* px = &rgba[(y * w + x) * 4];
            fputc(px[0], f); fputc(px[1], f); fputc(px[2], f);
        }
    fclose(f);
}

int main(int argc, char** argv) {
    std::string outDir = argc > 1 ? argv[1] : "/tmp";
    if (!glfwInit()) return 1;
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 4);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 1);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);
    glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
    GLFWwindow* win = glfwCreateWindow(900, 900, "chrys", nullptr, nullptr);
    if (!win) { glfwTerminate(); return 1; }
    glfwMakeContextCurrent(win);
    glewExperimental = GL_TRUE;
    if (glewInit() != GLEW_OK) return 1;

    const int W = 900, H = 900;
    RootRenderer renderer(W, H);
    renderer.mat.colorNoiseStrength = 0.5f;
    renderer.mat.colorNoiseScale    = 0.06f;
    renderer.mat.ambient = 0.28f;
    renderer.mat.diffuse = 0.95f;
    renderer.mat.specColor[0] = 0.14f; renderer.mat.specColor[1] = 0.13f; renderer.mat.specColor[2] = 0.12f;
    renderer.mat.shininess = 18.0f;
    renderer.fog.density = 0.0020f;     // light fog: the stem is far from the bloom
    renderer.wispCount = 2;
    renderer.wisps[0].basePos[1]=40.f; renderer.wisps[0].color[0]=1.f; renderer.wisps[0].color[1]=0.85f; renderer.wisps[0].color[2]=0.4f;
    renderer.wisps[0].intensity=2.f; renderer.wisps[0].driftRadius=10.f;
    renderer.wisps[1].basePos[0]=-15.f; renderer.wisps[1].basePos[1]=20.f;
    renderer.wisps[1].color[0]=0.4f; renderer.wisps[1].color[1]=0.7f; renderer.wisps[1].color[2]=1.f;
    renderer.wisps[1].intensity=1.5f; renderer.wisps[1].driftRadius=12.f;

    // Palette: STEM, LEAF, DISK(eye), PETAL, ACCENT (base) and the tip variant.
    const std::array<float,3> stemG{0.16f,0.30f,0.13f};
    const std::array<float,3> leafG{0.13f,0.25f,0.10f};
    const std::array<float,3> leafT{0.26f,0.42f,0.17f};
    auto setPal = [&](std::array<float,3> pb, std::array<float,3> pt, std::array<float,3> eye) {
        std::array<float,3> base[5] = {stemG, leafG, eye, pb, {0.80f,0.20f,0.40f}};
        std::array<float,3> tip[5]  = {stemG, leafT, eye, pt, {0.90f,0.30f,0.10f}};
        for (int i = 0; i < 5; ++i) {
            for (int c = 0; c < 3; ++c) { renderer.palette[i][c] = base[i][c];
                                          renderer.paletteTip[i][c] = tip[i][c]; }
        }
        renderer.paletteCount = 5; renderer.paletteTipCount = 5;
    };

    struct Shot { const char* name; int form;
                  std::array<float,3> pb, pt, eye; };
    Shot shots[] = {
        {"decorative", flower::CHRYS_DECORATIVE, {0.98f,0.80f,0.90f}, {0.85f,0.16f,0.55f}, {0.92f,0.90f,0.55f}},
        {"incurve",    flower::CHRYS_INCURVE,    {0.99f,0.82f,0.34f}, {0.92f,0.48f,0.08f}, {0.98f,0.80f,0.30f}},
    };

    std::vector<unsigned char> pix(W * H * 4);

    // --- Stem banding probe: four bare stalks side by side, isolating what
    //     actually creases a capsule chain (taper amount, link count, curvature).
    if (getenv("CHRYS_STEMTEST")) {
        flower::FlowerMesh m;
        m.curGroup = flower::G_STEM;
        struct Probe { double dx; double baseR, topR, sway, flare, neck; int sub; };
        Probe probes[] = {
            { -9.0, 0.70, 0.70, 0.0, 0.0, 0.0,  40},   // constant radius, straight
            { -3.0, 0.95, 0.56, 0.0, 0.0, 0.0,  40},   // tapered, straight, few links
            {  3.0, 0.95, 0.56, 0.0, 0.0, 0.0, 220},   // tapered, straight, many links
            {  9.0, 0.70, 0.70, 1.9, 0.0, 0.0,  40},   // constant radius, curved
        };
        for (auto& pr : probes) {
            flower::StemShape S;
            S.height = 24.0; S.baseR = pr.baseR; S.topR = pr.topR; S.sway = pr.sway;
            S.basalFlare = pr.flare; S.neckSwell = pr.neck; S.swayPhase = 0.0;
            flower::FlowerMesh one;
            one.curGroup = flower::G_STEM;
            flower::emitStem(one, S, pr.sub);
            for (auto& n : one.nodes) n.x += pr.dx;
            m.append(one);
        }
        setPal({0.98f,0.80f,0.90f}, {0.85f,0.16f,0.55f}, {0.9f,0.9f,0.5f});
        renderer.uploadSegments(m.nodes, m.segments, m.radii, &m.groups,
                                &m.prims, &m.frames, &m.aux);
        float target[3] = {0, 12.f, 0};
        float lightDir[3] = {0.4f, 0.62f, 0.5f};
        renderer.render(0.0f, 0.05f, 40.f, target, 0.5236f, lightDir);
        glBindTexture(GL_TEXTURE_2D, renderer.colorTex());
        glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, pix.data());
        writePPM(outDir + "/stemtest.ppm", W, H, pix);
        printf("wrote %s/stemtest.ppm (const|taper40|taper220|curved)\n", outDir.c_str());
    }

    for (auto& s : shots) {
        flower::ChrysanthParams cp; cp.form = s.form;
        flower::FlowerMesh mesh = flower::buildChrysanthemum(cp);
        setPal(s.pb, s.pt, s.eye);
        renderer.uploadSegments(mesh.nodes, mesh.segments, mesh.radii, &mesh.groups,
                                &mesh.prims, &mesh.frames, &mesh.aux);

        float maxY = -1e9f, minY = 1e9f;
        for (auto& n : mesh.nodes) { maxY = std::max(maxY, (float) n.y); minY = std::min(minY, (float) n.y); }
        float stemTop = cp.stemHeight;                 // where the bloom is grafted on
        float lightDir[3] = {0.4f, 0.62f, 0.5f};

        // name, azimuth, elevation, camera distance, target height
        struct View { const char* suffix; float az, elev, rad, ty; };
        const float plantR = (maxY - minY) * 1.18f;
        const float midY   = (minY + maxY) * 0.52f;
        View views[] = {
            // Near head-on: camera close to eye level, four azimuths, since which
            // way the head nods depends on where the wandering tip ended up.
            {"_headon_a", 0.00f, 0.08f, plantR, midY},
            {"_headon_b", 1.57f, 0.08f, plantR, midY},
            {"_headon_c", 3.14f, 0.08f, plantR, midY},
            {"_headon_d", 4.71f, 0.08f, plantR, midY},
            {"_plant",  0.60f, 0.16f, plantR, midY},                  // whole plant, 3/4
            {"_join",   0.60f, 0.10f,  34.f, stemTop - 2.f},          // stem -> involucre -> bloom
            {"_leaf",   0.60f, 0.22f,  30.f, cp.stemHeight * 0.42f},  // a stem leaf and its attachment
            {"_base",   0.60f, 0.12f,  26.f, cp.stemHeight * 0.12f},  // lower stem / ground end
        };
        for (auto& v : views) {
            float target[3] = {0, v.ty, 0};
            renderer.render(v.az, v.elev, v.rad, target, 0.5236f, lightDir);
            glBindTexture(GL_TEXTURE_2D, renderer.colorTex());
            glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, pix.data());
            writePPM(outDir + "/" + s.name + v.suffix + ".ppm", W, H, pix);
        }
        printf("wrote %s/%s _plant/_join/_leaf/_base  (segs=%zu)\n",
               outDir.c_str(), s.name, mesh.segments.size());
    }

    glfwDestroyWindow(win);
    glfwTerminate();
    return 0;
}
