// dev_tools.h — the headless CLI dev tools main.mm's --flag dispatch calls
// into: benchmarks (bench/rootbench/fieldbench), smoke tests (selftest/
// roottest), and render/diagnostic capture tools (rootshot, growshot,
// leafshot, abshot, maskshot, mirrorclip, transhot, orientshot,
// fieldshot, facetest, taptest, audiotest, textshot, clothshot, seqshot).
//
// None of these touch the live app's per-frame state -- each opens its own
// MetalContext (or none at all) and runs to completion, so they carry no
// dependency on app_state.h beyond what a couple of them call through
// core_frame.h (LoadImageRGB).
#pragma once

#ifndef __OBJC__
#error "dev_tools.h touches Metal types; include from an .mm file"
#endif
#import <Metal/Metal.h>

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

class RootScene;

// Shared with the --fitviewtest diagnostic block still in main.mm.
void writePPM(const char* path, id<MTLTexture> tex, int W, int H);

int  selftest();
int  bench(int downscale, int frames);
int  roottest();
int  rootshot(const char* path, float az, float el, float rad, int mode, bool overlays);
int  growshot(const char* path, int steps, float az, float el, float rad,
              float faceScale = -1.f, float targetY = -1e9f,
              float faceRecess = 1e9f, int W = 960, int H = 540,
              const std::vector<std::pair<std::string, std::string>>& fields = {},
              float zoom = 1.f, float faces = 0.f, unsigned faceSeed = 7u,
              int focus = -1);
int  leafshot(const char* path, int W, int H, float az, float el, float radius);
int  abshot(const char* path, int tranche, int W, int H,
            int focusMask, float zoom, float az, float el, int steps);
int  rootbench(int downscale, int frames, int baseW, int baseH);
int  fieldshot(const char* path, int grid, float az, float el);
int  fieldbench(int grid, int frames);
int  facetest(const char* path);
int  maskshot(const char* photo, const char* out, int fit_steps, int W, int H);
int  mirrorclip(const char* prefix, float secs, const char* photo, int fps,
                 int steps_per_frame);
int  transhot(const char* prefix, int frames, const char* photo, float fps,
              bool align = false, const float reg[4] = nullptr,
              float yawDeg = 14.f);
int  orientshot(const char* prefix, int dw, int dh, int orient);
int  taptest(uint32_t tapId, double seconds);
int  audiotest(double seconds, const char* wav_out);
int  textshot(const char* path, const char* str, float warp,
              float reveal, float softness);
// The cloth press, offscreen, in RootScene's own camera. The eyes-on pass the
// cloth port never got: the live path needs a Kinect, a visitor and a show
// clock, and none of those can be put in front of a compiler. `photo` fits a
// real MirrorScene as the film when given; otherwise the film is a labelled
// grid, which is what actually answers "does the sheet still cover the frame
// and is it still flat" -- a photograph hides both.
int  clothshot(const char* prefix, int frames, int W, int H, float fps,
               const char* photo);
// The timeline from Grow to Orbit, offscreen, retimed short, with stills of
// the Reveal: before anything pops in, half-way (dark and lit structures in
// one frame), all lit, and into the Orbit. Reports the variation bake time.
int  seqshot(const char* prefix, int W, int H,
             const std::vector<std::pair<std::string, std::string>>& fields);
