// mirror_app — unified Metal app hosting the neural mirror and the 3D root scene.
//
// This file is the shell: GLFW window + CAMetalLayer + Dear ImGui (Metal backend)
// + the main loop, adapted from neuromirror/reactor_cpp/src/main.mm. Scenes
// (MirrorScene, MetalRootRenderer) plug into MetalContext and render into offscreen
// textures that get composited here. For now it is a runnable empty-window
// checkpoint that verifies the Metal + GLFW + ImGui + CMake toolchain end to end.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Cocoa/Cocoa.h>

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>

#include "imgui.h"
#include "backends/imgui_impl_glfw.h"
#include "backends/imgui_impl_metal.h"

#include "audio_pulse.h"
#include "metal_context.h"
#include "mirror_scene.h"
#include "fit_target.h"
#include "face_tracker.h"
#include "face_capture.h"
#include "face_track.h"
#include "face_fit.h"
#if MIRROR_HAVE_KINECT
#include "kinect_target.h"
#endif
#include "root_scene.h"
#include "root_sequence.h"
#include "root_face_sequence.h"
#include "transition_scene.h"
#include "fit_view_scene.h"
#include "ui_params.h"
#include "midi_in.h"
#include "fullscreen_present.h"
#include "text_overlay.h"
#include "screen_layout.h"
#include "show_timeline.h"
#include "presence.h"
#include "chord.h"
#include "wwise_audio.h"
#include "LeafMesh.h"
#include "app_state.h"
#include "core_frame.h"
#include "dev_tools.h"
#include "panel.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <type_traits>

// For the panel-height check in --paneltest: the layout cursor is the only
// honest way to ask "did a hidden section draw anyway".
#include "imgui_internal.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

// Headless check of the MLX→Metal texture path (no window): render a few mirror
// frames and read back a pixel. Used to smoke-test without a GUI.

// Benchmark a field with/without culling+LOD. Usage: --fieldbench [grid] [frames]

// Load an image as h*w*3 floats in [0,1] for fitting. NSImage handles whatever
// the user drops in (png/jpeg/heic/tiff), and the explicit bitmap context
// normalises colour space and alpha so the fit target does not silently depend
// on the file's encoding.
// Fit loop settings, shared between the UI and the frame loop.
//
// Two sets, because fitting a face crop and fitting a whole frame are not the
// same problem. A crop is a few percent of the pixels, so a step costs a few
// percent as much and many more of them fit in a frame -- and with that much
// less data behind each gradient, a smaller step keeps it from chasing the
// landmark box's own jitter. The whole feed is the opposite: one expensive step
// per frame, over enough pixels to average out. Sharing one pair of numbers
// meant every crop/no-crop transition silently changed what the numbers meant.
// The grid divisor belongs to the pair for the same reason: a crop of the frame
// at divisor 2 is a few thousand pixels, so it can afford a finer grid than the
// whole feed ever could, and a face is where the detail has to go.

// 0..1 through the ramp; 1 when it is done or not running.
float W0RampT(double now) {
    if (g_w0_t0 < 0.0) return 1.f;
    if (g_w0_ramp_secs <= 0.f) return 1.f;
    return std::min(1.f, (float)((now - g_w0_t0) / g_w0_ramp_secs));
}

// Load a still as the stand-in camera frame. Decoded once at a working size --
// large enough that MediaPipe has a real face to land landmarks on, which the
// fit grid alone would not provide.
bool LoadPhotoSource(const char* path, std::string& err) {
    const int W = 640, H = 480;
    std::vector<float> f;
    if (!LoadImageRGB(path, W, H, f, err)) return false;
    g_photo.resize(f.size());
    for (size_t i = 0; i < f.size(); ++i)
        g_photo[i] = (unsigned char)std::min(255.f, std::max(0.f, f[i] * 255.f + 0.5f));
    g_photo_w = W; g_photo_h = H;
    return true;
}

// Coverage at a normalised point: 1 inside, 0 outside, smooth across the edge.
static float CamMaskAt(float u, float v) {
    if (!g_cam_mask_on) return 1.f;
    const float f = std::max(g_cam_feather, 1e-4f);
    // Distance inside the rectangle on each axis, in normalised units; the
    // nearest edge wins, which rounds the corners slightly at wide feathers.
    const float dx = std::min(u - std::min(g_cam_x0, g_cam_x1),
                              std::max(g_cam_x0, g_cam_x1) - u);
    const float dy = std::min(v - std::min(g_cam_y0, g_cam_y1),
                              std::max(g_cam_y0, g_cam_y1) - v);
    const float d = std::min(dx, dy);
    const float t = std::min(1.f, std::max(0.f, d / f));
    return t * t * (3.f - 2.f * t);
}

static void ApplyCamMaskF(std::vector<float>& rgb, int w, int h,
                          const mirror::DstRect& fill);
static void ApplyCamMaskF(std::vector<float>& rgb, int w, int h) {
    ApplyCamMaskF(rgb, w, h, mirror::DstRect{});
}
static void ApplyCamMaskF(std::vector<float>& rgb, int w, int h,
                          const mirror::DstRect& fill) {
    if (!g_cam_mask_on || w <= 0 || h <= 0 || rgb.size() != size_t(w) * h * 3) return;
    const int x0 = (fill.w > 0) ? std::max(0, fill.x) : 0;
    const int y0 = (fill.h > 0) ? std::max(0, fill.y) : 0;
    const int x1 = (fill.w > 0) ? std::min(w, fill.x + fill.w) : w;
    const int y1 = (fill.h > 0) ? std::min(h, fill.y + fill.h) : h;
    for (int y = y0; y < y1; ++y) {
        const float v = (float(y) + 0.5f) / float(h);
        for (int x = x0; x < x1; ++x) {
            const float m = CamMaskAt((float(x) + 0.5f) / float(w), v);
            if (m >= 1.f) continue;
            float* p = &rgb[(size_t(y) * w + x) * 3];
            p[0] *= m; p[1] *= m; p[2] *= m;
        }
    }
}

static void ApplyCamMask8(std::vector<unsigned char>& rgb, int w, int h) {
    if (!g_cam_mask_on || w <= 0 || h <= 0 || rgb.size() != size_t(w) * h * 3) return;
    for (int y = 0; y < h; ++y) {
        const float v = (float(y) + 0.5f) / float(h);
        for (int x = 0; x < w; ++x) {
            const float m = CamMaskAt((float(x) + 0.5f) / float(w), v);
            if (m >= 1.f) continue;
            unsigned char* p = &rgb[(size_t(y) * w + x) * 3];
            for (int c = 0; c < 3; ++c) p[c] = (unsigned char)(p[c] * m + 0.5f);
        }
    }
}

// `filtered` false takes one source pixel per destination pixel instead of
// averaging the footprint -- for the overlay, which only has to look right.
static bool SourceRGB8(int w, int h, std::vector<unsigned char>& out,
                       bool filtered = true) {
    if (g_source == (int)Source::Photo) {
        if (g_photo.empty()) return false;
        const mirror::SrcRect r =
            mirror::ComputeFeedRect(g_photo_w, g_photo_h, w, h, g_feed);
        if (filtered) {
            mirror::DownsampleRectToRGB8(g_photo.data(), g_photo_w, g_photo_h,
                                         3, 0, 2, r, w, h, out);
        } else {
            mirror::PointSampleRectToRGB8(g_photo.data(), g_photo_w, g_photo_h,
                                          3, 0, 2, r, w, h, out);
        }
        ApplyCamMask8(out, w, h);
        return true;
    }
#if MIRROR_HAVE_KINECT
    if (!g_kinect.lastFrameRGB8(w, h, out, filtered)) return false;
    ApplyCamMask8(out, w, h);
    return true;
#else
    return false;
#endif
}

// `fill` bounds the work to the part of the fit grid the training pass will
// read -- see FitFillRects. An empty rect means the whole frame.
static bool SourceRGBF(int w, int h, std::vector<float>& out,
                       const mirror::DstRect& fill = {}) {
    if (g_source == (int)Source::Photo) {
        if (g_photo.empty()) return false;
        mirror::DownsampleRectRGB8(
            g_photo.data(), g_photo_w, g_photo_h, 3, 0, 2,
            mirror::ComputeFeedRect(g_photo_w, g_photo_h, w, h, g_feed),
            w, h, out, fill);
        ApplyCamMaskF(out, w, h, fill);
        return true;
    }
#if MIRROR_HAVE_KINECT
    if (!g_kinect.lastFrameRGBF(w, h, out, fill)) return false;
    ApplyCamMaskF(out, w, h, fill);
    return true;
#else
    return false;
#endif
}

// Move the source on by one frame without resampling it. Returns true when
// something new arrived -- which is what decides whether the fit gets a new
// target, and therefore whether the resample below is worth doing at all.
static bool SourceAdvance() {
    if (g_source == (int)Source::Photo) return !g_photo.empty();
#if MIRROR_HAVE_KINECT
    return g_kinect.pump();
#else
    return false;
#endif
}

// --- head movement ----------------------------------------------------------
//
// A live fit has to answer a question a still image never poses: the subject
// moves, and the network is a function of position. Three answers, none of them
// strictly better than the others:
//
//   centred     Move the subject to the middle of the frame and fit it there.
//               The network is always shown the same problem, so the weights
//               are as stable as they can be -- at the cost of the mirror no
//               longer showing where in the room anyone is standing.
//   track       Fit the subject where it is. Honest to the camera, and the
//               least stable: a face that walks across the frame is a
//               different function at every step, and the weights spend their
//               capacity re-learning the same face at a new address.
//   stabilised  Fit the subject where it is, but shift the network's *input*
//               coordinates by the head's displacement. The subject stays put
//               in the network's own frame while staying put on screen too --
//               the picture of "track" with the weights of "centred".
//
// The cost sits in different places: centred resamples the image once a frame,
// stabilised rebuilds the fit features once a frame, track does neither.

static void UpdateHeadBox() {
    if (!g_track_on || !g_face.valid) { g_head_valid = false; return; }
    const float cx = g_face.centre_x, cy = g_face.centre_y;
    const float pf = 1.f + std::max(g_crop_pad, 0.f);
    const float hx = 0.5f * (g_face.max_x - g_face.min_x) * pf;
    const float hy = 0.5f * (g_face.max_y - g_face.min_y) * pf;
    if (!g_head_valid) {   // first detection: snap, do not ease in from nowhere
        g_head_cx = cx; g_head_cy = cy; g_head_hx = hx; g_head_hy = hy;
        g_head_valid = true;
        return;
    }
    const float a = std::min(1.f, std::max(0.01f, g_head_smooth));
    g_head_cx += a * (cx - g_head_cx);
    g_head_cy += a * (cy - g_head_cy);
    g_head_hx += a * (hx - g_head_hx);
    g_head_hy += a * (hy - g_head_hy);
}

// Defined below, next to the placement it describes: the mask and the region
// both need it, and both are built before it.
static void PinTransform(float& scale, float& u, float& v);

// --- the show's two derived signals -----------------------------------------
//
// Both are levels, sampled every frame; the debounce that turns them into
// events lives in show::Timeline, not here. Deliberately: "how long must a face
// be gone before the piece lets go" is a decision about the room, and belongs
// in the script next to the phase it governs.

// Someone is in front of the piece. `g_face.valid` already survives short
// detection misses (the acquire/hold logic above), so this is the honest
// per-frame answer and the script's `hold` covers the rest.
bool ShowFacePresent() {
    return g_track_on && g_face.valid;
}

// The neural (CPPN/pond) fit has actually captured this face -- not the mesh
// fit, which only ever runs once to personalize the Roots-phase mesh and
// never gates anything here. `g_fit_level_now` lags this frame's training
// step by one frame (see where it's written); at 60 fps that is not a
// meaningful delay against the `fit_hold` debounce the script applies to this
// signal, which is what actually earns "confident" against a score this noisy.
bool ShowFitConverged() {
    return g_track_on && g_face.valid && g_fit_level_now >= g_show_fit_score;
}

// Is there a face to narrow the fit to at all?
bool HaveCrop() {
    return g_mask_fit && g_track_on && g_face.valid && g_head_valid;
}

// Where the crop lands in the frame, normalised. Everything but the centred
// mode leaves the subject where the camera found it.
static float CropCX() {
    return g_head_mode == (int)HeadMode::Centred ? 0.5f : g_head_cx;
}
static float CropCY() {
    return g_head_mode == (int)HeadMode::Centred ? 0.5f : g_head_cy;
}

// Which pixels of the fit grid the live target supervises.
//
// The rule the app is built around: fit the video feed, and narrow to the face
// only when there actually is one. So an empty mask (false) is not a failure
// state -- it is the normal case of "no face tracked, fit the whole frame", and
// it is what the fit falls back to the moment someone leaves the room.
static bool BuildFitMask(int fw, int fh, std::vector<unsigned char>& mask) {
    if (!HaveCrop()) return false;
    // The same similarity the pixels were placed by -- the mask marks which of
    // them are trained, so it has to land on top of them exactly.
    float s = 1.f, ou = 0.f, ov = 0.f;
    PinTransform(s, ou, ov);
    if (g_mask_shape == (int)MaskShape::Hull) {
        // The hull moves with the pixels: in the centred mode the image was
        // resampled under it, so landmarks left where they were detected would
        // cut a face-shaped hole out of the background.
        std::vector<mirror::FaceLandmark> lm = g_face.landmarks;
        if (s != 1.f || ou != 0.f || ov != 0.f)
            for (mirror::FaceLandmark& L : lm) {
                L.x = L.x * s + ou;
                L.y = L.y * s + ov;
            }
        mirror::RasteriseFaceMask(lm, mirror::FaceOvalIndices(), fw, fh,
                                  g_mask_dilate, mask);
    } else {
        // Built from the *smoothed* box rather than the raw landmarks, so the
        // trained pixel set stops flickering between frames -- a mask whose
        // area changes forces the optimiser's feature gather to rebuild.
        mirror::RasteriseBox(g_head_cx * s + ou, g_head_cy * s + ov,
                             g_head_hx * s, g_head_hy * s,
                             fw, fh, g_mask_dilate, mask);
    }
    return true;
}

static void ScanMaskBBox(const std::vector<unsigned char>& mask, int fw, int fh,
                         mirror::DstRect& out) {
    out = mirror::DstRect{};
    if (fw <= 0 || fh <= 0 || mask.size() != size_t(fw) * fh) return;
    int x0 = fw, y0 = fh, x1 = -1, y1 = -1;
    for (int y = 0; y < fh; ++y) {
        const unsigned char* row = &mask[size_t(y) * fw];
        for (int x = 0; x < fw; ++x) {
            if (!row[x]) continue;
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            y1 = y;
        }
    }
    if (x1 < x0 || y1 < y0) return;
    out = mirror::DstRect{x0, y0, x1 - x0 + 1, y1 - y0 + 1};
}

static void ApplyHeadMode(mirror::PondParams& P, int fw, int fh) {
    P.coord_off_x = P.coord_off_y = 0.f;
    P.region.on = false;
    P.region.use_field = false;
    P.z_free_outside = g_z_free;
    P.grey_outside = g_grey_out;
    g_have_mask = false;
    g_mask_bbox = mirror::DstRect{};
    if (!HaveCrop() || fw <= 0 || fh <= 0) return;

    const float asp = float(fw) / float(fh);
    if (g_head_mode == (int)HeadMode::Stabilised) {
        // Coord space spans (-asp, asp) x (-1, 1) over the frame, so a
        // normalised displacement doubles going in.
        P.coord_off_x = (g_head_cx - 0.5f) * 2.f * asp;
        P.coord_off_y = (g_head_cy - 0.5f) * 2.f;
    }

    // Built here rather than at the point of use so the render's soft edge and
    // the training mask are the same shape by construction -- the edge is
    // supposed to mark where supervision stops, and deriving it separately
    // would let the two drift.
    g_have_mask = BuildFitMask(fw, fh, g_fit_mask);
    if (g_have_mask) ScanMaskBBox(g_fit_mask, fw, fh, g_mask_bbox);
    else             g_mask_bbox = mirror::DstRect{};
    if (!g_region_on) return;

    P.region.on = true;
    if (g_region_hull && g_have_mask) {
        // Distance outward from the mask itself, so the fade follows a face
        // outline when the mask is a hull. One coord unit is fh/2 pixels
        // (y spans -1..1 over the grid), and x uses the same scale because the
        // grid's x range is the aspect ratio -- so a single conversion is right
        // for both axes, which is exactly why the fade band comes out the same
        // width in every direction.
        mirror::DistanceOutside(g_fit_mask, fw, fh, g_region_dist);
        const float per_px = 2.f / float(fh);
        P.region_field.resize(g_region_dist.size());
        for (size_t i = 0; i < g_region_dist.size(); ++i)
            P.region_field[i] = g_region_dist[i] * per_px;
        P.region.use_field = true;
        P.region.fw = fw;
        P.region.fh = fh;
        P.region.ax = asp;
    } else {
        float s = 1.f, ou = 0.f, ov = 0.f;
        PinTransform(s, ou, ov);
        P.region.cx = ((g_head_cx * s + ou) - 0.5f) * 2.f * asp;
        P.region.cy = ((g_head_cy * s + ov) - 0.5f) * 2.f;
        P.region.hx = g_head_hx * s * 2.f * asp;
        P.region.hy = g_head_hy * s * 2.f;
    }
    P.region.fade_start = g_fade_start;
    P.region.fade_width = std::max(0.01f, g_fade_width);
}

// Where the subject is put, and how big.
//
// One function because the two are one resampling. Setting a size used to imply
// centring, which is two wishes welded together: you could only have "make them
// bigger" by also accepting "and move them to the middle". They are separate
// here -- the centred mode pins the destination to the middle of the frame,
// every other mode leaves the subject where the camera found it and only
// changes the scale.
//
// Returns false when there is nothing to do, which is the common case and worth
// distinguishing: an identity placement still costs a full bilinear resample of
// the frame, and one that resamples the face every frame is precisely the noise
// the whole-pixel shift exists to avoid.
static bool HeadPlacement(float& s, float& dcx, float& dcy) {
    s = 1.f;
    dcx = dcy = 0.5f;
    if (!HaveCrop()) return false;
    const bool centred = (g_head_mode == (int)HeadMode::Centred);
    // Not in the input-shift mode: that one moves the network's coordinates and
    // the render undoes it again, so resampling the pixels underneath would be
    // two placements arguing.
    const bool resize = g_face_size_on &&
                        g_head_mode != (int)HeadMode::Stabilised;
    if (!centred && !resize) return false;

    if (resize)
        s = std::min(6.f, std::max(0.1f, g_face_size / std::max(g_head_hy, 1e-3f)));

    if (!centred) {
        // Stay where they are -- but a scaled crop can run off the edge, and a
        // subject half outside the frame is half unsupervised. Clamped by the
        // scaled half-extent, so the box slides inward only as far as it must.
        // A subject too big to fit is centred instead, which is the only
        // placement that keeps as much of them as possible.
        const float hx = g_head_hx * s, hy = g_head_hy * s;
        dcx = (hx >= 0.5f) ? 0.5f
                           : std::min(std::max(g_head_cx, hx), 1.f - hx);
        dcy = (hy >= 0.5f) ? 0.5f
                           : std::min(std::max(g_head_cy, hy), 1.f - hy);
        // No scale change and no move: nothing worth a resample.
        if (s == 1.f) return false;
    }
    return true;
}

// The scale the placement is currently applying, for the panel's readout.
float PlaceScale() {
    float s = 1.f, dcx = 0.5f, dcy = 0.5f;
    HeadPlacement(s, dcx, dcy);
    return s;
}

// Where the fit drew the face, relative to where the tracker saw it, in
// normalised units: uv_drawn = uv_tracked * scale + (u, v).
//
// This is the pin. The landmarks are in camera space, the rendered face is
// wherever the head mode put it, and anything that reads the render at a
// landmark position -- the mask's texture, a drawn overlay of the mesh -- has
// to cross that gap or it samples the wrong pixels entirely.
static void PinTransform(float& scale, float& u, float& v) {
    scale = 1.f;
    u = v = 0.f;
    float s = 1.f, dcx = 0.5f, dcy = 0.5f;
    if (!HeadPlacement(s, dcx, dcy)) return;
    // The same map PlaceLiveFrame applies, written the other way round:
    // dest = (src - src_c) * s + dst_c  ==  src * s + (dst_c - s * src_c).
    scale = s;
    u = dcx - g_head_cx * s;
    v = dcy - g_head_cy * s;
}

// Place the subject for the centred mode. At scale 1 this is a whole-pixel
// shift, which is what the mode wants -- resampling the face every frame is
// precisely the noise it exists to remove. Asking for a specific size makes
// interpolation unavoidable, so that path costs a bilinear resample and says so.
static void PlaceLiveFrame(std::vector<float>& rgb, int fw, int fh,
                           const mirror::DstRect& fill) {
    float s = 1.f, dcx = 0.5f, dcy = 0.5f;
    if (!HeadPlacement(s, dcx, dcy)) return;
    if (s == 1.f) {
        // A pure move: whole pixels, no interpolation. Resampling the face
        // every frame is the noise this mode exists to remove.
        mirror::ShiftRGBF(fw, fh, (int)std::lround((dcx - g_head_cx) * fw),
                          (int)std::lround((dcy - g_head_cy) * fh), rgb, fill);
    } else {
        mirror::PlaceRGBF(fw, fh, g_head_cx, g_head_cy, s, dcx, dcy, rgb, fill);
    }
}

// The two rects the live frame needs this frame: `read` is what the training
// pass will look at, `resample` is what has to be produced to satisfy it.
//
// They differ only in the head-centred mode, which moves the pixels after the
// resample: the mask is built at the *pinned* position, so the pixels feeding
// it come from the crop's real position -- the mask rect shifted back by the
// displacement the placement is about to apply.
//
// Returns false when the whole frame is needed, which is the honest answer
// whenever there is no crop (the fit trains on everything) and whenever the
// placement resamples rather than shifts (bilinear scatters its reads).
static bool FitFillRects(int fw, int fh, mirror::DstRect& resample,
                         mirror::DstRect& read) {
    if (!g_have_mask || g_mask_bbox.w <= 0 || g_mask_bbox.h <= 0) return false;

    // A margin against the rounding in the shift below and in the rasteriser.
    const int m = 2;
    read = mirror::DstRect{g_mask_bbox.x - m, g_mask_bbox.y - m,
                           g_mask_bbox.w + 2 * m, g_mask_bbox.h + 2 * m};

    float s = 1.f, dcx = 0.5f, dcy = 0.5f;
    if (!HeadPlacement(s, dcx, dcy)) {
        resample = read;                        // nothing moves the pixels
        return true;
    }
    if (s != 1.f) return false;                 // bilinear: reads everywhere

    const int dx = (int)std::lround((dcx - g_head_cx) * fw);
    const int dy = (int)std::lround((dcy - g_head_cy) * fh);
    resample = mirror::DstRect{read.x - dx, read.y - dy, read.w, read.h};
    return true;
}

bool SourceReady() {
    if (g_source == (int)Source::Photo) return !g_photo.empty();
#if MIRROR_HAVE_KINECT
    return g_kinect.isOpen();
#else
    return false;
#endif
}

bool LoadImageRGB(const char* path, int w, int h,
                         std::vector<float>& out, std::string& err) {
    @autoreleasepool {
        NSString* p = [NSString stringWithUTF8String:path];
        NSImage* img = [[NSImage alloc] initWithContentsOfFile:p];
        if (!img) { err = std::string("could not open ") + path; return false; }
        CGImageRef cg = [img CGImageForProposedRect:nil context:nil hints:nil];
        if (!cg) { err = "could not decode image"; return false; }

        std::vector<uint8_t> rgba(size_t(w) * h * 4, 0);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(
            rgba.data(), w, h, 8, size_t(w) * 4, cs,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (!ctx) { err = "could not create bitmap context"; return false; }
        // Aspect-preserving, centred. Stretching to fill would deform the face,
        // and the fit would then dutifully recover a squashed identity --
        // FHIBE's crops are square while the working canvas is 4:3, so this is
        // not a hypothetical.
        const double iw = double(CGImageGetWidth(cg)), ih = double(CGImageGetHeight(cg));
        double dw = w, dh = h;
        if (iw > 0 && ih > 0) {
            const double s = std::min(double(w) / iw, double(h) / ih);
            dw = iw * s; dh = ih * s;
        }
        CGContextDrawImage(ctx, CGRectMake((w - dw) * 0.5, (h - dh) * 0.5, dw, dh), cg);
        CGContextRelease(ctx);

        out.resize(size_t(w) * h * 3);
        for (size_t i = 0; i < size_t(w) * h; ++i) {
            for (int c = 0; c < 3; ++c) out[i * 3 + c] = rgba[i * 4 + c] / 255.0f;
        }
        return true;
    }
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        // Where the panel starts. The installation runs with the display
        // fullscreen and the operator on a laptop, so that setup wants the
        // panel out of the frame from the first frame rather than after a
        // click; both are also toggles in the panel and on F1.
        if (a == "--reset-panel")  { g_panel_reset = true; g_panel_cli = true; continue; }
        if (a == "--panel-window") { g_ui_detached = true; g_panel_cli = true; continue; }
        if (a == "--no-panel")     { g_ui_visible = false; continue; }
        // Fullscreen is the default now (see app_state.mm); --fullscreen is
        // kept accepted, as a no-op, so existing launch scripts and the
        // launchd plist keep working unchanged. --windowed is the dev-build
        // opt-out, a 1280x720 titled window instead of the primary monitor.
        if (a == "--fullscreen")   { g_fullscreen = true; continue; }
        if (a == "--windowed")     { g_fullscreen = false; continue; }
#if MIRROR_HAVE_KINECT
        if (a == "--no-sensor")    { g_open_sensor = false; continue; }
#endif
        // Write the settings document and quit. It has to run the real panel
        // for a frame -- the registry *is* the panel -- but only one, because
        // declaring no longer depends on what is open or which scene is up.
        if (a == "--settings-doc") { g_write_settings_doc = true; continue; }
        // The panel drew what it should and nothing else. Separate from
        // --uitest because it needs the real panel: the failure it exists for
        // is a section that declares correctly and then draws when it should
        // not, which no count of parameters can see.
        if (a == "--paneltest") {
            g_panel_test = true;
            ui::SetIdCollisionProbe(true);
            continue;
        }
        if (a == "--selftest") return selftest();
        if (a == "--roottest") return roottest();
        // --transalign <photo> <out.ppm> [scaleX scaleY offX offY]
        //
        // One frame of the alignment hold, for setting the mask's registration
        // against a still. See TransitionScene::maskScale.
        if (a == "--transalign") {
            const char* photo = (i + 1 < argc) ? argv[i + 1] : "";
            const char* out   = (i + 2 < argc) ? argv[i + 2] : "transalign.ppm";
            float reg[4] = {1.f, 1.f, 0.f, 0.f};
            for (int k = 0; k < 4; ++k)
                if (i + 3 + k < argc) reg[k] = (float)atof(argv[i + 3 + k]);
            printf("transalign: scale (%.3f, %.3f) offset (%+.3f, %+.3f)\n",
                   reg[0], reg[1], reg[2], reg[3]);
            // One frame is all it is; the prefix path is reused so the shot
            // lands on the exact same pipeline the clip does.
            std::string pre(out);
            const size_t dot = pre.rfind(".ppm");
            if (dot != std::string::npos) pre = pre.substr(0, dot);
            return transhot(pre.c_str(), 1, photo, 30.f, /*align=*/true, reg, /*yawDeg=*/0.f);
        }
        if (a == "--transhot") {
            const char* prefix = (i + 1 < argc) ? argv[i + 1] : "trans_";
            int n = (i + 2 < argc) ? atoi(argv[i + 2]) : 150;
            const char* photo = (i + 3 < argc) ? argv[i + 3] : "";
            float fps = (i + 4 < argc) ? (float)atof(argv[i + 4]) : 30.f;
            // Degrees of test yaw; 0 for a head-on still.
            float yaw = (i + 5 < argc) ? (float)atof(argv[i + 5]) : 14.f;
            return transhot(prefix, n, photo, fps, false, nullptr, yaw);
        }
        if (a == "--orientshot") {
            const char* pre = (i + 1 < argc) ? argv[i + 1] : "orient";
            int ow = (i + 2 < argc) ? atoi(argv[i + 2]) : 1080;
            int oh = (i + 3 < argc) ? atoi(argv[i + 3]) : 1920;
            int oo = (i + 4 < argc) ? atoi(argv[i + 4]) : 0;   // 0 auto 1 land 2 port
            return orientshot(pre, ow, oh, oo);
        }
        if (a == "--textshot") {
            const char* out = (i + 1 < argc) ? argv[i + 1] : "text.ppm";
            const char* str = (i + 2 < argc) ? argv[i + 2] : "";
            float warp = (i + 3 < argc) ? (float)atof(argv[i + 3]) : 0.08f;
            float reveal = (i + 4 < argc) ? (float)atof(argv[i + 4]) : 1.f;
            float soft = (i + 5 < argc) ? (float)atof(argv[i + 5]) : 1.f;
            return textshot(out, str, warp, reveal, soft);
        }
        if (a == "--taptest") {
            const uint32_t tap = (i + 1 < argc) ? (uint32_t)atoi(argv[i + 1]) : 0;
            const double secs = (i + 2 < argc) ? atof(argv[i + 2]) : 10.0;
            return taptest(tap, secs);
        }
        if (a == "--audiotest") {
            const double secs = (i + 1 < argc) ? atof(argv[i + 1]) : 30.0;
            const char* wav = (i + 2 < argc) ? argv[i + 2] : nullptr;
            return audiotest(secs, wav);
        }
        if (a == "--fitviewtest") {
            // The fit view's shaders are loaded from disk at run time, so a
            // clean compile of the app says nothing about whether they work.
            // This builds the scene, feeds it a mask and a mesh, renders, and
            // reads a pixel back -- enough to catch a shader that does not
            // compile, a pipeline that fails to build, and a pass that draws
            // nothing at all.
            MetalContext ctx;
            if (!ctx.device()) { fprintf(stderr, "fitviewtest: no Metal device\n"); return 1; }
            const int W = 320, H = 240;
            FitViewScene fv(ctx, std::string(MIRROR_APP_SHADER_DIR) + "/fit_view.metal", W, H);
            if (!fv.valid()) { fprintf(stderr, "fitviewtest: pipelines failed\n"); return 1; }

            // A background that is not black, so "drew nothing" and "drew the
            // background" are distinguishable in the readback.
            MTLTextureDescriptor* td =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                   width:W height:H mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> bg = [ctx.device() newTextureWithDescriptor:td];
            std::vector<uint16_t> px(size_t(W) * H * 4, 0x3400);   // ~0.25 in fp16
            [bg replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0
                    withBytes:px.data() bytesPerRow:size_t(W) * 8];
            fv.setBackground(bg);

            std::vector<unsigned char> mask(size_t(64) * 48, 0);
            for (int y = 12; y < 36; ++y)
                for (int x = 16; x < 48; ++x) mask[size_t(y) * 64 + x] = 1;
            fv.setMask(mask, 64, 48);

            // One big red triangle across the middle of the frame.
            const std::vector<float> uv = {0.3f, 0.3f, 0.7f, 0.3f, 0.5f, 0.7f};
            const std::vector<float> rgb = {1.f, 0.f, 0.f, 1.f, 0.f, 0.f, 1.f, 0.f, 0.f};
            const std::vector<int> tris = {0, 1, 2};
            fv.setMesh(uv, rgb, tris);

            id<MTLTexture> out = nil;
            {
                id<MTLCommandBuffer> cb = [ctx.queue() commandBuffer];
                out = fv.render(cb);
                [cb commit];
                [cb waitUntilCompleted];
            }
            if (!out) { fprintf(stderr, "fitviewtest: render returned nil\n"); return 1; }
            writePPM("fitview.ppm", out, W, H);

            // Read back three pixels that must differ from each other: bare
            // background, background under the mask tint, and the mesh. Only
            // checking that *something* rendered would miss the failure this
            // was written for -- a vertex-layout mismatch drops the mesh while
            // leaving every other layer perfect.
            auto probe = [&](int x, int y) {
                uint16_t p[4] = {0, 0, 0, 0};
                [out getBytes:p bytesPerRow:sizeof(p)
                   fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
                auto h2f = [](uint16_t h) {
                    uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
                    if (e == 0) bits = (s << 31); else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
                    float f; __builtin_memcpy(&f, &bits, 4); return f;
                };
                return simd_make_float3(h2f(p[0]), h2f(p[1]), h2f(p[2]));
            };
            const simd_float3 bare = probe(5, 5);            // outside everything
            const simd_float3 masked = probe(100, 150);      // mask, below the mesh
            const simd_float3 mesh = probe(160, 120);        // inside the triangle
            printf("fitviewtest: bg %.3f %.3f %.3f | mask %.3f %.3f %.3f | "
                   "mesh %.3f %.3f %.3f\n",
                   bare.x, bare.y, bare.z, masked.x, masked.y, masked.z,
                   mesh.x, mesh.y, mesh.z);

            int fail = 0;
            if (!(bare.x > 0.2f && bare.x < 0.3f)) {
                fprintf(stderr, "fitviewtest: background did not render\n"); ++fail;
            }
            if (!(masked.y > bare.y + 0.05f)) {
                fprintf(stderr, "fitviewtest: mask overlay missing\n"); ++fail;
            }
            if (!(mesh.x > 0.8f && mesh.y < 0.2f && mesh.z < 0.2f)) {
                fprintf(stderr, "fitviewtest: mesh did not draw (expected red)\n"); ++fail;
            }
            printf("fitviewtest: %s\n", fail ? "FAIL" : "OK");
            return fail ? 1 : 0;
        }
        if (a == "--maskshot") {
            const char* photo = (i + 1 < argc) ? argv[i + 1]
                                : NEUROMIRROR_DIR "/emotion/_track_frames/f0016.png";
            const char* out = (i + 2 < argc) ? argv[i + 2] : "maskshot.ppm";
            int steps = (i + 3 < argc) ? atoi(argv[i + 3]) : 800;
            int mw = (i + 4 < argc) ? atoi(argv[i + 4]) : 640;
            int mh = (i + 5 < argc) ? atoi(argv[i + 5]) : 480;
            return maskshot(photo, out, steps, mw, mh);
        }
        if (a == "--mirrorclip") {
            const char* prefix = (i + 1 < argc) ? argv[i + 1] : "mirror_";
            float secs = (i + 2 < argc) ? (float)atof(argv[i + 2]) : 5.f;
            const char* photo = (i + 3 < argc) ? argv[i + 3] : "";
            int fps = (i + 4 < argc) ? atoi(argv[i + 4]) : 30;
            int spf = (i + 5 < argc) ? atoi(argv[i + 5]) : 12;
            return mirrorclip(prefix, secs, photo, fps, spf);
        }
        if (a == "--facetest") {
            return facetest(i + 1 < argc
                                ? argv[i + 1]
                                : NEUROMIRROR_DIR "/emotion/_track_frames/f0016.png");
        }
        if (a == "--fieldshot") {
            const char* path = (i + 1 < argc) ? argv[i + 1] : "field.ppm";
            int grid = (i + 2 < argc) ? atoi(argv[i + 2]) : 6;
            float az = (i + 3 < argc) ? atof(argv[i + 3]) : 0.5f;
            float el = (i + 4 < argc) ? atof(argv[i + 4]) : 0.35f;
            return fieldshot(path, grid, az, el);
        }
        if (a == "--fieldbench") {
            int grid = (i + 1 < argc) ? atoi(argv[i + 1]) : 8;
            int fr   = (i + 2 < argc) ? atoi(argv[i + 2]) : 100;
            return fieldbench(grid, fr);
        }
        if (a == "--rootbench") {
            int ds = (i + 1 < argc) ? atoi(argv[i + 1]) : 1;
            int fr = (i + 2 < argc) ? atoi(argv[i + 2]) : 200;
            int bw = (i + 3 < argc) ? atoi(argv[i + 3]) : 1920;
            int bh = (i + 4 < argc) ? atoi(argv[i + 4]) : 1080;
            return rootbench(ds, fr, bw, bh);
        }
        if (a == "--growshot") {
            // Positional args stop at the first key=value: the growth fields
            // are optional and there are twenty-odd of them, so they are named
            // rather than counted.
            std::vector<std::string> pos;
            std::vector<std::pair<std::string, std::string>> fields;
            int gw = 960, gh = 540;
            float gzoom = 1.f, gfaces = 0.f;
            unsigned gfaceSeed = 7u;
            int gfocus = -1;
            for (int j = i + 1; j < argc; ++j) {
                std::string t = argv[j];
                const size_t eq = t.find('=');
                if (eq == std::string::npos) { pos.push_back(t); continue; }
                std::string k = t.substr(0, eq), v = t.substr(eq + 1);
                if (k == "w") gw = atoi(v.c_str());
                else if (k == "h") gh = atoi(v.c_str());
                else if (k == "zoom") gzoom = (float)atof(v.c_str());
                else if (k == "faces") gfaces = (float)atof(v.c_str());
                else if (k == "facesSeed") gfaceSeed = (unsigned)strtoul(v.c_str(), nullptr, 10);
                else if (k == "focus") gfocus = atoi(v.c_str());
                else fields.emplace_back(k, v);
            }
            auto at = [&](size_t n) { return n < pos.size() ? pos[n].c_str() : nullptr; };
            const char* path = at(0) ? at(0) : "grow.ppm";
            int steps = at(1) ? atoi(at(1)) : 400;
            float az  = at(2) ? atof(at(2)) : 0.6f;
            float el  = at(3) ? atof(at(3)) : 0.2f;
            float rad = at(4) ? atof(at(4)) : -1.f;
            float fs2 = at(5) ? atof(at(5)) : -1.f;
            float ty2 = at(6) ? atof(at(6)) : -1e9f;
            float rc2 = at(7) ? atof(at(7)) : 1e9f;
            return growshot(path, steps, az, el, rad, fs2, ty2, rc2, gw, gh,
                            fields, gzoom, gfaces, gfaceSeed, gfocus);
        }
        if (a == "--leafshot") {
            const char* path = (i + 1 < argc) ? argv[i + 1] : "leaf.ppm";
            int   W  = (i + 2 < argc) ? atoi(argv[i + 2]) : 1000;
            int   H  = (i + 3 < argc) ? atoi(argv[i + 3]) : 1000;
            float az = (i + 4 < argc) ? atof(argv[i + 4]) : 0.6f;
            float el = (i + 5 < argc) ? atof(argv[i + 5]) : 0.18f;
            float rd = (i + 6 < argc) ? atof(argv[i + 6]) : -1.f;
            return leafshot(path, W, H, az, el, rd);
        }
        if (a == "--abshot") {
            const char* path = (i + 1 < argc) ? argv[i + 1] : "ab.ppm";
            int   tr = (i + 2 < argc) ? atoi(argv[i + 2]) : 3;
            int   W  = (i + 3 < argc) ? atoi(argv[i + 3]) : 1920;
            int   H  = (i + 4 < argc) ? atoi(argv[i + 4]) : 1080;
            int   fm = (i + 5 < argc) ? atoi(argv[i + 5]) : -1;
            float zm = (i + 6 < argc) ? atof(argv[i + 6]) : 1.0f;
            float az = (i + 7 < argc) ? atof(argv[i + 7]) : 0.6f;
            float el = (i + 8 < argc) ? atof(argv[i + 8]) : 0.2f;
            int   st = (i + 9 < argc) ? atoi(argv[i + 9]) : 1200;
            return abshot(path, tr, W, H, fm, zm, az, el, st);
        }
        if (a == "--uitest") {
            // The parameter registry, headless. ImGui runs without a backend
            // as long as it has a display size and a built font atlas, which
            // is enough to exercise declaration, MIDI routing and preset I/O --
            // all three of which fail *silently* when they fail.
            IMGUI_CHECKVERSION();
            ImGui::CreateContext();
            ImGuiIO& io = ImGui::GetIO();
            io.DisplaySize = ImVec2(400, 400);
            io.Fonts->Build();
            unsigned char* tex_px; int tex_w, tex_h;
            io.Fonts->GetTexDataAsRGBA32(&tex_px, &tex_w, &tex_h);
            io.Fonts->SetTexID((ImTextureID)1);

            float amp = 0.5f, gain = 2.0f;
            int   steps = 4;
            bool  flag = false;
            // Behind a header that is never opened, and behind a gate that is
            // switched off: the two ways a control used to fall out of the
            // registry entirely.
            float buried = 0.5f;
            float gated  = 0.5f;
            bool  gate_on = true;

            // One frame of the panel, declaring six controls in two sections.
            auto frame = [&]() {
                ImGui::NewFrame();
                ui::BeginFrame();
                ImGui::Begin("t");
                {
                    ui::Section a("mirror");
                    ui::SliderFloat("amp", &amp, 0.f, 1.f);
                    ui::SliderInt("steps", &steps, 0, 10);
                    ui::Checkbox("flag", &flag);
                    // A collapsing header in a headless frame is never open,
                    // so this is the collapsed case by construction.
                    ui::BeginHeader("folded");
                    ui::SliderFloat("buried", &buried, 0.f, 1.f);
                    ui::EndHeader();
                    ui::BeginGate(gate_on);
                    ui::SliderFloat("gated", &gated, 0.f, 1.f);
                    ui::EndGate();
                }
                {
                    ui::Section b("roots");
                    ui::SliderFloat("amp", &gain, 0.f, 4.f);   // same label, other section
                }
                ImGui::End();
                ImGui::Render();
            };
            frame();
            int bad = 0;
            if (ui::DeclaredCount() != 6) {
                printf("  declared %d, want 6\n", ui::DeclaredCount()); ++bad;
            }
            // Drawing and declaring are separate: neither the header nor the
            // gate may add a level to a parameter's name, or every preset ever
            // written stops finding it.
            {
                std::string err;
                const std::string p = ui::PresetDir() + "/__uinames.set";
                if (!ui::SavePreset(p, err)) { printf("  name save: %s\n", err.c_str()); ++bad; }
                std::ifstream f(p);
                std::string all, line;
                while (std::getline(f, line)) all += line + "\n";
                f.close();
                if (all.find("p mirror/buried = ") == std::string::npos) {
                    printf("  a folded control did not save under its own name\n"); ++bad;
                }
                if (all.find("p mirror/gated = ") == std::string::npos) {
                    printf("  a gated control did not save under its own name\n"); ++bad;
                }
                remove(p.c_str());
            }
            // The bug this split exists to kill: a value loaded for a control
            // that is not on screen must still land, and a save must not write
            // that control from a stale cache.
            {
                std::string err;
                const std::string p = ui::PresetDir() + "/__uihidden.set";
                buried = 0.8f; gated = 0.9f;
                gate_on = false;                 // and now the gate is shut
                frame();
                if (!ui::SavePreset(p, err)) { printf("  hidden save: %s\n", err.c_str()); ++bad; }
                buried = 0.f; gated = 0.f;
                frame();
                if (!ui::LoadPreset(p, err)) { printf("  hidden load: %s\n", err.c_str()); ++bad; }
                frame();
                if (std::fabs(buried - 0.8f) > 1e-4f) {
                    printf("  folded control did not take a loaded value: %.3f\n", buried);
                    ++bad;
                }
                if (std::fabs(gated - 0.9f) > 1e-4f) {
                    printf("  gated-off control did not take a loaded value: %.3f\n", gated);
                    ++bad;
                }
                remove(p.c_str());
                gate_on = true;
                buried = 0.5f; gated = 0.5f;
                frame();
            }
            // Banks come from the section, and a bank's file holds only its
            // own keys -- a mirror preset that carried machine settings would
            // rewire the room every time it loaded.
            {
                std::string err;
                const std::string p = ui::PresetDir() + "/__uibank.mirror";
                if (!ui::SaveBank(ui::Bank::Mirror, p, err)) {
                    printf("  bank save: %s\n", err.c_str()); ++bad;
                }
                std::ifstream f(p);
                std::string all, line;
                while (std::getline(f, line)) all += line + "\n";
                f.close();
                if (all.find("p mirror/amp") == std::string::npos) {
                    printf("  mirror bank is missing its own parameter\n"); ++bad;
                }
                if (all.find("p roots/") != std::string::npos) {
                    printf("  mirror bank leaked a roots parameter\n"); ++bad;
                }
                remove(p.c_str());
            }

            // Bind mirror/amp to cc 7 and sweep it. The two "amp" controls
            // share a label and must not share a binding -- that collision is
            // the whole reason parameters are named by section.
            ui::SetLearnTarget("mirror/amp");
            ui::ApplyCC(0, 7, 64);              // consumed by learn, not applied
            if (ui::BindingCount() != 1) { printf("  learn did not bind\n"); ++bad; }
            if (std::fabs(amp - 0.5f) > 1e-6f) {
                printf("  learn moved the value (%.3f); it should only bind\n", amp); ++bad;
            }
            ui::ApplyCC(0, 7, 127);
            frame();
            if (std::fabs(amp - 1.0f) > 1e-3f) { printf("  cc did not apply: %.3f\n", amp); ++bad; }
            if (std::fabs(gain - 2.0f) > 1e-6f) {
                printf("  cc leaked to the same label in another section\n"); ++bad;
            }
            ui::ApplyCC(0, 7, 0);
            frame();
            if (std::fabs(amp) > 1e-3f) { printf("  cc floor wrong: %.3f\n", amp); ++bad; }
            // A different cc must do nothing.
            ui::ApplyCC(0, 9, 127);
            frame();
            if (std::fabs(amp) > 1e-3f) { printf("  unbound cc moved a value\n"); ++bad; }

            // Preset round-trip, including the binding.
            amp = 0.25f; gain = 3.5f; steps = 9; flag = true;
            frame();
            const std::string path = ui::PresetDir() + "/__uitest.set";
            std::string err;
            if (!ui::SavePreset(path, err)) { printf("  save: %s\n", err.c_str()); ++bad; }
            amp = 0.f; gain = 0.f; steps = 0; flag = false;
            ui::ClearAllBindings();
            frame();
            if (!ui::LoadPreset(path, err)) { printf("  load: %s\n", err.c_str()); ++bad; }
            frame();                            // values land as controls declare
            if (std::fabs(amp - 0.25f) > 1e-4f) { printf("  amp %.4f != 0.25\n", amp); ++bad; }
            if (std::fabs(gain - 3.5f) > 1e-4f) { printf("  gain %.4f != 3.5\n", gain); ++bad; }
            if (steps != 9) { printf("  steps %d != 9\n", steps); ++bad; }
            if (!flag) { printf("  flag did not restore\n"); ++bad; }
            if (ui::BindingCount() != 1) { printf("  binding not restored\n"); ++bad; }
            if (!ui::UnclaimedKeys().empty()) {
                printf("  %zu unclaimed keys after a self-written preset\n",
                       ui::UnclaimedKeys().size());
                ++bad;
            }
            // An unknown key is reported, not fatal, and must not disturb
            // anything real.
            {
                std::ofstream f(path);
                f << "p mirror/amp = 0.75\n";
                f << "p mirror/gone = 1\n";
            }
            gain = 1.25f;
            if (!ui::LoadPreset(path, err)) { printf("  partial load failed\n"); ++bad; }
            frame();
            if (std::fabs(amp - 0.75f) > 1e-4f) { printf("  partial: amp not read\n"); ++bad; }
            if (std::fabs(gain - 1.25f) > 1e-4f) { printf("  partial: absent key clobbered\n"); ++bad; }
            if (ui::UnclaimedKeys().size() != 1) { printf("  unknown key not reported\n"); ++bad; }
            remove(path.c_str());

            // The "size"/"size" bug class: two controls sharing a literal
            // ImGui label under the same header, one directly in the header's
            // body and one inside a nested section -- exactly the shape of
            // the reported collision (a slider under "face tracking" and
            // another under "face tracking/overlay"). Their registry paths
            // already differ; before the PushID fix in ui::PushSection /
            // PushHeaderFrame, their live Dear ImGui IDs did not.
            {
                float face_size = 0.25f;
                int   overlay_size = 320;
                ui::SetIdCollisionProbe(true);
                ImGui::NewFrame();
                ui::BeginFrame();
                ImGui::Begin("t2");
                {
                    ui::Section s("face tracking");
                    ui::BeginHeader("face tracking");
                    ui::SliderFloat("size", &face_size, 0.05f, 0.5f);
                    {
                        ui::Section o("overlay");
                        ui::SliderInt("size", &overlay_size, 160, 640);
                    }
                    ui::EndHeader();
                }
                ImGui::End();
                ImGui::Render();
                const auto collisions = ui::IdCollisions();
                if (!collisions.empty()) {
                    printf("  %zu id collision(s):\n", collisions.size());
                    for (const auto& c : collisions) {
                        printf("   ");
                        for (const auto& p : c.paths) printf(" %s", p.c_str());
                        printf("\n");
                    }
                    ++bad;
                }
                if (!ui::DuplicatePaths().empty()) {
                    printf("  unexpected duplicate registry path(s) this frame\n");
                    ++bad;
                }
                ui::SetIdCollisionProbe(false);
            }

            ImGui::DestroyContext();
            printf("uitest: %s\n", bad ? "FAIL" : "OK");
            return bad ? 1 : 0;
        }
        // Round-trip every SimParams field through the roots bank. The
        // failure a preset system has is silent: a field nobody declared comes
        // back as its default and nothing complains, and the saved look simply
        // cannot be reproduced. That used to be caught by writing a .root file
        // from visitSimParams; now the registry is the only writer, so the test
        // has to run the real panel -- which is also the only honest way to
        // check it, since the panel is where declaration happens.
        if (a == "--presettest") { g_roots_roundtrip = true; continue; }
        if (a == "--roundtriptest") { g_full_roundtrip = true; continue; }
        if (a == "--rootpreset") {
            if (i + 1 < argc) g_root_preset_name = argv[++i];
            while (i + 1 < argc && strchr(argv[i + 1], '=')) {
                std::string kv = argv[++i];
                const size_t eq = kv.find('=');
                g_root_preset_kv.emplace_back(kv.substr(0, eq), kv.substr(eq + 1));
            }
            continue;
        }
        if (a == "--maskframes") {
            // The mask frames as numbers. A face is placed as
            // p + tangent*x + bitangent*y + normal*z, so the bitangent is the
            // direction the top of the head points: if its world Y is negative
            // the face is upside down, and that is a fact about three floats,
            // not something to squint at a render for.
            MetalContext ctx;
            if (!ctx.device()) { fprintf(stderr, "maskframes: no Metal device\n"); return 1; }
            RootScene roots(ctx, 320, 240);
            if (!roots.valid()) { fprintf(stderr, "maskframes: invalid\n"); return 1; }
            for (int k = 0; k < 4000 && !roots.simDone(); ++k) roots.advance(1.0 / 60.0);
            const auto& ms = roots.revealedMasks();
            printf("maskframes: %zu revealed\n", ms.size());
            int bad = 0;
            for (size_t k = 0; k < ms.size(); ++k) {
                const auto& m = ms[k];
                const float dotUp = m.bitangent[1];
                // The normal must also point away from the cone axis, or the
                // face is buried facing inward.
                const float outward = m.normal[0] * m.pos[0] + m.normal[2] * m.pos[2];
                printf("  [%zu] pos %6.2f %6.2f %6.2f | up %+.3f | outward %+.2f%s\n",
                       k, m.pos[0], m.pos[1], m.pos[2], dotUp, outward,
                       (dotUp > 0.f && outward > 0.f) ? "" : "   <-- WRONG");
                if (!(dotUp > 0.f && outward > 0.f)) ++bad;
            }
            printf("maskframes: %s\n", (ms.size() && !bad) ? "OK" : "FAIL");
            return (ms.size() && !bad) ? 0 : 1;
        }
        if (a == "--rootshot") {
            const char* path = (i + 1 < argc) ? argv[i + 1] : "root.ppm";
            float az  = (i + 2 < argc) ? atof(argv[i + 2]) : 0.6f;
            float el  = (i + 3 < argc) ? atof(argv[i + 3]) : 0.35f;
            float rad = (i + 4 < argc) ? atof(argv[i + 4]) : 42.0f;
            int   md  = (i + 5 < argc) ? atoi(argv[i + 5]) : 0;
            bool  ov  = (i + 6 < argc) ? atoi(argv[i + 6]) != 0 : false;
            return rootshot(path, az, el, rad, md, ov);
        }
        if (a == "--clothshot") {
            const char* prefix = (i + 1 < argc) ? argv[i + 1] : "cloth_";
            int   n  = (i + 2 < argc) ? atoi(argv[i + 2]) : 180;
            int   cw = (i + 3 < argc) ? atoi(argv[i + 3]) : 960;
            int   ch = (i + 4 < argc) ? atoi(argv[i + 4]) : 540;
            float fp = (i + 5 < argc) ? (float)atof(argv[i + 5]) : 30.f;
            const char* photo = (i + 6 < argc) ? argv[i + 6] : "";
            return clothshot(prefix, n, cw, ch, fp, photo);
        }
        if (a == "--seqshot") {
            // Positional prefix/W/H, then growth fields as key=value, the way
            // --growshot takes them.
            std::vector<std::string> pos;
            std::vector<std::pair<std::string, std::string>> fields;
            for (int j = i + 1; j < argc; ++j) {
                std::string t = argv[j];
                const size_t eq = t.find('=');
                if (eq == std::string::npos) pos.push_back(t);
                else fields.emplace_back(t.substr(0, eq), t.substr(eq + 1));
            }
            const char* prefix = pos.size() > 0 ? pos[0].c_str() : "seq_";
            int cw = pos.size() > 1 ? atoi(pos[1].c_str()) : 960;
            int ch = pos.size() > 2 ? atoi(pos[2].c_str()) : 540;
            return seqshot(prefix, cw, ch, fields);
        }
        if (a == "--bench") {
            int ds = (i + 1 < argc) ? atoi(argv[i + 1]) : 4;
            int fr = (i + 2 < argc) ? atoi(argv[i + 2]) : 200;
            return bench(ds, fr);
        }
    }

    // A flag on the command line is also a decision: it is remembered, so the
    // next launch without flags comes up the way this one was asked for.
    if (g_panel_cli) PanelStateSave(g_ui_detached);
    else             PanelStateLoad(&g_ui_detached);

    // The machine bank comes up on its own, every launch: it describes the room
    // this copy of the app is installed in, and having to remember to load the
    // camera calibration is a way of arriving at a show with the wrong one. The
    // values are staged here and land on the first panel frame, like any other
    // load. Its absence on a fresh checkout is not an error.
    {
        std::string e;
        if (ui::LoadBank(ui::Bank::Machine, ui::MachinePath(), e))
            printf("machine settings: loaded %s\n", ui::MachinePath().c_str());
        else
            printf("machine settings: none yet (%s)\n", e.c_str());

        // ...and then whatever each of the other banks was told to come up in.
        // Machine alone was never enough: the installation boots with nobody in
        // front of it, so without this the mirror, the look and the roots came
        // up on the defaults compiled into their structs however carefully they
        // had been dialled in the night before, and the only way to get last
        // night's state back was to open the panel and load four presets by
        // hand. Staged like every other load; they land on the first frame.
        std::string derr;
        if (ui::LoadDefaults(derr)) {
            std::string berr;
            const int n = ui::LoadBankDefaults(berr);
            printf("defaults: %d bank(s) loaded", n);
            for (int b = (int)ui::Bank::Fit; b < (int)ui::Bank::Count; ++b) {
                const std::string nm = ui::DefaultName((ui::Bank)b);
                if (!nm.empty())
                    printf("  %s=%s", ui::BankName((ui::Bank)b), nm.c_str());
            }
            printf("\n");
            // A default naming a preset that has since been deleted is worth
            // saying out loud and not worth refusing to start over.
            if (!berr.empty()) printf("defaults: %s\n", berr.c_str());
        } else {
            printf("defaults: none set (%s)\n", derr.c_str());
        }
        fflush(stdout);
    }

    if (!glfwInit()) { fprintf(stderr, "glfw init failed\n"); return 1; }
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);   // Metal owns the surface
    int W = 1280, H = 720;
    // Borderless-fullscreen rather than a true video mode: the mode switch is
    // what makes a GLFW fullscreen window minimise when it loses focus, and an
    // installation that blanks itself because something stole focus is worse
    // than one running a window. Sizing to the monitor's work area covers the
    // menu bar and Dock without asking macOS for a Space of its own.
    GLFWmonitor* mon = g_fullscreen ? glfwGetPrimaryMonitor() : nullptr;
    if (mon) {
        const GLFWvidmode* vm = glfwGetVideoMode(mon);
        if (vm) { W = vm->width; H = vm->height; }
        glfwWindowHint(GLFW_DECORATED, GLFW_FALSE);
        glfwWindowHint(GLFW_FLOATING, GLFW_TRUE);
    }
    GLFWwindow* win = glfwCreateWindow(W, H, "neuromirror ⇄ roots", nullptr, nullptr);
    if (!win) { fprintf(stderr, "window failed\n"); glfwTerminate(); return 1; }
    if (mon) {
        int mx = 0, my = 0;
        glfwGetMonitorPos(mon, &mx, &my);
        glfwSetWindowPos(win, mx, my);
    }

    MetalContext ctx;
    if (!ctx.device()) { fprintf(stderr, "no Metal device\n"); return 1; }
    id<MTLDevice> device = ctx.device();
    id<MTLCommandQueue> queue = ctx.queue();

    // Attach a CAMetalLayer to the GLFW window.
    NSWindow* nswin = glfwGetCocoaWindow(win);
    CAMetalLayer* layer = [CAMetalLayer layer];
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    nswin.contentView.layer = layer;
    nswin.contentView.wantsLayer = YES;

    // ImGui
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    // Multi-viewport: an ImGui window dragged off the main one becomes a real
    // OS window, so the panel can live on the operator's screen while the
    // composition has the installation's display to itself. Docking is on for
    // the same reason -- it is how a detached panel is put back.
    {
        ImGuiIO& io = ImGui::GetIO();
        io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable;
        io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
        // Platform windows are opaque and square: a rounded, translucent panel
        // over the desktop shows the corners of its own OS window.
        ImGuiStyle& st = ImGui::GetStyle();
        st.WindowRounding = 0.f;
        st.Colors[ImGuiCol_WindowBg].w = 1.f;
    }
    ImGui_ImplGlfw_InitForOther(win, true);
    ImGui_ImplMetal_Init(device);
    g_vp_device = device;
    g_vp_queue = [device newCommandQueue];

    // Retina fix for detached panels, over imgui_impl_metal.
    //
    // The backend sizes a platform window's drawable with viewport->DpiScale,
    // which the GLFW backend always reports as 1.0 on macOS (density lives in
    // FramebufferScale here, not DpiScale). Its render path corrects that from
    // the window's backingScaleFactor, but only on the frame the layer's
    // contentsScale changes -- so the first resize after the correction sets a
    // half-resolution drawable that ImGui then draws into at 2x: every glyph
    // twice the size it should be, and most of the panel off the edge.
    //
    // Sizing from backingScaleFactor -- the same number the backend's own
    // render path trusts -- is the whole fix. The layer is the content view's,
    // put there by ImGui_ImplMetal_CreateWindow.
    if (getenv("MIRROR_NO_DPI_FIX") == nullptr) ImGui::GetPlatformIO().Renderer_SetWindowSize =
        [](ImGuiViewport* vp, ImVec2 size) {
            void* handle = vp->PlatformHandleRaw ? vp->PlatformHandleRaw
                                                 : vp->PlatformHandle;
            if (!handle) return;
            NSWindow* w = (__bridge NSWindow*)handle;
            CAMetalLayer* l = (CAMetalLayer*)w.contentView.layer;
            if (![l isKindOfClass:[CAMetalLayer class]]) return;
            const CGFloat s = w.backingScaleFactor;
            l.contentsScale = s;
            l.drawableSize = CGSizeMake(std::max(CGFloat(1), size.x * s),
                                        std::max(CGFloat(1), size.y * s));
        };

    // ...and the render path over it, for the black panel.
    //
    // See g_vp_skips: the backend installs the viewport's CAMetalLayer once and
    // then assumes it is still the layer being displayed. When something
    // replaces the content view's layer -- which happens on some window moves --
    // it goes on rendering into the orphan, and the window shows the empty one
    // that took its place. Black, permanently, with nothing reporting a fault.
    //
    // Re-owning the layer every frame is the fix; re-deriving the size from the
    // content view's bounds each frame is the other half, since a stale
    // drawableSize is the same symptom by a different route.
    if (getenv("MIRROR_NO_VIEWPORT_FIX") == nullptr)
        ImGui::GetPlatformIO().Renderer_RenderWindow =
            [](ImGuiViewport* vp, void*) {
        void* handle = vp->PlatformHandleRaw ? vp->PlatformHandleRaw
                                             : vp->PlatformHandle;
        if (!handle) return;
        NSWindow* w = (__bridge NSWindow*)handle;
        NSView* view = w.contentView;
        if (!view) return;

        // Not on screen at all: nothing to draw into, and asking would block.
        if (!w.isVisible || w.isMiniaturized) return;
        // Fully occluded: -[CAMetalLayer nextDrawable] blocks about a second on
        // one of these, and this is the render thread. Counted rather than
        // silent -- a panel that has stopped being drawn and a panel that is
        // drawing black look identical from the outside and want opposite
        // fixes.
        if ((w.occlusionState & NSWindowOcclusionStateVisible) == 0) {
            ++g_vp_skips;
            return;
        }

        CAMetalLayer* l = nil;
        if ([view.layer isKindOfClass:[CAMetalLayer class]])
            l = (CAMetalLayer*)view.layer;
        if (!l) {
            l = [CAMetalLayer layer];
            l.device = g_vp_device;
            l.pixelFormat = MTLPixelFormatBGRA8Unorm;
            l.framebufferOnly = YES;
            view.layer = l;
            view.wantsLayer = YES;
            ++g_vp_relayers;
        }

        const CGFloat sc = w.backingScaleFactor;
        const CGSize want = CGSizeMake(
            std::max(CGFloat(1), view.bounds.size.width * sc),
            std::max(CGFloat(1), view.bounds.size.height * sc));
        if (l.contentsScale != sc) l.contentsScale = sc;
        if (!CGSizeEqualToSize(l.drawableSize, want)) l.drawableSize = want;

        id<CAMetalDrawable> d = [l nextDrawable];
        if (!d) return;
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> cb = [g_vp_queue commandBuffer];
        id<MTLRenderCommandEncoder> re =
            [cb renderCommandEncoderWithDescriptor:rp];
        ImGui_ImplMetal_RenderDrawData(vp->DrawData, cb, re);
        [re endEncoding];
        [cb presentDrawable:d];
        [cb commit];
    };

    // The sound engine, as early as the rest of the subsystems. A failure here
    // is reported and carried past: a missing bank should cost the show its
    // audio, not its picture.
    if (!g_audio.init(mirror::WwiseAudio::DefaultBankDir(), g_audio_err))
        fprintf(stderr, "wwise: %s\n", g_audio_err.c_str());
    else
        printf("wwise: engine up, banks from %s\n", g_audio.bankDir().c_str());

    printf("mirror_app — Metal shell up (device: %s)\n", device.name.UTF8String);
    printf("panel: F1 or ` hides/reveals the UI; "
           "\"own window\" puts it in its own OS window "
           "(--panel-window, --reset-panel)\n");

    // Scenes / presenter.
    MirrorScene mirror(ctx);
    RootScene roots(ctx, W, H);
    // The root scene's timeline (root_sequence.h): begin() reseeds whenever
    // the show (re-)enters Transition/Roots (below), step() drives the camera
    // and the growth pacing each frame the scene is up in those phases.
    RootSequence rootSeq;
    bool rootSeqActive = false;
    // The visitor's own head movement, recorded through Transition and
    // played back once Roots takes over -- see face_track.h/root_face_sequence.h.
    // Recorder accumulates through one Transition; the sequence plays
    // whatever the recorder produced at the lock instant, for as long as
    // that same visitor's sitting is up on the masks.
    mirror::FaceTrackRecorder faceTrackRec;
    RootFaceSequence rootFaceSeq;
    // What faceTrackRec.finish() produced for the last sitting, held here
    // until Roots is (re-)entered and rootFaceSeq.begin() can pick it up.
    mirror::FaceTrack pendingFaceTrack;
    // True from Transition entry until faceTrackRec.finish() runs (now keyed
    // off g_track_absent_t, not the lock instant -- see the phase-agnostic
    // absence block below).
    bool faceTrackRecActive = false;
    // The capture id this sitting's track belongs to, stashed at the cut
    // (same moment autoCaptureAtCut assigns cap.id) rather than read
    // back from g_capture_last at finish() time, which could in principle
    // have been overwritten by an unrelated manual capture in the many
    // seconds between the two.
    std::string thisSittingCaptureId;
    // Seconds the tracker has continuously reported nobody present, spanning
    // both Transition and Roots -- what faceTrackRecActive's finish() waits on.
    double g_track_absent_t = 0.0;

    // RootScene now renders continuously from Transition entry onward -- the
    // cloth press/settle/release/fall that used to live in a separate
    // TransitionScene, composited as Transition's background, is now a state
    // machine inside RootScene itself (RootScene::restartCloth/advanceCloth),
    // pressing against and draping off the very mask RootScene places and
    // grows the roots around. There is no more "pre-warm": RootScene simply
    // runs from the moment Transition is entered, and the literal Roots phase
    // is not a hand-off between two scenes any more, just the same one
    // continuing. rootSeqBegunForSitting guards against RootSequence being
    // reseeded twice for one sitting (once at Transition entry, again at the
    // literal Roots entry) -- see the entries()-diff block below.
    bool rootSeqBegunForSitting = false;
    double rootsClock = 0.0;          // seconds since Transition entry; RootSequence's own clock
    double clothClearAtPreWarm = -1.0;
    bool clothClearHoldElapsed = false;
    // The last g_show.phaseTime() seen while still in Transition -- captured
    // every Transition frame, read once at the Roots cut so
    // faceTrackRec.record() can keep using a clock continuous with what it
    // was recording all through Transition (g_show.phaseTime() resets to 0
    // at the Roots entry, same as rootsClock does at pre-warm entry -- two
    // different origins, neither of which is "seconds since Transition
    // entry" once past the cut, which is what a FaceTrack's timestamps need
    // to stay monotonic).
    double transitionExitPhaseTime = 0.0;
    // Whether RootScene's faceTris_ currently holds the fitter basis's
    // topology (as opposed to the canonical mesh's) -- setFittedFace() is
    // only ever given the (large, unchanging) triangle list once per sitting,
    // relying on RootScene to keep holding onto it. replant() overwrites
    // faceTris_ back to the canonical mesh's topology as part of clearing the
    // last visitor's face (see RootScene::replant), which leaves it mismatched
    // against the fitter's vertex count until this flag says the triangles
    // are due for a resend -- omitting them then, as a stale process-lifetime
    // "already sent" latch used to, is exactly the mismatch that renders the
    // mask mesh as scrambled shrapnel on every sitting after the first.
    bool rootFaceTrisUploaded = false;
    TransitionScene trans(ctx, W, H);
    // What is already on disk, so the picker is populated before anything
    // has been captured this run.
    g_capture_ids = mirror::ListCaptures();

    // --- the face bank (see plans/ROOT_TIMELINE.md, "The face bank") ------
    // Captures loaded once per id and kept for the life of the process:
    // LoadCapture reads the film as well, and a hood of a dozen structures
    // wears getting on for eighty captures, which is too many full-frame
    // PPMs to re-read on every visitor. The film is dropped once read -- the
    // masks wear the baked colours, and the film only serves the panel's
    // "load into the transition", which loads its own.
    std::unordered_map<std::string, mirror::FaceCapture> bankCache;
    // Deal the bank onto the masks: the most recent captures, newest first,
    // as many as the chain and the capped hood can wear, minus `excludeId`
    // (the sitting now on mask 0, once it has been saved). RootScene does
    // the dealing; this only decides which files to open.
    auto dealBankFaces = [&](const std::string& excludeId) {
        if (!roots.valid()) return;
        const int N = std::max(1, roots.simParams().N);
        const int hood = std::max(g_root_seq.reveal_max_structures, g_root_seq.reveal_structures);
        const int want = (N - 1) + std::max(0, hood) * N;
        std::vector<mirror::FaceCapture> bank;
        // g_capture_ids is oldest first (ListCaptures); the bank is newest first.
        for (auto it = g_capture_ids.rbegin();
             it != g_capture_ids.rend() && (int)bank.size() < want; ++it) {
            if (*it == excludeId) continue;
            auto c = bankCache.find(*it);
            if (c == bankCache.end()) {
                mirror::FaceCapture cap;
                std::string err;
                if (!mirror::LoadCapture(*it, cap, err)) {
                    // An unreadable capture is skipped, not fatal: the bank is
                    // a directory anyone can leave a half-written entry in.
                    fprintf(stderr, "face bank: %s\n", err.c_str());
                    continue;
                }
                cap.film.clear();
                cap.film.shrink_to_fit();
                cap.filmW = cap.filmH = 0;
                // Square of its sitter's head pose (see autoCaptureAtCut):
                // captures from before that was saved out carry 10-40
                // degrees of it, and a face that tilted on its mask read as
                // askew from the nest. A no-op on one already square.
                if (g_fitter.valid()) {
                    const float deg = mirror::SquareCaptureToNeutral(cap, g_fitter.basis().neutral());
                    if (deg > 2.f) printf("face bank: %s squared by %.0f deg\n", it->c_str(), deg);
                }
                c = bankCache.emplace(*it, std::move(cap)).first;
            }
            bank.push_back(c->second);
        }
        roots.assignBankFaces(bank, g_root_seq.reveal_max_structures,
                              g_root_seq.reveal_min_structures, g_root_seq.reveal_structures);
    };
    // The auto-capture, at the Transition -> Roots cut: the live fit, its
    // colours as sampled off the mirror (what mask 0 has been wearing through
    // the press), the mirror's last frame as the film, and the uv that
    // projects the fit into it -- the same pieces TransitionScene::
    // buildCapture assembled from its own lock, assembled here from the
    // live state instead, since the press no longer has a lock instant.
    // This is what grows the bank. Once per sitting: thisSittingCaptureId is
    // cleared at Transition entry and set here, and the face track's own
    // save keys off the same id.
    auto autoCaptureAtCut = [&]() {
        if (!g_capture_auto || !thisSittingCaptureId.empty()) return;
        if (!(g_fitter.valid() && g_track_on && g_face.valid)) return;
        const std::vector<float>& verts = g_fitter.vertices();
        if (verts.size() < 9 || g_face_colors.size() != verts.size()) return;
        mirror::FaceCapture cap;
        cap.id = mirror::NewCaptureId();
        cap.created = cap.id;
        // Square, not posed: vertices() carries the head rotation the mask
        // on the mirror follows (RotateAboutCentroid by rotation()), and a
        // bank face worn on a root mask with that tilt still in it sat
        // askew inside the nest the sim had grown square to the mask's
        // frame. The rotation is orthonormal, so its transpose undoes it
        // about the same centroid; the uv below is projected from the
        // fitter's own (posed) state and is per vertex, so it is unaffected.
        cap.verts = verts;
        {
            const float* r = g_fitter.rotation();
            const float rt[9] = {r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]};
            mirror::RotateAboutCentroid(cap.verts, rt);
        }
        cap.tris  = g_fitter.basis().triangles();
        cap.colors = g_face_colors;
        float ps = 1.f, uo = 0.f, vo = 0.f;
        PinTransform(ps, uo, vo);
        g_fitter.projectNormalised(g_track_w, g_track_h, ps, uo, vo, cap.uv);
        // The film, gamma-encoded to 8 bits the way freezeFilm did it, so a
        // capture from here and one from the transition decode alike.
        const std::vector<float>& img = mirror.lastImageRGB();
        const int fw = mirror.lowW(), fh = mirror.lowH();
        if (fw > 0 && fh > 0 && img.size() == size_t(fw) * size_t(fh) * 3) {
            cap.filmW = fw; cap.filmH = fh;
            cap.film.resize(img.size());
            for (size_t i = 0; i < img.size(); ++i)
                cap.film[i] = (unsigned char)(std::pow(std::clamp(img[i], 0.f, 1.f), 1.f / 2.2f) * 255.f + 0.5f);
        }
        std::string cerr;
        if (!cap.valid()) return;
        if (mirror::SaveCapture(cap, cerr)) {
            g_capture_last = cap.id;
            thisSittingCaptureId = cap.id;
            g_capture_msg = "saved " + cap.id;
            g_capture_ids = mirror::ListCaptures();
            printf("capture: saved %s (%zu verts, film %dx%d)\n",
                   cap.id.c_str(), cap.vertexCount(), cap.filmW, cap.filmH);
            // Into the cache too, film-less, so the next visitor's deal does
            // not go back to disk for the one capture this process just wrote.
            cap.film.clear();
            cap.film.shrink_to_fit();
            cap.filmW = cap.filmH = 0;
            bankCache[cap.id] = std::move(cap);
        } else {
            g_capture_msg = "save failed: " + cerr;
            fprintf(stderr, "capture: %s\n", g_capture_msg.c_str());
        }
    };
    FitViewScene fitview(ctx, std::string(MIRROR_APP_SHADER_DIR) + "/fit_view.metal", W, H);
    FullscreenPresent present(ctx, std::string(MIRROR_APP_SHADER_DIR) + "/present.metal",
                              layer.pixelFormat);
    // Composited in the present pass, so it sits over whichever scene is up
    // rather than belonging to any one of them.
    mirror::TextOverlay text(ctx);
    mirror::TextParams textp;

    // Camera is appended rather than inserted: g_show_scene holds these by
    // number and is written into show presets, so renumbering would repoint
    // every phase at a different scene. `Scene` itself lives in app_state.h --
    // the panel needs it too.
    int scene = (int)Scene::Mirror;

    // Seed the panel's per-phase timing arrays from the graph's own defaults,
    // so a fresh install with no Bank::Show preset saved yet still runs the
    // designed piece -- exactly what ShowScript's constructor used to do,
    // now done once here since Timeline no longer holds a script object to
    // default-construct.
    for (int pi = 0; pi < (int)show::Phase::Count; ++pi) {
        const show::PhaseGraph& g = show::Graph((show::Phase)pi);
        g_show_min[pi] = g.min_time;
        g_show_max[pi] = g.max_time;
        for (int e = 0; e < g.edge_count; ++e) {
            g_show_hold[pi][e] = g.edges[e].hold;
            g_show_grace[pi][e] = g.edges[e].grace;
        }
    }

#if MIRROR_HAVE_KINECT
    // The installation has nobody to press "open sensor", so the camera comes
    // up with the app. A failure here is reported and not fatal: every scene
    // but the live fit runs without the sensor, and the panel's "open sensor"
    // is still there to retry once the cable or the other process is dealt
    // with. Arming the live feed stays a deliberate act -- this opens the
    // device, it does not start training.
    if (g_open_sensor) {
        std::string kerr;
        if (g_kinect.open(kerr))
            printf("kinect: %s\n", g_kinect.deviceInfo().c_str());
        else
            printf("kinect: %s -- use \"open sensor\" in the panel to retry "
                   "(--no-sensor skips this)\n", kerr.c_str());
    }
#endif

    // The room's own mic, for the root scene's light responsivity (see
    // RootScene::setAmbientLevel) -- the Kinect's own mic array specifically,
    // see mic_level.h. Started only now, after g_kinect.open() above: opening
    // the sensor USB-resets it, which knocks its audio interface off the bus
    // for a moment (see audio_capture.h), and starting the mic first would
    // just race that reset. Best-effort, same as everything else here: no
    // Kinect built, no sensor plugged in, or a denied OS permission all just
    // mean a still light -- mic_level.mm logs which.
    if (!g_mic.start(g_mic_err))
        fprintf(stderr, "mic: %s\n", g_mic_err.c_str());

    int downscale = 4;       // mirror render-resolution divisor (low-res + upsample)
    int rootDownscale = 1;   // roots render-resolution divisor (manual, when auto off)
    bool rootAutoScale = true;   // cap the roots' internal resolution (see below)
    int  rootTargetDim = 1920;   // target max internal dimension when auto-scaling
    int rootSeed = 1;
    int fieldGrid = 6;           // NxN cached-system field for the LOD/cull demo

    double lastTime = glfwGetTime();
    double fpsAccum = 0.0; int fpsFrames = 0; double fpsShown = 0.0;

    while (!glfwWindowShouldClose(win)) {
        glfwPollEvents();

        int fbw, fbh;
        glfwGetFramebufferSize(win, &fbw, &fbh);
        layer.drawableSize = CGSizeMake(std::max(1, fbw), std::max(1, fbh));

        // The frame the work is composed for, which is the drawable in Auto and
        // a centred tall box when Portrait is forced on this landscape monitor.
        // Every size below comes from this rather than from the window, so
        // previewing the installation's framing is a setting and not a
        // rebuild -- and on the installation's own portrait display the two are
        // the same thing and nothing is letterboxed.
        const mirror::ScreenLayout layout = mirror::ComputeLayout(
            fbw, fbh, (mirror::Orientation)g_orientation, g_portrait_aspect);
        const int compW = layout.comp_w, compH = layout.comp_h;

        // The sensor's crop follows the composition, so it is pushed before
        // anything polls a frame.
#if MIRROR_HAVE_KINECT
        g_kinect.setCrop(g_feed);
#endif

        // And so does the tracker's frame. Derived here, from the same
        // composition every other consumer of the feed is derived from, so the
        // rect ComputeFeedRect selects for the tracker is the rect it selects
        // for the fit grid and for the preview -- which is the whole reason
        // landmarks normalised against one can be applied to the others.
        if (compW >= compH) {
            g_track_w = g_track_px;
            g_track_h = std::max(1, int(int64_t(g_track_px) * compH / compW));
        } else {
            g_track_h = g_track_px;
            g_track_w = std::max(1, int(int64_t(g_track_px) * compW / compH));
        }

        @autoreleasepool {
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (!drawable) { continue; }

            id<MTLCommandBuffer> cb = [queue commandBuffer];

            // Update the active scene's texture (MLX compute happens here).
            static double prevT = glfwGetTime();
            double nowT = glfwGetTime();
            double dt = nowT - prevT; prevT = nowT;
            // --- the frame, pulled once ---------------------------------
            //
            // Everything downstream reads the retained snapshot, so the pull
            // happens here, before any of it: pollColor is latest-wins and
            // consuming, and two pulls in a frame would hand the tracker and
            // the fit different moments -- a face outline from one instant
            // over the pixels of another, which shows up as the fit smearing.
            //
            // It runs whenever anything wants a frame, not only while the fit
            // is training: with the live feed on but the fit stopped, the
            // preview and the tracker still have to be live.
            static std::vector<float> live_rgb;
            int  fit_w = 0, fit_h = 0;
            bool live_fresh = false;
            bool source_polled = false;   // the overlay must not pull a second time
            if ((g_fit_live || g_track_on || g_show_source) && SourceReady()) {
                // Sized from the framebuffer rather than mirror.lowW(), which
                // this frame's ensureSize() has not set yet -- the two agree by
                // construction, and reading it after the fact would be a frame
                // behind on a resize.
                const int lw = std::max(1, compW / std::max(1, downscale));
                const int lh = std::max(1, compH / std::max(1, downscale));
                // Which tuning applies is decided by the *previous* frame's
                // crop state: the grid has to be chosen before the frame is
                // pulled, and whether there is a crop is not known until the
                // tracker has run on it. One frame of lag on a grid change is
                // nothing next to the hysteresis already in front of it -- and
                // everything within this frame stays consistent, because the
                // mask, the field and the target are all built at whatever
                // fit_w/fit_h this picks.
                const FitTune& grid = g_have_mask ? g_tune_crop : g_tune_full;
                fit_w = std::max(8, lw / std::max(1, grid.downscale));
                fit_h = std::max(8, lh / std::max(1, grid.downscale));
                // Only *advance* the source here. The resample used to happen
                // at this point too, which forced it to run before the tracker
                // and therefore before anything knew where the face was -- so
                // it had to produce the whole frame. It is deferred to just
                // below the mask instead, where the region it actually needs
                // is known exactly rather than guessed a frame late.
                live_fresh = SourceAdvance();
                source_polled = true;
            }

            // --- face tracking ------------------------------------------
            // Once per frame, before either scene uses it, so the mirror's
            // mask and the roots' mesh are built from the same detection
            // rather than from two frames a scene apart.
            if (g_track_on && g_tracker.isOpen() && SourceReady()) {
                if (SourceRGB8(g_track_w, g_track_h, g_track_rgb)) {
                    // Video mode rejects a repeated or decreasing timestamp
                    // with a hard error rather than dropping the frame, and
                    // the render loop can outrun the sensor, so the clock here
                    // is a counter rather than wall time.
                    g_track_ts += 33;
                    mirror::FaceResult r;
                    r.blendshape_names = g_face.blendshape_names;   // filled once
                    const bool hit = g_tracker.detect(g_track_rgb.data(), g_track_w,
                                                      g_track_h, g_track_ts, r);
                    // Hysteresis both ways. A detection is not believed until
                    // it has repeated, and a gap is not believed until it has
                    // lasted: MediaPipe drops frames on a blink or a turn, and
                    // treating those as "nobody there" costs a target resize, a
                    // feature-gather rebuild and a visible snap of the soft
                    // edge -- several frames of upheaval to report something
                    // that was over before it began.
                    if (hit) {
                        ++g_face_streak;
                        g_face_last_seen = nowT;
                        g_face_held = false;
                    } else {
                        g_face_streak = 0;
                        if (nowT - g_face_last_seen > g_face_hold_secs) {
                            g_face.valid = false;
                            g_face_held = false;
                        } else {
                            // Inside the hold: keep the last good landmarks,
                            // untouched. Everything downstream carries on
                            // against a frozen face rather than losing one.
                            g_face_held = g_face.valid;
                        }
                    }
                    if (hit && g_face_streak >= std::max(1, g_face_acquire)) {
                        g_face = std::move(r);
                        if (g_fitter.valid()) {
                            // The automatic start. Gated on the same acquire
                            // streak everything else here is, so a single
                            // spurious detection cannot kick off a collection
                            // that then has to be cancelled.
                            if (g_auto_fit_id && !g_collect_id &&
                                !g_fitter.hasIdentity() && nowT >= g_auto_fit_next) {
                                g_fitter.clearIdentity();
                                g_id_residual = -1.f;
                                g_collect_id = true;
                                g_id_started = nowT;
                                g_auto_fit_next = nowT + g_id_collect_secs + 2.0;
                            }
                            // Space the identity samples out in time. Taking
                            // them on consecutive render frames would collect
                            // eight views of the same 130 ms -- the multi-frame
                            // fit exists to average out landmark noise, and
                            // near-identical frames have the same noise in them.
                            if (g_collect_id && nowT - g_last_id_sample > 0.1) {
                                g_fitter.offerIdentityFrame(g_face, g_track_w,
                                                            g_track_h);
                                g_last_id_sample = nowT;
                                // Collection ends on the clock, not on a count:
                                // the retained set is a ranking, so it keeps
                                // improving for as long as it runs and would
                                // never "fill".
                                if (nowT - g_id_started > g_id_collect_secs) {
                                    if (g_fitter.identityFrames() > 0)
                                        g_fitter.fitIdentity(&g_id_residual);
                                    g_collect_id = false;
                                }
                            }
                            g_fitter.update(g_face, g_track_w, g_track_h);
                        }
                    }
                    // No `else` clearing the face: a miss is handled by the
                    // hold above, and a hit that has not yet met the acquire
                    // threshold is simply not adopted. Clearing here is what
                    // used to make a single dropped frame a whole event.
                }
            }

            // --- head movement ------------------------------------------
            // After the detection, before anything that consumes it. The
            // input shift and the region have to be settled here: the fit
            // features and the render both read them later in this frame and
            // must read the same values.
            UpdateHeadBox();
            ApplyHeadMode(mirror.params(), fit_w, fit_h);

            // --- the fit's target, over the mask only --------------------
            //
            // Now that the mask exists, resample just the part of the frame the
            // training pass will read. Everything outside keeps whatever it
            // last held: the trainer gathers masked pixels into a compact batch
            // and never looks at the rest, which is exactly the licence to not
            // produce it. With a face crop that is a few percent of the frame.
            //
            // Gated on g_fit_live because nothing else reads live_rgb -- the
            // tracker and the overlay have their own frames off the same
            // retained snapshot.
            // Whether live_rgb currently holds a complete frame or only the
            // region some earlier mask needed. It matters because the no-crop
            // path trains on *everything*: a face lost on a frame the sensor
            // had nothing new for would otherwise adopt the last bounded fill
            // and train on its stale surround.
            static bool live_rgb_whole = false;
            if (g_fit_live && fit_w > 0) {
                mirror::DstRect resample_rect, read_rect;
                const bool bounded = FitFillRects(fit_w, fit_h, resample_rect,
                                                  read_rect);
                // A fresh frame is the usual trigger; needing the whole frame
                // when only part of one is in hand is the other.
                if (live_fresh || (!bounded && !live_rgb_whole)) {
                    if (SourceRGBF(fit_w, fit_h, live_rgb,
                                   bounded ? resample_rect : mirror::DstRect{})) {
                        PlaceLiveFrame(live_rgb, fit_w, fit_h,
                                       bounded ? read_rect : mirror::DstRect{});
                        live_rgb_whole = !bounded;
                    }
                }
            } else if (!g_fit_live) {
                // Nothing is training on it; do not hold a stale frame that
                // would be adopted the moment the feed is armed.
                live_rgb.clear();
                live_rgb_whole = false;
            }

            // --- the network's input, as a picture ------------------------
            //
            // Uploaded here, from the buffer the trainer is about to be handed,
            // so what is on screen is this frame's target and not a
            // reconstruction of it. Masked pixels at full brightness, the rest
            // dimmed: the difference between them is exactly the difference
            // between what is supervised and what the network is free to invent.
            static id<MTLTexture> netTex = nil;
            static int netTexW = 0, netTexH = 0;
            static std::vector<unsigned char> netRGBA;
            bool netFresh = false;
            if (g_show_netin && fit_w > 0 && fit_h > 0 &&
                live_rgb.size() == size_t(fit_w) * fit_h * 3) {
                if (!netTex || netTexW != fit_w || netTexH != fit_h) {
                    MTLTextureDescriptor* td = [MTLTextureDescriptor
                        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                     width:fit_w
                                                    height:fit_h
                                                 mipmapped:NO];
                    td.usage = MTLTextureUsageShaderRead;
                    td.storageMode = MTLStorageModeManaged;
                    netTex = [ctx.device() newTextureWithDescriptor:td];
                    netTexW = fit_w; netTexH = fit_h;
                }
                netRGBA.resize(size_t(fit_w) * fit_h * 4);
                const bool have_mask =
                    g_have_mask && g_fit_mask.size() == size_t(fit_w) * fit_h;
                for (size_t i = 0, n = size_t(fit_w) * fit_h; i < n; ++i) {
                    const bool trained = !have_mask || g_fit_mask[i];
                    const float k = trained ? 1.f : g_netin_dim;
                    for (int c = 0; c < 3; ++c) {
                        const float v = live_rgb[i * 3 + c] * k;
                        netRGBA[i * 4 + c] =
                            (unsigned char)(std::min(1.f, std::max(0.f, v)) * 255.f + 0.5f);
                    }
                    netRGBA[i * 4 + 3] = 255;
                }
                [netTex replaceRegion:MTLRegionMake2D(0, 0, fit_w, fit_h)
                          mipmapLevel:0
                            withBytes:netRGBA.data()
                          bytesPerRow:size_t(fit_w) * 4];
                netFresh = true;
            }

            // --- the show -------------------------------------------------
            //
            // Stepped here: after the tracker and the fit have produced this
            // frame's answers, before anything reads `scene`. A timeline
            // advanced after the scene was chosen would render one frame of the
            // phase it just left, which on the transition is a visible stutter
            // at exactly the moment the piece is meant to be seamless.
            // The timeline is always the thing that decides what is on screen,
            // whether or not it is advancing itself. "Run the show" means the
            // edges are taken automatically; with it off the operator takes
            // them from the phase navigator, and the piece is in a phase either
            // way. There is no second, manual notion of "which scene" that the
            // timeline could disagree with -- that disagreement is what a scene
            // picker sitting beside a running timeline always turned into.
            {
                show::Signals sig;
                const bool facePresent = ShowFacePresent();
                sig.face_present = facePresent;
                sig.fit_converged = ShowFitConverged();
                // Roots runs its whole arc regardless of the visitor: the
                // structure growing, turning, the others lighting up, the
                // orbit and the datamosh out are the piece, and a tracker
                // that loses the person -- or nobody standing there at all
                // -- must not cut it short. So Roots' FaceAbsent edge never
                // sees an absence while the sequence is running; the
                // sequence's own Done is what moves the show on (see the
                // Roots render branch). The sitting-wide timer below
                // (g_track_absent_t) reads the real signal: the face-track
                // recording still has to know when the person actually left.
                if (g_show.phase() == show::Phase::Roots && rootSeqActive && !rootSeq.done())
                    sig.face_present = true;
                g_show.setSignals(sig);
                // The transition owns its own duration, so it reports its end
                // rather than being timed from outside -- now additionally
                // gated on the cloth having actually cleared (+ its tail),
                // computed in the pre-warm block below, so the cut to Roots
                // lands after the film is visibly out of the way rather than
                // racing the old fixed Timing sum.
                if (scene == (int)Scene::Transition && roots.valid() && roots.clothDone() &&
                    clothClearHoldElapsed)
                    g_show.sceneDone();

                // Seconds the visitor has been gone, spanning both Transition
                // and Roots -- what faceTrackRecActive's finish() below waits
                // on, since the recording window runs across that cut.
                if (g_show_on && !g_show_paused &&
                    (g_show.phase() == show::Phase::Transition ||
                     g_show.phase() == show::Phase::Roots))
                    g_track_absent_t = facePresent ? 0.0 : g_track_absent_t + dt;

                // finish() the recording once the visitor has been
                // continuously absent as long as show::Timeline itself
                // requires to call it "left" in Roots (the same absentHold
                // debounce, reused rather than duplicated) -- deliberately
                // decoupled from trans.capturePending()/the lock instant, so
                // the whole press/settle/release/fall and early Roots gets
                // recorded, not just the ~0.5s hold stage. The capture's
                // own single-instant snapshot is separate, taken at the
                // Transition -> Roots cut (autoCaptureAtCut, above).
                if (faceTrackRecActive) {
                    const float absentHold = g_show.hold(show::Phase::Roots, 0);
                    if ((float)g_track_absent_t >= absentHold) {
                        faceTrackRecActive = false;
                        mirror::FaceTrack track;
                        if (faceTrackRec.finish(g_fitter, track) && !thisSittingCaptureId.empty()) {
                            track.id = thisSittingCaptureId;
                            std::string terr;
                            if (mirror::SaveFaceTrack(track, terr))
                                pendingFaceTrack = std::move(track);
                            else
                                fprintf(stderr, "face track: save failed: %s\n", terr.c_str());
                        }
                    }
                }

                if (g_show_on && !g_show_paused) g_show.advance(dt);

                // Compared across frames rather than around advance(), so a
                // phase the navigator jumped to is handled by the same code on
                // the same footing as one the timeline reached on its own.
                static unsigned handled_entries = ~0u;
                if (g_show.entries() != handled_entries) {
                    handled_entries = g_show.entries();
                    const show::Phase p = g_show.phase();
                    if (g_show_log)
                        printf("show: %s (%s)\n", show::PhaseName(p),
                               g_show.lastReason().c_str());

                    switch (p) {
                        case show::Phase::Idle:
                            // Forget the last person. Without this the next one
                            // walks into a converged fit of somebody else's
                            // face and the fitting phase ends instantly.
                            g_collect_id = false;
                            g_id_residual = -1.f;
                            if (g_fitter.valid()) g_fitter.clearIdentity();
                            // The *neural* fit is the other half of the same
                            // forgetting, and it was not being done: the weights
                            // stayed trained on whoever was last in the room, so
                            // the idle mirror was quietly still wearing their
                            // face while it waited for the next person.
                            g_fit_arm = false;
                            mirror.pond().clearFit();
                            g_fit_level_now = 0.f;
                            // Put the idle field back the way the preset had
                            // it, or every pass through the piece would leave
                            // the mirror a little more textured than the last.
                            if (g_w0_idle >= 0.f) mirror.params().sine_w0 = g_w0_idle;
                            g_w0_t0 = -1.0;
                            g_w0_idle = -1.f;
                            // Same forgetting for the colour the fit brought
                            // in: the next person has to arrive in black and
                            // white, or the second visitor of the day walks up
                            // to a mirror already wearing the first one's.
                            //
                            // Unconditional now, not "restore g_colour_idle if
                            // it happens to be set": that guard is exactly what
                            // let this leak. g_colour_idle is only ever written
                            // while g_colour_fit_on is true (see the Fitting
                            // case below), so toggling the feature off and on
                            // around a sitting, or any other path that left it
                            // at -1, meant Idle saw "nothing to restore" and
                            // left color_mix wherever the ratchet had pushed
                            // it -- maxed, forever, no matter how many clean
                            // Roots->Idle cycles ran afterwards. Idle is the
                            // one place blackness is guaranteed; it does not
                            // get to be a no-op.
                            mirror.params().color_mix = 0.f;
                            g_colour_idle = -1.f;
                            g_colour_from = 0.f;
                            g_colour_now = 0.f;
                            // The harmony gets its resolution here too, not
                            // just on a converged fit: a visitor who walks off
                            // mid-fit still gets a chord that closes rather
                            // than one stranded wherever the fit happened to
                            // be when they left. Deliberately not reset() here
                            // as well -- that would erase the resolution in
                            // the same frame it is posted, before Wwise ever
                            // sees it (stageChanged() is only read once, later
                            // this same frame). The forgetting -- "the next
                            // person walks in on the last one's resolved
                            // major" -- happens instead at the next Fitting
                            // entry below, which is also the earliest a new
                            // visitor's own arc can begin.
                            g_chord.resolve();
                            // The shepherd glissando forgets its position too --
                            // otherwise the next visitor's rise starts wherever
                            // the last one's left off.
                            g_shepherd_phase = 0.f;
                            // Every entry into Idle starts a fade-in from
                            // black -- the one after Roots' outro, where the
                            // screen is already black and this is what
                            // brings the mirror back; and, harmlessly, the
                            // very first one at boot too.
                            g_screen_fade = 1.f;
                            g_idle_intro_t0 = nowT;
                            break;
                        case show::Phase::Fitting:
                            // Do not trust Idle to have already forgotten the
                            // last sitting's colour: the panel's "force" phase
                            // buttons, keys 1-4, and the MIDI phase fader all
                            // call goTo() directly, which can land here from
                            // Roots/Transition without ever running Idle's
                            // case above. If that happened, g_colour_idle is
                            // still the *previous* visitor's pre-fit baseline
                            // and color_mix is still wherever their ratchet
                            // left it (typically near-max) -- restore to that
                            // baseline now, the same forgetting Idle does,
                            // before this fit gets a chance to adopt the
                            // stale, already-saturated value as its own
                            // starting point below.
                            //
                            // Forced to 0 outright rather than restored from
                            // g_colour_idle -- that mirrors the Idle case's own
                            // fix: g_colour_idle is only ever populated while
                            // g_colour_fit_on is on, so trusting it here just
                            // reintroduces the same "nothing recorded, nothing
                            // reset" hole for the direct-jump path. Idle is
                            // black and white by definition; that is the value
                            // to land on, captured state or not.
                            mirror.params().color_mix = 0.f;
                            g_colour_idle = -1.f;
                            g_colour_from = 0.f;
                            g_colour_now = 0.f;
                            // The harmony forgets the last sitting here, not
                            // on the way into Idle: resolve() (see the Idle
                            // case above) needs to survive at least until
                            // Wwise reads it, and the new visitor's own arc
                            // has to start from the dark opening chord anyway,
                            // so this is the natural place for both.
                            g_chord.reset();
                            // Start collecting the moment the phase opens, so
                            // the `min` and the collection window overlap
                            // rather than running back to back.
                            if (g_fitter.valid()) {
                                g_fitter.clearIdentity();
                                g_id_residual = -1.f;
                                g_collect_id = true;
                                g_id_started = nowT;
                            }
                            // ...and start the fit itself. This phase *is* the
                            // fit -- the identity collection above only shapes
                            // the mesh -- but nothing here ever armed the feed
                            // or called beginFit, so the phase ran its whole
                            // length with the network untouched and handed the
                            // transition whatever was on screen. The operator
                            // pressing "fit" on the mirror page was the only
                            // thing that ever started one, which an installation
                            // has nobody to do.
                            g_fit_live = true;
                            g_fit_arm = true;
                            // Same reasoning as the colour guard above: a
                            // forced jump straight into Fitting can leave
                            // sine_w0 sitting at the previous visitor's fit
                            // frequency with g_w0_idle never restored, which
                            // would make this "ramp" capture that already-hot
                            // value as its own idle baseline and do nothing.
                            if (g_w0_idle >= 0.f) {
                                mirror.params().sine_w0 = g_w0_idle;
                                g_w0_idle = -1.f;
                            }
                            // Take the basis up to fitting frequency first.
                            // The arm below waits for it: seeding the optimiser
                            // at the idle w0 and turning it up afterwards would
                            // change nothing, because a fitted network no
                            // longer derives from it.
                            if (g_w0_ramp_on) {
                                g_w0_idle = mirror.params().sine_w0;
                                g_w0_from = mirror.params().sine_w0;
                                g_w0_t0 = nowT;
                            }
                            // Colour starts from wherever the preset left it --
                            // black and white in the show presets, but a preset
                            // that idles with some colour already in it should
                            // rise from there rather than jump down to grey.
                            if (g_colour_fit_on) {
                                g_colour_idle = mirror.params().color_mix;
                                g_colour_from = mirror.params().color_mix;
                                g_colour_now  = mirror.params().color_mix;
                            }
                            break;
                        case show::Phase::Transition:
                            // The harmony resolves here unconditionally, not
                            // just when the fit actually earned it: a fit that
                            // hit the time limit and is being carried into
                            // Transition anyway (see kFittingEdges' timeout in
                            // show_timeline.cpp) still deserves a chord that
                            // closes, not one left wherever it happened to be
                            // sitting at the 30s mark. Harmless on the
                            // converged path too -- fit_level is usually
                            // already close to the top by the time fit_hold
                            // has elapsed, and pinning it the rest of the way
                            // is exactly the arc's own ending.
                            g_chord.resolve();
                            // From the top, with whatever face the fitting
                            // phase ended up with. RootScene now renders
                            // continuously from here on -- see the
                            // Scene::Transition branch below -- so its cloth
                            // timeline and its authored camera sequence both
                            // start here rather than waiting for the literal
                            // Roots entry.
                            // A fresh plant for a fresh visitor, before the
                            // camera sequence reads the layout off it. Nothing
                            // used to do this: the growth simply carried on
                            // from wherever the last sitting left it, so the
                            // second visitor of the day walked up to a root
                            // system that was already fully grown before their
                            // press had even started.
                            if (roots.valid()) { roots.replant(); roots.restartCloth(); }
                            rootFaceTrisUploaded = false;
                            // Previous visitors onto the other masks, now
                            // rather than at the cut: they are not seen
                            // until Grow, but Grow can start straight off
                            // Face without going through the cut. This
                            // sitting's own capture does not exist yet, so
                            // nothing is excluded.
                            dealBankFaces(std::string());
                            rootSeq.begin(roots, g_root_seq);
                            rootSeqBegunForSitting = true;
                            faceTrackRec.begin();
                            faceTrackRecActive = true;
                            thisSittingCaptureId.clear();
                            g_track_absent_t = 0.0;
                            transitionExitPhaseTime = 0.0;
                            rootsClock = 0.0;
                            clothClearAtPreWarm = -1.0;
                            clothClearHoldElapsed = false;
                            break;
                        default:
                            break;
                    }

                    // The sequence reseeds on every entry into Roots or
                    // Transition -- new anchor, new neighbour hood -- and is
                    // off everywhere else, so a phase left with the sequence
                    // mid-stage doesn't come back to a stale one.
                    rootSeqActive = (p == show::Phase::Roots || p == show::Phase::Transition);
                    // Transition's own entry (above) already called begin() --
                    // RootScene has been rendering, and the sequence running,
                    // since that edge. Calling begin() again here on the
                    // literal Roots entry would restart Face from scratch
                    // right at the moment it is supposed to hand off
                    // seamlessly; only do it when Roots is reached without
                    // having gone through Transition first (a manual phase
                    // jump from the operator's navigator).
                    if (p == show::Phase::Roots) {
                        if (!rootSeqBegunForSitting) {
                            // Reached without going through Transition -- the
                            // operator's phase navigator. Since the press now
                            // lives in this same scene, "Roots" has to mean
                            // the state the press *ends* in: a fresh plant, no
                            // film, the mask already uncovered and wearing its
                            // face. Replaying the press here would make the
                            // two buttons do the same thing a second apart.
                            if (roots.valid()) { roots.replant(); roots.skipCloth(); }
                            rootFaceTrisUploaded = false;
                            rootsClock = 0.0;
                            clothClearAtPreWarm = 0.0;
                            clothClearHoldElapsed = true;
                            // The bank on the other masks, as at Transition
                            // entry; minus this sitting's capture if the
                            // jump came *back* to Roots after one was saved.
                            dealBankFaces(thisSittingCaptureId);
                            rootSeq.begin(roots, g_root_seq);
                        } else {
                            // The cut proper, arrived at through Transition:
                            // the sitting on mask 0 joins the bank. Not on
                            // the navigator path above -- there was no
                            // press, and whoever is in front of the sensor
                            // is not a sitting.
                            autoCaptureAtCut();
                        }
                        rootSeqBegunForSitting = false;
                    } else if (p != show::Phase::Transition) {
                        // A Transition the navigator abandoned (to Idle, say)
                        // must not leave "begun" latched: the next jump to
                        // Roots would then skip its own begin()/replant and
                        // auto-capture whoever is at the sensor as a sitting.
                        rootSeqBegunForSitting = false;
                    }
                    // The face sequence reseeds on every entry too, off the
                    // recorded track -- but only the track of the sitting now
                    // on mask 0. pendingFaceTrack is whatever the most recent
                    // finish() produced, and in the show that is the
                    // *previous* visitor's (a recording ends when its visitor
                    // has left, which is after their Roots); playing it here
                    // put the last visitor's identity on this one's mask from
                    // the first frame of Roots. It is not cleared, so
                    // re-entering Roots for the same sitting (toggling the
                    // phase by hand) still replays that sitting.
                    if (p == show::Phase::Roots) {
                        const bool ownTrack = !thisSittingCaptureId.empty() &&
                                              pendingFaceTrack.id == thisSittingCaptureId;
                        rootFaceSeq.begin(ownTrack ? pendingFaceTrack : mirror::FaceTrack{},
                                          g_fitter.basis());
                    }
                    // The sound follows the same edge as the scene, from the
                    // same place, so there is no second notion of "which phase
                    // is up" that could drift from this one.
                    //
                    // Each phase says what it wants *playing*, not what to
                    // change: posting the mirror bed's Play on every entry into
                    // Idle would restack a second voice on top of the one
                    // already running. So the beds are started on the entry
                    // that first needs them and stopped on the entry that does
                    // not, and the crossfades are the Stop actions' fade times
                    // in Wwise, not something timed here.
                    if (g_audio_on && g_audio_auto) {
                        g_audio.setState("Phase", show::PhaseName(p));
                        switch (p) {
                            case show::Phase::Idle:
                                // An empty room is the pluck and nothing else.
                                // The pad is a response to somebody being
                                // there, so it has no business playing to an
                                // empty room -- and its 8s stop fade means the
                                // last person's chord is still dying away as
                                // this posts.
                                //
                                // FirePlucker itself now rings all the way
                                // through Fitting/Transition/Roots (see the
                                // Phase::Roots case below), so by the time a
                                // visitor's loop lands back on Idle there is
                                // already a voice up -- stop it explicitly
                                // before re-posting, or the fresh Play would
                                // stack a second instance on top of it rather
                                // than replacing it.
                                g_audio.post("Stop_FirePlucker");
                                g_audio.postFirePlucker();
                                g_audio.post("Stop_Pad");
                                g_audio.post("Stop_Amb_Roots");
                                break;
                            case show::Phase::Fitting:
                                // The pluck keeps running underneath -- this is
                                // a layer arriving, not a change of music. The
                                // pad's own 6s envelope attack is the fade-in;
                                // nothing here times it.
                                g_audio.postFirePlucker();
                                g_audio.post("Play_Pad");
                                break;
                            case show::Phase::Transition:
                                // The pluck itself keeps ringing -- see the
                                // Comb_Tuning override below, which glides it
                                // down to a very low register instead. It
                                // keeps ringing through Roots too now (see
                                // the Phase::Roots case): its own marker
                                // stream, run through the same effect bus, is
                                // what paces the beat 3/4 mask switches.
                                g_audio.post("Play_Transition");
                                g_audio.post("Stop_Pad");
                                break;
                            case show::Phase::Roots:
                                g_audio.post("Play_Amb_Roots");
                                g_audio.post("Stop_Pad");
                                // FirePlucker is left running (still at the
                                // Transition hand-off's low register, below)
                                // rather than stopped: its markers are the
                                // "fire reverb drop" cues RootSequence's
                                // Reveal stage steps on.
                                // Stopped only on the way back to Idle, which
                                // re-posts Play_FirePlucker fresh for the next
                                // visitor.
                                break;
                            default:
                                break;
                        }
                    }
                }

                // Set every frame rather than on entry, so the diagnostic views
                // are a lens over the running piece rather than a fourth thing
                // that can be left switched on: drop the override and the phase
                // is still whatever it was, still showing what it should.
                scene = (g_view_override >= 0) ? g_view_override
                                               : g_show_scene[(int)g_show.phase()];

                // Idle's fade-in from black, started at the entries()-diff
                // above. Timed off nowT rather than dt so pausing the show
                // (which stops advance() but not the render loop) does not
                // stall it -- there is no clock this could be inconsistent
                // with, unlike the outro, which is why that one uses dt.
                if (g_idle_intro_t0 >= 0.0) {
                    const float t = g_idle_intro_seconds > 0.f
                        ? (float)((nowT - g_idle_intro_t0) / g_idle_intro_seconds)
                        : 1.f;
                    g_screen_fade = 1.f - std::clamp(t, 0.f, 1.f);
                    if (t >= 1.f) g_idle_intro_t0 = -1.0;
                }

                // --- honour a requested fit ---------------------------------
                //
                // Here rather than at the phase entry that asked for it: this is
                // the first point where the frame, the crop and the mask have
                // all settled for this frame, and it is the same data the manual
                // "fit" button on the mirror page works from -- so an automatic
                // fit and a hand-started one are the same operation.
                //
                // `live_fresh` deliberately is not required. The sensor runs at
                // 30 Hz under a faster render loop, so most frames have nothing
                // new; live_rgb still holds the last one at the right size, and
                // waiting for a fresh frame would stall the fit for no reason.
                // --- the frequency ramp, advanced ---------------------
                //
                // Before the arm is honoured, because the value it lands on is
                // the one beginFit seeds the optimiser from.
                if (g_w0_t0 >= 0.0) {
                    const float t = W0RampT(nowT);
                    // Smoothstep rather than linear: the field gaining detail
                    // is on screen, and a ramp that starts and stops abruptly
                    // reads as a glitch rather than as the piece doing
                    // something.
                    const float e = t * t * (3.f - 2.f * t);
                    mirror.params().sine_w0 = g_w0_from + (g_w0_fit - g_w0_from) * e;
                    if (t >= 1.f) g_w0_t0 = -1.0;
                }

                if (g_fit_arm && g_fit_live && W0RampT(nowT) >= 1.f &&
                    live_rgb.size() == size_t(fit_w) * fit_h * 3 && fit_w > 0) {
                    mirror::PondParams& FP = mirror.params();
                    if (g_have_mask) {
                        mirror.pond().beginFit(live_rgb, fit_h, fit_w, FP, g_fit_mask);
                    } else {
                        mirror.pond().beginFit(live_rgb, fit_h, fit_w, FP);
                    }
                    // See clearLastLoss()'s comment: without this, the frames
                    // between this beginFit() and the first real fitStep()
                    // still report the last visitor's converged loss.
                    mirror.clearLastLoss();
                    g_fit_arm = false;
                    if (g_show_log)
                        printf("show: fit started (%dx%d, %d px%s)\n", fit_w, fit_h,
                               mirror.pond().fitPixels(),
                               g_have_mask ? ", cropped" : "");
                }
            }

            // --- the room, to the sound engine ---------------------------
            //
            // After the show block so SceneProgress is this frame's, and after
            // the tracker so the presence signals are too. Every frame whether
            // or not a face is present: an empty room is a value, and one that
            // has to keep arriving for the smoothing to walk the sound down.
            {
                g_presence.update(g_face,
                                  g_track_h > 0 ? (float)g_track_w / (float)g_track_h : 1.f,
                                  (float)dt);
                const mirror::PresenceSignals& ps = g_presence.signals();

                mirror::AudioParams ap;
                ap.proximity = ps.proximity;
                ap.movement  = ps.movement;
                ap.centering = ps.centering;
                ap.head_yaw  = ps.head_yaw;
                ap.head_tilt = ps.head_tilt;
                // How well she has been captured, as one number: the *neural*
                // (CPPN/pond) fit's training loss against the threshold the
                // fitting phase waits on -- not the one-shot mesh/identity
                // fit (g_id_residual), which only ever produces a single
                // value a second or two into the phase and says nothing
                // about how the live fit is doing frame to frame. Loss falls
                // fast early and slowly thereafter, so a linear map against
                // the threshold hit 1.0 almost immediately; mapped in log
                // space instead (1/(1+loss/threshold), equivalent to a
                // sigmoid of log(loss/threshold)), so it's the *ratio* the
                // loss has closed that matters, not the absolute distance --
                // still half scale at exactly the threshold, but it keeps
                // tightening at a matching pace after, all the way in.
                // fitting() can go true a frame or more before the first
                // fitStep() actually runs (see W0RampT's gate above), during
                // which lastLoss() is still whatever it was left at -- either
                // clearLastLoss()'s -1 sentinel, or, before that fix existed,
                // the *previous* visitor's converged loss. Either way it is
                // not a real loss for this fit, so it maps to 0 explicitly
                // rather than through the ratio below, which was built for
                // loss >= 0 and does something undefined (or, for the -1
                // case, exactly the false-convergence spike this comment is
                // here to prevent) when handed a negative one.
                ap.fit_level = (mirror.pond().fitting() && mirror.lastLoss() >= 0.f)
                    ? std::clamp(1.f / (1.f + mirror.lastLoss() /
                                     std::max(1e-4f, g_show_fit_loss_half)),
                                 0.f, 1.f)
                    : 0.f;
                // Mirrored into a global for ShowFitConverged() to read -- see
                // its declaration -- right where it's computed, so there's one
                // place that decides what the fit score is this frame, not two.
                g_fit_level_now = ap.fit_level;
                ap.scene_progress = g_show.phaseProgress();
                ap.key = g_audio_key;
                ap.intensity = g_audio_on ? g_audio_intensity : 0.f;
                ap.transpose = g_audio_transpose;

                // The harmony, from the fit level that was just computed above
                // and the same movement signal the room produced. The pad's own
                // voicing now lives entirely in Wwise's `ChordStage` state (see
                // chord.h); what crosses here is just the checkpoint gate and
                // the pluck's comb tuning, which comes out of the same root so
                // the two elements cannot drift out of tune with each other.
                g_chord.config().root = g_audio_key;
                g_chord.update(ap.fit_level, ap.movement, (float)dt);
                ap.comb_hz = g_chord.voicing().comb_hz;
                if (g_chord.stageChanged()) {
                    static const char* const kStageNames[mirror::Chord::kStages] = {
                        "Stage0", "Stage1", "Stage2", "Stage3", "Stage4"
                    };
                    g_audio.setState("ChordStage", kStageNames[g_chord.stage()]);
                }

                // The shepherd glissando: a second, continuous rise under the
                // chord that never resolves, layered in Wwise as octave-spaced
                // voices crossfading on this same `Transpose` RTPC (see
                // Mirror_Pad_Shepherd). Rate follows fit_level rather than the
                // clock, so it reads as the room responding rather than a loop;
                // it only runs while the pad itself is sounding.
                if (g_shepherd_on && g_show.phase() == show::Phase::Fitting) {
                    const float rate = g_shepherd_rate_min +
                        (g_shepherd_rate_max - g_shepherd_rate_min) * ap.fit_level;
                    g_shepherd_phase = std::fmod(g_shepherd_phase + rate * (float)dt, 12.f);
                    ap.transpose = g_shepherd_phase;
                }

                // The pad's flanger: a sweep that speeds up as the fit
                // converges, same idea as the shepherd's rate above but
                // spent on the pad's own colour instead of its pitch. Not
                // gated to Fitting -- fit_level is already 0 outside it (the
                // pond isn't training), so this settles to the slow end on
                // its own everywhere else.
                ap.flanger_rate = g_flanger_rate_min +
                    (g_flanger_rate_max - g_flanger_rate_min) * ap.fit_level;

                // The Transition handoff drops the pluck to a very low
                // register -- not a chord tone, so it bypasses Chord
                // entirely. The pluck event itself keeps playing (see the
                // Phase::Transition and Phase::Roots cases above); the
                // effect's own Glide portamentos down to this from wherever
                // the pluck was, and it holds there through Roots too, since
                // the pluck is still ringing (and still the source of the
                // beat 3/4 marker cues) rather than reverting to the Fitting
                // register it never actually left musically.
                if (g_show.phase() == show::Phase::Transition ||
                    g_show.phase() == show::Phase::Roots) {
                    constexpr float kTransitionCombHz = 25.f;  // 20-40 Hz
                    ap.comb_hz = kTransitionCombHz;
                }

                g_audio.update(ap);
            }

            // --- colour follows the fit ----------------------------------
            //
            // After the audio block because that is where `g_fit_level_now` is
            // computed, and before the fit steps and the render below, so the
            // frame that is drawn is the one this level asked for.
            //
            // Runs in every phase, not just Fitting. `g_fit_level_now` reads
            // zero the moment the pond stops fitting, so a phase test here
            // would be doing the ratchet's job badly: the ratchet is what
            // holds the colour through the transition and the roots, and it
            // holds it whether the level fell because the sitting moved on or
            // because a training step went badly. Idle's entry is the one
            // place the colour is taken back out.
            if (g_colour_fit_on && g_colour_idle >= 0.f) {
                const float shaped = std::clamp(
                    g_fit_level_now / std::max(1e-3f, g_colour_fit_full), 0.f, 1.f);
                const float target = g_colour_from +
                                     (g_colour_fit_max - g_colour_from) *
                                         (shaped * shaped * (3.f - 2.f * shaped));
                // One way only, and no faster than the slew: see the note on
                // g_colour_fit_secs. A converged fit that wobbles must not
                // take the colour back out with it.
                const float step = g_colour_fit_secs > 0.f
                                       ? (float)dt / g_colour_fit_secs
                                       : 1.f;
                if (target > g_colour_now)
                    g_colour_now = std::min(target, g_colour_now + step);
                mirror.params().color_mix = g_colour_now;
            }

            // --- source overlay: upload the raw frame ---------------------
            //
            // Deliberately the *same* call the tracker makes (SourceRGB8), not a
            // second path to the sensor: the point of the overlay is to show the
            // picture the rest of the pipeline is looking at, mirroring and all.
            // A prettier but independently-fetched preview would be exactly the
            // kind of thing that agrees with the sensor while disagreeing with
            // the fit.
            static id<MTLTexture> srcTex = nil;
            static int srcTexW = 0, srcTexH = 0;
            static std::vector<unsigned char> srcRGB, srcRGBA;
            bool srcFresh = false;
            int pipW = 0, pipH = 0;
            const bool wantSource = g_show_source ||
                                    scene == (int)Scene::CamMask ||
                                    scene == (int)Scene::Camera;
            if (wantSource && SourceReady()) {
                // Preview at the *composition's* aspect, not the source's.
                // Once the frame is a different shape from the sensor, the crop
                // is what the fit and the tracker are handed, and a preview of
                // the whole 16:9 sensor would be showing something no part of
                // the app ever sees -- which is exactly the wrong thing to be
                // looking at when the complaint is "the fit is not following
                // me". The mask editor draws this full-frame, so it also has to
                // be the shape the mask will be applied in.
                //
                // 320 on the long edge is enough to see a face in the corner and
                // cheap to box-filter down to; the editor gets a real resolution
                // because edges are what is being placed there.
                const bool full_frame = scene == (int)Scene::CamMask ||
                                        scene == (int)Scene::Camera;
                const int base = full_frame ? 960 : 320;
                if (compW >= compH) {
                    pipW = base;
                    pipH = std::max(1, int(int64_t(base) * compH / compW));
                } else {
                    pipH = base;
                    pipW = std::max(1, int(int64_t(base) * compW / compH));
                }
#if MIRROR_HAVE_KINECT
                // Advance the retained snapshot when nothing else did. Without
                // this the overlay (and the tracker, which reads the same
                // snapshot) would sit on one frozen frame whenever the live fit
                // is off -- and a frozen preview is worse than none, because it
                // looks like a working camera.
                if (!source_polled && g_source == (int)Source::Kinect &&
                    g_kinect.isOpen()) {
                    // pump(), not poll(): this only needs the snapshot moved
                    // along. poll() here box-filtered the whole 1920x1080 frame
                    // into a scratch buffer that nothing ever read -- the most
                    // expensive no-op in the loop, paid on every frame the live
                    // fit was disarmed.
                    g_kinect.pump();
                }
#endif
                // The corner thumbnail is point-sampled: it is a few hundred
                // pixels wide, nothing downstream measures it, and box-filtering
                // the whole sensor frame for it was the one resample in the loop
                // that bought nothing at all.
                //
                // The full-screen views keep the filter. The mask editor is a
                // view you judge edges in -- which is what it is for -- and it
                // only runs when it is the scene on screen, so it is not in the
                // show's budget at all.
                if (SourceRGB8(pipW, pipH, srcRGB, /*filtered=*/full_frame) &&
                    srcRGB.size() == size_t(pipW) * pipH * 3) {
                    if (!srcTex || srcTexW != pipW || srcTexH != pipH) {
                        MTLTextureDescriptor* td = [MTLTextureDescriptor
                            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                         width:pipW
                                                        height:pipH
                                                     mipmapped:NO];
                        td.usage = MTLTextureUsageShaderRead;
                        td.storageMode = MTLStorageModeManaged;
                        srcTex = [ctx.device() newTextureWithDescriptor:td];
                        srcTexW = pipW; srcTexH = pipH;
                    }
                    srcRGBA.resize(size_t(pipW) * pipH * 4);
                    for (size_t i = 0, n = size_t(pipW) * pipH; i < n; ++i) {
                        srcRGBA[i * 4 + 0] = srcRGB[i * 3 + 0];
                        srcRGBA[i * 4 + 1] = srcRGB[i * 3 + 1];
                        srcRGBA[i * 4 + 2] = srcRGB[i * 3 + 2];
                        srcRGBA[i * 4 + 3] = 255;
                    }
                    [srcTex replaceRegion:MTLRegionMake2D(0, 0, pipW, pipH)
                              mipmapLevel:0
                                withBytes:srcRGBA.data()
                              bytesPerRow:size_t(pipW) * 4];
                    srcFresh = true;
                }
            }

            // Raindrops belong to Idle -- the init phase, face gone, network
            // untrained for the next visitor -- and nowhere else. Fitting is
            // the one this actually protects: the ripple field is signal the
            // network's target does not contain, so it has to be off for the
            // whole time the pond is being fit, not just toggled off by hand
            // and forgotten. Transition and Roots have no fit running either,
            // but they are their own visual beat and were never meant to
            // carry rain. Driven every frame rather than left to the panel's
            // "raindrops" checkbox, which used to leave this to hand-toggling
            // (and to whatever it was last left at).
            const show::Phase dropPhase = g_show.phase();
            if (mirror.valid())
                mirror.params().drops_on = (dropPhase == show::Phase::Idle);

            // Audio onsets -> raindrops. Polled here, once per frame and
            // whatever scene is up: the tap is a live input, and letting it
            // back up while another scene is showing would land the whole
            // backlog at once on the way back to the mirror. The phase check
            // above already keeps these from rendering outside Idle; skipping
            // the trigger call too just avoids queuing work that would only
            // be thrown away.
            {
                const std::vector<mirror::AudioOnset> hits = g_pulses.poll();
                if (g_pulse_drops && mirror.valid() && dropPhase == show::Phase::Idle) {
                    for (const mirror::AudioOnset& e : hits)
                        mirror.pond().triggerDrop(e.strength * g_pulse_gain, e.pan);
                }
            }

            // Pluck-bed crackle onsets -> raindrops, and (now that the pluck
            // rings all the way through Roots too, see the Phase::Roots audio
            // case) the same cue stream doubling as RootSequence's "fire
            // reverb drop" markers for the Reveal stage -- see rootMarkerHit
            // below. Drained here, once per frame, regardless of scene: the
            // tap is a live input and letting it back up while another scene
            // is showing would land the whole backlog at once on return.
            const std::vector<mirror::MarkerHit> pluckHits = g_audio.pollFirePluckerMarkers();
            const bool rootMarkerHit = !pluckHits.empty();
            {
                const bool active = g_pluck_drops && mirror.valid() &&
                                     dropPhase == show::Phase::Idle;
                if (active) {
                    for (const mirror::MarkerHit& e : pluckHits)
                        mirror.pond().triggerDrop(e.strength * g_pluck_drop_gain, 0.f);
                }
            }

            // Room responsivity for the root scene's key light: the mic's own
            // smoothed level, and wherever the tracked visitor currently sits
            // in frame. Set every frame regardless of which Roots-related
            // branch below actually runs (pre-warm during Transition, or the
            // literal Roots phase) -- both call roots.advance(), which is
            // where these are consumed. See RootScene::setAmbientLevel/
            // setTrackedPosition.
            roots.setAmbientLevel(g_mic.level());
            roots.setTrackedPosition(g_face.centre_x, g_face.centre_y,
                                     g_track_on && g_face.valid);

            id<MTLTexture> sceneTex = nil;

            // The mirror's frame, trained and rendered. A lambda because two
            // scenes need exactly this and a copy in each would be two places
            // for the training schedule to drift apart.
            auto renderMirror = [&]() -> id<MTLTexture> {
                mirror.ensureSize(compW / std::max(1, downscale), compH / std::max(1, downscale));
                mirror.advance(dt);
                // Training runs here, not inside render(): one place, once per
                // frame, so the cost is attributable and the displayed frame is
                // always the post-step state.
                if (mirror.pond().fitting()) {
                    // Live feed: swap the target, keeping weights and Adam
                    // state. beginFit() here would reset the optimiser every
                    // frame and the fit would never build enough momentum to
                    // follow motion (measured 677x worse tracking error).
                    if (g_fit_live && live_fresh) {
                        // The mask was built at the fit grid's size in
                        // ApplyHeadMode, from normalised landmarks -- a rescale
                        // of the outline rather than a resample of any image.
                        // With a mask, the training pass gathers only those
                        // pixels: a face is ~4% of the frame, so a step costs
                        // ~4% of the unmasked one.
                        if (g_have_mask) {
                            mirror.pond().updateFitTarget(live_rgb, fit_h, fit_w,
                                                          g_fit_mask);
                        } else {
                            mirror.pond().updateFitTarget(live_rgb, fit_h, fit_w);
                        }
                        ++g_target_swaps;
                    }
                    const FitTune& tune = g_have_mask ? g_tune_crop : g_tune_full;
                    mirror.fitSteps(tune.steps, tune.lr);
                }
                id<MTLTexture> out = mirror.render();

                // Sample the neural texture onto the fitted mesh. This runs on
                // the mirror's own output, so the mask ends up wearing the
                // network's reconstruction of the face rather than the raw
                // camera pixels -- which is the point: what the mask carries
                // into the root scene is what the mirror made of the person.
                //
                // Sampled at the *pinned* position, not the landmark one: the
                // render puts the face wherever the head mode put it.
                //
                // Cheap enough to do every frame: 2056 bilinear samples.
                if (g_texture_mask && g_track_on && g_face.valid &&
                    g_fitter.valid() && mirror.pond().fitted()) {
                    float ps = 1.f, uo = 0.f, vo = 0.f;
                    PinTransform(ps, uo, vo);
                    g_fitter.sampleTexture(mirror.lastImageRGB(),
                                           mirror.lowW(), mirror.lowH(),
                                           g_track_w, g_track_h, g_face_colors,
                                           ps, uo, vo);
                    g_face_colors_fresh = true;
                }
                return out;
            };

            // Fog only exists in the Roots renderer -- TransitionScene has
            // none -- so it fades in over the Face stage instead of snapping
            // on, or the instant the cloth falls away/the composite window
            // ends would read as a pop. Flat at the phase's own intensity
            // after that. `clock` is rootsClock during pre-warm and during
            // the literal Roots phase alike, so the fade starts counting the
            // moment compositing begins, not just at the phase cut.
            auto applyFogFade = [&](double clock) {
                const float fadeSecs = std::max(1e-3f, g_root_seq.fog_fade_seconds);
                const float ft = std::clamp((float)(clock / fadeSecs), 0.f, 1.f);
                const float target = g_phase_fog_intensity[(int)show::Phase::Roots];
                roots.renderer().fog.visibility =
                    kFogClearVisibility + (target - kFogClearVisibility) * ft;
            };

            // Pause, in the root scene, holds the *scene*: not only the show's
            // phase clock (see g_show.advance above) but the sequence, the
            // sim, the cloth, the face playback and recording, the fog fade
            // and the mirror under the Transition -- so the operator can dial
            // in lighting and materials on one frame. The scene still
            // advances with dt 0 and renders every frame (RootScene::advance's
            // header), so every panel change shows on the held frame.
            const bool rootHold = g_show_paused;
            const double rootDt = rootHold ? 0.0 : dt;
            // The panel's jump row (g_root_jump): a cut to the start of a
            // stage, honoured here before the sequence steps so the frame it
            // lands on is this one. Only while the sequence is running -- the
            // panel greys the row out otherwise, but the request is cleared
            // regardless so a click from an inactive phase cannot fire later.
            auto honourRootJump = [&]() {
                const int want = g_root_jump;
                g_root_jump = -1;
                if (want < 0 || want >= (int)RootSequence::Stage::Done) return;
                if (!rootSeqActive || !rootSeq.valid()) return;
                rootSeq.jumpTo((RootSequence::Stage)want, roots, g_root_seq, rootsClock);
                // Past Face the film is over (jumpTo retired it), so the
                // Transition's own gate on the cut to Roots is met now
                // rather than a clear-tail later.
                if (want > (int)RootSequence::Stage::Face) {
                    if (clothClearAtPreWarm < 0.0) clothClearAtPreWarm = rootsClock;
                    clothClearHoldElapsed = true;
                }
            };
            // The moment the viewer stops driving mask 0 (the sequence leaving
            // Face, by its own clock or a jump), the mask freezes on whatever
            // pose their head was in on that last frame -- and a tilted head
            // left the face askew in the nest the sim grew square to the
            // mask's frame, the same fault the bank's captures had. Upload
            // it once more, squared: the fitter's own rotation undone about
            // the centroid, exactly as autoCaptureAtCut saves it. Only the
            // live tracker's mesh: a loaded capture or a replayed sitting is
            // already the mask's own business.
            auto squareAnchorMaskOnLeavingFace = [&](RootSequence::Stage before) {
                if (!rootSeqActive || !rootSeq.valid()) return;
                if (before != RootSequence::Stage::Face || rootSeq.stage() == RootSequence::Stage::Face) return;
                if (!g_capture_loaded.empty() || rootFaceSeq.valid()) return;
                if (!(g_fitter.valid() && roots.usingFittedFace())) return;
                std::vector<float> v = g_fitter.vertices();
                if (v.size() < 9) return;
                const float* r = g_fitter.rotation();
                const float rt[9] = {r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]};
                mirror::RotateAboutCentroid(v, rt);
                roots.setFittedFace(v, rootFaceTrisUploaded ? std::vector<int>()
                                                            : g_fitter.basis().triangles());
                rootFaceTrisUploaded = true;
            };
            g_root_stage = -1;   // set below by whichever root branch renders

            // Hand the captured neural texture over. The mirror is not running
            // by the time the mask is on screen -- only one sim runs at a time
            // -- so there is no live texture left to sample; what the mask
            // wears is whatever was captured while the mirror still had the
            // person. Uploaded once, on the frame after capture, because it
            // does not change again until the mirror runs again.
            //
            // Shared by the Transition and Roots branches rather than living
            // in Roots alone, which is where it used to be. That was wrong the
            // moment the press moved into RootScene: the mask the cloth
            // uncovers is drawn by the Transition branch, and with no colours
            // uploaded yet it wore the flat fallback material for the whole
            // reveal, then changed appearance at the cut to Roots -- the face
            // arriving one phase after the face was revealed.
            auto uploadFaceColorsIfFresh = [&]() {
                if (g_capture_loaded.empty() && g_face_colors_fresh &&
                    !g_face_colors.empty()) {
                    roots.setFaceColors(g_face_colors);
                    g_face_colors_fresh = false;
                }
            };

            if (scene == (int)Scene::Mirror && mirror.valid()) {
                sceneTex = renderMirror();
            } else if (scene == (int)Scene::FitView && fitview.valid()) {
                // Same mirror frame, drawn flat with the mask and the mesh on
                // top of it. Deliberately runs the training too: a diagnostic
                // that froze the thing it is diagnosing would only ever show
                // the moment the scene was entered.
                fitview.setBackground(renderMirror());
                if (g_have_mask && fit_w > 0) {
                    fitview.setMask(g_fit_mask, fit_w, fit_h);
                } else {
                    fitview.clearMask();
                }
                if (g_track_on && g_face.valid && g_fitter.valid()) {
                    float ps = 1.f, uo = 0.f, vo = 0.f;
                    PinTransform(ps, uo, vo);
                    static std::vector<float> mesh_uv;
                    g_fitter.projectNormalised(g_track_w, g_track_h, ps, uo, vo, mesh_uv);
                    static bool tris_sent = false;
                    fitview.setMesh(mesh_uv, g_face_colors,
                                    tris_sent ? std::vector<int>()
                                              : g_fitter.basis().triangles());
                    tris_sent = true;
                } else {
                    fitview.clearMesh();
                }
                fitview.ensureSize(compW, compH);
                sceneTex = fitview.render(cb);
            } else if (scene == (int)Scene::Camera && fitview.valid()) {
                // The camera, as it arrives, with nothing done to it. This is
                // the view for answering "is the sensor actually working" and
                // for setting the crop, and both questions are only answerable
                // against an unprocessed frame: a preview that had already had
                // the mask and the crop applied would agree with itself no
                // matter what the camera was doing.
                fitview.setBackground(srcTex);
                fitview.clearMask();
                fitview.clearMesh();
                fitview.ensureSize(compW, compH);
                sceneTex = fitview.render(cb);
            } else if (scene == (int)Scene::CamMask && fitview.valid()) {
                // The raw camera frame, full-frame, with the mask already
                // applied to it -- so what is being edited is the result, not a
                // rectangle floating over an unmasked preview. The handles are
                // drawn as an ImGui overlay further down, where the mouse is.
                fitview.setBackground(srcTex);
                fitview.clearMask();
                fitview.clearMesh();
                fitview.ensureSize(compW, compH);
                sceneTex = fitview.render(cb);
            } else if (scene == (int)Scene::Transition && roots.valid()) {
                // The transition is driven by the mirror, so the mirror keeps
                // rendering underneath it -- that texture is the film the
                // cloth (now RootScene's own, see root_scene.h's "the cloth"
                // section) samples. Its training is left alone: the effect is
                // a handoff, and a fit that kept moving during it would
                // change the sheet's skin mid-fall.
                mirror.ensureSize(compW / std::max(1, downscale), compH / std::max(1, downscale));
                if (!rootHold) mirror.advance(dt);
                roots.setPondTexture(mirror.render());

                // The mask's *shape*, re-sent every frame rather than latched
                // when the phase opened, so an expression keeps moving
                // through the press. Its *placement* is RootScene's own --
                // the anchor mask's fixed cavity frame (see root_sim.cpp) --
                // not a per-frame projection the way TransitionScene's was;
                // one placement, owned by RootScene, is the whole point of
                // this architecture. See root_scene.h's cloth section for
                // what that trades away (pixel-exact film registration during
                // the press) against what it gains (no second mask).
                //
                // Only while the sequence is still on Face: the viewer stops
                // driving the mask the moment Grow starts (the recording keeps
                // going -- RootFaceSequence plays it back later).
                const bool viewerDrivesMask =
                    !rootSeq.valid() || rootSeq.stage() == RootSequence::Stage::Face;
                if (g_fitter.valid() && g_track_on && g_face.valid && !rootHold) {
                    if (viewerDrivesMask) {
                        roots.setFittedFace(g_fitter.vertices(),
                                            rootFaceTrisUploaded ? std::vector<int>()
                                                                 : g_fitter.basis().triangles());
                        rootFaceTrisUploaded = true;
                    }
                    // Same live fit, kept rather than thrown away this time --
                    // see faceTrackRec's declaration above.
                    faceTrackRec.record(g_show.phaseTime(), g_fitter);
                    transitionExitPhaseTime = g_show.phaseTime();
                }
                // The mask the cloth is about to uncover has to already be
                // wearing the face -- see the lambda's own comment. Gated
                // like the mesh above: the mirror keeps sampling colours
                // every frame it renders, and once the mesh has frozen for
                // Grow the colours freeze with it.
                if (viewerDrivesMask) uploadFaceColorsIfFresh();
                // The capture of this sitting (g_capture_auto) is not taken
                // here but at the Transition -> Roots cut -- autoCaptureAtCut,
                // called from the phase-entry block -- from the same live fit
                // and colours this branch has been sending to mask 0. There
                // is no lock instant to hang it on any more: the press is
                // RootScene's own, and the mask stays live-driven through it.

                // The press is choreographed against the sequence's Face
                // stage, which sits at 2.6x the anchor's own extent -- close
                // enough that the film tents visibly over a brow and a nose.
                // The sequence is always what drives the camera here; only a
                // layout with no masks at all (the synthetic stand-in) leaves
                // it invalid and the fallback framing in charge.
                rootsClock += rootDt;
                const RootSequence::Stage stageBefore = rootSeq.stage();
                honourRootJump();
                const bool cleared = roots.clothCleared();
                if (cleared && clothClearAtPreWarm < 0.0) clothClearAtPreWarm = rootsClock;
                clothClearHoldElapsed = clothClearHoldElapsed || (clothClearAtPreWarm >= 0.0 &&
                    rootsClock >= clothClearAtPreWarm + g_root_seq.face_clear_tail_seconds);
                if (!rootHold) {
                    RootSequence::Inputs in;
                    in.clothCleared = cleared;
                    in.markerHit    = rootMarkerHit;
                    in.trackedValid = roots.trackedPosition(in.trackedX, in.trackedY);
                    rootSeq.step(roots, rootsClock, dt, g_root_seq, in);
                } else {
                    // The sequence owns simPaused and re-decides it on the
                    // next step; held for this frame only.
                    roots.simPaused = true;
                }
                squareAnchorMaskOnLeavingFace(stageBefore);
                if (rootSeq.valid()) g_root_stage = (int)rootSeq.stage();

                roots.ensureSize(compW / std::max(1, rootDownscale),
                                 compH / std::max(1, rootDownscale));
                applyFogFade(rootsClock);
                roots.advance(rootDt);
                sceneTex = roots.render(cb);
            } else if (scene == (int)Scene::Roots && roots.valid()) {
                // The roots pass is overdraw-bound (per-fragment ray-capsule
                // intersection, multiplied by how many capsules stack per pixel),
                // so cost scales with pixels x overdraw. Rendering below the window
                // resolution and bilinear-upsampling (present.metal) — with the fog
                // pass's FXAA-lite smoothing the low-res image first — is the main
                // lever. Auto-scale caps the internal max dimension so a 4K/Retina
                // window stays fast instead of collapsing on a dense/zoomed nest.
                int effDs = std::max(1, rootDownscale);
                if (rootAutoScale) {
                    int maxdim = std::max(compW, compH);
                    effDs = std::max(1, (maxdim + rootTargetDim - 1) / rootTargetDim);
                }
                // A fitted face on the root scene's masks, re-uploaded only
                // when the tracker actually produced a new detection -- the
                // rebuild walks every placed mask, so doing it on a frame where
                // nothing changed is pure cost.
                //
                // A loaded capture outranks the live tracker. The whole point of
                // one is that the sitter has gone: driving the masks from
                // whoever happens to be in front of the sensor now would
                // overwrite the face that was just carried in on the mask, one
                // frame after the transition handed it over.
                const bool viewerDrivesMask =
                    !rootSeqActive || !rootSeq.valid() ||
                    rootSeq.stage() == RootSequence::Stage::Face;
                if (!g_capture_loaded.empty()) {
                    // Already uploaded when it was loaded; nothing per frame.
                } else if (rootFaceSeq.valid()) {
                    // The sitting that just came through Transition outranks
                    // both a loaded capture's static mesh and the live
                    // tracker, for the same reason a loaded capture already
                    // does: driving the masks from whoever is in front of
                    // the sensor now would overwrite the face this phase is
                    // actually about. rootFaceSeq.step() below does the
                    // per-frame upload.
                } else if (g_drive_roots && g_track_on && g_fitter.valid() && g_face.valid &&
                           viewerDrivesMask && !rootHold) {
                    // ...and the live tracker only while the sequence is
                    // still on Face: from Grow on the mask is the sitting's,
                    // not whoever is in front of the sensor now.
                    roots.setFittedFace(g_fitter.vertices(),
                                        rootFaceTrisUploaded ? std::vector<int>()
                                                             : g_fitter.basis().triangles());
                    rootFaceTrisUploaded = true;
                } else if (!g_drive_roots && roots.usingFittedFace()) {
                    roots.clearFittedFace();
                    // clearFittedFace() puts faceTris_ back to the canonical
                    // mesh's topology; the next setFittedFace() has to send
                    // the fitter basis's triangles again or they mismatch its
                    // (differently-sized) vertex array -- see rootFaceTrisUploaded's
                    // declaration.
                    rootFaceTrisUploaded = false;
                }

                // Same gate as the mesh: a "fresh" flag left over from the
                // Transition branch (which stops uploading once Grow starts)
                // must not land the sensor's colours on a frozen mask.
                if (viewerDrivesMask) uploadFaceColorsIfFresh();
                roots.ensureSize(compW / effDs, compH / effDs);
                // rootsClock keeps counting seconds since Transition entry,
                // continuous across the pre-warm -> literal-Roots cut -- the
                // same clock RootSequence and (while it is still active)
                // faceTrackRec.record() use below.
                rootsClock += rootDt;
                const RootSequence::Stage stageBefore = rootSeq.stage();
                honourRootJump();
                if (rootSeqActive && !rootHold) {
                    // No wantOutro: the visitor leaving does not shorten the
                    // piece (see the Signals block above). The outro comes
                    // when the orbit has run its authored seconds.
                    RootSequence::Inputs in;
                    // clothCleared is definitionally true by the time Roots
                    // is literally entered (sceneDone() itself waited on
                    // clothClearHoldElapsed), but passed live rather than
                    // hardcoded so a manually-navigated phase jump (no
                    // Transition having run first) still behaves sanely.
                    in.clothCleared = roots.clothCleared();
                    in.markerHit    = rootMarkerHit;
                    in.trackedValid = roots.trackedPosition(in.trackedX, in.trackedY);
                    rootSeq.step(roots, rootsClock, dt, g_root_seq, in);
                    // fade() is 0 outside the outro, so this also takes the
                    // fade back off after a jump out of the Outro.
                    g_screen_fade = rootSeq.fade();
                    // The sequence has run its whole arc -- the orbit timed
                    // out, or the visitor left and the fade has landed. Move
                    // the show on if its own timeline has not already: the
                    // piece does not sit on a black screen waiting for a
                    // FaceAbsent edge that may never come.
                    if (rootSeq.done() && g_show.phase() == show::Phase::Roots)
                        g_show.goTo(show::Phase::Idle);
                } else if (rootHold) {
                    // Held: the sequence owns simPaused and re-decides it on
                    // the next step; this frame the growth stands still.
                    roots.simPaused = true;
                }
                squareAnchorMaskOnLeavingFace(stageBefore);
                if (rootSeqActive && rootSeq.valid()) g_root_stage = (int)rootSeq.stage();
                if (rootFaceSeq.valid() && !rootHold)
                    rootFaceSeq.step(roots, g_show.phaseTime(), dt);
                // The live tracker keeps recording, for as long as the same
                // visitor is still actually present -- see the phase-agnostic
                // finish() trigger above, which ends this once they're gone.
                // transitionExitPhaseTime + g_show.phaseTime() picks up
                // exactly where Transition's own g_show.phaseTime()-based
                // timestamps left off, not rootsClock (which is
                // RootSequence's own clock, zeroed at pre-warm entry).
                if (faceTrackRecActive && g_track_on && g_face.valid && g_fitter.valid() &&
                    !rootHold)
                    faceTrackRec.record(transitionExitPhaseTime + g_show.phaseTime(), g_fitter);

                applyFogFade(rootsClock);

                roots.advance(rootDt);
                sceneTex = roots.render(cb);   // encodes geometry + fog passes into cb
            }

            MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = drawable.texture;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].clearColor =
                layout.letterboxed ? MTLClearColorMake(0, 0, 0, 1)
                                   : MTLClearColorMake(0.05, 0.05, 0.06, 1.0);
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

            // MIDI, then the panel. Draining first means a knob moved this
            // frame is already in the parameter when the control draws it, so
            // the slider and the hardware never disagree on screen.
            if (g_midi.isOpen()) {
                static std::vector<midi::CC> ccs;
                g_midi.drain(ccs);
                for (const midi::CC& c : ccs) {
                    // Two CCs are the show's, not parameters: they are edges
                    // rather than values, which is what a cue is. Routed before
                    // ui::ApplyCC so a binding accidentally learned onto one of
                    // them cannot swallow the operator's override.
                    if (g_show_on && c.cc == g_show_cue_cc) {
                        if (c.value >= 64) g_show.go();
                        continue;
                    }
                    if (g_show_on && c.cc == g_show_phase_cc) {
                        // The full 0-127 range across the four phases, so a
                        // fader selects them as quarters and a pad sending 0 /
                        // 42 / 85 / 127 lands on one each.
                        const int p = std::min((int)show::Phase::Count - 1,
                                               c.value * (int)show::Phase::Count / 128);
                        g_show.goTo((show::Phase)p);
                        continue;
                    }
                    ui::ApplyCC(c.channel, c.cc, c.value);
                }
                // Devices plugged in mid-session are the normal case.
                static double last_scan = 0.0;
                if (nowT - last_scan > 2.0) { g_midi.rescan(); last_scan = nowT; }
            }
            ui::BeginFrame();

            ImGui_ImplMetal_NewFrame(rpd);
            ImGui_ImplGlfw_NewFrame();
            ImGui::NewFrame();

            // Keyboard cues, for rehearsal without a controller: 1-4 force a
            // phase, space fires the "go" cue. Guarded on WantCaptureKeyboard,
            // or typing a caption into the text field would jump the show
            // around. Read after NewFrame so the key state is this frame's.
            if (g_show_on && !ImGui::GetIO().WantCaptureKeyboard) {
                for (int p = 0; p < (int)show::Phase::Count; ++p) {
                    if (ImGui::IsKeyPressed((ImGuiKey)(ImGuiKey_1 + p), false))
                        g_show.goTo((show::Phase)p);
                }
                if (ImGui::IsKeyPressed(ImGuiKey_Space, false))
                    g_show.go();
            }

            // Leak-hunt harness: MIRROR_AUTOCYCLE=<seconds> forces a phase edge
            // on a timer, so a per-visitor leak shows up in a soak test without
            // a body in front of the Kinect. Round-robins Idle->Fitting->
            // Transition->Roots by default; MIRROR_AUTOCYCLE_PAIR=<a>,<b> (phase
            // indices, show::Phase order) bounces between just two phases
            // instead, which is how the transition_scene.mm savedPondTex leak
            // was isolated -- Idle<->Transition reproduced the growth alone
            // while Idle<->Fitting and Roots<->Idle did not.
            if (const char* e = getenv("MIRROR_AUTOCYCLE")) {
                static const double period = std::max(0.05, atof(e));
                static int pair_a = -1, pair_b = -1;
                static bool pair_checked = false;
                if (!pair_checked) {
                    pair_checked = true;
                    if (const char* p = getenv("MIRROR_AUTOCYCLE_PAIR"))
                        sscanf(p, "%d,%d", &pair_a, &pair_b);
                }
                static double t_next = 0.0;
                if (nowT >= t_next) {
                    t_next = nowT + period;
                    show::Phase next;
                    if (pair_a >= 0) {
                        next = (g_show.phase() == (show::Phase)pair_a)
                            ? (show::Phase)pair_b : (show::Phase)pair_a;
                    } else {
                        next = (show::Phase)(((int)g_show.phase() + 1) %
                                             (int)show::Phase::Count);
                    }
                    g_show.goTo(next);
                    printf("autocycle: -> %s\n", show::PhaseName(next));
                }
            }

            // F1 takes the UI away and brings it back. Not guarded on the show
            // being on -- it is wanted most when someone is looking at the
            // piece -- but text input keeps the key, so a caption being typed
            // cannot be interrupted by a stray function key.
            // Two keys, because on macOS F1 is the display's brightness unless
            // "use F-keys as standard function keys" is set, and an operator
            // who cannot get the panel back has lost the show.
            if (!ImGui::GetIO().WantTextInput &&
                (ImGui::IsKeyPressed(ImGuiKey_F1, false) ||
                 ImGui::IsKeyPressed(ImGuiKey_GraveAccent, false)))
                g_ui_visible = !g_ui_visible;

            // The readout is its own key, and deliberately not tied to the
            // panel: the case it exists for is a phase that will not advance
            // with the UI hidden, and having to bring the whole panel up to
            // find out why puts a wall of controls over the piece to read one
            // line of text.
            if (!ImGui::GetIO().WantTextInput &&
                ImGui::IsKeyPressed(ImGuiKey_F2, false))
                g_show_hud = !g_show_hud;

            // The panel and its overlays -- see panel.h/.mm. PanelFrameArgs
            // bundles the per-frame locals they read/write that aren't
            // already reachable through app_state.h globals.
            PanelFrameArgs panelArgs{
                mirror, roots, trans, text, textp,
                scene, fbw, fbh, compW, compH, layout, nowT, fit_w, fit_h,
                live_rgb, fpsShown,
                downscale, rootDownscale, rootAutoScale, rootTargetDim,
                rootSeed, fieldGrid,
                srcTex, srcTexW, srcTexH, netTex, netTexW, netTexH,
                pipW, pipH,
                srcFresh, netFresh,
            };
            DrawControlPanel(panelArgs);

            // --presettest, as a state machine over frames: a loaded value only
            // lands when the control next declares itself, so each step here
            // needs its own frame. Deliberately non-default values, all
            // distinct, so a field that reads back *another* field's value is
            // caught too and not just a field that is missing.
            if (g_roots_roundtrip) {
                static int rt_step = 0;
                static rootsim::SimParams rt_want;
                static int rt_bad = 0;
                const std::string rt_path = ui::BankDir(ui::Bank::Roots) +
                                            "/__roundtrip.roots";
                rootsim::SimParams& SP = roots.simParams();
                std::string rt_err;
                switch (rt_step) {
                    case 0:
                        SP.speciesXml = "Glycine_max.xml";
                        SP.N = 11;  SP.R0 = 17.5f; SP.Hh = 61.25f;
                        SP.startFrac = 0.21f; SP.endFrac = 0.87f;
                        SP.taperPower = 1.37f; SP.angleStepGoldenMult = 0.93f;
                        SP.distStepFrac = 0.11f; SP.dwellDays = 23.5f;
                        SP.weight = 0.77f; SP.mainTravelTrials = 19.f;
                        SP.lateralWeight = 0.31f; SP.dwellWeight = 0.83f;
                        SP.dwellLateralWeight = 0.71f; SP.sigma = 0.47f;
                        SP.viewCylLen = 9.5f; SP.maxHopDays = 71.f;
                        SP.travelSlack = 2.65f; SP.evenNests = false;
                        SP.reachMult = 1.9f; SP.travelPullReach = 1.45f;
                        SP.coneSurfaceTravel = true; SP.coneShellThickness = 5.5f;
                        SP.growthDt = 0.35f; SP.targetLift = 1.25f;
                        SP.spawnBehind = 0.75f; SP.seed = 4242u;
                        rt_want = SP;
                        break;
                    case 1:                     // the values are declared now
                        if (!ui::SaveBank(ui::Bank::Roots, rt_path, rt_err)) {
                            printf("  save: %s\n", rt_err.c_str()); ++rt_bad;
                        }
                        SP = rootsim::SimParams{};        // wipe to defaults
                        break;
                    case 2:
                        if (!ui::LoadBank(ui::Bank::Roots, rt_path, rt_err)) {
                            printf("  load: %s\n", rt_err.c_str()); ++rt_bad;
                        }
                        break;
                    case 3: {                   // the loaded values have landed
                        rootsim::SimParams got = SP, want = rt_want;
                        auto cmp = [&](const char* n, auto& g, auto& w) {
                            if constexpr (std::is_same_v<std::decay_t<decltype(g)>,
                                                         std::string>) {
                                if (g != w) {
                                    printf("  MISMATCH %-22s %s != %s\n", n,
                                           g.c_str(), w.c_str());
                                    ++rt_bad;
                                }
                            } else if constexpr (std::is_floating_point_v<
                                                     std::decay_t<decltype(g)>>) {
                                if (std::fabs(double(g) - double(w)) > 1e-4) {
                                    printf("  MISMATCH %-22s %g != %g\n", n,
                                           double(g), double(w));
                                    ++rt_bad;
                                }
                            } else {
                                if (g != w) {
                                    printf("  MISMATCH %-22s %lld != %lld\n", n,
                                           (long long)g, (long long)w);
                                    ++rt_bad;
                                }
                            }
                        };
                        // Walked from the field list rather than by hand, so a
                        // field added to SimParams and forgotten in the panel
                        // shows up here rather than in a rehearsal.
                        rootsim::visitSimParams(got, [&](const char* n, auto& g) {
                            rootsim::visitSimParams(want, [&](const char* n2, auto& w) {
                                if (std::string(n) != n2) return;
                                if constexpr (std::is_same_v<decltype(g), decltype(w)>)
                                    cmp(n, g, w);
                            });
                        });
                        remove(rt_path.c_str());
                        printf("presettest: %s\n", rt_bad ? "FAIL" : "OK");
                        fflush(stdout);
                        glfwSetWindowShouldClose(win, 1);
                        g_exit_code = rt_bad ? 1 : 0;
                        break;
                    }
                }
                ++rt_step;
            }

            // --roundtriptest, as a state machine over frames for the same
            // reason --presettest is one: a staged or loaded value only lands
            // when its control next declares itself. Walks the live registry
            // directly rather than a hand-written struct visitor, so it
            // covers every bank's ~350 real controls without anyone having to
            // keep a second list of what they are.
            if (g_full_roundtrip) {
                static int frt_step = 0;
                static std::vector<ui::ParamSnapshot> frt_before, frt_mutated;
                static const ui::Bank kBanks[] = {
                    ui::Bank::Machine, ui::Bank::Fit,   ui::Bank::Debug,
                    ui::Bank::Show,    ui::Bank::Look,  ui::Bank::Mirror,
                    ui::Bank::Roots};
                auto scratchPath = [](ui::Bank b) {
                    // Machine is one file, not a directory of presets --
                    // SaveBank deliberately never creates BankDir(Machine),
                    // so a scratch path under it would fail to open.
                    if (b == ui::Bank::Machine)
                        return ui::PresetDir() + "/__roundtrip_full" + ui::BankExt(b);
                    return ui::BankDir(b) + "/__roundtrip_full" + ui::BankExt(b);
                };
                switch (frt_step) {
                    case 0: {
                        // Snapshot, then stage a value guaranteed different
                        // from the current one for every live parameter.
                        frt_before = ui::Snapshot();
                        for (const auto& p : frt_before)
                            ui::StageValue(p.path, ui::MutatedLiteral(p.path));
                        break;
                    }
                    case 1: {
                        // The staged values landed this frame; snapshot again
                        // so comparison later is against what the controls
                        // actually took, not just what was asked for.
                        frt_mutated = ui::Snapshot();
                        break;
                    }
                    case 2: {
                        std::string e;
                        for (ui::Bank b : kBanks) {
                            if (!ui::SaveBank(b, scratchPath(b), e))
                                printf("  save %s: %s\n", ui::BankName(b), e.c_str());
                        }
                        break;
                    }
                    case 3: {
                        // Corrupt every value back to what it was before the
                        // mutation -- if a load silently no-ops, comparing
                        // against the pre-mutation value would look like a
                        // pass by coincidence; this makes sure the reload is
                        // what actually restores the mutated value.
                        for (const auto& p : frt_before)
                            ui::StageValue(p.path, p.literal);
                        break;
                    }
                    case 4: {
                        // The corruption lands this frame.
                        break;
                    }
                    case 5: {
                        // Merged: all seven banks load in this one frame, and
                        // none of them has had a frame to declare and consume
                        // its values yet -- without merge, each LoadBank call
                        // would wipe out the bank loaded just before it.
                        std::string e;
                        for (ui::Bank b : kBanks) {
                            if (!ui::LoadBank(b, scratchPath(b), e, /*merge=*/true))
                                printf("  load %s: %s\n", ui::BankName(b), e.c_str());
                        }
                        break;
                    }
                    case 6: {
                        // The loaded values land this frame; check next.
                        break;
                    }
                    case 7: {
                        const auto after = ui::Snapshot();
                        int total = 0, bad = 0;
                        for (const auto& want : frt_mutated) {
                            ++total;
                            const auto it = std::find_if(
                                after.begin(), after.end(),
                                [&](const ui::ParamSnapshot& p) { return p.path == want.path; });
                            if (it == after.end()) {
                                printf("FAIL %-55s missing after reload\n",
                                       want.path.c_str());
                                ++bad;
                                continue;
                            }
                            if (!ui::LiteralsMatch(want.path, want.literal, it->literal)) {
                                printf("FAIL %-55s wanted %-12s got %s\n",
                                       want.path.c_str(), want.literal.c_str(),
                                       it->literal.c_str());
                                ++bad;
                            }
                        }
                        if (!ui::UnassignedParams().empty()) {
                            printf("FAIL %zu parameter(s) in no bank -- untested by "
                                   "this loop, since no SaveBank call touches them\n",
                                   ui::UnassignedParams().size());
                            ++bad;
                        }
                        for (ui::Bank b : kBanks) remove(scratchPath(b).c_str());

                        printf("roundtriptest: %d/%d parameters round-tripped correctly\n",
                               total - bad, total);
                        printf("roundtriptest: %s\n", bad ? "FAIL" : "OK");
                        fflush(stdout);
                        g_exit_code = bad ? 1 : 0;
                        glfwSetWindowShouldClose(win, 1);
                        break;
                    }
                }
                ++frt_step;
            }

            // --rootpreset: apply the growth fields, let them declare, save.
            //
            // Two frames, for the same reason --presettest needs them: a value
            // written into SimParams here only becomes a registry value when
            // the panel next declares the control that owns it, and saving
            // before that writes the previous frame's numbers.
            if (!g_root_preset_name.empty()) {
                static int rp_step = 0;
                rootsim::SimParams& SP = roots.simParams();
                if (rp_step == 0) {
                    for (const auto& kv : g_root_preset_kv) {
                        const std::string key =
                            kv.first == "species" ? "speciesXml" : kv.first;
                        bool hit = false;
                        rootsim::visitSimParams(SP, [&](const char* name, auto& f) {
                            if (key != name) return;
                            hit = true;
                            using T = std::decay_t<decltype(f)>;
                            if constexpr (std::is_same_v<T, std::string>) f = kv.second;
                            else if constexpr (std::is_same_v<T, bool>)
                                f = atoi(kv.second.c_str()) != 0;
                            else if constexpr (std::is_same_v<T, int>)
                                f = atoi(kv.second.c_str());
                            else if constexpr (std::is_same_v<T, unsigned>)
                                f = (unsigned)strtoul(kv.second.c_str(), nullptr, 10);
                            else f = (T)atof(kv.second.c_str());
                        });
                        if (!hit) {
                            fprintf(stderr, "rootpreset: no growth field '%s'\n",
                                    kv.first.c_str());
                            g_exit_code = 1;
                        }
                    }
                } else {
                    const std::string path = ui::BankDir(ui::Bank::Roots) + "/" +
                                             g_root_preset_name + ui::BankExt(ui::Bank::Roots);
                    std::string err;
                    if (ui::SaveBank(ui::Bank::Roots, path, err)) {
                        printf("rootpreset: wrote %s (%d parameters in the bank)\n",
                               path.c_str(), ui::BankCount(ui::Bank::Roots));
                    } else {
                        fprintf(stderr, "rootpreset: %s\n", err.c_str());
                        g_exit_code = 1;
                    }
                    fflush(stdout);
                    glfwSetWindowShouldClose(win, 1);
                }
                ++rp_step;
            }

            if (g_panel_test) {
                // One tab page per frame. The height threshold is loose on
                // purpose -- this is not a layout test, it is the difference
                // between one page and all of them, which was 171px against
                // 2341px when the raw ImGui calls in hidden bodies were
                // escaping. Cycling every tab (not just whichever one is
                // selected by default) is what catches an ID or registry-path
                // collision that only exists once two controls share a tab.
                static bool any_bad = false;
                // The largest single tab (roots, ~170 params) runs a little
                // over 1300px; every tab drawn on top of each other, the
                // failure this check exists for, was 2341px on 7 tabs and
                // only grows with 9 -- 2000 comfortably separates the two.
                const bool height_ok =
                    g_panel_content_h > 40.f && g_panel_content_h < 2000.f;
                const auto collisions = ui::IdCollisions();
                const bool id_ok = collisions.empty();
                const bool path_ok = ui::DuplicatePaths().empty();
                const bool ok = height_ok && id_ok && path_ok;
                if (!ok) any_bad = true;
                printf("paneltest: tab %d/%d %s (content %.0f px, %d params)\n",
                       g_panel_test_tab + 1, g_panel_test_tab_count,
                       ok ? "OK" : "FAIL", g_panel_content_h, ui::DeclaredCount());
                if (!height_ok)
                    printf("  a hidden section is drawing: expected one tab page\n");
                for (const auto& c : collisions) {
                    printf("  id collision:");
                    for (const auto& p : c.paths) printf(" %s", p.c_str());
                    printf("\n");
                }
                if (!path_ok) {
                    printf("  duplicate registry path(s) this frame:");
                    for (const auto& p : ui::DuplicatePaths()) printf(" %s", p.c_str());
                    printf("\n");
                }
                fflush(stdout);
                ++g_panel_test_tab;
                if (g_panel_test_tab >= g_panel_test_tab_count) {
                    printf("paneltest: %s\n", any_bad ? "FAIL" : "OK");
                    fflush(stdout);
                    g_exit_code = any_bad ? 1 : 0;
                    glfwSetWindowShouldClose(win, 1);
                }
            }

            if (g_write_settings_doc) {
                const std::string p =
                    std::string(MIRROR_APP_SRC_DIR) + "/../SETTINGS.md";
                std::string e;
                if (ui::WriteSettingsDoc(p, e)) {
                    printf("settings doc: wrote %s (%d parameters)\n",
                           p.c_str(), ui::DeclaredCount());
                    if (!ui::UnassignedParams().empty())
                        printf("settings doc: %zu parameter(s) in no bank\n",
                               ui::UnassignedParams().size());
                } else {
                    fprintf(stderr, "settings doc: %s\n", e.c_str());
                }
                fflush(stdout);
                glfwSetWindowShouldClose(win, 1);
            }

            DrawOverlayWindows(panelArgs);

            ImGui::Render();

            // The text refracts through the ripples the mirror was *just*
            // rendered with, so the sources come from the pond rather than
            // being rebuilt from the clock here. In the other scenes there are
            // none, and the field is left unwarped and simply crisp.
            mirror::TextRipple tr;
            if (scene == (int)Scene::Mirror) {
                const mirror::PondParams& P = mirror.params();
                tr.k = P.ring_freq;
                tr.decay = P.decay;
                tr.core_r2 = P.core_rolloff ? P.core_radius * P.core_radius : 0.f;
                const auto& srcs = mirror.pond().lastSources();
                tr.n = int(std::min(srcs.size(), size_t(16)));
                for (int i = 0; i < tr.n; ++i)
                    for (int j = 0; j < mirror::RIPPLE_SRC_DIM; ++j) tr.src[i][j] = srcs[i][j];
            }
            mirror::TextParams eff = textp;
            text.update(eff);
            const float texAsp =
                sceneTex ? float(sceneTex.width) / float(sceneTex.height) : 1.f;
            const mirror::TextUniforms tu =
                text.uniforms(eff, texAsp, tr, glfwGetTime(), g_screen_fade);

            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpd];
            if (sceneTex) {
                // The composition lands in its own viewport rather than across
                // the drawable. The fullscreen triangle is in clip space, so
                // restricting the viewport is the whole of the letterbox --
                // no transform in present.metal, and the text overlay inside it
                // stays in composition coords and rotates nothing.
                [re setViewport:(MTLViewport){
                    (double)layout.vp_x, (double)layout.vp_y,
                    (double)layout.vp_w, (double)layout.vp_h, 0.0, 1.0}];
                present.encode(re, sceneTex, text.texture(), tu);
                // ImGui draws to the whole window: the panel belongs to the
                // machine this is being operated from, not to the frame.
                [re setViewport:(MTLViewport){0.0, 0.0, (double)std::max(1, fbw),
                                              (double)std::max(1, fbh), 0.0, 1.0}];
            }
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, re);
            [re endEncoding];

            [cb presentDrawable:drawable];
            [cb commit];

            // Windows that live outside the main one: their platform windows
            // are created, moved and drawn here, each on its own command
            // buffer (see imgui_impl_metal's Renderer_RenderWindow). This is
            // not optional -- the GLFW backend polls every viewport's window
            // at the top of the next frame, and a viewport that never got one
            // is a null dereference. After commit, so the composition is never
            // waiting on a panel.
            if (ImGui::GetIO().ConfigFlags & ImGuiConfigFlags_ViewportsEnable) {
                ImGui::UpdatePlatformWindows();
                // GLFW takes "floating" as a *creation hint* only, so the class
                // flag above reaches a viewport when its window is made and
                // never again -- and a viewport that is destroyed and remade
                // (the panel docked and pulled back out) can come back at the
                // ordinary level. Setting the attribute here is idempotent and
                // does not care when the window appeared.
                ImGuiPlatformIO& pio = ImGui::GetPlatformIO();
                for (ImGuiViewport* vp : pio.Viewports) {
                    if (vp == ImGui::GetMainViewport() || !vp->PlatformHandle) continue;
                    GLFWwindow* w = (GLFWwindow*)vp->PlatformHandle;
                    if (!glfwGetWindowAttrib(w, GLFW_FLOATING))
                        glfwSetWindowAttrib(w, GLFW_FLOATING, GLFW_TRUE);
                }
                ImGui::RenderPlatformWindowsDefault();
            }
        }

        double now = glfwGetTime();
        fpsAccum += now - lastTime; lastTime = now; fpsFrames++;
        if (fpsAccum >= 0.5) { fpsShown = fpsFrames / fpsAccum; fpsAccum = 0; fpsFrames = 0; }
    }

    // Before the window goes: the engine owns a real audio device and a couple
    // of threads, and leaving it running past the last RenderAudio() is how a
    // quit turns into a stuck tone.
    g_audio.term();
    g_mic.stop();

    ImGui_ImplMetal_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    ImGui::DestroyContext();
    glfwDestroyWindow(win);
    glfwTerminate();
    return g_exit_code;
}
