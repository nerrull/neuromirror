// dev_tools.mm — the headless CLI dev tools declared in dev_tools.h. Moved
// verbatim out of main.mm (see PANEL.md / the split's history); nothing here
// touches the live app's per-frame state.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Cocoa/Cocoa.h>

#include "imgui.h"
#include "metal_context.h"
#include "mirror_scene.h"
#include "fit_target.h"
#include "face_tracker.h"
#include "face_capture.h"
#include "face_fit.h"
#include "root_scene.h"
#include "root_camera_sequence.h"
#include "transition_scene.h"
#include "fit_view_scene.h"
#include "screen_layout.h"
#include "chord.h"
#include "wwise_audio.h"
#include "audio_pulse.h"
#include "fullscreen_present.h"
#include "text_overlay.h"
#include "LeafMesh.h"
#include "dev_tools.h"
#include "core_frame.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

int selftest() {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "selftest: no Metal device\n"); return 1; }
    MirrorScene mirror(ctx);
    if (!mirror.valid()) { fprintf(stderr, "selftest: mirror invalid\n"); return 1; }
    // Exercise the transition path too, so the whole pipeline is covered.
    mirror.params().transition = 0.5f;
    id<MTLTexture> tex = nil;
    for (int i = 0; i < 5; ++i) { mirror.advance(1.0 / 60.0); tex = mirror.render(); }
    // Read back one RGBA16F texel (center) to confirm real data landed.
    uint16_t px[4] = {0, 0, 0, 0};
    NSUInteger cx = tex.width / 2, cy = tex.height / 2;
    [tex getBytes:px bytesPerRow:sizeof(px)
       fromRegion:MTLRegionMake2D(cx, cy, 1, 1) mipmapLevel:0];
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float f; __builtin_memcpy(&f, &bits, 4); return f;
    };
    printf("selftest: %dx%d center rgba = %.3f %.3f %.3f %.3f  OK\n",
           (int)tex.width, (int)tex.height, h2f(px[0]), h2f(px[1]), h2f(px[2]), h2f(px[3]));
    return 0;
}

// Headless throughput benchmark of the mirror's MLX compute (features + fused
// MLP), matching demo_pond's method: eval each frame, synchronize once at the
// end. Reports ms/frame at 1920x1080 / downscale.  Usage: --bench [downscale] [frames]
int bench(int downscale, int frames) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "bench: no Metal device\n"); return 1; }
    const int W = 1920, H = 1080;
    const int lw = std::max(2, W / downscale), lh = std::max(2, H / downscale);
    mirror::Pond pond(11);
    mirror::PondParams p;

    auto now = [] { return std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count(); };

    { auto a = pond.render(lh, lw, 0.0, p); mirror::mx::eval(a); }   // warmup
    mirror::mx::synchronize();
    double t0 = now();
    for (int f = 0; f < frames; ++f) {
        auto a = pond.render(lh, lw, f / 60.0, p);
        mirror::mx::eval(a);
    }
    mirror::mx::synchronize();
    double dt = (now() - t0) / frames;
    printf("bench: pond compute %dx%d (ds=%d, %d frames): %.3f ms/frame (%.0f fps)\n",
           lw, lh, downscale, frames, dt * 1e3, 1.0 / dt);
    return 0;
}

// Headless check of the root scene's Metal pipeline (no window): compiles the
// MSL passes, renders a few frames of the synthetic root structure into the
// offscreen fog texture, and reads back the centre texel to confirm real data.
int roottest() {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "roottest: no Metal device\n"); return 1; }
    RootScene roots(ctx, 640, 360);
    if (!roots.valid()) { fprintf(stderr, "roottest: root scene invalid (shader compile?)\n"); return 1; }
    id<MTLTexture> tex = nil;
    for (int i = 0; i < 3; ++i) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            roots.advance(1.0 / 60.0);
            tex = roots.render(cb);
            [cb commit];
            [cb waitUntilCompleted];
        }
    }
    if (!tex) { fprintf(stderr, "roottest: no texture\n"); return 1; }
    uint16_t px[4] = {0, 0, 0, 0};
    NSUInteger cx = tex.width / 2, cy = tex.height / 2;
    [tex getBytes:px bytesPerRow:sizeof(px)
       fromRegion:MTLRegionMake2D(cx, cy, 1, 1) mipmapLevel:0];
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float f; __builtin_memcpy(&f, &bits, 4); return f;
    };
    printf("roottest: %dx%d center rgba = %.3f %.3f %.3f %.3f  OK\n",
           (int)tex.width, (int)tex.height, h2f(px[0]), h2f(px[1]), h2f(px[2]), h2f(px[3]));
    return 0;
}

// Headless render of the root scene to a PPM file for visual validation.
// Usage: --rootshot <out.ppm> [az] [el] [radius] [mode] [overlays]
// mode: 0 Phong (default), 1 PBR, 2 Invert.  overlays: 1 = axes + grid.
int rootshot(const char* path, float az, float el, float rad, int mode, bool overlays) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "rootshot: no Metal device\n"); return 1; }
    const int W = 960, H = 540;
    RootScene roots(ctx, W, H);
    if (!roots.valid()) { fprintf(stderr, "rootshot: root scene invalid\n"); return 1; }
    roots.autoOrbit = false;
    roots.azimuth = az; roots.elevation = el; roots.radius = rad;
    roots.renderer().shaderMode = (MetalRootRenderer::ShaderMode)mode;
    if (overlays) {
        roots.renderer().overlay.showAxes = true;
        roots.renderer().overlay.showGrid = true;
    }
    id<MTLTexture> tex = nil;
    for (int i = 0; i < 3; ++i) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            roots.advance(1.0 / 60.0);
            tex = roots.render(cb);
            [cb commit];
            [cb waitUntilCompleted];
        }
    }
    std::vector<uint16_t> px((size_t)W * H * 4);
    [tex getBytes:px.data() bytesPerRow:W * 4 * sizeof(uint16_t)
       fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float f; __builtin_memcpy(&f, &bits, 4); return f;
    };
    FILE* fp = fopen(path, "wb");
    if (!fp) { fprintf(stderr, "rootshot: cannot open %s\n", path); return 1; }
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            const uint16_t* p = &px[((size_t)y * W + x) * 4];
            for (int c = 0; c < 3; ++c) {
                float v = h2f(p[c]);
                v = v <= 0.f ? 0.f : (v >= 1.f ? 1.f : v);
                unsigned char b = (unsigned char)(powf(v, 1.0f / 2.2f) * 255.0f + 0.5f);
                fputc(b, fp);
            }
        }
    fclose(fp);
    printf("rootshot: wrote %s (%dx%d)\n", path, W, H);
    return 0;
}

// Post-processing overrides by name, shared by the headless shots (defined
// below, with the table of keys).
static void applyPostOverride(RootScene& roots, const char* spec);

// Headless live-growth check: steps the CPlantBox sim `steps` frames, then
// renders to a PPM. Usage:
//   --growshot <out.ppm> [steps] [az] [el] [radius] [faceScale] [targetY] [faceRecess]
int growshot(const char* path, int steps, float az, float el, float rad,
                    float faceScale, float targetY,
                    float faceRecess, int W, int H,
                    const std::vector<std::pair<std::string, std::string>>& fields,
                    float zoom, float faces, unsigned faceSeed,
                    int focus, int group, int groupOf) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "growshot: no Metal device\n"); return 1; }
    RootScene roots(ctx, W, H);
    if (!roots.valid()) { fprintf(stderr, "growshot: root scene invalid\n"); return 1; }
    printf("growshot: sim active = %d\n", roots.simActive() ? 1 : 0);
    // Growth fields off the command line, so a look dialled in with root_sweep
    // can be *seen* without going through the panel. Same names root_sweep and
    // --rootpreset take.
    if (!fields.empty()) {
        rootsim::SimParams& SP = roots.simParams();
        for (const auto& kv : fields) {
            const std::string key = kv.first == "species" ? "speciesXml" : kv.first;
            bool hit = false;
            rootsim::visitSimParams(SP, [&](const char* name, auto& f) {
                if (key != name) return;
                hit = true;
                using T = std::decay_t<decltype(f)>;
                if constexpr (std::is_same_v<T, std::string>) f = kv.second;
                else if constexpr (std::is_same_v<T, bool>) f = atoi(kv.second.c_str()) != 0;
                else if constexpr (std::is_same_v<T, int>) f = atoi(kv.second.c_str());
                else if constexpr (std::is_same_v<T, unsigned>)
                    f = (unsigned)strtoul(kv.second.c_str(), nullptr, 10);
                else f = (T)atof(kv.second.c_str());
            });
            if (!hit) fprintf(stderr, "growshot: no growth field '%s'\n", kv.first.c_str());
        }
        roots.regrow();
    }
    roots.autoOrbit = false;
    roots.zoom = zoom;
    roots.focusMask = focus;
    roots.focusGroup = group;
    roots.focusGroupSize = groupOf;
    // Same post-processing door --abshot uses, so a shot meant for looking at
    // rather than diffing can lift the fog off the subject.
    applyPostOverride(roots, getenv("GROWSHOT_POST"));
    if (rad > 0) roots.radius = rad;
    // Framing overrides, so a single mask can be filled the frame with. The
    // masks are a couple of centimetres on a fifty-centimetre cone, and their
    // orientation is not decidable at the scale the whole system is shot at.
    if (faceScale > 0) roots.faceScale = faceScale;
    // Recess is signed and 0 is a meaningful value, so the "unset" sentinel has
    // to sit outside the slider's range rather than at zero.
    if (faceRecess < 1e8f) roots.faceRecess = faceRecess;
    if (targetY > -1e8f) roots.target[1] = targetY;
    roots.azimuth = az; roots.elevation = el;
    // A different face on every mask, sampled from the morphable basis: the
    // repo has no photo set to fit, and for testing layout and framing what
    // matters is that the masks are visibly different people.
    if (faces > 0.f) roots.setTestIdentities(roots.simParams().N, faceSeed, faces);

    id<MTLTexture> tex = nil;
    for (int i = 0; i < steps; ++i) roots.advance(1.0 / 60.0);   // grow (no GPU work)
    for (int i = 0; i < 2; ++i) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            tex = roots.render(cb);
            [cb commit]; [cb waitUntilCompleted];
        }
    }
    std::vector<uint16_t> px((size_t)W * H * 4);
    [tex getBytes:px.data() bytesPerRow:W * 4 * sizeof(uint16_t)
       fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float f; __builtin_memcpy(&f, &bits, 4); return f;
    };
    FILE* fp = fopen(path, "wb");
    if (!fp) { fprintf(stderr, "growshot: cannot open %s\n", path); return 1; }
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            const uint16_t* p = &px[((size_t)y * W + x) * 4];
            for (int c = 0; c < 3; ++c) {
                float v = h2f(p[c]); v = v <= 0.f ? 0.f : (v >= 1.f ? 1.f : v);
                fputc((unsigned char)(powf(v, 1.0f / 2.2f) * 255.0f + 0.5f), fp);
            }
        }
    fclose(fp);
    printf("growshot: wrote %s (%dx%d, %d steps, done=%d)\n",
           path, W, H, steps, roots.simDone() ? 1 : 0);
    return 0;
}



// Growth fields by name, shared by --growshot, --rootpreset and --rootmovie.
// The names are visitSimParams', plus "species" for the one the panel spells
// differently.
static void applyGrowthFields(RootScene& roots,
                              const std::vector<std::pair<std::string, std::string>>& fields) {
    if (fields.empty()) return;
    rootsim::SimParams& SP = roots.simParams();
    for (const auto& kv : fields) {
        const std::string key = kv.first == "species" ? "speciesXml" : kv.first;
        bool hit = false;
        rootsim::visitSimParams(SP, [&](const char* name, auto& f) {
            if (key != name) return;
            hit = true;
            using T = std::decay_t<decltype(f)>;
            if constexpr (std::is_same_v<T, std::string>) f = kv.second;
            else if constexpr (std::is_same_v<T, bool>) f = atoi(kv.second.c_str()) != 0;
            else if constexpr (std::is_same_v<T, int>) f = atoi(kv.second.c_str());
            else if constexpr (std::is_same_v<T, unsigned>)
                f = (unsigned)strtoul(kv.second.c_str(), nullptr, 10);
            else f = (T)atof(kv.second.c_str());
        });
        if (!hit) fprintf(stderr, "growth: no field '%s'\n", kv.first.c_str());
    }
    roots.regrow();
}

// RGBA16F texture -> binary PPM. `encoded` when the composite pass has already
// made the texture display-referred, in which case applying gamma again would
// wash it out.
static bool writeTexturePPM(id<MTLTexture> tex, int W, int H, const char* path,
                            bool encoded) {
    std::vector<uint16_t> px((size_t)W * H * 4);
    [tex getBytes:px.data() bytesPerRow:W * 4 * sizeof(uint16_t)
       fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float f; __builtin_memcpy(&f, &bits, 4); return f;
    };
    FILE* fp = fopen(path, "wb");
    if (!fp) { fprintf(stderr, "cannot open %s\n", path); return false; }
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            const uint16_t* p = &px[((size_t)y * W + x) * 4];
            for (int c = 0; c < 3; ++c) {
                float v = h2f(p[c]);
                v = v <= 0.f ? 0.f : (v >= 1.f ? 1.f : v);
                if (!encoded) v = powf(v, 1.0f / 2.2f);
                fputc((unsigned char)(v * 255.0f + 0.5f), fp);
            }
        }
    fclose(fp);
    return true;
}

// The pull-back, as a moving camera rather than five stills.
//
//   --rootmovie <out.mp4> [seconds] [fps] [W] [H] [field=value ...]
//
// Four beats, and the anchor face is the centre of frame in every one of them:
//
//   1  the face alone      nothing has grown yet, tight on the mask
//   2  the roots arrive    growth runs; the camera does not move, so the beat
//                          ends framed exactly where beat 1 began
//   3  the structure       the pull-back: the other masks come into frame while
//                          the anchor face stays put
//   4  the others          copies of the piece standing around this one
//
// Beats 1 and 2 share a framing on purpose. The move is beat 3, and it reads as
// a move only because the anchor keeps one face nailed to the centre while the
// radius grows around it -- a cut between framings cannot do that.
int rootmovie(const char* outPath, double seconds, int fps, int W, int H,
                     const std::vector<std::pair<std::string, std::string>>& fields,
                     float faces, unsigned faceSeed) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "rootmovie: no Metal device\n"); return 1; }
    RootScene roots(ctx, W, H);
    if (!roots.valid()) { fprintf(stderr, "rootmovie: root scene invalid\n"); return 1; }

    applyGrowthFields(roots, fields);
    applyPostOverride(roots, getenv("GROWSHOT_POST"));
    if (faces > 0.f) roots.setTestIdentities(roots.simParams().N, faceSeed, faces);

    // The camera and its beat schedule now live in RootCameraSequence, shared
    // with the live app -- begin() reads the layout once, step() drives the
    // camera/growth-pacing fields each frame. Beats 1-3 split `seconds` in
    // the same proportions the sequence always has (13% / 17% / 48%); beat 4
    // (the meander) would keep going past it if asked to, but the frame loop
    // below stops at `frames` regardless. Growth-rate/camera-speed ranges and
    // the outro are left at RootBeatParams' defaults -- an export has no
    // panel and no outro to fade into.
    RootBeatParams bp;
    bp.beat1_seconds = float(seconds * 0.13);
    bp.beat2_seconds = float(seconds * 0.17);
    bp.beat3_seconds = float(seconds * 0.48);
    RootCameraSequence seq;
    seq.begin(roots, bp);
    if (!seq.valid()) { fprintf(stderr, "rootmovie: no masks\n"); return 1; }

    const int frames = std::max(2, (int)std::lround(seconds * fps));
    const double dt = 1.0 / fps;

    char dirTemplate[] = "/tmp/rootmovie.XXXXXX";
    const char* dir = mkdtemp(dirTemplate);
    if (!dir) { fprintf(stderr, "rootmovie: no temp dir\n"); return 1; }

    for (int f = 0; f < frames; ++f) {
        const double ts = double(f) / (frames - 1) * seconds;

        // No cloth in this offline export -- clothCleared=true from frame 0
        // so beat 1 just runs its authored beat1_seconds, unaffected by the
        // live app's cloth-clearance gating. No live Wwise marker stream
        // either, so beats 3/4 fall back to their plain timers (see
        // RootBeatParams::beat3_focus_fallback_seconds / beat4_dwell_seconds)
        // -- exactly what those exist for.
        seq.step(roots, ts, dt, bp, /*wantOutro=*/false, /*clothCleared=*/true,
                 /*markerHit=*/false);
        roots.advance(dt);

        id<MTLTexture> tex = nil;
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            tex = roots.render(cb);
            [cb commit]; [cb waitUntilCompleted];
        }
        if (!tex) { fprintf(stderr, "rootmovie: no texture\n"); return 1; }
        char path[512];
        snprintf(path, sizeof(path), "%s/f%05d.ppm", dir, f);
        if (!writeTexturePPM(tex, W, H, path, roots.renderer().outputIsEncoded()))
            return 1;
        if ((f % 25) == 0) { printf("rootmovie: %d/%d\n", f, frames); fflush(stdout); }
    }

    char cmd[1024];
    snprintf(cmd, sizeof(cmd),
             "ffmpeg -y -loglevel error -framerate %d -i %s/f%%05d.ppm "
             "-c:v libx264 -pix_fmt yuv420p -crf 18 %s",
             fps, dir, outPath);
    const int rc = system(cmd);
    snprintf(cmd, sizeof(cmd), "rm -rf %s", dir);
    system(cmd);
    if (rc != 0) { fprintf(stderr, "rootmovie: ffmpeg failed (%d)\n", rc); return 1; }
    printf("rootmovie: wrote %s (%d frames, %dx%d @ %d fps)\n", outPath, frames, W, H, fps);
    return 0;
}

// Post-tranche overrides, so a single knob can be isolated without a rebuild:
//   ABSHOT_POST="bloom=0,exposure=1.4"
// Shared by --abshot and --rootbench, which is the point: the setting that was
// measured and the setting that was photographed have to be spelled the same
// way or the cost table and the images stop describing the same thing.
static void applyPostOverride(RootScene& roots, const char* spec) {
    if (!spec) return;
    auto& P = roots.renderer().post;
    auto& A = roots.renderer().ao;
    auto& F = roots.renderer().face;
    auto& E = roots.renderer().env;
    auto& D = roots.renderer().detail;
    auto& M = roots.renderer().mat;
    auto& B = roots.renderer().pbr;
    const std::string s(spec);
    size_t pos = 0;
    while (pos < s.size()) {
        const size_t comma = std::min(s.find(',', pos), s.size());
        const std::string kv = s.substr(pos, comma - pos);
        pos = comma + 1;
        const size_t eq = kv.find('=');
        if (eq == std::string::npos) continue;
        const std::string k = kv.substr(0, eq);
        const float v = (float)atof(kv.c_str() + eq + 1);
        if      (k == "bloom")      P.bloom = v != 0.f;
        else if (k == "bloomThr")   P.bloomThreshold = v;
        else if (k == "bloomInt")   P.bloomIntensity = v;
        else if (k == "dof")        P.dof = v != 0.f;
        else if (k == "dofStr")     P.dofStrength = v;
        else if (k == "dofRange")   P.dofRange = v;
        else if (k == "grain")      P.grain = v;
        else if (k == "vignette")   P.vignette = v;
        else if (k == "exposure")   P.exposure = v;
        else if (k == "ssaa")       P.ssaa = (int)v;
        else if (k == "ao")         A.enabled = v != 0.f;
        else if (k == "aoInt")      A.intensity = v;
        else if (k == "aoRad")      A.radius = v;
        else if (k == "aoSamples")  A.samples = (int)v;
        else if (k == "relief")     F.reliefStrength = v;
        else if (k == "faceRough")  F.roughness = v;
        else if (k == "faceLight")  F.lightIntensity = v;
        else if (k == "smooth")     F.smoothNormals = v != 0.f;
        else if (k == "bg")         { E.background[0] = E.background[1] =
                                      E.background[2] = v; }
        else if (k == "hemi")       E.hemiStrength = v;
        else if (k == "envSpec")    E.envSpec = v;
        else if (k == "sssWrap")    E.sssWrap = v;
        else if (k == "sssTrans")   E.sssTrans = v;
        else if (k == "detStr")     D.strength = v;
        else if (k == "detScale")   D.scale = v;
        else if (k == "detStretch") D.stretch = v;
        else if (k == "detRough")   D.rough = v;
        else if (k == "detTint")    D.tint = v;
        else if (k == "mode")       roots.renderer().shaderMode =
                                        (MetalRootRenderer::ShaderMode)(int)v;
        else if (k == "rough")      B.roughness = v;
        else if (k == "metallic")   B.metallic = v;
        else if (k == "shininess")  M.shininess = v;
        else if (k == "diffuse")    M.diffuse = v;
        else if (k == "spec")       { M.specColor[0] *= v; M.specColor[1] *= v;
                                      M.specColor[2] *= v; }
        else if (k == "pulse")      roots.renderer().pulse.enabled = v != 0.f;
        else if (k == "vis")        roots.renderer().fog.visibility = v;
        else if (k == "fogH")       roots.renderer().fog.heightScale = v;
        else if (k == "fogStart")   { roots.renderer().fog.startAuto = false;
                                      roots.renderer().fog.startDist = v; }
        else if (k == "fogFrac")    roots.renderer().fog.startFrac = v;
        else if (k == "fogNoise")   roots.renderer().fog.noiseStrength = v;
        else if (k == "fogCon")     roots.renderer().fog.noiseContrast = v;
        else if (k == "fogScale")   roots.renderer().fog.noiseScale = v;
        else if (k == "fogSteps")   roots.renderer().fog.steps = (int)v;
        else if (k == "fogScat")    roots.renderer().fog.scatter = v;
        else if (k == "fogAniso")   roots.renderer().fog.anisotropy = v;
        else if (k == "fogDs")      roots.renderer().fog.downscale = (int)v;
        else if (k == "fogOn")      roots.renderer().fog.enabled = v != 0.f;
        else if (k == "ca")         P.caStrength = v;
        else if (k == "streak")     P.streak = v;
        else if (k == "streakLen")  P.streakLength = v;
        else if (k == "halation")   P.halation = v;
        else if (k == "haloMip")    P.halationMip = (int)v;
        else if (k == "contrast")   P.contrast = v;
        else if (k == "satur")      P.saturation = v;
        else if (k == "splitBal")   P.toneBalance = v;
        else if (k == "grainSize")  P.grainSize = v;
        else if (k == "grainChroma") P.grainChroma = v;
        else if (k == "splitStr")   P.splitStrength = v;
        else if (k == "k1")         P.distortK1 = v;
        else if (k == "k2")         P.distortK2 = v;
        else if (k == "dzoom")      P.distortZoom = v;
        else if (k == "focal")      { roots.useFocal = true; roots.focalMM = v; }
        else if (k == "wide")       roots.setWideAngle(v != 0.f);
        else if (k == "key")        E.keyIntensity = v;
        else if (k == "spotOuter")  F.spotOuterDeg = v;
        else if (k == "spotInner")  F.spotInnerDeg = v;
        // --- where the key is (see root_scene.h) ----------------------------
        // Note micKey/trackAngle: both room responses are *on* by default and
        // both write the key every frame, so an offline shot that did not turn
        // them off would be lit by a microphone that is not there
        // (keyIntensity collapsing to the silence value) and aimed by a
        // tracker with no visitor in front of it.
        else if (k == "autoFrame")  roots.autoFrame = v != 0.f;
        else if (k == "autoOrbit")  roots.autoOrbit = v != 0.f;
        else if (k == "orbitRate")  roots.orbitRate = v;
        else if (k == "az")         roots.azimuth = v;
        else if (k == "el")         roots.elevation = v;
        else if (k == "radius")     roots.radius = v;
        else if (k == "targetY")    roots.target[1] = v;
        else if (k == "focusMask")  roots.focusMask = (int)v;
        else if (k == "fogDither")  P.fogDither = v;
        else if (k == "lightMode")  roots.lightMode = (RootScene::LightMode)(int)v;
        else if (k == "lightFocus") roots.lightFocus = (RootScene::LightFocus)(int)v;
        else if (k == "lightX")     roots.lightDir[0] = v;
        else if (k == "lightY")     roots.lightDir[1] = v;
        else if (k == "lightZ")     roots.lightDir[2] = v;
        else if (k == "lampX")      roots.lightPos[0] = v;
        else if (k == "lampY")      roots.lightPos[1] = v;
        else if (k == "lampZ")      roots.lightPos[2] = v;
        else if (k == "lightOffAz") roots.lightOffsetAz = v;
        else if (k == "lightOffEl") roots.lightOffsetEl = v;
        else if (k == "trackAngle") roots.trackLightAngle = v != 0.f;
        else if (k == "micKey")     roots.micLightResponsive = v != 0.f;
        else fprintf(stderr, "post override: unknown key '%s'\n", k.c_str());
    }
}

// Headless capture of the MESHED leaves alone (plus a stalk to hang them on),
// so the leaf geometry can be judged without growing a whole scene first.
//   --leafshot <out.ppm> [W] [H] [az] [el] [radius]
//
// Leaves are meshed rather than drawn as blade SDFs: a blade built from a union
// of capsules keeps a rounded, constant-thickness margin all the way round and
// reads as a moulded plastic part, while a mesh takes the margin to an edge and
// thickens only over the veins. See sdf_viewer/LeafMesh.h.
int leafshot(const char* path, int W, int H, float az, float el, float radius) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "leafshot: no Metal device\n"); return 1; }
    const std::string shaderDir    = std::string(MIRROR_APP_SHADER_DIR);
    const std::string sharedHeader = std::string(MIRROR_APP_SRC_DIR) + "/root_shared.h";
    MetalRootRenderer R(ctx, shaderDir, sharedHeader, W, H);

    // A stalk, as capsules on the normal segment path -- a swept tube is what
    // that path is good at, so only the blades move to the mesh path.
    std::vector<float> nodes;
    std::vector<int>   segs;
    std::vector<float> radii;
    const float stemH = 34.0f, stemR = 0.62f;
    const int   stemSub = 160;
    for (int i = 0; i <= stemSub; ++i) {
        float t = (float) i / stemSub;
        nodes.push_back(std::sin(t * 1.6f) * 0.9f * t);
        nodes.push_back(t * stemH);
        nodes.push_back(0.f);
        if (i > 0) {
            segs.push_back(i - 1); segs.push_back(i);
            radii.push_back(stemR * (1.0f - 0.30f * t));
        }
    }

    // Leaves up the stalk, alternating around it at the golden angle.
    std::vector<float> leafVerts;
    const float golden = 3.14159265f * (3.0f - 2.2360679f);
    const int   nLeaves = 5;
    for (int i = 0; i < nLeaves; ++i) {
        float f = nLeaves > 1 ? (float) i / (nLeaves - 1) : 0.f;
        float t = 0.16f + 0.62f * f;
        float ang = i * golden;
        float y = t * stemH;
        float sx = std::sin(t * 1.6f) * 0.9f * t;

        leafmesh::LeafParams LP;
        LP.length    = 13.0f - 4.0f * f;
        LP.halfWidth = LP.length * 0.36f;
        LP.thickness = 0.070f;
        LP.curl      = 0.26f + 0.10f * f;

        // Out from the stem, tilted a little up, and rolled about its own midrib
        // so a leaf held near horizontal still turns a face to the camera.
        leafmesh::V3 out(std::cos(ang), 0.20f, std::sin(ang));
        leafmesh::V3 axis = leafmesh::normalize(out);
        float roll = (i & 1) ? 0.42f : -0.42f;
        leafmesh::V3 up(std::sin(roll) * std::sin(ang), std::cos(roll), -std::sin(roll) * std::cos(ang));
        leafmesh::Frame F;
        F.origin = leafmesh::V3(sx, y, 0.f) + axis * (stemR * 1.6f);
        F.axis   = axis;
        F.up     = leafmesh::normalize(up);
        leafmesh::emitLeaf(leafVerts, LP, F);

        // Petiole: a short tube from inside the stalk out to the blade base.
        int n0 = (int)(nodes.size() / 3);
        leafmesh::V3 a = leafmesh::V3(sx, y, 0.f) - axis * (stemR * 0.6f);
        const int psub = 10;
        for (int k = 0; k <= psub; ++k) {
            float u = (float) k / psub;
            leafmesh::V3 p = a + (F.origin - a) * u;
            nodes.push_back(p.x); nodes.push_back(p.y); nodes.push_back(p.z);
            if (k > 0) {
                segs.push_back(n0 + k - 1); segs.push_back(n0 + k);
                radii.push_back(stemR * (0.42f - 0.12f * u));
            }
        }
    }

    // Green stalk: without a palette the segments fall back to the root
    // material, which is bark, and the shot stops being about the leaves.
    R.palette[0][0] = 0.16f; R.palette[0][1] = 0.30f; R.palette[0][2] = 0.13f;
    R.paletteTip[0][0] = 0.20f; R.paletteTip[0][1] = 0.36f; R.paletteTip[0][2] = 0.15f;
    R.paletteCount = 1; R.paletteTipCount = 1;

    R.uploadSegments(nodes, segs, radii);
    R.uploadLeafMesh(leafVerts);
    R.pulse.enabled = false;

    float target[3] = {0.f, stemH * 0.45f, 0.f};
    float lightDir[3] = {0.42f, 0.66f, 0.52f};
    if (radius <= 0.f) radius = stemH * 1.15f;

    id<MTLTexture> tex = nil;
    for (int i = 0; i < 2; ++i) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            tex = R.render(cb, az, el, radius, target, 0.5236f, lightDir);
            [cb commit]; [cb waitUntilCompleted];
        }
    }
    if (!tex) { fprintf(stderr, "leafshot: no texture\n"); return 1; }

    std::vector<uint16_t> px((size_t) W * H * 4);
    [tex getBytes:px.data() bytesPerRow:W * 4 * sizeof(uint16_t)
       fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float fv; __builtin_memcpy(&fv, &bits, 4); return fv;
    };
    const bool encoded = R.outputIsEncoded();
    FILE* fp = fopen(path, "wb");
    if (!fp) { fprintf(stderr, "leafshot: cannot open %s\n", path); return 1; }
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            const uint16_t* p = &px[((size_t) y * W + x) * 4];
            for (int c = 0; c < 3; ++c) {
                float v = h2f(p[c]);
                v = v <= 0.f ? 0.f : (v >= 1.f ? 1.f : v);
                if (!encoded) v = powf(v, 1.0f / 2.2f);
                fputc((unsigned char)(v * 255.0f + 0.5f), fp);
            }
        }
    fclose(fp);
    printf("leafshot: wrote %s (%dx%d, %d leaf verts, %zu stem segs)\n",
           path, W, H, (int)(leafVerts.size() / 12), radii.size());
    return 0;
}

// Headless A/B capture: the same grown scene, the same camera, rendered at one
// of the renderer's quality tranches. Usage:
//   --abshot <out.ppm> [tranche] [W] [H] [focusMask] [zoom] [az] [el] [steps]
//
// Separate from --growshot because a comparison is only worth anything if the
// only thing that changed is the setting under test: this fixes the resolution,
// the framing and the growth length, and takes the tranche as an argument, so
// two runs differ in exactly one variable. Framing goes through focusMask/zoom
// rather than through a raw radius, since applyFraming() derives the camera from
// the scene's own bounds each frame and would overwrite a radius set here.
int abshot(const char* path, int tranche, int W, int H,
                  int focusMask, float zoom, float az, float el, int steps) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "abshot: no Metal device\n"); return 1; }
    RootScene roots(ctx, W, H);
    if (!roots.valid()) { fprintf(stderr, "abshot: root scene invalid\n"); return 1; }
    roots.renderer().setTranche(tranche);
    // Pulses off for captures. They travel along the roots on their own clock,
    // so two shots taken at the same growth step still differ wherever a pulse
    // happens to be -- which is exactly the kind of difference that makes an A/B
    // pair unreadable, since a bright band moving between two frames is far more
    // salient than the shading change being compared. Re-enable with
    // ABSHOT_POST="pulse=1" when the pulses themselves are the subject.
    roots.renderer().pulse.enabled = false;
    applyPostOverride(roots, getenv("ABSHOT_POST"));
    roots.autoOrbit = false;
    roots.azimuth = az; roots.elevation = el;
    roots.focusMask = focusMask;
    roots.zoom = zoom;

    for (int i = 0; i < steps; ++i) roots.advance(1.0 / 60.0);

    id<MTLTexture> tex = nil;
    for (int i = 0; i < 2; ++i) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            tex = roots.render(cb);
            [cb commit]; [cb waitUntilCompleted];
        }
    }
    if (!tex) { fprintf(stderr, "abshot: no texture\n"); return 1; }
    std::vector<uint16_t> px((size_t)W * H * 4);
    [tex getBytes:px.data() bytesPerRow:W * 4 * sizeof(uint16_t)
       fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float f; __builtin_memcpy(&f, &bits, 4); return f;
    };
    // Once the composite pass is in the chain the texture is already
    // display-referred; applying the usual 1/2.2 on top would wash it out and
    // make every comparison against a tranche-0 shot meaningless.
    const bool encoded = roots.renderer().outputIsEncoded();
    FILE* fp = fopen(path, "wb");
    if (!fp) { fprintf(stderr, "abshot: cannot open %s\n", path); return 1; }
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            const uint16_t* p = &px[((size_t)y * W + x) * 4];
            for (int c = 0; c < 3; ++c) {
                float v = h2f(p[c]);
                v = v <= 0.f ? 0.f : (v >= 1.f ? 1.f : v);
                if (!encoded) v = powf(v, 1.0f / 2.2f);
                fputc((unsigned char)(v * 255.0f + 0.5f), fp);
            }
        }
    fclose(fp);
    printf("abshot: wrote %s (%dx%d, tranche %d, ssaa %d, encoded %d, masks %d)\n",
           path, W, H, tranche, roots.renderer().post.ssaa, encoded ? 1 : 0,
           roots.maskCount());
    return 0;
}

// Headless GPU benchmark of the root render: grow the sim to completion, then
// time `frames` full render()s (geometry + face + fog). Usage:
//   --rootbench [downscale] [frames]
int rootbench(int downscale, int frames, int baseW, int baseH) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "rootbench: no Metal device\n"); return 1; }
    const int W = baseW / std::max(1, downscale), H = baseH / std::max(1, downscale);
    RootScene roots(ctx, W, H);
    if (!roots.valid()) { fprintf(stderr, "rootbench: invalid\n"); return 1; }
    roots.autoOrbit = false;
    if (const char* t = getenv("ROOTBENCH_TRANCHE")) roots.renderer().setTranche(atoi(t));
    applyPostOverride(roots, getenv("ROOTBENCH_POST"));
    if (const char* m = getenv("ROOTBENCH_MODE"))
        roots.renderer().shaderMode = (MetalRootRenderer::ShaderMode)atoi(m);
    if (const char* r = getenv("ROOTBENCH_RADIUS")) roots.radius = atof(r);

    auto now = [] { return std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count(); };

    // Grow to done, timing the CPU cost of advance() (sim step + geometry rebuild
    // + buffer uploads) — this is what runs every frame while roots are growing.
    double advAccum = 0.0; int advN = 0;
    for (int i = 0; i < 4000 && !roots.simDone(); ++i) {
        double a0 = now(); roots.advance(1.0 / 60.0); advAccum += now() - a0; advN++;
    }
    if (advN > 0)
        printf("rootbench: advance() CPU during growth: %.3f ms/frame (%d frames)\n",
               advAccum / advN * 1e3, advN);

    @autoreleasepool {   // warmup
        id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
        roots.render(cb); [cb commit]; [cb waitUntilCompleted];
    }
    double t0 = now();
    for (int f = 0; f < frames; ++f) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            roots.render(cb); [cb commit]; [cb waitUntilCompleted];
        }
    }
    double dt = (now() - t0) / frames;
    printf("rootbench: %dx%d (ds=%d, tranche=%d, ssaa=%d, sim done=%d): "
           "%.3f ms/frame (%.0f fps)\n",
           W, H, downscale, roots.renderer().tranche(), roots.renderer().post.ssaa,
           roots.simDone() ? 1 : 0, dt * 1e3, 1.0 / dt);
    return 0;
}

// Write an RGBA16F texture to a gamma-corrected PPM.
void writePPM(const char* path, id<MTLTexture> tex, int W, int H) {
    std::vector<uint16_t> px((size_t)W * H * 4);
    [tex getBytes:px.data() bytesPerRow:W * 4 * sizeof(uint16_t)
       fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float f; __builtin_memcpy(&f, &bits, 4); return f;
    };
    FILE* fp = fopen(path, "wb");
    if (!fp) return;
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            const uint16_t* p = &px[((size_t)y * W + x) * 4];
            for (int c = 0; c < 3; ++c) {
                float v = h2f(p[c]); v = v <= 0.f ? 0.f : (v >= 1.f ? 1.f : v);
                fputc((unsigned char)(powf(v, 1.0f / 2.2f) * 255.0f + 0.5f), fp);
            }
        }
    fclose(fp);
}

// Build a field of cached root systems and render it. Usage:
//   --fieldshot <out.ppm> [grid] [az] [el]
int fieldshot(const char* path, int grid, float az, float el) {
    MetalContext ctx;
    if (!ctx.device()) return 1;
    const int W = 1280, H = 720;
    RootScene roots(ctx, W, H);
    if (!roots.valid()) { fprintf(stderr, "fieldshot: invalid\n"); return 1; }
    const float spacing = 30.f;
    roots.buildField(grid, spacing);
    roots.autoOrbit = false;
    roots.azimuth = az; roots.elevation = el;
    roots.target[0] = 0; roots.target[1] = -10; roots.target[2] = 0;
    roots.radius = grid * spacing * 0.85f;
    id<MTLTexture> tex = nil;
    for (int i = 0; i < 2; ++i) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            tex = roots.render(cb); [cb commit]; [cb waitUntilCompleted];
        }
    }
    writePPM(path, tex, W, H);
    MetalRootRenderer& R = roots.renderer();
    printf("fieldshot: wrote %s  instances=%d visible=%d culled=%d drawnSegs=%ld\n",
           path, R.instanceCount(), R.lastVisibleInstances, R.lastCulledInstances,
           R.lastDrawnSegments);
    return 0;
}

int fieldbench(int grid, int frames) {
    MetalContext ctx;
    if (!ctx.device()) return 1;
    const int W = 1920, H = 1080;
    RootScene roots(ctx, W, H);
    if (!roots.valid()) { fprintf(stderr, "fieldbench: invalid\n"); return 1; }
    const float spacing = 30.f;
    roots.buildField(grid, spacing);
    roots.autoOrbit = false;
    // Immersive viewpoint: camera low and near the field edge looking across it,
    // so a good share of systems fall off-screen (culling) and the rest recede
    // into the distance (LOD) — the target end-goal viewing condition.
    roots.target[0] = grid * spacing * 0.15f; roots.target[1] = -8; roots.target[2] = 0;
    roots.radius = spacing * 1.6f;
    roots.elevation = 0.12f; roots.azimuth = 0.9f;
    MetalRootRenderer& R = roots.renderer();

    auto now = [] { return std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count(); };
    auto timeIt = [&](const char* label) {
        @autoreleasepool { id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            roots.render(cb); [cb commit]; [cb waitUntilCompleted]; }   // warmup
        double t0 = now();
        for (int f = 0; f < frames; ++f) @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            roots.render(cb); [cb commit]; [cb waitUntilCompleted];
        }
        double dt = (now() - t0) / frames;
        printf("fieldbench %-18s %.3f ms/frame (%.0f fps)  visible=%d culled=%d drawnSegs=%ld\n",
               label, dt*1e3, 1.0/dt, R.lastVisibleInstances, R.lastCulledInstances, R.lastDrawnSegments);
    };
    printf("fieldbench: %dx%d field = %d instances @ %dx%d\n", grid, grid, R.instanceCount(), W, H);
    R.cullInstances = false; R.subpixelCull = false; R.lodBias = 0.0001f;  timeIt("naive(all,full)");
    R.cullInstances = false; R.subpixelCull = false; R.lodBias = 1.0f;     timeIt("LOD-only");
    R.cullInstances = true;  R.subpixelCull = true;  R.lodBias = 1.0f;     timeIt("cull+subpx+LOD");
    return 0;
}

// Headless end-to-end face path on a still image: MediaPipe -> landmarks ->
// training mask, and -> morphable fit -> mesh. face_fit_test covers the solver
// against synthetic ground truth, but everything upstream of it -- the tracker,
// the MP68 mapping, the blendshape name matching, the y-flip -- only runs when
// a real detector looks at a real face. Usage: --facetest [image.png]
int facetest(const char* path) {
    if (!mirror::FaceTracker::available()) {
        printf("facetest: MediaPipe not compiled in -- run ./setup-mediapipe.sh\n");
        return 0;
    }
    const int W = 640, H = 480;
    std::vector<float> rgbf;
    std::string err;
    if (!LoadImageRGB(path, W, H, rgbf, err)) {
        fprintf(stderr, "facetest: %s: %s\n", path, err.c_str());
        return 1;
    }
    std::vector<unsigned char> rgb(rgbf.size());
    for (size_t i = 0; i < rgbf.size(); ++i)
        rgb[i] = (unsigned char)std::min(255.f, std::max(0.f, rgbf[i] * 255.f + 0.5f));

    mirror::FaceTracker tracker;
    if (!tracker.open(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_landmarker.task", err)) {
        fprintf(stderr, "facetest: %s\n", err.c_str());
        return 1;
    }
    mirror::FaceResult face;
    if (!tracker.detect(rgb.data(), W, H, 1000, face)) {
        fprintf(stderr, "facetest: no face detected in %s\n", path);
        return 1;
    }
    printf("facetest: %s  %dx%d\n", path, W, H);
    printf("  landmarks %zu  blendshapes %zu  named %zu\n",
           face.landmarks.size(), face.blendshapes.size(),
           face.blendshape_names.size());
    printf("  bounds x %.3f..%.3f  y %.3f..%.3f\n",
           face.min_x, face.max_x, face.min_y, face.max_y);

    // --- the mirror's consumer: the training mask -------------------------
    std::vector<unsigned char> mask;
    mirror::RasteriseFaceMask(face.landmarks, mirror::FaceOvalIndices(),
                              W, H, 6, mask);
    size_t on = 0;
    for (unsigned char m : mask) on += m ? 1 : 0;
    printf("  training mask: %.2f%% of frame (%zu px)\n",
           100.0 * double(on) / double(mask.size()), on);
    if (on == 0) { fprintf(stderr, "facetest: empty mask\n"); return 1; }

    // --- the roots' consumer: the fitted mesh -----------------------------
    mirror::FaceFitter fitter;
    if (!fitter.load(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_basis.bin", err)) {
        printf("  %s\n  (skipping the fit)\n", err.c_str());
        return 0;
    }
    printf("  frontality %.3f  neutrality %.3f\n",
           mirror::FaceFitter::Frontality(face.landmarks),
           mirror::FaceFitter::Neutrality(face.blendshapes, face.blendshape_names));

    fitter.offerIdentityFrame(face, W, H);
    float residual = -1.f;
    if (fitter.identityFrames() > 0 && fitter.fitIdentity(&residual))
        printf("  identity fitted from 1 frame, residual %.3f px\n", residual);
    else
        printf("  frame rejected for identity (not frontal/neutral enough)\n");

    if (!fitter.update(face, W, H)) { fprintf(stderr, "facetest: update failed\n"); return 1; }
    float yaw, pitch, roll;
    fitter.headAngles(yaw, pitch, roll);
    printf("  head pose: yaw %+.1f  pitch %+.1f  roll %+.1f (deg)\n",
           yaw * 57.2958f, pitch * 57.2958f, roll * 57.2958f);

    int nz = 0;
    for (float v : fitter.expression()) if (v > 0.01f) ++nz;
    printf("  expression: %d of %d modes active\n", nz, fitter.basis().expressionModes());

    // The check that matters: does the fitted mesh land on the face? Compare
    // the projected mesh's bounds to the tracker's own landmark bounds. A lost
    // y-flip or a bad pose puts it somewhere else entirely.
    std::vector<float> vpx;
    fitter.projectVertices(vpx);
    float x0 = vpx[0], x1 = vpx[0], y0 = vpx[1], y1 = vpx[1];
    for (size_t i = 0; i < vpx.size() / 2; ++i) {
        x0 = std::min(x0, vpx[i * 2]);     x1 = std::max(x1, vpx[i * 2]);
        y0 = std::min(y0, vpx[i * 2 + 1]); y1 = std::max(y1, vpx[i * 2 + 1]);
    }
    printf("  projected mesh px: x %.0f..%.0f  y %.0f..%.0f\n", x0, x1, y0, y1);
    printf("  tracker face  px: x %.0f..%.0f  y %.0f..%.0f\n",
           face.min_x * W, face.max_x * W, face.min_y * H, face.max_y * H);

    // Centres should agree to well within a face width; the mesh is a mask, so
    // its extent is legitimately smaller than the full landmark set's.
    const float mcx = 0.5f * (x0 + x1), mcy = 0.5f * (y0 + y1);
    const float fcx = face.centre_x * W, fcy = face.centre_y * H;
    const float fw = (face.max_x - face.min_x) * W;
    const float off = std::sqrt((mcx - fcx) * (mcx - fcx) + (mcy - fcy) * (mcy - fcy));
    printf("  mesh centre is %.1f px from the face centre (%.0f%% of face width)\n",
           off, 100.0 * off / fw);
    if (off > 0.35f * fw) {
        fprintf(stderr, "facetest: FAIL -- fitted mesh is not on the face\n");
        return 1;
    }

    // --- and into the root scene ------------------------------------------
    // The fitted mesh replacing the canonical model is the other half of the
    // wiring, and it is the half that can fail silently: a bad vertex count or
    // a stale triangle list produces an empty face pass rather than an error.
    {
        MetalContext ctx;
        if (!ctx.device()) { fprintf(stderr, "facetest: no Metal device\n"); return 1; }
        RootScene roots(ctx, 640, 360);
        if (!roots.valid()) { fprintf(stderr, "facetest: root scene invalid\n"); return 1; }
        roots.setFittedFace(fitter.vertices(), fitter.basis().triangles());
        if (!roots.usingFittedFace()) {
            fprintf(stderr, "facetest: FAIL -- root scene rejected the fitted mesh\n");
            return 1;
        }
        // Animate it: a second mesh from a different expression must actually
        // reach the renderer, not just the first one.
        for (int i = 0; i < 3; ++i) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
                roots.advance(1.0 / 60.0);
                roots.setFittedFace(fitter.vertices(), std::vector<int>());
                (void)roots.render(cb);
                [cb commit];
                [cb waitUntilCompleted];
            }
        }
        printf("  root scene: fitted face uploaded (%d verts, %d tris) and rendered\n",
               fitter.basis().vertexCount(), fitter.basis().triangleCount());
        roots.clearFittedFace();
        if (roots.usingFittedFace()) {
            fprintf(stderr, "facetest: FAIL -- clearFittedFace did not revert\n");
            return 1;
        }
    }
    printf("facetest: OK\n");
    return 0;
}

// --- demo renders -----------------------------------------------------------

static void writePPM_rgb(const std::string& path, const std::vector<float>& rgb,
                         int w, int h) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    std::vector<unsigned char> row(size_t(w) * 3);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w * 3; ++x) {
            const float v = rgb[size_t(y) * w * 3 + x];
            row[x] = (unsigned char)std::min(255.f, std::max(0.f, v * 255.f + 0.5f));
        }
        fwrite(row.data(), 1, row.size(), f);
    }
    fclose(f);
}

// Rasterise the fitted mesh over `dst` with per-vertex colour, back-face culled
// and depth-sorted (painter's). A z-buffer would be more correct, but the mesh
// is a convex-ish mask with no self-occlusion once back faces are gone, and
// sorting 4048 triangles is simpler than carrying depth through the raster.
static void rasteriseMesh(std::vector<float>& dst, int W, int H,
                          const std::vector<float>& px,      // projected xy
                          const std::vector<float>& verts,   // model xyz (for depth)
                          const std::vector<int>& tris,
                          const std::vector<float>& vcol,
                          float alpha) {
    struct Tri { int i; float z; };
    std::vector<Tri> order;
    order.reserve(tris.size() / 3);
    for (size_t t = 0; t + 2 < tris.size(); t += 3) {
        const int a = tris[t], b = tris[t + 1], c = tris[t + 2];
        // Back-face cull by 2D winding in image (y-down) space.
        const float e1x = px[b * 2] - px[a * 2], e1y = px[b * 2 + 1] - px[a * 2 + 1];
        const float e2x = px[c * 2] - px[a * 2], e2y = px[c * 2 + 1] - px[a * 2 + 1];
        if (e1x * e2y - e1y * e2x >= 0.f) continue;
        const float z = (verts[a * 3 + 2] + verts[b * 3 + 2] + verts[c * 3 + 2]) / 3.f;
        order.push_back({int(t), z});
    }
    std::sort(order.begin(), order.end(),
              [](const Tri& a, const Tri& b) { return a.z < b.z; });

    for (const Tri& tr : order) {
        const int a = tris[tr.i], b = tris[tr.i + 1], c = tris[tr.i + 2];
        const float ax = px[a * 2], ay = px[a * 2 + 1];
        const float bx = px[b * 2], by = px[b * 2 + 1];
        const float cx = px[c * 2], cy = px[c * 2 + 1];
        int x0 = int(std::floor(std::min({ax, bx, cx})));
        int x1 = int(std::ceil (std::max({ax, bx, cx})));
        int y0 = int(std::floor(std::min({ay, by, cy})));
        int y1 = int(std::ceil (std::max({ay, by, cy})));
        x0 = std::max(0, x0); y0 = std::max(0, y0);
        x1 = std::min(W - 1, x1); y1 = std::min(H - 1, y1);
        const float den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
        if (std::fabs(den) < 1e-9f) continue;
        for (int y = y0; y <= y1; ++y) {
            for (int x = x0; x <= x1; ++x) {
                const float fx = float(x) + 0.5f, fy = float(y) + 0.5f;
                float l0 = ((by - cy) * (fx - cx) + (cx - bx) * (fy - cy)) / den;
                float l1 = ((cy - ay) * (fx - cx) + (ax - cx) * (fy - cy)) / den;
                float l2 = 1.f - l0 - l1;
                if (l0 < 0 || l1 < 0 || l2 < 0) continue;
                float* o = &dst[(size_t(y) * W + x) * 3];
                for (int k = 0; k < 3; ++k) {
                    const float col = vcol.empty()
                        ? 0.8f
                        : l0 * vcol[a * 3 + k] + l1 * vcol[b * 3 + k] + l2 * vcol[c * 3 + k];
                    o[k] = o[k] * (1.f - alpha) + col * alpha;
                }
            }
        }
    }
}

// Wireframe over an image: front-facing edges only, so the mesh reads as a
// surface on the face rather than a ball of lines.
static void drawMeshWire(std::vector<float>& dst, int W, int H,
                         const std::vector<float>& px, const std::vector<int>& tris,
                         const float col[3], float a) {
    auto line = [&](float x0, float y0, float x1, float y1) {
        const int steps = int(std::max(std::fabs(x1 - x0), std::fabs(y1 - y0))) + 1;
        for (int s = 0; s <= steps; ++s) {
            const float t = float(s) / float(steps);
            const int x = int(x0 + (x1 - x0) * t + 0.5f);
            const int y = int(y0 + (y1 - y0) * t + 0.5f);
            if (x < 0 || y < 0 || x >= W || y >= H) continue;
            float* o = &dst[(size_t(y) * W + x) * 3];
            for (int k = 0; k < 3; ++k) o[k] = o[k] * (1.f - a) + col[k] * a;
        }
    };
    for (size_t t = 0; t + 2 < tris.size(); t += 3) {
        const int i0 = tris[t], i1 = tris[t + 1], i2 = tris[t + 2];
        const float e1x = px[i1 * 2] - px[i0 * 2], e1y = px[i1 * 2 + 1] - px[i0 * 2 + 1];
        const float e2x = px[i2 * 2] - px[i0 * 2], e2y = px[i2 * 2 + 1] - px[i0 * 2 + 1];
        if (e1x * e2y - e1y * e2x >= 0.f) continue;   // back-facing
        line(px[i0 * 2], px[i0 * 2 + 1], px[i1 * 2], px[i1 * 2 + 1]);
        line(px[i1 * 2], px[i1 * 2 + 1], px[i2 * 2], px[i2 * 2 + 1]);
        line(px[i2 * 2], px[i2 * 2 + 1], px[i0 * 2], px[i0 * 2 + 1]);
    }
}

// --maskshot <photo> <out.ppm>
//
// The whole face path on one still, as four panels: the source, the fitted
// Maxine/NVF mask over it, what the neural mirror made of that face, and the
// mask wearing that reconstruction. This is the picture that shows the fit and
// the texturing are actually doing what they claim.
int maskshot(const char* photo, const char* out, int fit_steps, int W, int H) {
    if (!mirror::FaceTracker::available()) {
        fprintf(stderr, "maskshot: MediaPipe not compiled in\n"); return 1;
    }
    std::string err;
    std::vector<float> src;
    if (!LoadImageRGB(photo, W, H, src, err)) {
        fprintf(stderr, "maskshot: %s: %s\n", photo, err.c_str()); return 1;
    }
    std::vector<unsigned char> rgb8(src.size());
    for (size_t i = 0; i < src.size(); ++i)
        rgb8[i] = (unsigned char)std::min(255.f, std::max(0.f, src[i] * 255.f + 0.5f));

    mirror::FaceTracker tracker;
    if (!tracker.open(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_landmarker.task", err)) {
        fprintf(stderr, "maskshot: %s\n", err.c_str()); return 1;
    }
    mirror::FaceResult face;
    if (!tracker.detect(rgb8.data(), W, H, 1000, face)) {
        fprintf(stderr, "maskshot: no face in %s\n", photo); return 1;
    }
    mirror::FaceFitter fitter;
    if (!fitter.load(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_basis.bin", err)) {
        fprintf(stderr, "maskshot: %s\n", err.c_str()); return 1;
    }
    fitter.config().min_frontality = 0.f;
    fitter.offerIdentityFrame(face, W, H);
    float residual = -1.f;
    fitter.fitIdentity(&residual);
    fitter.update(face, W, H);
    printf("maskshot: identity residual %.2f px\n", residual);

    // --- the neural mirror, fitted to the face ---------------------------
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "maskshot: no Metal device\n"); return 1; }
    MirrorScene mirror(ctx, 11, W / 2, H / 2);
    if (!mirror.valid()) { fprintf(stderr, "maskshot: mirror invalid\n"); return 1; }

    const int fw = W / 2, fh = H / 2;
    std::vector<float> target;
    mirror::DownsampleRGB8(rgb8.data(), W, H, 3, 0, 2, fw, fh, target);
    std::vector<unsigned char> mask;
    mirror::RasteriseFaceMask(face.landmarks, mirror::FaceOvalIndices(), fw, fh, 6, mask);
    mirror.pond().beginFit(target, fh, fw, mirror.params(), mask);
    for (int i = 0; i < fit_steps; ++i) mirror.fitSteps(1, 3e-3f);
    mirror.render();
    printf("maskshot: %d fit steps, loss %.5f\n", fit_steps, mirror.lastLoss());

    std::vector<float> colors;
    fitter.sampleTexture(mirror.lastImageRGB(), mirror.lowW(), mirror.lowH(),
                         W, H, colors);

    // --- compose ----------------------------------------------------------
    std::vector<float> px;
    fitter.projectVertices(px);
    const std::vector<int>& tris = fitter.basis().triangles();

    std::vector<float> p1 = src;
    // The fitted mask as a wireframe: what is being shown here is that the
    // *geometry* landed on the face, so the topology has to be visible. A
    // filled mask hides exactly the thing the panel exists to demonstrate.
    std::vector<float> p2 = src;
    const float wire[3] = {0.25f, 1.0f, 0.55f};
    drawMeshWire(p2, W, H, px, tris, wire, 0.55f);

    // The mirror's own output, upscaled to panel size.
    std::vector<float> p3(size_t(W) * H * 3);
    {
        const std::vector<float>& m = mirror.lastImageRGB();
        const int mw = mirror.lowW(), mh = mirror.lowH();
        for (int y = 0; y < H; ++y)
            for (int x = 0; x < W; ++x) {
                const int sx = std::min(mw - 1, x * mw / W), sy = std::min(mh - 1, y * mh / H);
                for (int k = 0; k < 3; ++k)
                    p3[(size_t(y) * W + x) * 3 + k] = m[(size_t(sy) * mw + sx) * 3 + k];
            }
    }
    std::vector<float> p4(size_t(W) * H * 3, 0.06f);
    rasteriseMesh(p4, W, H, px, fitter.vertices(), tris, colors, 1.0f);

    const int PW = W * 2, PH = H * 2;
    std::vector<float> sheet(size_t(PW) * PH * 3, 0.f);
    auto blit = [&](const std::vector<float>& p, int ox, int oy) {
        for (int y = 0; y < H; ++y)
            for (int x = 0; x < W * 3; ++x)
                sheet[(size_t(y + oy) * PW) * 3 + size_t(ox) * 3 + x] =
                    p[size_t(y) * W * 3 + x];
    };
    blit(p1, 0, 0);   blit(p2, W, 0);
    blit(p3, 0, H);   blit(p4, W, H);

    writePPM_rgb(out, sheet, PW, PH);
    printf("maskshot: wrote %s (%dx%d)\n"
           "  [source | fitted NVF mask]  [neural mirror fit | mask textured from it]\n",
           out, PW, PH);
    return 0;
}

// --mirrorclip <out_prefix> <secs> [photo]
//
// A clip of the neural mirror converging onto a face: frames written as PPMs
// for an external encoder. The interesting thing about the mirror is temporal
// -- the fit never finishes, it tracks -- so a still cannot show it.
int mirrorclip(const char* prefix, float secs, const char* photo, int fps,
                      int steps_per_frame) {
    const int W = 960, H = 540;
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "mirrorclip: no Metal device\n"); return 1; }
    MirrorScene mirror(ctx, 11, W, H);
    if (!mirror.valid()) { fprintf(stderr, "mirrorclip: mirror invalid\n"); return 1; }

    if (photo && *photo) {
        std::string err;
        std::vector<float> src;
        if (!LoadImageRGB(photo, W, H, src, err)) {
            fprintf(stderr, "mirrorclip: %s: %s\n", photo, err.c_str()); return 1;
        }
        std::vector<unsigned char> rgb8(src.size());
        for (size_t i = 0; i < src.size(); ++i)
            rgb8[i] = (unsigned char)std::min(255.f, std::max(0.f, src[i] * 255.f + 0.5f));

        const int fw = W / 2, fh = H / 2;
        std::vector<float> target;
        mirror::DownsampleRGB8(rgb8.data(), W, H, 3, 0, 2, fw, fh, target);

        std::vector<unsigned char> mask;
        if (mirror::FaceTracker::available()) {
            mirror::FaceTracker tracker;
            std::string terr;
            mirror::FaceResult face;
            if (tracker.open(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_landmarker.task",
                             terr) &&
                tracker.detect(rgb8.data(), W, H, 1000, face)) {
                mirror::RasteriseFaceMask(face.landmarks, mirror::FaceOvalIndices(),
                                          fw, fh, 8, mask);
                printf("mirrorclip: masked to the face (%zu of %d px)\n",
                       std::count_if(mask.begin(), mask.end(),
                                     [](unsigned char c) { return c != 0; }),
                       fw * fh);
            }
        }
        mirror.pond().beginFit(target, fh, fw, mirror.params(), mask);
    }

    const int frames = std::max(1, int(secs * float(fps)));
    const double dt = 1.0 / double(fps);
    for (int i = 0; i < frames; ++i) {
        @autoreleasepool {
            mirror.advance(dt);
            if (mirror.pond().fitting()) mirror.fitSteps(steps_per_frame, 3e-3f);
            mirror.render();
            char path[512];
            snprintf(path, sizeof(path), "%s%04d.ppm", prefix, i);
            writePPM_rgb(path, mirror.lastImageRGB(), mirror.lowW(), mirror.lowH());
        }
    }
    printf("mirrorclip: wrote %d frames %s0000.ppm.. (%dx%d, %d fps, loss %.5f)\n",
           frames, prefix, W, H, fps, mirror.lastLoss());
    return 0;
}

// --transhot <prefix> <frames> [photo]
//
// The full 4-phase transition, offscreen. Mirrors cloth_cpp's `--shots`, but
// against live assets: the pond is a real MirrorScene fitted to the photo, and
// the face is the real fitted NVF mesh rather than a baked heightmap.
int transhot(const char* prefix, int frames, const char* photo, float fps,
                    bool align, const float reg[4],
                    float yawDeg) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "transhot: no Metal device\n"); return 1; }

    const int W = 960, H = 960;   // square: the front-on frustum is square
    MirrorScene mirror(ctx, 11, W / 2, H / 2);
    if (!mirror.valid()) { fprintf(stderr, "transhot: mirror invalid\n"); return 1; }
    TransitionScene trans(ctx, W, H);
    FitViewScene fitview(ctx, std::string(MIRROR_APP_SHADER_DIR) + "/fit_view.metal", W, H);
    if (!trans.valid()) { fprintf(stderr, "transhot: transition invalid (shader?)\n"); return 1; }

    // Fit the mirror to the photo and fit the face mesh to it, so both assets
    // are the live ones. This is the whole point of the port: cloth_cpp could
    // only ever run this against two frozen files.
    if (photo && *photo) {
        std::string err;
        std::vector<float> src;
        if (!LoadImageRGB(photo, W, H, src, err)) {
            fprintf(stderr, "transhot: %s: %s\n", photo, err.c_str()); return 1;
        }
        std::vector<unsigned char> rgb8(src.size());
        for (size_t i = 0; i < src.size(); ++i)
            rgb8[i] = (unsigned char)std::min(255.f, std::max(0.f, src[i] * 255.f + 0.5f));

        const int fw = W / 2, fh = H / 2;
        std::vector<float> target;
        mirror::DownsampleRGB8(rgb8.data(), W, H, 3, 0, 2, fw, fh, target);

        if (mirror::FaceTracker::available()) {
            mirror::FaceTracker tracker;
            std::string terr;
            mirror::FaceResult face;
            if (tracker.open(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_landmarker.task", terr) &&
                tracker.detect(rgb8.data(), W, H, 1000, face)) {
                std::vector<unsigned char> mask;
                mirror::RasteriseFaceMask(face.landmarks, mirror::FaceOvalIndices(),
                                          fw, fh, 8, mask);
                mirror.pond().beginFit(target, fh, fw, mirror.params(), mask);

                mirror::FaceFitter fitter;
                if (fitter.load(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_basis.bin", terr)) {
                    fitter.config().min_frontality = 0.f;
                    fitter.offerIdentityFrame(face, W, H);
                    float res = -1.f;
                    fitter.fitIdentity(&res);
                    fitter.update(face, W, H);
                    // The fit's own projection as the mask's uv, so the film
                    // lands on the photo's face pixel for pixel -- the same
                    // path the live app takes, with an identity pin transform
                    // because a still photo has no head mode to undo.
                    std::vector<float> mask_uv;
                    fitter.projectNormalised(W, H, 1.f, 0.f, 0.f, mask_uv);
                    trans.setFaceMesh(fitter.vertices(), fitter.basis().triangles(), mask_uv);
                    printf("transhot: face fitted (residual %.2f px), %d verts\n",
                           res, fitter.basis().vertexCount());
                } else {
                    printf("transhot: no face basis (%s)\n", terr.c_str());
                }
            }
        }
        // Converge the mirror before the clip starts, so the film is a face and
        // not noise on frame 0.
        for (int i = 0; i < 1200; ++i) mirror.fitSteps(1, 3e-3f);
        printf("transhot: mirror fitted, loss %.5f\n", mirror.lastLoss());
    }

    // No photo, or no face found in it: the transition still plays, against the
    // basis's neutral mask. There is no faceless mode -- the gesture is a film
    // coming off a mask, and an empty frame is not a shorter version of it.
    if (!trans.hasFace()) {
        mirror::FaceBasis basis;
        std::string berr;
        if (basis.load(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_basis.bin", berr))
            trans.setFaceMesh(basis.neutral(), basis.triangles());
        else
            printf("transhot: no face basis (%s)\n", berr.c_str());
    }

    // The alignment hold: the mask fully through a flat film, both on screen,
    // the timeline going nowhere. This is the state the registration is set in,
    // and having it headless is what makes a chosen scale checkable against a
    // still rather than only by eye on a moving sheet.
    if (align) {
        trans.alignMask = true;
        if (reg) {
            trans.maskScale[0] = reg[0]; trans.maskScale[1] = reg[1];
            trans.maskOffset[0] = reg[2]; trans.maskOffset[1] = reg[3];
        }
    }

    const double dt = 1.0 / double(fps);
    for (int f = 0; f < frames; ++f) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            // A little side-to-side, so the drape has an asymmetric solid to
            // come off. A photo cannot turn its head; a person in front of the
            // piece does, and the mesh carries that on its own.
            trans.maskYaw = yawDeg * (float(M_PI) / 180.f)
                          * std::sin(float(f) / float(fps) * 2.f * float(M_PI) * 0.22f);
            mirror.advance(dt);
            if (mirror.pond().fitting()) mirror.fitSteps(1, 3e-3f);
            id<MTLTexture> pond = mirror.render();
            trans.setPondTexture(pond);
            trans.advance(dt);
            id<MTLTexture> tex = trans.render(cb);
            [cb commit];
            [cb waitUntilCompleted];
            char path[512];
            snprintf(path, sizeof(path), "%s%04d.ppm", prefix, f);
            writePPM(path, tex, W, H);
        }
    }
    printf("transhot: wrote %d frames %s0000.ppm.. (%dx%d @ %.0f fps)\n",
           frames, prefix, W, H, fps);
    return 0;
}

// --orientshot <prefix> [w] [h]
//
// The composition at a given drawable size, for both scenes that care about its
// shape. Defaults to 1080x1920 -- the installation's panel with macOS set to
// portrait -- because the whole point of the orientation work is that the piece
// is composed for a screen nobody is developing on.
//
// Renders <prefix>_mirror.ppm (pond + text overlay, through the real present
// path) and <prefix>_roots.ppm (the 3D scene), and prints the layout and the
// camera rect. Aspect-dependent things fail here by looking *plausible* -- a
// squashed face, a title running off the side, a frustum that crops the roots --
// so this exists to be looked at.
int orientshot(const char* prefix, int dw, int dh, int orient) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "orientshot: no Metal device\n"); return 1; }

    const mirror::ScreenLayout L = mirror::ComputeLayout(
        dw, dh, (mirror::Orientation)orient, 9.f / 16.f);
    const int W = L.comp_w, H = L.comp_h;
    printf("orientshot: drawable %dx%d -> compose %dx%d (aspect %.4f)%s\n",
           dw, dh, W, H, float(W) / float(H),
           L.letterboxed ? " letterboxed" : "");

    const mirror::SrcRect fr =
        mirror::ComputeFeedRect(1920, 1080, W / 4, H / 4, mirror::FeedCrop{});
    printf("orientshot: 1920x1080 sensor -> crop %dx%d at (%d, %d), "
           "%.0f%% of the width kept\n",
           fr.w, fr.h, fr.x, fr.y, 100.0 * fr.w / 1920.0);

    char path[512];

    // --- the mirror, with the text over it ---------------------------------
    {
        MirrorScene m(ctx, 11, W / 2, H / 2);
        if (!m.valid()) { fprintf(stderr, "orientshot: mirror invalid\n"); return 1; }
        m.params().drops_on = true;
        m.params().orbit_on = true;

        FullscreenPresent present(ctx,
            std::string(MIRROR_APP_SHADER_DIR) + "/present.metal",
            MTLPixelFormatRGBA16Float);
        if (!present.valid()) {
            fprintf(stderr, "orientshot: present shader failed\n"); return 1;
        }
        mirror::TextOverlay text(ctx);
        mirror::TextParams tp;
        tp.on = true;
        tp.text = "JARDINS\nRACINE";
        text.update(tp);

        // Drawable-sized, with the composition blitted into its viewport --
        // the same two calls the frame loop makes, so a letterbox that is
        // offset or the wrong size shows up here rather than on the wall.
        MTLTextureDescriptor* d = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                         width:dw height:dh mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        id<MTLTexture> out = [ctx.device() newTextureWithDescriptor:d];

        @autoreleasepool {
            m.advance(1.0);
            id<MTLTexture> pond = m.render();

            mirror::TextRipple tr;
            const mirror::PondParams& P = m.params();
            tr.k = P.ring_freq;
            tr.decay = P.decay;
            tr.core_r2 = P.core_rolloff ? P.core_radius * P.core_radius : 0.f;
            const auto& srcs = m.pond().lastSources();
            tr.n = int(std::min(srcs.size(), size_t(16)));
            for (int i = 0; i < tr.n; ++i)
                for (int j = 0; j < mirror::RIPPLE_SRC_DIM; ++j) tr.src[i][j] = srcs[i][j];

            MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = out;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            id<MTLRenderCommandEncoder> re =
                [cb renderCommandEncoderWithDescriptor:rpd];
            [re setViewport:(MTLViewport){
                (double)L.vp_x, (double)L.vp_y,
                (double)L.vp_w, (double)L.vp_h, 0.0, 1.0}];
            present.encode(re, pond, text.texture(),
                           text.uniforms(tp, float(W) / float(H), tr, 1.0));
            [re endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            snprintf(path, sizeof(path), "%s_mirror.ppm", prefix);
            writePPM(path, out, dw, dh);
            printf("orientshot: wrote %s\n", path);
        }
    }

    // --- the root scene -----------------------------------------------------
    {
        RootScene roots(ctx, W, H);
        if (!roots.valid()) {
            fprintf(stderr, "orientshot: root scene invalid\n"); return 1;
        }
        roots.autoOrbit = false;
        // The same camera --rootshot uses, and enough steps for the growth to
        // be worth looking at: one frame in, the system is a single capsule and
        // says nothing about how the scene frames up in a tall window.
        roots.azimuth = 0.6f; roots.elevation = 0.35f; roots.radius = 42.f;
        id<MTLTexture> tex = nil;
        for (int i = 0; i < 300; ++i) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
                roots.advance(1.0 / 60.0);
                tex = roots.render(cb);
                [cb commit];
                [cb waitUntilCompleted];
            }
        }
        snprintf(path, sizeof(path), "%s_roots.ppm", prefix);
        writePPM(path, tex, W, H);
        printf("orientshot: wrote %s\n", path);
    }
    return 0;
}

// --textshot <out.ppm> [text] [warp] [reveal] [softness]
//
// The text overlay over a live pond, through the real present pass. Headless
// because the two things most likely to be wrong about this effect -- whether
// present.metal still compiles with the overlay in it, and whether the glyphs
// land where the placement says they do -- are both visible in one still frame
// and neither needs a person at the window.
//
// Ripples are turned on here even though they default off: the warp is the half
// of the effect that has anything to go wrong in it, and with no sources the
// shader's refraction branch never runs.
// --taptest: is the Wwise onset tap actually reaching this app?
//
// The failure this exists for is silent and has four or five possible causes at
// once -- no plug-in instance, the wrong Tap ID, a bus with nothing on it, a
// threshold nobody can clear, a sound engine that is not running -- and from
// inside the panel they all look identical. This connects to a tap, watches it
// for a while with nothing else in the way, and prints what arrives.
int taptest(uint32_t tapId, double seconds) {
    mirror::AudioPulses pulses;
    printf("taptest: taps currently publishing:\n");
    for (const mirror::AudioTap& t : pulses.taps())
        printf("  #%u  %-24s %u Hz\n", t.tapId,
               t.label.empty() ? "(unnamed)" : t.label.c_str(), t.sampleRate);
    if (!pulses.connect(tapId)) {
        fprintf(stderr, "taptest: no tap #%u -- is an Onset Tap effect on a bus,"
                        " with that Tap ID, in a running sound engine?\n", tapId);
        return 1;
    }
    printf("connected to #%u \"%s\"; watching for %.0f s\n",
           tapId, pulses.label().c_str(), seconds);

    // The drops are driven too, so this covers the spawner as well as the
    // transport: a tap that delivers events into a pond that ignores them is
    // still a broken installation.
    mirror::Pond pond(11);
    mirror::PondParams p;
    p.drops_on = true;
    p.spawn.rain_on = false;      // audio only, so every drop below is a hit

    // A plain steady clock, not glfwGetTime(): GLFW is not initialised on this
    // path, and its clock reads a constant 0 until it is -- which is an
    // infinite loop rather than a wrong number.
    const auto clock_now = [] {
        using namespace std::chrono;
        return duration<double>(steady_clock::now().time_since_epoch()).count();
    };
    int hits = 0;
    const double t0 = clock_now();
    double t = 0.0;
    while (t < seconds) {
        for (const mirror::AudioOnset& e : pulses.poll()) {
            ++hits;
            printf("  %6.2fs  strength %.2f  pan %+.2f  %.1f dB\n",
                   t, e.strength, e.pan, e.levelDb);
            pond.triggerDrop(e.strength, e.pan);
        }
        pond.render(48, 64, t, p);
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
        t = clock_now() - t0;
    }
    printf("taptest: %d onsets in %.0f s (%.2f/s), %d drops still in flight, "
           "level %.1f dB vs a %.1f dB bar, %s\n",
           hits, seconds, hits / seconds, (int)pond.lastSources().size(),
           pulses.levelDb(), pulses.thresholdDb(),
           pulses.live() ? "tap is live" : "TAP IS IDLE (no audio being processed)");
    return hits > 0 ? 0 : 1;
}

// --audiotest: does the Wwise engine in this process actually make a sound?
//
// The mirror image of --taptest, and for the same reason: when nothing is
// audible the causes are a bank that did not load, a plug-in that is in the
// bank but not linked into this binary, an event name that no longer matches
// the project, or a bus sitting at -96 -- and from inside a running show they
// are indistinguishable. This walks the piece's arc with no window, no camera
// and no scenes in the way: start the mirror bed, sweep the room parameters
// across their whole range, hand off through the transition to the roots, and
// let go.
//
// It is deliberately audible. Silence here with no error printed means the
// signal chain is broken somewhere Wwise considers legal, which is exactly the
// case a return code cannot tell you about.
int audiotest(double seconds, const char* wav_out) {
    mirror::WwiseAudio audio;
    std::string err;
    if (!audio.init(mirror::WwiseAudio::DefaultBankDir(), err)) {
        fprintf(stderr, "audiotest: %s\n", err.c_str());
        return 1;
    }
    printf("audiotest: engine up, banks from %s\n", audio.bankDir().c_str());
    if (wav_out && *wav_out) {
        if (audio.startCapture(wav_out)) printf("audiotest: recording to %s\n", wav_out);
        else fprintf(stderr, "audiotest: could not record to %s\n", wav_out);
    }

    // Not glfwGetTime(): GLFW is not initialised on this path and reads a
    // constant 0 until it is, which is an infinite loop rather than a wrong
    // number. (Same reason as taptest above.)
    const auto clock_now = [] {
        using namespace std::chrono;
        return duration<double>(steady_clock::now().time_since_epoch()).count();
    };

    struct Beat { double at; const char* phase; const char* event; };
    const Beat beats[] = {
        {0.00, "Idle",       "Play_FirePlucker"},   // an empty room: pluck only
        {0.30, "Fitting",    "Play_Pad"},           // the chord swells in
        {0.42, nullptr,      "Play_Drop"},
        {0.50, nullptr,      "Play_Pluck"},
        {0.58, nullptr,      "Play_Bell"},
        {0.65, "Transition", "Play_Transition"},
        {0.67, nullptr,      "Stop_Pad"},
        {0.70, nullptr,      "Stop_FirePlucker"},
        {0.78, "Roots",      "Play_Amb_Roots"},
        {0.96, nullptr,      "Stop_Amb_Roots"},
    };
    // The harmony, driven from the same module the show drives it from, so this
    // exercises the real chord rather than a second copy of the table. The fit
    // sweep below crosses every checkpoint, so a run is audibly the whole arc:
    // dark minor at the top, resolved major by the handoff.
    mirror::Chord chord;
    size_t next = 0;
    int last_stage = -1;

    const double t0 = clock_now();
    double t = 0.0;
    while (t < seconds) {
        const double u = t / seconds;   // 0..1 through the whole run

        while (next < IM_ARRAYSIZE(beats) && u >= beats[next].at) {
            if (beats[next].phase) {
                printf("  %5.1fs  phase %s\n", t, beats[next].phase);
                audio.setState("Phase", beats[next].phase);
            }
            if (beats[next].event) {
                printf("  %5.1fs  %s\n", t, beats[next].event);
                audio.post(beats[next].event);
            }
            ++next;
        }

        // Every parameter swept, each at its own rate, so a stuck one is
        // audible as the one thing that stopped moving rather than hidden in a
        // single ramp everything follows.
        mirror::AudioParams p;
        p.proximity      = 0.5f - 0.5f * std::cos((float)u * 6.2831853f);
        p.movement       = 0.5f - 0.5f * std::cos((float)u * 12.566371f);
        p.centering      = std::sin((float)u * 6.2831853f);
        p.head_yaw       = 60.f * std::sin((float)u * 3.1415927f);
        p.head_tilt      = 45.f * std::sin((float)u * 9.4247780f);
        p.fit_level      = std::min(1.f, (float)u * 2.f);
        p.scene_progress = (float)u;
        p.key            = 48.f;
        p.intensity      = 1.f;

        chord.config().root = p.key;
        chord.update(p.fit_level, p.movement, 0.016f);
        p.comb_hz = chord.voicing().comb_hz;
        if (chord.stageChanged()) {
            static const char* const kStageNames[mirror::Chord::kStages] = {
                "Stage0", "Stage1", "Stage2", "Stage3", "Stage4"
            };
            last_stage = chord.stage();
            audio.setState("ChordStage", kStageNames[last_stage]);
            printf("  %5.1fs  chord stage %d  (%.1f %.1f %.1f %.1f)\n", t,
                   last_stage + 1, chord.voicing().target[0], chord.voicing().target[1],
                   chord.voicing().target[2], chord.voicing().target[3]);
        }

        audio.update(p);

        std::this_thread::sleep_for(std::chrono::milliseconds(16));
        t = clock_now() - t0;
    }

    printf("audiotest: %lu events posted over %.0f s. If that was silent, check\n"
           "  GeneratedSoundBanks/Mac/PluginInfo.json against the factory headers\n"
           "  included by wwise_audio.cpp -- an unregistered plug-in loads fine\n"
           "  and plays nothing.\n", audio.eventsPosted(), seconds);
    audio.stopCapture();
    audio.term();
    return 0;
}

int textshot(const char* path, const char* str, float warp,
                    float reveal, float softness) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "textshot: no Metal device\n"); return 1; }

    const int W = 1280, H = 720;
    MirrorScene mirror(ctx, 11, W / 2, H / 2);
    if (!mirror.valid()) { fprintf(stderr, "textshot: mirror invalid\n"); return 1; }
    mirror.params().drops_on = true;
    mirror.params().orbit_on = true;
    mirror.params().warp = 0.3f;

    FullscreenPresent present(ctx, std::string(MIRROR_APP_SHADER_DIR) + "/present.metal",
                              MTLPixelFormatRGBA16Float);
    if (!present.valid()) { fprintf(stderr, "textshot: present shader failed\n"); return 1; }

    mirror::TextOverlay text(ctx);
    mirror::TextParams tp;
    tp.on = true;
    if (str && *str) tp.text = str;
    tp.warp = warp;
    tp.reveal = reveal;
    tp.softness = softness;
    text.update(tp);
    if (!text.valid()) { fprintf(stderr, "textshot: no field built\n"); return 1; }
    printf("textshot: field %dx%d for \"%s\"\n", text.fieldW(), text.fieldH(),
           tp.text.c_str());

    MTLTextureDescriptor* d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                     width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [ctx.device() newTextureWithDescriptor:d];

    @autoreleasepool {
        mirror.advance(1.0);          // off zero, so the ripples have a phase
        id<MTLTexture> pond = mirror.render();

        mirror::TextRipple tr;
        const mirror::PondParams& P = mirror.params();
        tr.k = P.ring_freq;
        tr.decay = P.decay;
        tr.core_r2 = P.core_rolloff ? P.core_radius * P.core_radius : 0.f;
        const auto& srcs = mirror.pond().lastSources();
        tr.n = int(std::min(srcs.size(), size_t(16)));
        for (int i = 0; i < tr.n; ++i)
            for (int j = 0; j < mirror::RIPPLE_SRC_DIM; ++j) tr.src[i][j] = srcs[i][j];
        printf("textshot: %d ripple sources, warp %.2f, reveal %.2f\n",
               tr.n, warp, reveal);

        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = out;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

        id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpd];
        present.encode(re, pond, text.texture(),
                       text.uniforms(tp, float(W) / float(H), tr, 1.0));
        [re endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        writePPM(path, out, W, H);
    }
    printf("textshot: wrote %s (%dx%d)\n", path, W, H);
    return 0;
}

// --clothshot <prefix> <frames> [W H fps photo]
//
// The pond -> face press as RootScene now draws it, straight to PPM. The live
// path (main.mm's Scene::Transition branch) needs a sensor, a visitor and the
// show clock; this reproduces the same four calls -- restartCloth, the camera
// sequence, setPondTexture, advance/render -- against the canonical mask and
// either a fitted MirrorScene or a synthetic film.
//
// The synthetic film is the default on purpose. Two of the three things that
// can be wrong with the sheet are invisible against a photograph: whether it
// still reaches the edges of the frame, and whether it is flat where it is
// supposed to be flat. A ruled grid shows both at a glance.
static id<MTLTexture> makeGridFilm(const MetalContext& ctx, int W, int H) {
    MTLTextureDescriptor* d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [ctx.device() newTextureWithDescriptor:d];
    std::vector<uint8_t> px((size_t)W * H * 4);
    const int cells = 16;
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            const int gx = x * cells / W, gy = y * cells / H;
            const bool odd = ((gx + gy) & 1) != 0;
            // The border ring is red: if the sheet covers the frame, red is
            // visible on all four edges of every rendered frame, and if it has
            // shrunk off the frustum the scene behind it shows instead.
            const bool edge = x < W / 64 || y < H / 64 || x >= W - W / 64 || y >= H - H / 64;
            uint8_t r = odd ? 210 : 40, g = odd ? 200 : 45, b = odd ? 180 : 60;
            if (edge) { r = 230; g = 30; b = 30; }
            uint8_t* p = &px[((size_t)y * W + x) * 4];
            p[0] = r; p[1] = g; p[2] = b; p[3] = 255;
        }
    [tex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0
             withBytes:px.data() bytesPerRow:W * 4];
    return tex;
}

// Reads any of the RGBA16Float targets in this app into linear floats. Shared
// by the pond dump and the cloth dump below so the seam number compares two
// images that have had exactly the same thing done to them -- a diff between
// one image that was gamma-encoded on the way out and one that was not measures
// the writer, not the seam.
static std::vector<float> readTexRGB(id<MTLTexture> tex, int W, int H) {
    std::vector<uint16_t> px((size_t)W * H * 4);
    [tex getBytes:px.data() bytesPerRow:W * 4 * sizeof(uint16_t)
       fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float f; __builtin_memcpy(&f, &bits, 4); return f;
    };
    std::vector<float> out((size_t)W * H * 3);
    for (size_t i = 0; i < (size_t)W * H; ++i)
        for (int c = 0; c < 3; ++c) out[i * 3 + c] = h2f(px[i * 4 + c]);
    return out;
}

static void writeRGBPPM(const char* path, const std::vector<float>& rgb, int W, int H,
                        bool encoded) {
    FILE* fp = fopen(path, "wb");
    if (!fp) return;
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    for (size_t i = 0; i < (size_t)W * H * 3; ++i) {
        float v = std::min(1.f, std::max(0.f, rgb[i]));
        if (!encoded) v = std::pow(v, 1.f / 2.2f);
        fputc((unsigned char)(v * 255.f + 0.5f), fp);
    }
    fclose(fp);
}

int clothshot(const char* prefix, int frames, int W, int H, float fps,
              const char* photo) {
    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "clothshot: no Metal device\n"); return 1; }
    RootScene roots(ctx, W, H);
    if (!roots.valid()) { fprintf(stderr, "clothshot: root scene invalid\n"); return 1; }

    // The mask the cloth drapes over. The canonical model RootScene loads on
    // its own is the right stand-in: the live path re-sends a fitted mesh every
    // frame, but the *placement* -- which is what the collider is built from --
    // is RootScene's own either way.
    MirrorScene mirror(ctx, 11, W / 2, H / 2);
    id<MTLTexture> film = nil;
    if (photo && *photo) {
        std::string err;
        std::vector<float> src;
        if (!LoadImageRGB(photo, W, H, src, err)) {
            fprintf(stderr, "clothshot: %s: %s\n", photo, err.c_str()); return 1;
        }
        std::vector<unsigned char> rgb8(src.size());
        for (size_t i = 0; i < src.size(); ++i)
            rgb8[i] = (unsigned char)std::min(255.f, std::max(0.f, src[i] * 255.f + 0.5f));
        const int fw = W / 2, fh = H / 2;
        std::vector<float> target;
        mirror::DownsampleRGB8(rgb8.data(), W, H, 3, 0, 2, fw, fh, target);
        // The whole live chain, in the order main.mm runs it: track the face,
        // fit the identity, hand RootScene the mesh, then bake the mirror's own
        // output onto that mesh as per-vertex colour. The last step is the one
        // that matters for "does the mask wear the face" -- RootScene has no
        // live texture to sample by the time it draws (the mirror has stopped),
        // so setFaceColors is the only path the face has onto the mask.
        std::string terr;
        mirror::FaceTracker tracker;
        mirror::FaceResult face;
        bool tracked = false;
        if (mirror::FaceTracker::available() &&
            tracker.open(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_landmarker.task", terr) &&
            tracker.detect(rgb8.data(), W, H, 1000, face)) {
            tracked = true;
            std::vector<unsigned char> fmask;
            mirror::RasteriseFaceMask(face.landmarks, mirror::FaceOvalIndices(), fw, fh, 8, fmask);
            mirror.pond().beginFit(target, fh, fw, mirror.params(), fmask);
        } else {
            printf("clothshot: no face tracked (%s)\n", terr.c_str());
            mirror.pond().beginFit(target, fh, fw, mirror.params(), {});
        }
        for (int i = 0; i < 1200; ++i) mirror.fitSteps(1, 3e-3f);
        mirror.advance(1.0 / double(fps));
        mirror.render();               // populates lastImageRGB for the bake
        printf("clothshot: mirror fitted, loss %.5f\n", mirror.lastLoss());

        if (tracked) {
            mirror::FaceFitter fitter;
            if (fitter.load(std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_basis.bin", terr)) {
                fitter.config().min_frontality = 0.f;
                fitter.offerIdentityFrame(face, W, H);
                float res = -1.f;
                fitter.fitIdentity(&res);
                fitter.update(face, W, H);
                roots.setFittedFace(fitter.vertices(), fitter.basis().triangles());
                std::vector<float> colors;
                fitter.sampleTexture(mirror.lastImageRGB(), mirror.lowW(), mirror.lowH(),
                                     W, H, colors);
                roots.setFaceColors(colors);
                printf("clothshot: face fitted (residual %.2f px), %d verts, %zu colours\n",
                       res, fitter.basis().vertexCount(), colors.size() / 3);
            } else {
                printf("clothshot: no face basis (%s)\n", terr.c_str());
            }
        }
    } else {
        film = makeGridFilm(ctx, W, H);
    }

    // CLOTHSHOT_NOCLOTH=1 renders the same frames with the sheet suppressed --
    // the A/B that says whether something on screen is the cloth or the scene
    // behind it, which by eye alone is genuinely ambiguous once the post chain
    // (bloom, DOF, fog, tonemap) has been over both.
    if (const char* nc = getenv("CLOTHSHOT_NOCLOTH")) roots.showCloth = atoi(nc) == 0;
    const bool traceOn = getenv("CLOTHSHOT_TRACE") && atoi(getenv("CLOTHSHOT_TRACE")) != 0;
    // CLOTHSHOT_RAW=1 drops the scene's post-processing, so what lands in the
    // PPM is the geometry pass and not a graded version of it.
    if (const char* raw = getenv("CLOTHSHOT_RAW")) {
        if (atoi(raw)) {
            auto& P = roots.renderer().post;
            P.bloom = false; P.dof = false; P.vignette = 0.f; P.grain = 0.f;
            P.halation = 0.f; P.exposure = 1.f;
            roots.renderer().fog.enabled = false;
            roots.renderer().ao.enabled = false;
        }
    }

    // CLOTHSHOT_TIMING="hold,press,settle,release,fall" -- the press schedule is
    // a look decision that now has panel sliders, and tuning it against stills
    // needs the same numbers reachable from here.
    if (const char* t = getenv("CLOTHSHOT_TIMING")) {
        float v[5] = {roots.clothTiming.hold, roots.clothTiming.press,
                      roots.clothTiming.settle, roots.clothTiming.release,
                      roots.clothTiming.fall};
        int n = sscanf(t, "%f,%f,%f,%f,%f", &v[0], &v[1], &v[2], &v[3], &v[4]);
        if (n > 0) {
            roots.clothTiming.hold = v[0]; roots.clothTiming.press = v[1];
            roots.clothTiming.settle = v[2]; roots.clothTiming.release = v[3];
            roots.clothTiming.fall = v[4];
            printf("clothshot: timing hold %.2f press %.2f settle %.2f release %.2f fall %.2f\n",
                   v[0], v[1], v[2], v[3], v[4]);
        }
    }

    RootBeatParams bp;
    RootCameraSequence seq;
    seq.begin(roots, bp);
    if (!seq.valid()) { fprintf(stderr, "clothshot: no masks\n"); return 1; }

    // CLOTHSHOT_AUTOFRAME=1 reproduces the show's *default* camera, which is
    // not the authored sequence at all: g_root_authored_camera is off unless
    // the operator turns it on, so applyFraming is what actually drives the
    // live press -- and applyFraming eases, converging target and radius in
    // from wherever the previous phase left them. That is the configuration
    // the sheet was reported off-centre in, so it is the one worth being able
    // to render.
    const bool autoframe = getenv("CLOTHSHOT_AUTOFRAME") &&
                           atoi(getenv("CLOTHSHOT_AUTOFRAME")) != 0;
    if (autoframe) {
        roots.autoFrame = true;
        const bool outward = atoi(getenv("CLOTHSHOT_AUTOFRAME")) == 2;

        // Prime the camera at the *start* pose before arming the ease.
        //
        // applyFraming snaps rather than eases until camPrimed_ is set, which
        // happens on its first call ever -- so a harness that just assigns a
        // pose and starts rendering gets one snap and then a stationary
        // camera, which is exactly the case the cloth already handles and not
        // the one worth testing. Live, camPrimed_ has been true since startup,
        // so the phase change hands the press a camera in mid-flight. One
        // zero-ease advance here reproduces that state.
        roots.camEase = 0.f;
        roots.focusMask = outward ? roots.anchorMask : -1;
        roots.advance(1.0 / double(fps));

        // ...then aim it somewhere else and let it ease the whole way there
        // while the press runs. Inward (=1) is the live default: tight on the
        // anchor. Outward (=2) is the adversarial direction, where the frustum
        // keeps growing past whatever the sheet was built to cover -- the case
        // that breaks a sheet sized against its entry pose while leaving the
        // opening frame perfect.
        roots.camEase = 0.6f;
        roots.focusMask = outward ? -1 : roots.anchorMask;
    }
    roots.restartCloth();

    const double dt = 1.0 / double(fps);
    double clock = 0.0;
    std::vector<float> seamPond;
    // Worst-case border coverage over the whole pinned window.
    //
    // SEAM only ever looks at frame 0, and frame 0 is the one moment the sheet
    // is guaranteed right because it is the moment it was solved. The camera
    // keeps easing afterwards, and a sheet frozen against the entry pose can
    // stop reaching the edges without SEAM moving at all -- so the number that
    // says "the film still covers the frame" has to be measured across the
    // window, not at its start. Measured against a cloth-off render of the
    // same frame rather than by guessing at colours: a border pixel that is
    // identical with and without the sheet is a border pixel the sheet is not
    // covering, and that is exact.
    double worstUncovered = 0.0;
    int    worstFrame = -1, coverageFrames = 0;
    for (int f = 0; f < frames; ++f) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
            id<MTLTexture> pond = film;
            if (!film) { mirror.advance(dt); pond = mirror.render(); }
            roots.setPondTexture(pond);
            // The seam: on the first frame, keep the film exactly as the Mirror
            // phase hands it to the presenter. The Transition phase's opening
            // frame has to be that image and not a graded version of it -- the
            // sheet is flat, fully pinned and covering the frustum, so every
            // pixel of it is the pond and nothing else. Whatever these two
            // differ by is what the audience sees at the cut.
            // Only ever measured against a real MirrorScene frame. The
            // synthetic grid film is RGBA8Unorm and readTexRGB reads halves,
            // so a seam number off the grid path is reading its bytes as
            // float16 and reporting noise in the tens of thousands.
            if (f == 0 && pond && !film) {
                // At the pond's own resolution and then bilinearly upscaled --
                // the mirror renders below the window size and the presenter
                // scales it up, so the image the audience actually sees at the
                // cut is the upscaled one. Reading it at W x H instead silently
                // returns zeros, which reads as a perfectly black pond.
                const int pw = (int)pond.width, ph = (int)pond.height;
                const std::vector<float> src = readTexRGB(pond, pw, ph);
                seamPond.assign((size_t)W * H * 3, 0.f);
                for (int y = 0; y < H; ++y) {
                    const float sy = std::min(float(ph - 1),
                        std::max(0.f, (y + 0.5f) * float(ph) / float(H) - 0.5f));
                    const int y0 = int(sy), y1 = std::min(ph - 1, y0 + 1);
                    const float fy = sy - float(y0);
                    for (int x = 0; x < W; ++x) {
                        const float sx = std::min(float(pw - 1),
                            std::max(0.f, (x + 0.5f) * float(pw) / float(W) - 0.5f));
                        const int x0 = int(sx), x1 = std::min(pw - 1, x0 + 1);
                        const float fx = sx - float(x0);
                        for (int c = 0; c < 3; ++c) {
                            const float a = src[((size_t)y0 * pw + x0) * 3 + c];
                            const float b = src[((size_t)y0 * pw + x1) * 3 + c];
                            const float d = src[((size_t)y1 * pw + x0) * 3 + c];
                            const float e = src[((size_t)y1 * pw + x1) * 3 + c];
                            seamPond[((size_t)y * W + x) * 3 + c] =
                                (a + (b - a) * fx) * (1.f - fy) + (d + (e - d) * fx) * fy;
                        }
                    }
                }
            }
            clock += dt;
            if (!autoframe)
                seq.step(roots, clock, dt, bp, /*wantOutro=*/false, roots.clothCleared(),
                         /*markerHit=*/false);
            roots.advance(dt);
            id<MTLTexture> tex = roots.render(cb);
            [cb commit]; [cb waitUntilCompleted];
            if (!tex) { fprintf(stderr, "clothshot: no texture\n"); return 1; }
            char path[512];
            snprintf(path, sizeof(path), "%s%04d.ppm", prefix, f);
            if (!writeTexturePPM(tex, W, H, path, roots.renderer().outputIsEncoded()))
                return 1;


            if (f == 0 && !seamPond.empty()) {
                // Both sides read and written identically -- see readTexRGB.
                // The pond is display-referred already (it is what the Mirror
                // phase puts on screen); the cloth frame is encoded iff the
                // post chain ran, which outputIsEncoded() answers.
                const std::vector<float> shown = readTexRGB(tex, W, H);
                snprintf(path, sizeof(path), "%sseam_pond.ppm", prefix);
                writeRGBPPM(path, seamPond, W, H, /*encoded=*/true);
                snprintf(path, sizeof(path), "%sseam_cloth.ppm", prefix);
                writeRGBPPM(path, shown, W, H, roots.renderer().outputIsEncoded());
                double sum = 0, worst = 0; size_t n = 0;
                std::vector<float> diff(shown.size());
                for (size_t k = 0; k < shown.size() && k < seamPond.size(); ++k) {
                    const double d = std::fabs(double(shown[k]) - double(seamPond[k]));
                    diff[k] = float(std::min(1.0, d * 4.0));   // x4 so it is visible
                    sum += d; worst = std::max(worst, d); ++n;
                }
                snprintf(path, sizeof(path), "%sseam_diff.ppm", prefix);
                writeRGBPPM(path, diff, W, H, /*encoded=*/true);
                printf("clothshot: SEAM mean |pond - cloth| = %.4f  worst = %.4f  "
                       "(0 = the cut is invisible; wrote %sseam_{pond,cloth,diff}.ppm)\n",
                       n ? sum / double(n) : 0.0, worst, prefix);
            }

            // Coverage, for as long as the sheet is supposed to be covering:
            // hold, press and settle. Once the release starts the film is
            // meant to be leaving, and border that stops being film is the
            // effect working rather than failing.
            // Not while tracing: both metrics re-render into the renderer's own
            // colour target, so whichever runs second reads the other's bare
            // frame as if it were the real one -- which reports the film as
            // absent on every frame, including the ones where it covers
            // everything.
            if (!traceOn && roots.showCloth && roots.clothRelease() <= 0.f && roots.clothActive()) {
                const std::vector<float> withCloth = readTexRGB(tex, W, H);
                // Drop the sheet and draw the same frame again. Safe to leave
                // dropped: advance() re-packs it at the top of the next frame.
                roots.renderer().uploadClothMesh({});
                id<MTLCommandBuffer> cb2 = [ctx.queue() commandBuffer];
                id<MTLTexture> bare = roots.render(cb2);
                [cb2 commit]; [cb2 waitUntilCompleted];
                const std::vector<float> without = readTexRGB(bare, W, H);
                size_t border = 0, uncovered = 0;
                auto sample = [&](int x, int y) {
                    const size_t k = ((size_t)y * W + x) * 3;
                    ++border;
                    const float d = std::fabs(withCloth[k]     - without[k])
                                  + std::fabs(withCloth[k + 1] - without[k + 1])
                                  + std::fabs(withCloth[k + 2] - without[k + 2]);
                    if (d < 1e-4f) ++uncovered;
                };
                for (int y = 0; y < H; ++y) { sample(0, y); sample(W - 1, y); }
                for (int x = 0; x < W; ++x) { sample(x, 0); sample(x, H - 1); }
                const double frac = border ? double(uncovered) / double(border) : 0.0;
                ++coverageFrames;
                if (frac > worstUncovered || worstFrame < 0) {
                    worstUncovered = frac; worstFrame = f;
                }
            }
            // CLOTHSHOT_TRACE=1: what fraction of the WHOLE frame the film still
            // occupies, per frame, beside the clearance reading. The kill
            // distance is meant to be "far enough behind the mask that the film
            // has gone", and that is only checkable by measuring both at once --
            // clearance alone cannot say whether a receding sheet is still on
            // screen, because a plane receding along the view axis stays inside
            // the frustum however far it goes and only leaves by crumpling.
            if (traceOn && roots.clothActive()) {
                const std::vector<float> withCloth = readTexRGB(tex, W, H);
                roots.renderer().uploadClothMesh({});
                id<MTLCommandBuffer> cb3 = [ctx.queue() commandBuffer];
                id<MTLTexture> bare = roots.render(cb3);
                [cb3 commit]; [cb3 waitUntilCompleted];
                const std::vector<float> without = readTexRGB(bare, W, H);
                size_t on = 0, tot = 0;
                for (size_t k = 0; k + 2 < withCloth.size(); k += 3 * 7) {
                    ++tot;
                    const float d = std::fabs(withCloth[k]     - without[k])
                                  + std::fabs(withCloth[k + 1] - without[k + 1])
                                  + std::fabs(withCloth[k + 2] - without[k + 2]);
                    if (d > 1e-3f) ++on;
                }
                printf("TRACE %d %.4f %.4f %.4f\n", f, float(roots.clothClock()),
                       roots.clothClearance(), tot ? double(on) / double(tot) : 0.0);
            }
            if ((f % 20) == 0)
                printf("clothshot: %3d/%d  %-7s press %.2f release %.2f clearance %.3f "
                       "cam r=%.2f t=(%.2f,%.2f,%.2f)\n",
                       f, frames, roots.clothPhaseName(), roots.clothPress(),
                       roots.clothRelease(), roots.clothClearance(),
                       roots.radius, roots.target[0], roots.target[1], roots.target[2]);
        }
    }
    // The sample count is printed because a coverage number measured over zero
    // frames looks exactly like perfect coverage, and the whole reason this
    // metric exists is that a number which quietly stops looking is worse than
    // no number at all.
    printf("clothshot: COVERAGE worst %.2f%% of the border not film, at frame %d, "
           "over %d frames (0%% = the film reaches every edge for the whole "
           "pinned window)\n",
           worstUncovered * 100.0, worstFrame, coverageFrames);
    printf("clothshot: wrote %d frames %s0000.ppm.. (%dx%d @ %.0f fps)\n",
           frames, prefix, W, H, fps);
    return 0;
}
