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

#include "metal_context.h"
#include "mirror_scene.h"
#include "fit_target.h"
#include "face_tracker.h"
#include "face_find.h"
#include "face_capture.h"
#include "face_track.h"
#include "root_structure.h"
#include "face_fit.h"
#if MIRROR_HAVE_KINECT
#include "kinect_target.h"
#include "kinect_log.h"
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
#include <atomic>
#include <chrono>
#include <cmath>
#include <type_traits>

// For the panel-height check in --paneltest: the layout cursor is the only
// honest way to ask "did a hidden section draw anyway".
#include "imgui_internal.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <random>
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
// The colour's own ease (see the "colour follows the fit" block in the
// render loop): where it started, where it is going, and when it began;
// t0 < 0 is "not easing". Reset wherever g_colour_now is.
static double g_colour_ease_t0 = -1.0;
static float  g_colour_ease_a = 0.f, g_colour_ease_b = 0.f;

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
// The source (sensor) frame's size, whichever source: false until there is one.
static bool SourceSize(int& w, int& h) {
    if (g_source == (int)Source::Photo) {
        w = g_photo_w; h = g_photo_h;
        return !g_photo.empty() && w > 0 && h > 0;
    }
#if MIRROR_HAVE_KINECT
    return g_kinect.frameSize(w, h);
#else
    return false;
#endif
}

// The video frame: the sensor less g_video_edge_crop on each side. What the
// tracker looks at and what a position is normalised across.
static mirror::SrcRect VideoRect(int sw, int sh) {
    const float c = std::min(std::max(g_video_edge_crop, 0.f), 0.45f);
    const int x = int(std::lround(c * sw));
    return mirror::SrcRect{x, 0, std::max(1, sw - 2 * x), sh};
}
bool VideoSize(int& w, int& h) {
    int sw = 0, sh = 0;
    if (!SourceSize(sw, sh)) return false;
    const mirror::SrcRect v = VideoRect(sw, sh);
    w = v.w; h = v.h;
    return true;
}

// The feed's rect of the source this frame (ComputeFeedRect for the
// composition), and the same rect in the tracker's pixels: g_face_w x
// g_face_h is the frame the landmarks are normalised to, and the frame the
// mesh fit is solved in. Set each frame ahead of the tracking (below).
static mirror::SrcRect g_feed_rect;
static bool g_feed_rect_valid = false;
static int g_face_w = 480, g_face_h = 270;

// Feed-normalised coordinates to the screen's: where a point of the feed's
// crop sits across the *sensor*, normalised, which is where it lands across
// the screen -- the face's place in the room mapped 16:9 onto 9:16, whatever
// the feed crop shows. Identity until a source is up.
void ScreenFromFeed(float& u, float& v) {
    int sw = 0, sh = 0;
    if (!g_feed_rect_valid || !SourceSize(sw, sh) || g_feed_rect.w <= 0 || g_feed_rect.h <= 0)
        return;
    const mirror::SrcRect vr = VideoRect(sw, sh);
    u = (u * g_feed_rect.w + g_feed_rect.x - vr.x) / float(vr.w);
    v = (v * g_feed_rect.h + g_feed_rect.y - vr.y) / float(vr.h);
}

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

// `from`/`to`: the image is of source rect `from` while the mask is drawn
// in the coordinates of rect `to` (the feed's) -- the tracker's whole-frame
// image. Without them the image is the feed itself.
static void ApplyCamMask8(std::vector<unsigned char>& rgb, int w, int h,
                          const mirror::SrcRect* from = nullptr,
                          const mirror::SrcRect* to = nullptr) {
    if (!g_cam_mask_on || w <= 0 || h <= 0 || rgb.size() != size_t(w) * h * 3) return;
    const bool remap = from && to && from->w > 0 && from->h > 0 && to->w > 0 && to->h > 0;
    for (int y = 0; y < h; ++y) {
        float v = (float(y) + 0.5f) / float(h);
        if (remap) v = (v * from->h + from->y - to->y) / float(to->h);
        for (int x = 0; x < w; ++x) {
            float u = (float(x) + 0.5f) / float(w);
            if (remap) u = (u * from->w + from->x - to->x) / float(to->w);
            const float m = CamMaskAt(u, v);
            if (m >= 1.f) continue;
            unsigned char* p = &rgb[(size_t(y) * w + x) * 3];
            for (int c = 0; c < 3; ++c) p[c] = (unsigned char)(p[c] * m + 0.5f);
        }
    }
}

// `filtered` false takes one source pixel per destination pixel instead of
// averaging the footprint -- for the overlay, which only has to look right.
// `whole` takes the video frame (VideoRect) instead of the feed crop -- the
// tracker's picture (see the tracking block in the loop) and the corner
// preview's; the camera mask is still the feed's, remapped onto it.
// `rect`, with `whole`, takes that rect of the source instead of the video
// frame -- the landmarker's crop around the face.
static bool SourceRGB8(int w, int h, std::vector<unsigned char>& out,
                       bool filtered = true, bool whole = false,
                       const mirror::SrcRect* rect = nullptr) {
    int sw = 0, sh = 0;
    mirror::SrcRect wholeRect, feedRect;
    if (whole) {
        if (!SourceSize(sw, sh)) return false;
        wholeRect = rect ? *rect : VideoRect(sw, sh);
        feedRect = g_feed_rect;
    }
    if (g_source == (int)Source::Photo) {
        if (g_photo.empty()) return false;
        const mirror::SrcRect r = whole ? wholeRect :
            mirror::ComputeFeedRect(g_photo_w, g_photo_h, w, h, g_feed);
        if (filtered) {
            mirror::DownsampleRectToRGB8(g_photo.data(), g_photo_w, g_photo_h,
                                         3, 0, 2, r, w, h, out);
        } else {
            mirror::PointSampleRectToRGB8(g_photo.data(), g_photo_w, g_photo_h,
                                          3, 0, 2, r, w, h, out);
        }
        ApplyCamMask8(out, w, h, whole ? &wholeRect : nullptr, whole ? &feedRect : nullptr);
        return true;
    }
#if MIRROR_HAVE_KINECT
    if (!(whole ? g_kinect.lastFrameRGB8(wholeRect, w, h, out, filtered)
                : g_kinect.lastFrameRGB8(w, h, out, filtered))) return false;
    ApplyCamMask8(out, w, h, whole ? &wholeRect : nullptr, whole ? &feedRect : nullptr);
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

// --- frame profile ----------------------------------------------------------
//
// Where a frame goes, for the fps in the title to be diagnosable rather than
// just read. ProfMark("name") closes the stage since the previous mark into
// that bucket; the GPU time of the frame's command buffer lands from its
// completion handler; "drawable" is the time blocked in nextDrawable, which
// is where a frame waits when the GPU (or the display) is the limit. Summed
// over half a second into g_frame_profile, which the panel shows next to
// the fps, and printed with MIRROR_PROFILE=1 so a run can be pasted back.
namespace {
struct FrameProf {
    std::vector<std::pair<std::string, double>> buckets;   // insertion order
    std::chrono::steady_clock::time_point last;
    std::atomic<double> gpuAccum{0.0};
    double frames = 0, since = 0;
    double lastPrint = 0;
    bool print = getenv("MIRROR_PROFILE") != nullptr;
    void begin() { last = std::chrono::steady_clock::now(); }
    void mark(const char* name) {
        const auto now = std::chrono::steady_clock::now();
        const double ms = std::chrono::duration<double, std::milli>(now - last).count();
        last = now;
        for (auto& b : buckets) if (b.first == name) { b.second += ms; return; }
        buckets.push_back({name, ms});
    }
    // Once per frame, after the last mark; `dt` is the wall time the frame took.
    void end(double dt, double nowT) {
        frames += 1; since += dt;
        if (since < 0.5) return;
        char line[512];
        int n = snprintf(line, sizeof line, "%.1f ms/frame:", since * 1e3 / frames);
        double cpu = 0;
        for (auto& b : buckets) {
            cpu += b.second;
            n += snprintf(line + n, sizeof line - size_t(n), " %s %.1f", b.first.c_str(), b.second / frames);
            b.second = 0;
        }
        const double gpu = gpuAccum.exchange(0.0);
        snprintf(line + n, sizeof line - size_t(n), " | cpu %.1f gpu %.1f", cpu / frames, gpu / frames);
        g_frame_profile = line;
        if (print && nowT - lastPrint > 2.0) { printf("profile: %s\n", line); fflush(stdout); lastPrint = nowT; }
        frames = 0; since = 0;
    }
};
FrameProf g_prof;
}  // namespace

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
//               the picture of "track" with the weights of "centred". The
//               shift is a latch (UpdateInputShift below), with its own gain
//               per phase and a size multiplier of its own.
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

// Defined below, next to the placement they describe: the mask, the region
// and the input shift all need them, and all are built before them.
static void PinTransform(float& scale, float& u, float& v);
static bool HeadPlacement(float& s, float& dcx, float& dcy);

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

// --- the room ---------------------------------------------------------------
//
// A reflection sits behind the glass at twice the viewer's distance, so on
// the glass it is half life-size whatever the distance, and it is at the
// viewer's own height, straight in front of them. The camera's picture is
// neither: its face shrinks as 1/d and sits wherever the lens, above the
// screen and looking down, saw it. This is the conversion, from the
// fitter's scale (sensor pixels per centimetre of head, the head model
// being in centimetres) and the camera's optics.

// Sensor px per cm of head, from the last frame the mesh was fitted on.
// Held across misses: the placement must not jump when the fit skips.
static float g_head_ppcm = 0.f;

// The visitor's place in the room: distance along the camera's axis, and
// across / up from the screen's centre, all in cm. Also the sensor's focal
// length in px, for whoever needs the same optics. False without a source
// or a fitted frame yet.
static bool MirrorGeometry(float& d, float& x, float& y, float& f) {
    int sw = 0, sh = 0;
    if (!g_feed_rect_valid || !SourceSize(sw, sh) || g_head_ppcm <= 0.f) return false;
    const float hfov = std::min(170.f, std::max(10.f, g_cam_hfov_deg)) * float(M_PI) / 180.f;
    f = 0.5f * float(sw) / std::tan(0.5f * hfov);
    d = f / g_head_ppcm * std::max(0.1f, g_dist_trim);
    // The head's centre in sensor px from the optical centre; y down.
    const float X = g_feed_rect.x + g_head_cx * g_feed_rect.w - 0.5f * float(sw);
    const float Y = g_feed_rect.y + g_head_cy * g_feed_rect.h - 0.5f * float(sh);
    x = X / f * d;
    // Tilted down by t, the camera's "down" leans toward the room and its
    // "forward" dips: height relative to the lens is -(y cos t + d sin t).
    const float t = g_cam_tilt_deg * float(M_PI) / 180.f;
    y = g_cam_above_cm - ((Y / f * d) * std::cos(t) + d * std::sin(t));
    return true;
}

// Where the head goes on screen, normalised: where the mirror would show it.
// Before the first fitted frame, where it is across the sensor.
static void HeadScreenPos(float& u, float& v) {
    float d, x, y, f;
    if (MirrorGeometry(d, x, y, f) && g_feed_rect.h > 0) {
        const float H = std::max(1.f, g_screen_h_cm);
        const float W = H * float(g_feed_rect.w) / float(g_feed_rect.h);
        u = 0.5f + x / W;
        v = 0.5f - y / H;
        return;
    }
    u = g_head_cx; v = g_head_cy;
    ScreenFromFeed(u, v);
}

// The scale that puts the head at a mirror's size: half life-size on the
// glass, eased toward the camera's own size by g_size_follows, times the
// artistic multiplier. 1 before the first fitted frame.
static float MirrorScale() {
    float d, x, y, f;
    if (!MirrorGeometry(d, x, y, f) || g_feed_rect.h <= 0) return 1.f;
    // A cm of head is g_head_ppcm sensor px, and the feed rect's height is
    // the frame's; a mirror wants 0.5 cm of the screen's height per cm.
    const float have = g_head_ppcm / float(g_feed_rect.h);
    const float want = 0.5f / std::max(1.f, g_screen_h_cm);
    const float k = std::min(1.f, std::max(0.f, g_size_follows));
    const float mirror = std::pow(want / have, 1.f - k);
    return mirror * std::max(0.1f, g_stab_size_mul);
}

// Where the crop lands in the frame, normalised. Everything but the centred
// mode puts the subject where the mirror would (HeadScreenPos).
static float CropCX() {
    if (g_head_mode == (int)HeadMode::Centred) return 0.5f;
    float u, v;
    HeadScreenPos(u, v);
    return u;
}
static float CropCY() {
    if (g_head_mode == (int)HeadMode::Centred) return 0.5f;
    float u, v;
    HeadScreenPos(u, v);
    return v;
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

// Whether the crop currently in force is a *held* one: the tracker lost the
// face for longer than its own hold, but a fit is live, so ApplyHeadMode kept
// last frame's mask and region rather than dropping to the whole feed. While
// this is set nothing may train -- the mask no longer says where the face is.
static bool g_mask_held = false;

// `fit_live`: a fit is in progress or finished (the trainer is ready). It
// decides what a lost face means. Without a fit, no crop simply means no
// crop. With one, losing the crop used to do three things at once, all of
// them wrong and all of them undone the moment the face came back: the
// region switched off, so the trained face was drawn at the live, drifting z
// instead of the one it was learned at and `grey outside` stopped applying
// (the whole frame in full colour, at a latent the weights were never
// trained for -- garbage, and saturated garbage at that); the fit grid
// swapped to the whole-feed one; and the trainer was handed the entire
// camera frame as its target at the feed lr, so the network started learning
// the room. The tracker's own hold is 0.6s and the show's fitting phase
// waits 9.9s before it gives up on an absent face, and in between it did
// this on every dropout -- a turn, a hand over the mouth, leaning in close --
// which read as the mirror flipping between two sets of weights.
//
// So: while a fit is live and the crop was there last frame, a lost face
// holds the last mask and region as they are, and g_mask_held tells the
// training path to sit out until the face is back. Idle's clearFit() (or the
// panel's) ends the hold, because there is no longer a fit to protect.
// The input shift, for the stabilised mode: a latch, not a position. Each
// frame the field moves by the head's displacement since the last one, scaled
// by the gain for the phase (a fraction in Idle, so a passer-by nudges the
// field rather than dragging it; full during the fit, where a face has to
// land at the same network input wherever the person stands -- and only the
// displacement matters for that, not where the shift started). A lost face
// holds the shift where it is; a new one picks up from there. Snapping back
// to zero on every loss was a visible jump in Idle, with nothing to justify
// it. It is zeroed once per cycle, at the Idle entry (see the phase switch).
//
// The head's own position, in coord space, is latched alongside: it is where
// the shift's falloff (ShiftFalloff) is centred, and it holds with the shift
// when the face is lost, for the same reason.
static float g_shift_x = 0.f, g_shift_y = 0.f;
static float g_shift_cx = 0.f, g_shift_cy = 0.f;
static void UpdateInputShift(float asp, bool fit_live) {
    static bool  prev_valid = false;
    static float prev_cx = 0.5f, prev_cy = 0.5f;
    if (g_head_mode != (int)HeadMode::Stabilised || !HaveCrop()) {
        prev_valid = false;
        return;
    }
    // Where the face lands on screen -- the same centre the placement uses,
    // so a subject clamped at the frame's edge stops moving the field too.
    float s = 1.f, cx = 0.5f, cy = 0.5f;
    if (!HeadPlacement(s, cx, cy)) { cx = g_head_cx; cy = g_head_cy; }
    if (prev_valid) {
        const bool idle = g_show_on ? (g_show.phase() == show::Phase::Idle) : !fit_live;
        const float gain = idle ? g_shift_gain_idle : g_shift_gain_fit;
        // Coord space spans (-asp, asp) x (-1, 1) over the frame, so a
        // normalised displacement doubles going in.
        g_shift_x += (cx - prev_cx) * 2.f * asp * gain;
        g_shift_y += (cy - prev_cy) * 2.f * gain;
    }
    g_shift_cx = (cx - 0.5f) * 2.f * asp;
    g_shift_cy = (cy - 0.5f) * 2.f;
    prev_cx = cx; prev_cy = cy; prev_valid = true;
}

static void ApplyHeadMode(mirror::PondParams& P, int fw, int fh, bool fit_live) {
    UpdateInputShift(fw > 0 && fh > 0 ? float(fw) / float(fh) : 1.f, fit_live);
    if (fit_live && g_have_mask && !HaveCrop() && fw > 0 && fh > 0 &&
        g_fit_mask.size() == size_t(fw) * fh) {
        g_mask_held = true;
        return;
    }
    g_mask_held = false;
    P.coord_off_x = P.coord_off_y = 0.f;
    P.shift_falloff = mirror::ShiftFalloff{};
    if (g_head_mode == (int)HeadMode::Stabilised) {
        P.coord_off_x = g_shift_x;
        P.coord_off_y = g_shift_y;
        P.shift_falloff = {g_shift_cx, g_shift_cy, g_shift_radius, g_shift_fade, g_shift_far};
    }
    P.region.on = false;
    P.region.use_field = false;
    P.z_free_outside = g_z_free;
    P.grey_outside = g_grey_out;
    g_have_mask = false;
    g_mask_bbox = mirror::DstRect{};
    if (!HaveCrop() || fw <= 0 || fh <= 0) return;

    const float asp = float(fw) / float(fh);

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

    s = std::min(6.f, std::max(0.1f, MirrorScale()));
    if (std::fabs(s - 1.f) < 1e-3f) s = 1.f;

    if (!centred) {
        // Where the mirror would show them (HeadScreenPos): the head box is
        // in the feed crop's coordinates, where its pixels are, and the
        // pixels are moved from there to here.
        float mx, my;
        HeadScreenPos(mx, my);
        // A scaled crop can run off the edge, and a subject half outside the
        // frame is half unsupervised. Clamped by the scaled half-extent, so
        // the box slides inward only as far as it must. A subject too big to
        // fit is centred instead, which is the only placement that keeps as
        // much of them as possible.
        const float hx = g_head_hx * s, hy = g_head_hy * s;
        dcx = (hx >= 0.5f) ? 0.5f : std::min(std::max(mx, hx), 1.f - hx);
        dcy = (hy >= 0.5f) ? 0.5f : std::min(std::max(my, hy), 1.f - hy);
        // No scale change and no move: nothing worth a resample.
        if (s == 1.f && std::fabs(dcx - g_head_cx) < 1e-4f && std::fabs(dcy - g_head_cy) < 1e-4f)
            return false;
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
        // The mic only scales the root scene's key light, and opening any
        // audio input puts macOS's orange recording dot in the corner of the
        // piece, which no one can switch off. The show runs without it.
        if (a == "--no-mic")       { g_no_mic = true; continue; }
        // Fullscreen is the default now (see app_state.mm); --fullscreen is
        // kept accepted, as a no-op, so existing launch scripts and the
        // launchd plist keep working unchanged. --windowed is the dev-build
        // opt-out, a 1280x720 titled window instead of the primary monitor.
        if (a == "--fullscreen")   { g_fullscreen = true; continue; }
        if (a == "--windowed")     { g_fullscreen = false; continue; }
#if MIRROR_HAVE_KINECT
        if (a == "--no-sensor")    { g_open_sensor = false; continue; }
        // Hidden dev hook: exercises the watchdog's recovery path -- close,
        // background reopen, swap back in -- without physically unplugging
        // anything. 5s into the run it calls the exact same "declare lost"
        // code a real stall or USB error would (see
        // KinectFitTarget::forceLossForTest). Frame dt is tracked for the
        // 20s after so a max can be printed -- the render loop must not
        // notice the recovery happening on the worker thread.
        if (a == "--kinect-drop-test") { g_kinect_drop_test = true; continue; }
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
    // macOS 26 draws a one-pixel hairline along the edge of every window,
    // borderless ones included, and the piece is a bright image with a grey
    // frame around it. The window is made a pixel larger than the monitor on
    // every side, so the hairline lands off screen. The composition loses a
    // one-pixel rim, which nobody sees.
    const int kBleed = mon ? 1 : 0;
    if (mon) {
        const GLFWvidmode* vm = glfwGetVideoMode(mon);
        if (vm) { W = vm->width + 2 * kBleed; H = vm->height + 2 * kBleed; }
        glfwWindowHint(GLFW_DECORATED, GLFW_FALSE);
        glfwWindowHint(GLFW_FLOATING, GLFW_TRUE);
    }
    GLFWwindow* win = glfwCreateWindow(W, H, "neuromirror ⇄ roots", nullptr, nullptr);
    if (!win) { fprintf(stderr, "window failed\n"); glfwTerminate(); return 1; }
    if (mon) {
        // The menu bar and Dock sit above a floating window, whatever its
        // size, so a fresh account (whose menu bar does not auto-hide) shows
        // a strip of it along the top. Hide both for as long as this app is
        // frontmost; they come back when it is not, which is what an
        // operator wants. Position after, since AppKit nudges a window that
        // was created under a menu bar down by its height.
        [NSApp setPresentationOptions:NSApplicationPresentationHideDock
                                    | NSApplicationPresentationHideMenuBar];
        // launchd starts the app without bringing it to the front, and both
        // the presentation options and the hidden cursor only hold for the
        // frontmost app.
        [NSApp activateIgnoringOtherApps:YES];
        int mx = 0, my = 0;
        glfwGetMonitorPos(mon, &mx, &my);
        glfwSetWindowPos(win, mx - kBleed, my - kBleed);
        int px = 0, py = 0, pw = 0, ph = 0;
        glfwGetWindowPos(win, &px, &py);
        glfwGetWindowSize(win, &pw, &ph);
        printf("window: %dx%d at %d,%d (monitor %dx%d at %d,%d)\n",
               pw, ph, px, py, W - 2 * kBleed, H - 2 * kBleed, mx, my);
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
    // Black behind the layer, not AppKit's light grey: where the compositor
    // filters the layer's edge against the window (a one-pixel ring at the
    // border of the fullscreen window), what shows through must be black.
    nswin.backgroundColor = [NSColor blackColor];
    nswin.opaque = YES;
    layer.opaque = YES;
    layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);

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
    // The resolved window (Transition entry -> mouth starts opening): the
    // audio block below computes `resolvedWindowActive` and drives the
    // pad/pluck/flanger from it, and also runs the strum -- the harp that a
    // head movement sweeps while the window holds (see WwiseAudio::postStrum).
    // Declared here, above the audio block, in case anything else ever needs
    // to read the window's state at the same frame's value.
    bool resolvedWindowActive = false;
    bool wasResolvedWindow = false;
    float tResolvedWindow = 0.f;   // seconds since the window opened
    // The strum's strings lie across the head's yaw: this is how many of
    // them sat to the nose's left last frame, so a crossing on the next can
    // pluck the strings passed over. -1 = take the nose's position silently
    // on the next frame (the window's entry), or the first frame would strum.
    int strumString = -1;
    float strumPrevYaw = 0.f;   // last frame's yaw, for the turn's speed
    float strumRate = 0.f;      // deg/s, smoothed -- see the strum block
    bool strumDropPending = false;   // the send-off's second frame, see the exit edge
    // The harp's strings: a scale over the resolved chord, in the pluck's
    // register (visitorNote), g_strum_octave up. Which scale is
    // g_strum_scale (the panel's "strum scale", same order):
    //   pentatonic -- root, 9th, 3rd, 5th, 6th: every one consonant over the
    //     pad's major triad and none an octave leap, so a sweep is a run.
    //   lydian -- the whole mode, root to octave.
    //   lydian colour -- 6th, 9th, #11th, 7th, the tones that make it lydian,
    //     the octave above.
    // Filled by strumStrings() whenever the harp sounds, string 0 at the
    // left; strumOrder says which tone each string carries (the identity,
    // or a per-sitting shuffle when g_strum_shuffle -- see the window's
    // entry edge). Returns the count.
    struct StrumScale { const char* name; int n; float tones[8]; };
    static const StrumScale kStrumScales[] = {
        {"pentatonic",    5, {0.f, 2.f, 4.f, 7.f, 9.f}},
        {"lydian",        8, {0.f, 2.f, 4.f, 6.f, 7.f, 9.f, 11.f, 12.f}},
        {"lydian colour", 4, {9.f, 14.f, 18.f, 23.f}},
    };
    constexpr int kStrumScaleCount = sizeof(kStrumScales) / sizeof(kStrumScales[0]);
    constexpr int kMaxStrings = RootScene::kMaxHarpWires;
    int strumOrder[kMaxStrings] = {0, 1, 2, 3, 4, 5, 6, 7};
    auto strumScale = [&]() -> const StrumScale& {
        return kStrumScales[std::clamp(g_strum_scale, 0, kStrumScaleCount - 1)];
    };
    auto strumStrings = [&](float out[kMaxStrings]) {
        const StrumScale& sc = strumScale();
        for (int i = 0; i < sc.n; ++i)
            out[i] = g_chord.visitorNote() + sc.tones[strumOrder[i] % sc.n]
                   + 12.f * (float)g_strum_octave;
        return sc.n;
    };
    // The strings drawn (RootScene::setHarpWires): one per string,
    // g_strum_wire_px wide at rest, and on a pluck widening by
    // g_strum_wire_pluck_width and vibrating g_strum_wire_vib_px either
    // way, decaying over g_strum_wire_decay_s, at the note's frequency over
    // g_strum_wire_pulse_div -- a slow wave of the pitch itself.
    float strumWireEnv[kMaxStrings] = {};    // the pluck's flare, 1 -> 0
    float strumWireHz[kMaxStrings] = {};     // its wave's rate
    float strumWirePhase[kMaxStrings] = {};  // cycles
    float strumWireVis = 0.f;                // the wires' fade, toward 1 while the window holds
    auto strumWirePluck = [&](int i, float hz) {
        if (i < 0 || i >= kMaxStrings) return;
        strumWireEnv[i] = 1.f;
        strumWireHz[i] = hz / std::max(g_strum_wire_pulse_div, 1.f);
        strumWirePhase[i] = 0.f;
    };
    // The visitor's own head movement, recorded through Transition and
    // played back once Roots takes over -- see face_track.h/root_face_sequence.h.
    // Recorder accumulates through one Transition; the sequence plays
    // whatever the recorder produced at the lock instant, for as long as
    // that same visitor's sitting is up on the masks.
    mirror::FaceTrackRecorder faceTrackRec;
    RootFaceSequence rootFaceSeq;
    // The bank's own recordings, on the other masks -- begun at each deal
    // (dealBankFaces, below) with one track per bank capture, stepped next
    // to rootFaceSeq in both root branches. See root_face_sequence.h.
    BankFacePlayback bankFaceSeq;
    // Set once this sitting's finished plant has been written to
    // captures/<id>/roots.bin (saveSittingPlant, below); reset with the rest
    // of the sitting's state at Transition entry and the navigator's Roots
    // entry.
    bool plantSavedForSitting = false;
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
    // cloth hold/release/fall that used to live in a separate
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
    // Set the moment onLeaveFace (below) has fed this sitting's own finished
    // FaceTrack straight to rootFaceSeq.begin(), so the later phase-entry
    // handler (p == Roots) does not restart the same playback a frame later.
    // Reset at every Transition entry; left false for the rest of a sitting
    // whose recording never finished before the cut (too short a recording,
    // or a phase reached without a Transition -- the operator's navigator),
    // so that handler's own begin() -- the original, still-needed fallback --
    // runs instead.
    bool rootFaceSeqBegunForSitting = false;
    double rootsClock = 0.0;          // seconds since Transition entry; RootSequence's own clock
    bool   rootsBedStopped = false;   // Stop_Amb_Roots already posted for this Roots visit
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
    // ...and with each capture, under the same id, the two things a sitting
    // leaves behind besides its face: the head-movement track (track.bin,
    // face_track.h) the bank's masks replay, and the plant it grew
    // (roots.bin, root_structure.h) the hood is built from. Either may be
    // absent (a capture from before they were saved, a sitting cut short) --
    // the entry is then just the face, and the mask holds still / the
    // structure is a seeded growth, as before.
    struct BankEntry {
        mirror::FaceCapture   cap;
        mirror::FaceTrack     track;   // valid() false when there is none
        mirror::RootStructure plant;   // valid() false when there is none
    };
    std::unordered_map<std::string, BankEntry> bankCache;
    // Deal the bank onto the masks: the most recent captures, newest first,
    // as many as the chain and the capped hood can wear, minus `excludeId`
    // (the sitting now on mask 0, once it has been saved). RootScene does
    // the dealing; this only decides which files to open. The same deal
    // hands RootScene the plants (structure k's is the plant of the capture
    // on its mask 0, per RootScene::structureFaces) and starts the bank's
    // face playback, both behind their show/roots toggles.
    auto dealBankFaces = [&](const std::string& excludeId) {
        if (!roots.valid()) return;
        const int N = std::max(1, roots.simParams().N);
        const int hood = std::max(g_root_seq.reveal_max_structures, g_root_seq.reveal_structures);
        const int want = (N - 1) + std::max(0, hood) * N;
        std::vector<mirror::FaceCapture> bank;
        std::vector<mirror::FaceTrack> tracks;
        std::vector<const mirror::RootStructure*> plants;   // parallel to bank
        // g_capture_ids is oldest first (ListCaptures); the bank is newest first.
        for (auto it = g_capture_ids.rbegin();
             it != g_capture_ids.rend() && (int)bank.size() < want; ++it) {
            if (*it == excludeId) continue;
            auto c = bankCache.find(*it);
            if (c == bankCache.end()) {
                BankEntry e;
                std::string err;
                if (!mirror::LoadCapture(*it, e.cap, err)) {
                    // An unreadable capture is skipped, not fatal: the bank is
                    // a directory anyone can leave a half-written entry in.
                    fprintf(stderr, "face bank: %s\n", err.c_str());
                    continue;
                }
                e.cap.film.clear();
                e.cap.film.shrink_to_fit();
                e.cap.filmW = e.cap.filmH = 0;
                // A capture saved before the basis punched its eye and mouth
                // holes carries the closed skin; same vertices, so the
                // basis's own triangles apply.
                if (g_fitter.valid() && e.cap.verts.size() == g_fitter.basis().neutral().size())
                    e.cap.tris = g_fitter.basis().triangles();
                // Square of its sitter's head pose (see autoCaptureAtCut):
                // captures from before that was saved out carry 10-40
                // degrees of it, and a face that tilted on its mask read as
                // askew from the nest. A no-op on one already square.
                if (g_fitter.valid()) {
                    const float deg = mirror::SquareCaptureToNeutral(e.cap, g_fitter.basis().neutral());
                    if (deg > 2.f) printf("face bank: %s squared by %.0f deg\n", it->c_str(), deg);
                }
                // Absent is the ordinary case for both (err left empty);
                // only a file that is there and unreadable is worth a line.
                if (!mirror::LoadFaceTrack(*it, e.track, err) && !err.empty())
                    fprintf(stderr, "face bank: %s\n", err.c_str());
                if (!mirror::LoadRootStructure(*it, e.plant, err) && !err.empty())
                    fprintf(stderr, "face bank: %s\n", err.c_str());
                c = bankCache.emplace(*it, std::move(e)).first;
            }
            bank.push_back(c->second.cap);
            tracks.push_back(g_root_seq.bank_replay ? c->second.track : mirror::FaceTrack{});
            plants.push_back(&c->second.plant);
        }
        roots.assignBankFaces(bank, g_root_seq.reveal_max_structures,
                              g_root_seq.reveal_min_structures, g_root_seq.reveal_structures);
        // Structure k's plant: the one saved with the capture its mask 0
        // wears (structureFaces()[k].captureIdx[0]); an empty slot leaves
        // RootScene to its seeded growth for that structure.
        std::vector<mirror::RootStructure> dealt;
        if (g_root_seq.bank_plants) {
            const auto& sf = roots.structureFaces();
            dealt.resize(sf.size());
            for (size_t k = 0; k < sf.size(); ++k) {
                const auto& idxs = sf[k].captureIdx;
                if (idxs.empty() || idxs[0] < 0 || idxs[0] >= (int)plants.size()) continue;
                if (plants[size_t(idxs[0])]->valid()) dealt[k] = *plants[size_t(idxs[0])];
            }
        }
        roots.setBankPlants(std::move(dealt));
        if (g_fitter.valid())
            bankFaceSeq.begin(tracks, g_fitter.basis(), g_root_seq.replayConfig());
        else bankFaceSeq.reset();
        // The room each chain mask's head sweeps as it replays, into the
        // sim's keep-out, so the roots grow around the swing and not through
        // it. Chain mask i wears bank chainFaces()[i]. After replant(), which
        // is where the caller puts this.
        {
            const std::vector<int>& cf = roots.chainFaces();
            float half[3];
            for (size_t i = 1; i < cf.size(); ++i)
                if (cf[i] >= 0 && bankFaceSeq.motionHalfExtents(cf[i], half))
                    roots.setMaskExtent((int)i, half);
        }
        int withTrack = 0, withPlant = 0;
        for (const auto& t : tracks) withTrack += t.valid() ? 1 : 0;
        for (const auto* pl : plants) withPlant += pl->valid() ? 1 : 0;
        printf("face bank: dealt %zu captures (%d with a track, %d with a plant)\n",
               bank.size(), withTrack, withPlant);
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
    //
    // The tracker need not have the visitor on this very frame: they may
    // have stepped away in the last seconds of Face, or the tracker may
    // have dropped one frame at exactly the wrong moment. Either way the
    // fitter still holds its last solve of them -- the mesh mask 0 has been
    // wearing -- and the colours were sampled while they were there. Only a
    // sitting the tracker never had at all (no recorded frames) has nothing
    // to capture; requiring a live detection here instead threw away the
    // capture and, with it, the sitting's whole track.
    // The sitting's seed (RootSequenceParams::vary_seed): a fresh random
    // offset on the preset's seed before every replant, so each visitor
    // grows their own root system. Logged, so a plant worth keeping can be
    // reproduced by putting base + offset in the preset.
    std::mt19937 sittingSeedRng{std::random_device{}()};
    auto newSittingSeed = [&]() {
        const unsigned offset = g_root_seq.vary_seed
            ? 1u + unsigned(sittingSeedRng() % 1000000u) : 0u;
        roots.setSeedOffset(offset);
        if (offset) printf("root: sitting seed %u (%u + %u)\n",
                           roots.effectiveSeed(), roots.simParams().seed, offset);
    };
    auto autoCaptureAtCut = [&]() {
        if (!g_capture_auto || !thisSittingCaptureId.empty()) return;
        if (!(g_fitter.valid() && g_track_on && (g_face.valid || faceTrackRec.frames() > 0)))
            return;
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
        // The sitting's best sampling, with the film and uv of that same
        // instant (see g_face_colors_best); the frame of the cut only when
        // there was none.
        const bool best = g_face_colors_best.size() == verts.size() &&
                          g_face_best_uv.size() * 3 == verts.size() * 2;
        if (best) {
            cap.colors = g_face_colors_best;
            cap.uv = g_face_best_uv;
            cap.film = g_face_best_film;
            cap.filmW = g_face_best_film_w; cap.filmH = g_face_best_film_h;
        } else {
            cap.colors = g_face_colors;
            float ps = 1.f, uo = 0.f, vo = 0.f;
            PinTransform(ps, uo, vo);
            g_fitter.projectNormalised(g_face_w, g_face_h, ps, uo, vo, cap.uv);
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
        }
        std::string cerr;
        if (!cap.valid()) return;
        if (mirror::SaveCapture(cap, cerr)) {
            g_capture_last = cap.id;
            thisSittingCaptureId = cap.id;
            g_capture_msg = "saved " + cap.id;
            g_capture_ids = mirror::ListCaptures();
            printf("capture: saved %s (%zu verts, film %dx%d, %s, texture %s%s)\n",
                   cap.id.c_str(), cap.vertexCount(), cap.filmW, cap.filmH,
                   best ? "best frame" : "frame of the cut",
                   g_texture_source == (int)TextureSource::Camera ? "camera" : "mirror",
                   g_id_solves > 1 ? " -- identity re-solved" : "");
            // Into the cache too, film-less, so the next visitor's deal does
            // not go back to disk for the one capture this process just wrote.
            // Its track and plant do not exist yet; the saves that write them
            // later in this sitting fill the entry in themselves.
            cap.film.clear();
            cap.film.shrink_to_fit();
            cap.filmW = cap.filmH = 0;
            bankCache[cap.id].cap = std::move(cap);
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
        // Before the first open(): overrides kinect_source.cpp's own quiet
        // logger with one that timestamps every line and keeps a copy in
        // ~/Library/Logs/mirror_app/kinect.log, so a USB drop hours into an
        // unattended run is still legible afterwards.
        mirror::InstallKinectDiagnosticLogger();

        std::string kerr;
        if (g_kinect.open(kerr))
            printf("kinect: %s\n", g_kinect.deviceInfo().c_str());
        else
            printf("kinect: %s -- use \"open sensor\" in the panel to retry "
                   "(--no-sensor skips this)\n", kerr.c_str());

        // Diagnostic only (see kinect_usb_watch.h) -- says *why* a later
        // stall happened (USB/power vs. a firmware wedge) but does not drive
        // the watchdog's own recovery: nothing in this callback closes or
        // reopens anything.
        g_kinect_usb_watch.start([](bool attached, const std::string& detail) {
            char buf[384];
            if (attached) {
                const double since = mirror::SecondsSinceKinectUsbDetach();
                if (since >= 0.0) {
                    snprintf(buf, sizeof(buf),
                             "kinect usb: attached after %.1fs (%s)", since,
                             detail.c_str());
                } else {
                    snprintf(buf, sizeof(buf), "kinect usb: attached (%s)",
                             detail.c_str());
                }

                // A rolling count over the last 60s: one attach is a normal
                // startup; more than one is the flapping this exists to make
                // visible (a re-enumerating hub, a marginal cable/power
                // connection) even though each individual event alone looks
                // harmless once recovered from.
                static std::vector<double> recent_attach_times;
                const double now = glfwGetTime();
                recent_attach_times.push_back(now);
                recent_attach_times.erase(
                    std::remove_if(recent_attach_times.begin(),
                                   recent_attach_times.end(),
                                   [&](double t) { return now - t > 60.0; }),
                    recent_attach_times.end());
                if (recent_attach_times.size() > 1) {
                    char summary[96];
                    snprintf(summary, sizeof(summary),
                             "kinect usb: %zu attach events in the last 60s",
                             recent_attach_times.size());
                    mirror::kinectlog::Log(summary);
                }
            } else {
                mirror::NoteKinectUsbDetach();
                snprintf(buf, sizeof(buf),
                         "kinect usb: detached (%s; last colour frame %.2fs "
                         "ago; show phase %s; uptime %s)",
                         detail.c_str(), g_kinect.secondsSinceLastFrame(),
                         show::PhaseName(g_show.phase()),
                         mirror::kinectlog::FormatDurationShort(
                             g_kinect.uptimeSeconds())
                             .c_str());
            }
            mirror::kinectlog::Log(buf);
        });
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
    if (g_no_mic)
        g_mic_err = "--no-mic";
    else if (!g_mic.start(g_mic_err))
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
        // Unconditional every frame, whether or not anything polled a frame
        // and whether or not the sensor is even open: this is what advances
        // the watchdog's backoff clock and makes the one reopen attempt per
        // retry (see KinectFitTarget::tick).
        g_kinect.setStallSeconds(g_kinect_stall_s);
        g_kinect.tick(show::PhaseName(g_show.phase()),
                     mirror::KinectUsbDetachTime());
#endif

        // And so does the tracker's frame: the *whole* sensor, at tracker px
        // on its long edge, whatever the feed shows -- a detector fed the
        // feed's crop lost anyone outside it, and fed the full-width feed
        // (a 16:9 band across a portrait frame) saw faces a few dozen
        // pixels high. Its landmarks, normalised to that frame, are mapped
        // into the feed rect's coordinates the moment they arrive (the
        // tracking block), so everything downstream -- the mask, the
        // region, the fit, the strum -- still trades in the feed's
        // normalised coordinates, as it always did, and a face's place
        // across the sensor is its place across the picture. Without a
        // source yet the two frames coincide.
        {
            int sw = 0, sh = 0;
            g_feed_rect_valid = SourceSize(sw, sh);
            const mirror::SrcRect vr = g_feed_rect_valid ? VideoRect(sw, sh) : mirror::SrcRect{};
            const int aw = g_feed_rect_valid ? vr.w : compW;
            const int ah = g_feed_rect_valid ? vr.h : compH;
            if (aw >= ah) {
                g_track_w = g_track_px;
                g_track_h = std::max(1, int(int64_t(g_track_px) * ah / aw));
            } else {
                g_track_h = g_track_px;
                g_track_w = std::max(1, int(int64_t(g_track_px) * aw / ah));
            }
            if (g_feed_rect_valid) {
                g_feed_rect = mirror::ComputeFeedRect(sw, sh, compW, compH, g_feed);
                // The tracker's scale is set against the video frame, so
                // the feed rect goes through that, not the sensor -- with an
                // edge crop the two differ in width and the face would
                // stretch by the difference.
                g_face_w = std::max(1, int(std::lround(double(g_track_w) * g_feed_rect.w / vr.w)));
                g_face_h = std::max(1, int(std::lround(double(g_track_h) * g_feed_rect.h / vr.h)));
            } else {
                g_face_w = g_track_w; g_face_h = g_track_h;
            }
        }

        @autoreleasepool {
            g_prof.begin();
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (!drawable) { continue; }
            g_prof.mark("drawable");

            id<MTLCommandBuffer> cb = [queue commandBuffer];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                const double ms = (done.GPUEndTime - done.GPUStartTime) * 1e3;
                double cur = g_prof.gpuAccum.load();
                while (!g_prof.gpuAccum.compare_exchange_weak(cur, cur + ms)) {}
            }];

            // Update the active scene's texture (MLX compute happens here).
            static double prevT = glfwGetTime();
            double nowT = glfwGetTime();
            double dt = nowT - prevT; prevT = nowT;
#if MIRROR_HAVE_KINECT
            // --kinect-drop-test: force a simulated sensor loss 5s in, then
            // watch this same dt for the ~20s the recovery worker needs to
            // notice, close, and reopen -- if the worker-thread offload in
            // KinectFitTarget actually keeps close()/open() off this thread,
            // dt here should never show the 4s/3s hitches a synchronous
            // recovery used to cause. One log line reports what happened.
            if (g_kinect_drop_test) {
                static double t0 = nowT;
                static bool fired = false, reported = false;
                static double max_dt = 0.0;
                static double fire_time = 0.0;
                const double since_start = nowT - t0;
                if (!fired && since_start >= 5.0) {
                    fired = true;
                    fire_time = nowT;
                    max_dt = 0.0;
                    g_kinect.forceLossForTest();
                }
                if (fired && !reported) {
                    max_dt = std::max(max_dt, dt);
                    if (nowT - fire_time >= 20.0) {
                        reported = true;
                        char buf[160];
                        snprintf(buf, sizeof(buf),
                                 "kinect-drop-test: max frame dt during recovery window = %.1fms",
                                 max_dt * 1000.0);
                        mirror::kinectlog::Log(buf);
                    }
                }
            }
#endif
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

            g_prof.mark("pull");
            // --- face tracking ------------------------------------------
            // Once per frame, before either scene uses it, so the mirror's
            // mask and the roots' mesh are built from the same detection
            // rather than from two frames a scene apart.
            if (g_track_on && g_tracker.isOpen() && SourceReady()) {
                // --- stage one: the finder, on the full-size frame --------
                // Vision on the sensor's own pixels (face_find.h): a face
                // the landmarker's shrunken input would never find. It
                // follows ONE face -- the one it had, by nearest centre,
                // and only picks afresh once that one has been gone for the
                // hold -- so a second visitor in the frame does not steal
                // the tracking. Then a square crop around it, held with
                // hysteresis so the landmarker's input does not jitter
                // under the landmarks, is what stage two is handed.
                static mirror::FaceFinder finder;
                static std::vector<mirror::FaceBox> boxes;
                static bool  lockValid = false;     // the face being followed
                // Its box, normalised to the video frame in the *raw* frame's
                // orientation (the resampler's mirroring is applied on the
                // way to the landmarker and undone on the way back).
                static float lockX = 0, lockY = 0, lockW = 0, lockH = 0;
                static double lockLastSeen = -1.0;
                static mirror::SrcRect roi;         // the landmarker's crop, source px
                static bool roiValid = false;
                int sw = 0, sh = 0;
                const bool haveSrc = SourceSize(sw, sh);
                const mirror::SrcRect vr = haveSrc ? VideoRect(sw, sh) : mirror::SrcRect{};
                bool useRoi = false;
                bool flipX = false;   // the video frame is the raw frame mirrored
#if MIRROR_HAVE_KINECT
                flipX = g_source != (int)Source::Photo && !g_kinect.mirrored();
#endif
                if (g_face_find_on && haveSrc) {
                    const unsigned char* raw = nullptr;
                    int rw = 0, rh = 0, bpp = 0;
                    bool rawOk = false;
                    if (g_source == (int)Source::Photo) {
                        raw = g_photo.data(); rw = g_photo_w; rh = g_photo_h; bpp = 3;
                        rawOk = !g_photo.empty();
                    }
#if MIRROR_HAVE_KINECT
                    else { bool rgbx = false; rawOk = g_kinect.rawFrame(raw, rw, rh, bpp, rgbx); }
#endif
                    // Off the render thread (FaceFinder::submit/take): the
                    // request is 7-8 ms on 1920x1080, too much of a 60 fps
                    // frame. Only a frame the sensor has not shown it yet
                    // is handed over, and once a face is followed only
                    // every third of those -- 10 Hz is plenty for a crop
                    // held with hysteresis, 30 Hz while searching. A photo
                    // is looked at once a second.
                    static uint64_t lastSeenFrame = ~0ull;
                    static int photoTick = 0, sensorTick = 0;
                    bool fresh = false;
                    if (g_source == (int)Source::Photo) fresh = (photoTick++ % 60) == 0;
#if MIRROR_HAVE_KINECT
                    else {
                        const uint64_t n = g_kinect.frames();
                        if (n != lastSeenFrame) { lastSeenFrame = n; fresh = (sensorTick++ % (lockValid ? 3 : 1)) == 0; }
                    }
#endif
                    if (rawOk && rw == sw && rh == sh && fresh) finder.submit(raw, rw, rh, bpp);
                    bool found = false;
                    if (finder.take(boxes, found)) {
                        g_face_find_ms = (float)finder.lastMs();
                        // Into the video frame's normalised coordinates; a
                        // face outside the video frame is not offered.
                        g_face_find_count = 0;
                        int best = -1; float bestD = 1e9f;
                        for (size_t i = 0; i < boxes.size(); ++i) {
                            mirror::FaceBox& b = boxes[i];
                            b.x = (b.x * sw - vr.x) / float(vr.w);
                            b.w = b.w * sw / float(vr.w);
                            b.y = (b.y * sh - vr.y) / float(vr.h);
                            b.h = b.h * sh / float(vr.h);
                            const float cx = b.x + 0.5f * b.w, cy = b.y + 0.5f * b.h;
                            if (cx < 0.f || cx > 1.f || cy < 0.f || cy > 1.f) continue;
                            ++g_face_find_count;
                            if (lockValid) {
                                // The one it had: nearest centre, within a
                                // couple of face-widths of where it was.
                                const float lcx = lockX + 0.5f * lockW, lcy = lockY + 0.5f * lockH;
                                const float d = std::hypot(cx - lcx, cy - lcy);
                                if (d < 2.f * std::max(lockW, 0.02f) && d < bestD) { bestD = d; best = (int)i; }
                            } else {
                                // Nobody followed: the largest face.
                                const float d = -b.w * b.h;
                                if (d < bestD) { bestD = d; best = (int)i; }
                            }
                        }
                        if (best >= 0) {
                            const mirror::FaceBox& b = boxes[best];
                            lockX = b.x; lockY = b.y; lockW = b.w; lockH = b.h;
                            lockValid = true;
                            lockLastSeen = nowT;
                        } else if (lockValid && nowT - lockLastSeen > g_face_hold_secs) {
                            lockValid = false;   // gone: free to pick afresh
                        }
                    }
                    if (lockValid) {
                        // A square around the box, g_face_find_pad times its
                        // longer side, in source pixels, kept inside the
                        // video frame. Re-cut only when the face has left the
                        // crop's middle or changed size by a quarter.
                        const float side = std::max(0.02f, std::max(lockW * vr.w, lockH * vr.h) * std::max(g_face_find_pad, 1.2f));
                        const float cx = vr.x + (lockX + 0.5f * lockW) * vr.w;
                        const float cy = vr.y + (lockY + 0.5f * lockH) * vr.h;
                        bool recut = !roiValid;
                        if (roiValid) {
                            const float rcx = roi.x + 0.5f * roi.w, rcy = roi.y + 0.5f * roi.h;
                            const float tol = 0.18f * roi.w;
                            const float ratio = side / std::max(1.f, (float)roi.w);
                            recut = std::fabs(cx - rcx) > tol || std::fabs(cy - rcy) > tol ||
                                    ratio > 1.25f || ratio < 0.8f;
                        }
                        if (recut) {
                            const int s = std::max(32, std::min((int)std::lround(side), std::min(vr.w, vr.h)));
                            int x = (int)std::lround(cx - 0.5f * s), y = (int)std::lround(cy - 0.5f * s);
                            x = std::min(std::max(x, vr.x), vr.x + vr.w - s);
                            y = std::min(std::max(y, vr.y), vr.y + vr.h - s);
                            roi = mirror::SrcRect{x, y, s, s};
                            roiValid = true;
                        }
                        useRoi = true;
                    } else {
                        roiValid = false;
                    }
                } else {
                    lockValid = false; roiValid = false;
                    g_face_find_count = 0; g_face_find_ms = 0.f;
                }
                if (useRoi) {
                    g_face_roi_x = (roi.x - vr.x) / float(vr.w); g_face_roi_w = roi.w / float(vr.w);
                    g_face_roi_y = (roi.y - vr.y) / float(vr.h); g_face_roi_h = roi.h / float(vr.h);
                    if (flipX) g_face_roi_x = 1.f - g_face_roi_x - g_face_roi_w;
                } else {
                    g_face_roi_w = g_face_roi_h = 0.f;
                }

                // --- stage two: the landmarker, on the crop ----------------
                // The crop at tracker px square (a face filling it), or,
                // with no face found / the finder off, the whole video frame
                // at tracker px on its long edge, as before.
                const int tw = useRoi ? g_track_px : g_track_w;
                const int th = useRoi ? g_track_px : g_track_h;
                if (SourceRGB8(tw, th, g_track_rgb, /*filtered=*/true,
                               /*whole=*/g_feed_rect_valid, useRoi ? &roi : nullptr)) {
                    // Video mode rejects a repeated or decreasing timestamp
                    // with a hard error rather than dropping the frame, and
                    // the render loop can outrun the sensor, so the clock here
                    // is a counter rather than wall time.
                    g_track_ts += 33;
                    mirror::FaceResult r;
                    r.blendshape_names = g_face.blendshape_names;   // filled once
                    const bool hit = g_tracker.detect(g_track_rgb.data(), tw, th,
                                                      g_track_ts, r);
                    // Crop-normalised landmarks into the video frame's. The
                    // resampler mirrors within the rect when the source is
                    // not already a mirror (see KinectFitTarget::setMirrored),
                    // and the whole frame is mirrored the same way, so the
                    // map is through the raw column and back.
                    if (hit && useRoi && haveSrc) {
                        const bool flip = flipX;
                        for (mirror::FaceLandmark& L : r.landmarks) {
                            const float rawX = flip ? roi.x + (1.f - L.x) * roi.w : roi.x + L.x * roi.w;
                            L.x = flip ? (vr.x + vr.w - rawX) / float(vr.w) : (rawX - vr.x) / float(vr.w);
                            L.y = (roi.y + L.y * roi.h - vr.y) / float(vr.h);
                            L.z *= roi.w / float(vr.w);
                        }
                    }
                    // Whole-sensor landmarks into the feed rect's normalised
                    // coordinates (see the frame derivation above). A face
                    // outside the feed's crop maps outside 0..1, and is
                    // placed there -- off the picture's edge, still tracked.
                    if (hit && g_feed_rect_valid) {
                        int sw = 0, sh = 0;
                        if (SourceSize(sw, sh) && g_feed_rect.w > 0 && g_feed_rect.h > 0) {
                            const mirror::SrcRect vr = VideoRect(sw, sh);
                            const float kx = float(vr.w) / float(g_feed_rect.w);
                            const float ky = float(vr.h) / float(g_feed_rect.h);
                            const float ox = float(g_feed_rect.x - vr.x) / float(g_feed_rect.w);
                            const float oy = float(g_feed_rect.y - vr.y) / float(g_feed_rect.h);
                            float mnx = 1e9f, mny = 1e9f, mxx = -1e9f, mxy = -1e9f;
                            for (mirror::FaceLandmark& L : r.landmarks) {
                                L.x = L.x * kx - ox;
                                L.y = L.y * ky - oy;
                                L.z *= kx;   // MediaPipe's z is in x-units
                                mnx = std::min(mnx, L.x); mxx = std::max(mxx, L.x);
                                mny = std::min(mny, L.y); mxy = std::max(mxy, L.y);
                            }
                            if (!r.landmarks.empty()) {
                                r.min_x = mnx; r.max_x = mxx; r.min_y = mny; r.max_y = mxy;
                                r.centre_x = 0.5f * (mnx + mxx);
                                r.centre_y = 0.5f * (mny + mxy);
                            }
                        }
                    }
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
                                ResetIdentityFit();
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
                                g_fitter.offerIdentityFrame(g_face, g_face_w,
                                                            g_face_h);
                                g_last_id_sample = nowT;
                                // Collection ends on the clock, not on a count:
                                // the retained set is a ranking, so it keeps
                                // improving for as long as it runs and would
                                // never "fill".
                                // ...and then, past the window, re-solved every
                                // g_id_resolve_secs on the set as it stands,
                                // keeping the best (see app_state.mm). The
                                // collection runs until whatever forgets the
                                // sitter ends it (Transition entry, Idle, a
                                // lost face); 0 keeps the old single solve.
                                const bool windowDone = nowT - g_id_started > g_id_collect_secs;
                                const bool due = g_id_solves == 0 ||
                                    (g_id_resolve_secs > 0.f &&
                                     nowT - g_id_last_solve >= g_id_resolve_secs);
                                if (windowDone && due && g_fitter.identityFrames() > 0) {
                                    float px = -1.f, rel = -1.f;
                                    if (g_fitter.fitIdentity(&px, &rel)) {
                                        ++g_id_solves;
                                        g_id_last_solve = nowT;
                                        if (g_id_best_rel < 0.f || rel <= g_id_best_rel * 1.25f) {
                                            g_id_best_alpha = g_fitter.alpha();
                                            g_id_best_rel = rel;
                                            g_id_residual = px;
                                        } else {
                                            ++g_id_rejected;
                                            g_fitter.setAlpha(g_id_best_alpha);
                                        }
                                    }
                                }
                                if (windowDone && g_id_resolve_secs <= 0.f) g_collect_id = false;
                            }
                            if (g_fitter.update(g_face, g_face_w, g_face_h) &&
                                g_feed_rect_valid && g_feed_rect.w > 0) {
                                // px per cm in the fitter's frame, whose
                                // width is the feed rect's.
                                g_head_ppcm = g_fitter.pose().s *
                                              float(g_feed_rect.w) / float(g_face_w);
                                float d, x, y, f;
                                if (MirrorGeometry(d, x, y, f)) {
                                    g_head_d_cm = d; g_head_x_cm = x; g_head_y_cm = y;
                                }
                            }
                        }
                    }
                    // No `else` clearing the face: a miss is handled by the
                    // hold above, and a hit that has not yet met the acquire
                    // threshold is simply not adopted. Clearing here is what
                    // used to make a single dropped frame a whole event.
                }
            }

            g_prof.mark("track");
            // --- head movement ------------------------------------------
            // After the detection, before anything that consumes it. The
            // input shift and the region have to be settled here: the fit
            // features and the render both read them later in this frame and
            // must read the same values.
            UpdateHeadBox();
            ApplyHeadMode(mirror.params(), fit_w, fit_h,
                          mirror.valid() && mirror.pond().fitted());

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

            g_prof.mark("fit input");
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
                // The safety-net half of show_timeline's Transition ceiling
                // (see show_timeline.cpp's kTransitionEdges comment): before
                // this is seen true the phase's fixed max_time still applies,
                // in case the cloth never clears at all. The actual cut to
                // Roots is SceneDone, called below (onLeaveFace) the moment
                // RootSequence leaves its Face stage -- not from this signal.
                sig.cloth_cleared = scene == (int)Scene::Transition && roots.valid() &&
                                     roots.clothCleared();
                g_show.setSignals(sig);

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
                // the whole hold/release/fall and early Roots gets
                // recorded, not just the ~0.5s hold stage. The capture's
                // own single-instant snapshot is separate, taken at the
                // Transition -> Roots cut (autoCaptureAtCut, above).
                if (faceTrackRecActive) {
                    const float absentHold = g_show.hold(show::Phase::Roots, 0);
                    if ((float)g_track_absent_t >= absentHold) {
                        faceTrackRecActive = false;
                        // A visitor gone this long before the cut (they left
                        // as the cloth cleared, say) has no capture id yet
                        // -- the ordinary one is taken at the cut, still
                        // seconds away -- and a track with no id to key to
                        // was simply dropped. Take the capture now, from
                        // the fitter's last solve of them, so the sitting
                        // is banked like any other. A no-op once one exists.
                        autoCaptureAtCut();
                        mirror::FaceTrack track;
                        if (faceTrackRec.finish(g_fitter, track) && !thisSittingCaptureId.empty()) {
                            track.id = thisSittingCaptureId;
                            std::string terr;
                            if (mirror::SaveFaceTrack(track, terr)) {
                                bankCache[track.id].track = track;
                                pendingFaceTrack = std::move(track);
                            } else {
                                fprintf(stderr, "face track: save failed: %s\n", terr.c_str());
                            }
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
                            // The input shift too: the latch holds across
                            // lost faces within a cycle, but a new cycle
                            // starts the field from zero (the mirror is not
                            // on screen at this cut, so nothing jumps).
                            g_shift_x = g_shift_y = 0.f;
                            g_collect_id = false;
                            ResetIdentityFit();
                            ResetBestFaceColors();
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
                            g_colour_ease_t0 = -1.0;
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
                            // A fresh per-visitor pluck offset draw for
                            // whoever is about to be waited for -- see
                            // Chord::newVisitor()'s comment. Deliberately
                            // here, not at the Fitting entry below: the draw
                            // has to hold fixed through this visitor's whole
                            // Idle wait, or reset() (Fitting entry) has
                            // nothing stable to continue and the pluck jumps
                            // the moment Fitting begins.
                            g_chord.newVisitor();
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
                            g_colour_ease_t0 = -1.0;
                            // The harmony forgets the last sitting here, not
                            // on the way into Idle: resolve() (see the Idle
                            // case above) needs to survive at least until
                            // Wwise reads it, and the new visitor's own arc
                            // has to start from the dark opening chord anyway,
                            // so this is the natural place for both.
                            //
                            // Logged so the console shows the handoff was
                            // actually continuous -- the pluck's Hz and the
                            // pad's effective root just before and just after
                            // reset() -- rather than trusting it by ear alone.
                            {
                                const float pluck_before = g_chord.voicing().comb_hz;
                                const float root_before = g_chord.effectiveRoot();
                                g_chord.reset();
                                if (g_show_log)
                                    printf("chord: handoff pluck %.2f -> %.2f root %.2f -> %.2f\n",
                                           pluck_before, g_chord.voicing().comb_hz,
                                           root_before, g_chord.effectiveRoot());
                            }
                            // Start collecting the moment the phase opens, so
                            // the `min` and the collection window overlap
                            // rather than running back to back.
                            if (g_fitter.valid()) {
                                ResetIdentityFit();
                                g_collect_id = true;
                                g_id_started = nowT;
                            }
                            // The texture's best-of too: this sitting's, not
                            // the last one's.
                            ResetBestFaceColors();
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
                                g_colour_ease_t0 = -1.0;
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
                            // The identity stands from here: the press and
                            // the capture take the mesh as it is, not one
                            // that might change under them.
                            g_collect_id = false;
                            if (!g_id_best_alpha.empty()) g_fitter.setAlpha(g_id_best_alpha);
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
                            if (roots.valid()) { newSittingSeed(); roots.replant(); roots.restartCloth(); }
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
                            rootFaceSeqBegunForSitting = false;
                            // The previous sitting's replay must not carry
                            // over: left active, it kept the last visitor's
                            // recording (or held frame) on mask 0 through
                            // this visitor's whole Face stage, over the
                            // live fit (both root branches step it whenever
                            // it is active, and holdAnchorMaskOnLeavingFace
                            // bails on it too). Mask 0 is the live tracker's
                            // again until onLeaveFace hands over this
                            // sitting's own track.
                            rootFaceSeq.reset();
                            plantSavedForSitting = false;
                            faceTrackRec.begin();
                            faceTrackRecActive = true;
                            thisSittingCaptureId.clear();
                            g_track_absent_t = 0.0;
                            transitionExitPhaseTime = 0.0;
                            rootsClock = 0.0;
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
                            if (roots.valid()) { newSittingSeed(); roots.replant(); roots.skipCloth(); }
                            rootFaceTrisUploaded = false;
                            rootsClock = 0.0;
                            // No Transition ran, so onLeaveFace never fed
                            // rootFaceSeq a fresh recording for this jump --
                            // the handler below must run its own begin().
                            rootFaceSeqBegunForSitting = false;
                            plantSavedForSitting = false;
                            // A jump here is a new sitting, whoever is at the
                            // sensor: the last one's capture id must not
                            // carry over, or the handler below finds
                            // pendingFaceTrack still keyed to it and replays
                            // the *previous* visitor's recording on mask 0
                            // instead of tracking this one.
                            thisSittingCaptureId.clear();
                            // The bank on the other masks, as at Transition
                            // entry; nothing excluded (see above).
                            dealBankFaces(std::string());
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
                    // the first frame of Roots. The navigator's jump clears
                    // thisSittingCaptureId (above), so that path never
                    // matches -- mask 0 stays the live tracker's.
                    //
                    // The usual forward path already fed rootFaceSeq this
                    // sitting's own track the instant it finished, at the
                    // Face -> Grow cut (onLeaveFace, below) -- well before
                    // this literal phase entry, which now lands on the same
                    // frame or the next. rootFaceSeqBegunForSitting guards
                    // against restarting that same playback from here a
                    // frame later. The two paths this still runs for: the
                    // operator's navigator jumping straight to Roots (no
                    // Transition, so onLeaveFace never ran), and the
                    // fallback for a sitting whose recording never finished
                    // before the cut -- both fall back to pendingFaceTrack,
                    // whatever the most recent finish() (the absence-based
                    // fallback, or a previous sitting's) produced.
                    if (p == show::Phase::Roots && !rootFaceSeqBegunForSitting) {
                        const bool ownTrack = !thisSittingCaptureId.empty() &&
                                              pendingFaceTrack.id == thisSittingCaptureId;
                        // reset() first: begin() keeps a hold that is already
                        // under way, and a jump straight here from Idle would
                        // otherwise keep the previous sitting's held frame.
                        rootFaceSeq.reset();
                        rootFaceSeq.begin(ownTrack ? pendingFaceTrack : mirror::FaceTrack{},
                                          g_fitter.basis(), g_root_seq.replayConfig());
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
                                // The roots bed is normally already fading --
                                // stopped at the Outro's start, below, so it
                                // is gone by the time the mirror fades back
                                // in. This catches a jump here from
                                // anywhere else.
                                if (!rootsBedStopped) g_audio.post("Stop_Amb_Roots");
                                rootsBedStopped = true;
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
                                // what paces the beat 3/4 mask switches. The
                                // pad is left running too now, not stopped
                                // here: it rides through the cloth and the
                                // face capture, resolved, and is stopped
                                // explicitly on the resolved window's exit
                                // edge below instead (see `resolved`).
                                g_audio.post("Play_Transition");
                                break;
                            case show::Phase::Roots:
                                g_audio.post("Play_Amb_Roots");
                                rootsBedStopped = false;
                                // The pad is not stopped here either, for the
                                // same reason as the Transition case above:
                                // Roots is entered mid-Face while the chord is
                                // still resolved, and stopping it here would
                                // cut it out from under the resolved window
                                // rather than letting the exit edge do it.
                                //
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

                // ...and, when the fit is meant to be a face crop and a
                // tracker is running, for the crop itself. The phase was
                // entered because a face was there, but the w0 ramp runs
                // for seconds and a dropout across the moment it lands
                // used to start the fit unmasked -- on the whole frame, at
                // the feed grid -- and the sitting fitted the room.
                const bool crop_expected = g_mask_fit && g_track_on;
                if (g_fit_arm && g_fit_live && W0RampT(nowT) >= 1.f &&
                    (!crop_expected || g_have_mask) &&
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
                    g_fit_t0 = nowT;
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
                                  g_face_h > 0 ? (float)g_face_w / (float)g_face_h : 1.f,
                                  (float)dt);
                const mirror::PresenceSignals& ps = g_presence.signals();

                if (mirror.valid()) mirror.params().movement = ps.movement;

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
                ap.intensity = g_audio_on ? g_audio_intensity : 0.f;
                ap.transpose = g_audio_transpose;

                // The harmony, from the fit level that was just computed above
                // and the same movement signal the room produced. The pad's own
                // voicing now lives entirely in Wwise's `ChordStage` state (see
                // chord.h); what crosses here is the checkpoint gate, the
                // pluck's comb tuning, `Key` -- this visitor's note, so the
                // pluck, the drone and the drops all sit on the note the pluck
                // has been ringing through the idle wait -- and `PadOctave`,
                // which drops the pad alone onto the chord's root.
                g_chord.update(ap.fit_level, ap.movement, (float)dt);
                ap.comb_hz = g_chord.voicing().comb_hz;
                ap.key = g_chord.keyNote();
                ap.pad_octave = g_chord.padOctave();
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

                // The resolved window: from Transition's entry until the mouth
                // starts to open, spanning the cloth's fall and the whole of
                // the Face stage's capture. While it holds, the chord that
                // `g_chord.resolve()` locked in at Transition entry rides
                // through both -- the pad keeps playing (see the entry
                // switch's Transition/Roots cases above, which no longer stop
                // it), the pluck holds the resolved note instead of dropping
                // to the low Roots register below, and a head movement can
                // strum the chord (its own source, see postStrum -- it never
                // retunes the pluck).
                const float mouthRamp = rootSeq.valid()
                    ? rootSeq.mouthOpenRamp(rootsClock, g_root_seq) : 0.f;
                resolvedWindowActive =
                    (g_show.phase() == show::Phase::Transition ||
                     (g_show.phase() == show::Phase::Roots && rootSeqActive &&
                      rootSeq.valid() &&
                      rootSeq.stage() == RootSequence::Stage::Face)) &&
                    mouthRamp <= 0.f;
                if (resolvedWindowActive && !wasResolvedWindow) {
                    tResolvedWindow = 0.f;
                    strumString = -1;
                    strumPrevYaw = ap.head_yaw;
                    strumRate = 0.f;
                    // The strings' order across the yaw: low to high, or
                    // dealt at random for this sitting.
                    const int n = strumScale().n;
                    for (int i = 0; i < kMaxStrings; ++i) strumOrder[i] = i;
                    if (g_strum_shuffle)
                        std::shuffle(strumOrder, strumOrder + n, sittingSeedRng);
                } else if (resolvedWindowActive) {
                    tResolvedWindow += (float)dt;
                }
                if (!resolvedWindowActive && wasResolvedWindow && g_audio_on && g_audio_auto) {
                    // The window just closed -- the mouth started opening, or
                    // the phase left Transition/Roots-Face some other way
                    // (a navigator jump, a visitor lost mid-fit). This is now
                    // the pad's only Stop_Pad outside Idle's. The harp's
                    // send-off: every string plucked once, then (next frame,
                    // once the voices have started at their notes) their
                    // glide opened up and their tuning dropped to the floor,
                    // so the chord slides down into the roots as they grow.
                    g_audio.post("Stop_Pad");
                    float notes[kMaxStrings];
                    const int n = strumStrings(notes);
                    for (int i = 0; i < n; ++i) {
                        const float hz = 440.f * std::pow(2.f, (notes[i] - 69.f) / 12.f);
                        g_audio.postStrum(hz, 1.f);
                        strumWirePluck(i, hz);
                    }
                    strumDropPending = true;
                } else if (strumDropPending) {
                    g_audio.dropStrums(g_strum_drop_glide_ms, 20.f);
                    strumDropPending = false;
                }
                wasResolvedWindow = resolvedWindowActive;

                if (resolvedWindowActive) {
                    // In the pluck's own register -- the visitor's note, the
                    // one it rang through the idle wait and climbed from
                    // during the fit -- not the chord's root, which
                    // `chord octave` drops by up to five octaves and which
                    // is where the pad sits, not the pluck. `update()` is
                    // what lands this on the Stage4 note already, via
                    // g_chord's own voicing.
                    ap.comb_hz = g_chord.voicing().comb_hz;
                    ap.comb_glide_ms = g_resolved_glide_ms;
                    ap.flanger_mix = 54.f *
                        (1.f - std::clamp(tResolvedWindow / g_resolved_flanger_fade_s, 0.f, 1.f));
                    // Held at the slow end -- fit_level is already 0 here (the
                    // pond isn't training), so ap.flanger_rate above already
                    // landed on g_flanger_rate_min; this just makes that
                    // explicit rather than relying on it.
                    ap.flanger_rate = g_flanger_rate_min;
                    // The pluck steps aside for the harp -- both are combs,
                    // and the pluck's held note muddies the strings -- and
                    // comes back (the `else` below) as the roots start.
                    ap.pluck_mute = g_strum_mute_pluck ? 1.f : 0.f;
                    ap.pluck_mute_fade_ms = g_strum_mute_fade_ms;

                    // The strum: a harp lying across the head's yaw. The
                    // scale's tones (strumStrings above) are its
                    // strings, the lowest at full-left (-g_strum_range_deg),
                    // the highest at full-right, the rest evenly between --
                    // with the face-on dead zone cut out of the middle, so a
                    // nose at rest sits on nothing. Turning across a string
                    // plucks it, each on its own Wwise voice (postStrum) so
                    // it never touches the pluck's comb above.
                    float notes[kMaxStrings];
                    const int n = strumStrings(notes);
                    // q: the nose's position with the dead zone removed, in
                    // degrees, -span..span; string i sits at q_i.
                    const float span = std::max(g_strum_range_deg - g_strum_dead_deg, 1.f);
                    const float gap = 2.f * span / std::max(n - 1, 1);   // between strings
                    const float yaw = ap.head_yaw;
                    const float q = std::fabs(yaw) > g_strum_dead_deg
                        ? (yaw > 0.f ? yaw - g_strum_dead_deg : yaw + g_strum_dead_deg) : 0.f;
                    auto stringAt = [&](int i) { return -span + gap * i; };
                    // Hysteresis: a string only counts as crossed once the
                    // nose is g_strum_hysteresis of a gap past it, so tracker
                    // jitter on a string doesn't re-pluck it.
                    const float h = g_strum_hysteresis * gap;
                    // Loudness from how fast the head is turning: full at
                    // g_strum_full_vel deg/s, quieter below (the Strum_Velocity
                    // curve in Wwise sets the floor). The raw frame-to-frame
                    // rate is all tracker jitter -- a degree of wobble at 60
                    // fps reads as 60 deg/s -- so it is smoothed over
                    // g_strum_vel_smooth_ms before it sets the loudness.
                    const float rate = dt > 0.0 ? std::fabs(yaw - strumPrevYaw) / (float)dt : 0.f;
                    strumRate += (rate - strumRate) *
                        (1.f - std::exp(-(float)dt / std::max(g_strum_vel_smooth_ms, 1.f) * 1000.f));
                    const float vel = std::clamp(strumRate / std::max(g_strum_full_vel, 1.f), 0.f, 1.f);
                    strumPrevYaw = yaw;
                    if (strumString < 0) {
                        strumString = 0;
                        while (strumString < n && q > stringAt(strumString)) ++strumString;
                    }
                    // strumString counts the strings to the nose's left. Step
                    // it one string at a time toward the nose, plucking each
                    // string crossed in the order it was passed.
                    for (;;) {
                        int plucked;
                        if (strumString < n && q > stringAt(strumString) + h)
                            plucked = strumString++;
                        else if (strumString > 0 && q < stringAt(strumString - 1) - h)
                            plucked = --strumString;
                        else
                            break;
                        const float hz = 440.f * std::pow(2.f, (notes[plucked] - 69.f) / 12.f);
                        strumWirePluck(plucked, hz);
                        if (!g_audio_on) continue;
                        g_audio.postStrum(hz, vel);
                    }
                } else {
                    ap.comb_glide_ms = 265.f;
                    ap.flanger_mix = 54.f;
                    ap.pluck_mute = 0.f;
                    ap.pluck_mute_fade_ms = g_strum_mute_fade_ms;
                    // The Transition handoff drops the pluck to a very low
                    // register -- not a chord tone, so it bypasses Chord
                    // entirely. The pluck event itself keeps playing (see the
                    // Phase::Transition and Phase::Roots cases above); the
                    // effect's own Glide portamentos down to this from
                    // wherever the pluck was, and it holds there through the
                    // rest of Roots too, since the pluck is still ringing
                    // (and still the source of the beat 3/4 marker cues)
                    // rather than reverting to the Fitting register it never
                    // actually left musically.
                    if (g_show.phase() == show::Phase::Transition ||
                        g_show.phase() == show::Phase::Roots) {
                        constexpr float kTransitionCombHz = 25.f;  // 20-40 Hz
                        ap.comb_hz = kTransitionCombHz;
                    }
                }

                g_audio.update(ap);

                // The strings, to the scene: where each stands around the
                // mask (its yaw, as the strum block places it, over the
                // range -- -1..1, spread over g_strum_wire_arc_deg), how
                // wide, and how far its wave swings. They fade in as the
                // window opens and out as it closes, so the send-off's flare
                // is still seen.
                {
                    const float want = (resolvedWindowActive && g_strum_wires) ? 1.f : 0.f;
                    strumWireVis += (want - strumWireVis) * (1.f - std::exp(-(float)dt / 0.4f));
                    if (strumWireVis < 1e-3f && want == 0.f) strumWireVis = 0.f;
                    const int n = strumScale().n;
                    const float span = std::max(g_strum_range_deg - g_strum_dead_deg, 1.f);
                    const float gap = 2.f * span / std::max(n - 1, 1);
                    float xoff[kMaxStrings], width[kMaxStrings], wob[kMaxStrings];
                    for (int i = 0; i < n; ++i) {
                        const float q = -span + gap * i;
                        const float yaw = q + (q > 0.f ? g_strum_dead_deg : q < 0.f ? -g_strum_dead_deg : 0.f);
                        xoff[i] = yaw / std::max(g_strum_range_deg, 1.f);
                        strumWireEnv[i] *= std::exp(-(float)dt / std::max(g_strum_wire_decay_s, 0.01f));
                        strumWirePhase[i] = std::fmod(strumWirePhase[i] + (float)dt * strumWireHz[i], 1.f);
                        width[i] = strumWireVis * g_strum_wire_px * (1.f + g_strum_wire_pluck_width * strumWireEnv[i]);
                        wob[i] = g_strum_wire_vib_px * strumWireEnv[i] * std::sin(strumWirePhase[i] * 6.2831853f);
                    }
                    roots.setHarpWires(xoff, width, wob, strumWireVis > 0.f ? n : 0,
                                       g_strum_wire_arc_deg, g_strum_wire_radius,
                                       g_strum_wire_height);
                }
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
                // One way only: a converged fit that wobbles must not take
                // the colour back out with it. And eased, the way the w0
                // ramp is (smoothstep over g_colour_fit_secs) rather than
                // the linear slew this used to be, whose onset read as a
                // step: the colour starts easing the first frame the target
                // is above it, and a target that keeps rising mid-ease just
                // moves the end.
                if (target > g_colour_now + 1e-4f && g_colour_ease_t0 < 0.0) {
                    g_colour_ease_t0 = nowT;
                    g_colour_ease_a = g_colour_now;
                    g_colour_ease_b = target;
                }
                if (g_colour_ease_t0 >= 0.0) {
                    g_colour_ease_b = std::max(g_colour_ease_b, target);
                    const float t = g_colour_fit_secs > 0.f
                        ? std::min(1.f, (float)((nowT - g_colour_ease_t0) / g_colour_fit_secs))
                        : 1.f;
                    const float e = t * t * (3.f - 2.f * t);
                    g_colour_now = g_colour_ease_a + (g_colour_ease_b - g_colour_ease_a) * e;
                    if (t >= 1.f) g_colour_ease_t0 = -1.0;
                }
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
                // The corner thumbnail is the *video frame* at its own
                // shape -- what the tracker looks at, with the landmarks
                // mapped back onto it -- the full-screen views the feed
                // crop at the composition's, since the mask is applied there.
                int vw = 0, vh = 0;
                const bool video = !full_frame && VideoSize(vw, vh);
                const int aw = video ? vw : compW, ah = video ? vh : compH;
                if (aw >= ah) {
                    pipW = base;
                    pipH = std::max(1, int(int64_t(base) * ah / aw));
                } else {
                    pipH = base;
                    pipW = std::max(1, int(int64_t(base) * aw / ah));
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
                if (SourceRGB8(pipW, pipH, srcRGB, /*filtered=*/full_frame, /*whole=*/video) &&
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

            // Pluck-bed crackle onsets -> raindrops, and (now that the pluck
            // rings all the way through Roots too, see the Phase::Roots audio
            // case) the same cue stream doubling as RootSequence's "fire
            // reverb drop" markers for the Reveal stage -- see rootMarkerHit
            // below. Drained here, once per frame, regardless of scene: the
            // tap is a live input and letting it back up while another scene
            // is showing would land the whole backlog at once on return.
            const std::vector<mirror::MarkerHit> pluckHits = g_audio.pollFirePluckerMarkers();
            const bool rootMarkerHit = !pluckHits.empty();
            float rootMarkerStrength = 0.f;
            for (const mirror::MarkerHit& e : pluckHits)
                rootMarkerStrength = std::max(rootMarkerStrength, e.strength);
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
            {
                // Where the mirror shows the visitor.
                float tx, ty;
                HeadScreenPos(tx, ty);
                roots.setTrackedPosition(tx, ty, g_track_on && g_face.valid);
            }

            g_prof.mark("show");
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
                // Not while the crop is only *held* (see ApplyHeadMode): the
                // mask then marks where the face was, not where it is, and a
                // step against it would teach the face whatever is there now.
                if (mirror.pond().fitting() && !g_mask_held) {
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
                    // The warm-up: the lr eased up from g_lr_warm_from x over
                    // the first g_lr_warm_secs of the fit, so the first
                    // seconds resolve rather than snap.
                    float warm = 1.f;
                    if (g_fit_t0 >= 0.0 && g_lr_warm_secs > 0.f) {
                        const float t = std::min(1.f, (float)((nowT - g_fit_t0) / g_lr_warm_secs));
                        warm = g_lr_warm_from + (1.f - g_lr_warm_from) * t * t;
                    }
                    mirror.fitSteps(tune.steps, tune.lr * warm);
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
                //
                // Or off the camera frame (TextureSource::Camera): the real
                // photograph, in the frame the fit was solved in, no pin.
                const bool camSrc = g_texture_source == (int)TextureSource::Camera;
                if (g_texture_mask && g_track_on && g_face.valid && g_fitter.valid() &&
                    (camSrc ? !g_track_rgb.empty() : mirror.pond().fitted())) {
                    float ps = 1.f, uo = 0.f, vo = 0.f;
                    PinTransform(ps, uo, vo);
                    // The camera frame the fit was solved in is the feed's
                    // rect (g_face_w x g_face_h), not the tracker's whole
                    // frame: resampled here, on demand.
                    static std::vector<unsigned char> feedRGB;
                    if (camSrc && SourceRGB8(g_face_w, g_face_h, feedRGB))
                        g_fitter.sampleTexture(feedRGB.data(), g_face_w, g_face_h,
                                               g_face_w, g_face_h, g_face_colors);
                    else if (!camSrc)
                        g_fitter.sampleTexture(mirror.lastImageRGB(),
                                               mirror.lowW(), mirror.lowH(),
                                               g_face_w, g_face_h, g_face_colors,
                                               ps, uo, vo);
                    g_face_colors_fresh = true;
                    // The sitting's best sampling, for the capture (see
                    // app_state.mm): a frontal face, and off the mirror one
                    // the network had converged on. A held (frozen) face is
                    // not a new look at them.
                    if (!g_face_held) {
                        const float score = mirror::FaceFitter::Frontality(g_face.landmarks)
                                          * (camSrc ? 1.f : g_fit_level_now);
                        if (score > g_face_colors_best_score) {
                            g_face_colors_best_score = score;
                            g_face_colors_best = g_face_colors;
                            g_fitter.projectNormalised(g_face_w, g_face_h, ps, uo, vo,
                                                       g_face_best_uv);
                            const std::vector<float>& img = mirror.lastImageRGB();
                            const int fw = mirror.lowW(), fh = mirror.lowH();
                            if (fw > 0 && fh > 0 && img.size() == size_t(fw) * size_t(fh) * 3) {
                                g_face_best_film_w = fw; g_face_best_film_h = fh;
                                g_face_best_film.resize(img.size());
                                for (size_t i = 0; i < img.size(); ++i)
                                    g_face_best_film[i] = (unsigned char)(
                                        std::pow(std::clamp(img[i], 0.f, 1.f), 1.f / 2.2f) * 255.f + 0.5f);
                            }
                        }
                    }
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
                const float target = g_roots_fog_intensity;
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
                // Keys 5/6 (below) ask for Grow/Orbit from *outside* Roots:
                // the request waits here until the sequence is up, then
                // rides the same path as the panel's row.
                if (g_root_jump_on_entry >= 0 && rootSeqActive && rootSeq.valid()) {
                    g_root_jump = g_root_jump_on_entry;
                    g_root_jump_on_entry = -1;
                }
                const int want = g_root_jump;
                g_root_jump = -1;
                if (want < 0 || want >= (int)RootSequence::Stage::Done) return;
                if (!rootSeqActive || !rootSeq.valid()) return;
                // A jump past Face lands here already having left it, so
                // onLeaveFace (below, keyed off stageBefore/stage() the same
                // way) fires for this same frame -- sceneDone(), the
                // recording's finish() and rootFaceSeq's begin() all happen
                // on the jump, exactly as they would on the sequence's own
                // clock reaching the same edge.
                rootSeq.jumpTo((RootSequence::Stage)want, roots, g_root_seq, rootsClock);
            };
            // The freeze, at the same edge holdAnchorMaskOnLeavingFace
            // reacts to (Face -> anything else): this is where show_timeline's
            // Transition -> Roots cut now actually happens (SceneDone, not a
            // cloth-clear-plus-tail timer -- see show_timeline.cpp's
            // kTransitionEdges comment), and where the sitting's own face
            // recording finishes and is handed straight to rootFaceSeq so mask
            // 0 replays *this* visitor from Grow onward instead of freezing on
            // a static mesh (or, worse, the previous visitor's track -- see
            // ROOT_TIMELINE.md's old "known gap"). Called before
            // holdAnchorMaskOnLeavingFace, above, so that lambda's own
            // "rootFaceSeq.active() already" bail is seeing this frame's
            // result, not last frame's: once a fresh recording is handed over
            // here, rootFaceSeq.step() (below) settles the mask onto its
            // last frame; the fallback only builds that frame from the
            // fitter when there is no recording to take it from.
            auto onLeaveFace = [&](RootSequence::Stage before) {
                if (!rootSeqActive || !rootSeq.valid()) return;
                if (before != RootSequence::Stage::Face || rootSeq.stage() == RootSequence::Stage::Face)
                    return;
                g_show.sceneDone();
                // Make sure this sitting has a capture id before finish()
                // keys the track to it -- the ordinary path already ran this
                // at the literal Roots entry, one frame later; running it
                // here too is a no-op the second time (guarded on
                // thisSittingCaptureId already being set).
                autoCaptureAtCut();
                if (!faceTrackRecActive) {
                    // Already finished, by the absence-based path above: the
                    // visitor left well before the cut. If that produced this
                    // sitting's own track, it is still what mask 0 should
                    // hold on -- the recording's last frame is the last the
                    // tracker saw of them.
                    if (!thisSittingCaptureId.empty() && pendingFaceTrack.id == thisSittingCaptureId) {
                        rootFaceSeq.begin(pendingFaceTrack, g_fitter.basis(), g_root_seq.replayConfig());
                        rootFaceSeqBegunForSitting = true;
                    }
                    return;
                }
                faceTrackRecActive = false;
                mirror::FaceTrack track;
                if (!faceTrackRec.finish(g_fitter, track) || thisSittingCaptureId.empty())
                    return;   // too short a recording, or no capture -- the
                              // phase-entry handler's fallback covers it
                track.id = thisSittingCaptureId;
                std::string terr;
                if (!mirror::SaveFaceTrack(track, terr)) {
                    fprintf(stderr, "face track: save failed: %s\n", terr.c_str());
                    return;
                }
                // The cache entry autoCaptureAtCut made for this sitting
                // gets its track, so the next deal replays it without a
                // trip to disk.
                bankCache[track.id].track = track;
                pendingFaceTrack = std::move(track);
                rootFaceSeq.begin(pendingFaceTrack, g_fitter.basis(), g_root_seq.replayConfig());
                rootFaceSeqBegunForSitting = true;
            };
            // The plant, at the Grow -> Turn edge (by the sequence's clock or
            // a jump, either way the sim has run to done): written under the
            // sitting's capture id so a later hood can stand this visitor's
            // own structure around a later visitor's (dealBankFaces,
            // RootScene::setBankPlants). Only a finished growth -- a Grow
            // that timed out leaves masks no root reached, and that is not a
            // structure worth repeating -- and only once per sitting.
            auto saveSittingPlant = [&](RootSequence::Stage before) {
                if (!rootSeqActive || !rootSeq.valid()) return;
                if (before != RootSequence::Stage::Grow || rootSeq.stage() == RootSequence::Stage::Grow)
                    return;
                if (plantSavedForSitting || thisSittingCaptureId.empty()) return;
                plantSavedForSitting = true;
                if (!roots.simDone()) {
                    printf("root: plant not saved for %s (growth did not finish)\n",
                           thisSittingCaptureId.c_str());
                    return;
                }
                mirror::RootStructure plant;
                if (!roots.livePlant(plant)) return;
                plant.id = thisSittingCaptureId;
                std::string perr;
                if (!mirror::SaveRootStructure(plant, perr)) {
                    fprintf(stderr, "root: plant save failed: %s\n", perr.c_str());
                    return;
                }
                printf("root: saved plant %s (%zu nodes, %zu segs, %zu masks)\n",
                       plant.id.c_str(), plant.nodeCount(), plant.segs.size() / 2,
                       plant.masks.size());
                bankCache[plant.id].plant = std::move(plant);   // as for the track
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
            // Shared by uploadLiveFace() and both rootFaceSeq.step() calls
            // below, so the live path and the replay path apply exactly the
            // same target -- see RootSequenceParams' mouth_open_* comment.
            auto rootMouthOpenTarget = [&]() -> mirror::MouthOpen {
                mirror::MouthOpen m;
                if (!rootSeq.valid()) return m;
                m.ramp  = rootSeq.mouthOpenRamp(rootsClock, g_root_seq);
                m.jaw   = std::max(0.f, g_root_seq.mouth_open_amount);
                m.width = std::max(0.f, g_root_seq.mouth_open_width);
                m.lips  = std::max(0.f, g_root_seq.mouth_open_lips);
                return m;
            };
            // The mouth-open modes of the fitter's basis, looked up once --
            // shared by uploadLiveFace and holdAnchorMaskOnLeavingFace below.
            static mirror::MouthOpenModes liveMouthModes;
            static bool liveMouthTried = false;
            if (!liveMouthTried && g_fitter.valid()) {
                liveMouthTried = true;
                liveMouthModes = mirror::mouthOpenModes(g_fitter.basis());
            }
            // Mask 0's held frame -- the one it wears from Grow on, for the
            // rest of the sitting: squared (a tilted head left the face
            // askew in the nest the sim grew square to the mask's frame, the
            // same fault the bank's captures had) and jaw all the way open
            // (the root leaves through it), built from the fitter's last
            // solve exactly as autoCaptureAtCut saves it plus the mouth-open.
            // The fitter's last solve is the last thing the tracker saw of
            // the visitor whether they are still there or stepped out
            // seconds ago, so this needs no live detection. Handed to
            // rootFaceSeq.holdTo, which eases the mask onto it from whatever
            // it wears now over `settle` seconds and then holds. Only the
            // live tracker's mesh: a loaded capture is already the mask's
            // own business.
            auto holdAnchorMask = [&](double settle) {
                if (!g_capture_loaded.empty() || rootFaceSeq.active()) return;
                if (!(g_fitter.valid() && roots.usingFittedFace())) return;
                mirror::MouthOpen target = rootMouthOpenTarget();
                target.ramp = 1.f;   // held for the whole sitting, so all the way open
                std::vector<float> expr = g_fitter.expression();
                mirror::applyMouthOpen(liveMouthModes, target, expr);
                std::vector<float> v;
                g_fitter.basis().reconstruct(g_fitter.alpha(), expr, v);   // unposed: square
                if (v.size() < 9) return;
                rootFaceSeq.holdTo(v, g_fitter.basis(), settle);
                rootFaceSeqBegunForSitting = true;
            };
            // The ordinary path to the hold: hold_settle_seconds before Face
            // ends -- a time the sequence knows from the moment the cloth
            // clears (RootSequence::faceEndsAt) -- so the settle is over and
            // the mask still by the time Grow's first sim step measures
            // where its mouth is. A settle that ran *into* Grow left the
            // root growing out of a mouth that then drifted away from it.
            // From here the viewer no longer drives the mask (the live
            // upload below is gated on rootFaceSeq.active()); the recording
            // carries on regardless, for the bank.
            auto holdMaskAheadOfGrow = [&]() {
                if (!rootSeqActive || !rootSeq.valid() || rootHold) return;
                if (rootSeq.stage() != RootSequence::Stage::Face || rootFaceSeq.active()) return;
                const double end = rootSeq.faceEndsAt(g_root_seq);
                if (end < 0.0) return;
                const double settle = std::max(0.f, g_root_seq.hold_settle_seconds);
                if (rootsClock < end - settle) return;
                holdAnchorMask(std::max(0.0, end - rootsClock));
            };
            // The same hold at the Face -> anything edge itself, for a cut
            // that arrived unannounced -- a jump, or a Face so short the
            // settle never had its window -- with no recording of the
            // sitting handed over either (onLeaveFace, below, could not
            // finish one). A snap, not a settle: Grow has begun. Before this
            // the fallback uploaded the raw squared vertices: the mouth the
            // ramp had just opened snapped back to wherever the tracker
            // last left it.
            auto holdAnchorMaskOnLeavingFace = [&](RootSequence::Stage before) {
                if (!rootSeqActive || !rootSeq.valid()) return;
                if (before != RootSequence::Stage::Face || rootSeq.stage() == RootSequence::Stage::Face) return;
                holdAnchorMask(0.0);
            };
            // The live tracker's mesh onto mask 0, with the jaw forced open
            // once the sequence's mouth-open ramp calls for it (root_sequence.h's
            // mouth_open_* -- the root leaves mask 0 through its mouth, so it
            // is opened before Grow needs it). Only while the sequence is
            // still on Face does this path drive the mask at all
            // (viewerDrivesMask at each call site); Grow onward is
            // RootFaceSequence's replay, overridden the same way in its own
            // step() call below.
            //
            // applyMouthOpen over the live expression: raises the openers,
            // never clamps them, so a visitor still talking through the
            // ramp's start is not cut off; fades the closers. When it
            // changes nothing (ramp at 0, or the live expression already
            // past every target) this is exactly the old
            // setFittedFace(g_fitter.vertices(), ...) call.
            auto uploadLiveFace = [&]() {
                const mirror::MouthOpen target = rootMouthOpenTarget();
                const std::vector<float>& liveExpr = g_fitter.expression();
                std::vector<float> expr = liveExpr;
                mirror::applyMouthOpen(liveMouthModes, target, expr);
                const bool needOverride = expr != liveExpr;
                // The fitter poses its mesh about the centroid (the middle
                // of the face); on the mask it turns about the neck, the
                // same pivot the replay uses (FaceReplayConfig), or the live
                // head and the replayed one would move differently.
                std::vector<float> verts;
                if (needOverride) {
                    g_fitter.basis().reconstruct(g_fitter.alpha(), expr, verts);
                    mirror::RotateAboutCentroid(verts, g_fitter.rotation());
                } else {
                    verts = g_fitter.vertices();
                }
                {
                    const float pivot[3] = {0.f, -g_root_seq.head_pivot_down_cm,
                                            -g_root_seq.head_pivot_back_cm};
                    mirror::ShiftRotationPivot(verts, g_fitter.rotation(), pivot);
                }
                // Exponential smoothing over the posed mesh
                // (live_smooth_seconds): the per-frame jitter of the fit,
                // taken out the way track_smooth_seconds takes it out of a
                // replay. Restarts whenever the mesh changes size (a new
                // basis) or the upload was interrupted.
                static std::vector<float> smoothVerts;
                const float tau = g_root_seq.live_smooth_seconds;
                if (tau > 0.f && rootFaceTrisUploaded && smoothVerts.size() == verts.size()) {
                    const float k = 1.f - std::exp(-(float)dt / tau);
                    for (size_t i = 0; i < verts.size(); ++i)
                        smoothVerts[i] += (verts[i] - smoothVerts[i]) * k;
                } else {
                    smoothVerts = verts;
                }
                // The mask's frame: the identity alone, neutral and unposed,
                // rebuilt only when the solve changes (see RootScene::
                // setFittedFace on why not the posed mesh).
                static std::vector<float> refAlpha, refVerts;
                if (refAlpha != g_fitter.alpha() || refVerts.size() != verts.size()) {
                    refAlpha = g_fitter.alpha();
                    g_fitter.basis().reconstructIdentity(refAlpha, refVerts);
                }
                roots.setFittedFace(smoothVerts, rootFaceTrisUploaded ? std::vector<int>()
                                                                      : g_fitter.basis().triangles(),
                                    &refVerts);
                rootFaceTrisUploaded = true;
                // What the hold at Face -> Grow settles from -- see
                // RootFaceSequence::holdTo.
                rootFaceSeq.noteMaskVerts(smoothVerts);
            };
            // The mouth-open ramp with nobody tracked: the visitor stepped
            // out of the sensor (or the tracker lost them) during the last
            // seconds of Face, so the tracked upload above stops -- and the
            // mask would freeze with its mouth shut until Grow's replay
            // opened it in one frame. Keep driving mask 0 from the fitter's
            // last pose so the ramp still plays.
            auto uploadLiveFaceForRamp = [&]() {
                if (g_fitter.valid() && rootFaceTrisUploaded && rootMouthOpenTarget().ramp > 0.f)
                    uploadLiveFace();
            };
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
                    g_fitter.projectNormalised(g_face_w, g_face_h, ps, uo, vo, mesh_uv);
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
                // section) samples. It trains for as long as the sheet is
                // still pinned -- renderMirror() is the same trained-and-
                // rendered path Scene::Mirror uses, and it also samples face
                // colours, which uploadFaceColorsIfFresh() below already
                // expects. Once the pins let go the film has to stop
                // changing mid-fall, so from there it is just re-rendered
                // without another training step: the last trained frame is
                // the skin the sheet falls away with.
                mirror.ensureSize(compW / std::max(1, downscale), compH / std::max(1, downscale));
                if (roots.clothPinned() && !rootHold) {
                    roots.setPondTexture(renderMirror());
                } else {
                    if (!rootHold) mirror.advance(dt);
                    roots.setPondTexture(mirror.render());
                }

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
                // Only while the sequence is still on Face, and only until
                // the mask starts settling onto its held frame ahead of Grow
                // (holdMaskAheadOfGrow): the viewer stops driving the mask
                // then (the recording keeps going -- RootFaceSequence and the
                // bank play it back later).
                holdMaskAheadOfGrow();
                const bool viewerDrivesMask =
                    (!rootSeq.valid() || rootSeq.stage() == RootSequence::Stage::Face) &&
                    !rootFaceSeq.active();
                if (g_fitter.valid() && g_track_on && g_face.valid && !rootHold) {
                    if (viewerDrivesMask) {
                        uploadLiveFace();
                    }
                    // Same live fit, kept rather than thrown away this time --
                    // see faceTrackRec's declaration above.
                    faceTrackRec.record(g_show.phaseTime(), g_fitter);
                    transitionExitPhaseTime = g_show.phaseTime();
                } else if (viewerDrivesMask && !rootHold) {
                    uploadLiveFaceForRamp();
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
                if (!rootHold) {
                    RootSequence::Inputs in;
                    in.clothCleared = roots.clothCleared();
                    in.markerHit    = rootMarkerHit;
                    in.markerStrength = rootMarkerStrength;
                    in.trackedValid = roots.trackedPosition(in.trackedX, in.trackedY);
                    in.movement     = g_presence.signals().movement;
                    rootSeq.step(roots, rootsClock, dt, g_root_seq, in);
                } else {
                    // The sequence owns simPaused and re-decides it on the
                    // next step; held for this frame only.
                    roots.simPaused = true;
                }
                onLeaveFace(stageBefore);
                holdAnchorMaskOnLeavingFace(stageBefore);
                saveSittingPlant(stageBefore);
                // rootFaceSeq may have just begun (onLeaveFace, above) while
                // this frame is still rendering Transition -- the literal
                // Roots phase entry lands a frame later at most. Step it here
                // too so mask 0 does not sit frozen on the tracker's last
                // frame for that gap.
                if (rootFaceSeq.active() && !rootHold)
                    rootFaceSeq.step(roots, rootsClock, dt, rootMouthOpenTarget(),
                                     rootSeq.valid() && rootSeq.mouthOpenRamp(rootsClock, g_root_seq) >= 1.f);
                if (!rootHold) bankFaceSeq.step(roots, rootsClock, dt);
                if (rootSeq.valid()) g_root_stage = (int)rootSeq.stage();

                roots.ensureSize(compW / std::max(1, rootDownscale),
                                 compH / std::max(1, rootDownscale));
                applyFogFade(rootsClock);
                roots.debugSpawnMarkers = g_root_seq.debug_spawn_markers;
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
                holdMaskAheadOfGrow();
                const bool viewerDrivesMask =
                    !rootSeqActive || !rootSeq.valid() ||
                    rootSeq.stage() == RootSequence::Stage::Face;
                if (!g_capture_loaded.empty()) {
                    // Already uploaded when it was loaded; nothing per frame.
                } else if (rootFaceSeq.active()) {
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
                    uploadLiveFace();
                } else if (g_drive_roots && viewerDrivesMask && !rootHold) {
                    uploadLiveFaceForRamp();
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
                    // is literally entered on the ordinary forward path (the
                    // cloth pressed and cleared well before Face -> Grow, the
                    // moment sceneDone() now fires on -- see onLeaveFace), but
                    // passed live rather than hardcoded so a manually-
                    // navigated phase jump (no Transition having run first)
                    // still behaves sanely.
                    in.clothCleared = roots.clothCleared();
                    in.markerHit    = rootMarkerHit;
                    in.markerStrength = rootMarkerStrength;
                    in.trackedValid = roots.trackedPosition(in.trackedX, in.trackedY);
                    in.movement     = g_presence.signals().movement;
                    rootSeq.step(roots, rootsClock, dt, g_root_seq, in);
                    // fade() is 0 outside the outro, so this also takes the
                    // fade back off after a jump out of the Outro.
                    g_screen_fade = rootSeq.fade();
                    // The bed starts dying with the datamosh, not on Idle's
                    // entry: its Stop fade (Wwise's) is about the length of
                    // the whole outro, so it is essentially silent as the
                    // mirror fades back in, rather than hanging on under
                    // the first seconds of the pluck.
                    if (g_audio_on && g_audio_auto && !rootsBedStopped &&
                        stageBefore != RootSequence::Stage::Outro &&
                        rootSeq.stage() == RootSequence::Stage::Outro) {
                        g_audio.post("Stop_Amb_Roots");
                        rootsBedStopped = true;
                    }
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
                // Covers the operator's navigator jumping straight to Roots
                // (no Transition, so this is the only place the Face -> Grow
                // edge is ever seen for that sitting) -- sceneDone() here is
                // a harmless no-op, the show is already in Roots.
                onLeaveFace(stageBefore);
                holdAnchorMaskOnLeavingFace(stageBefore);
                saveSittingPlant(stageBefore);
                if (rootSeqActive && rootSeq.valid()) g_root_stage = (int)rootSeq.stage();
                // Both replays on rootsClock rather than phaseTime():
                // continuous across the Transition -> Roots cut (the same
                // clock the recording's timestamps are on), so a face that
                // was already moving does not jump.
                if (rootFaceSeq.active() && !rootHold)
                    rootFaceSeq.step(roots, rootsClock, dt, rootMouthOpenTarget(),
                                     rootSeq.valid() && rootSeq.mouthOpenRamp(rootsClock, g_root_seq) >= 1.f);
                if (!rootHold) bankFaceSeq.step(roots, rootsClock, dt);
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

                roots.debugSpawnMarkers = g_root_seq.debug_spawn_markers;
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
            g_prof.mark("scene");
            ui::BeginFrame();

            ImGui_ImplMetal_NewFrame(rpd);
            ImGui_ImplGlfw_NewFrame();
            ImGui::NewFrame();

            // Keyboard cues, for rehearsal without a controller: 1-4 force a
            // phase, 5 is Roots straight into Grow (skipping the Face stage),
            // 6 straight into Orbit (the chain finished at once, the hood
            // placed -- RootSequence::jumpTo), space fires the "go" cue. Guarded on WantCaptureKeyboard, or
            // typing a caption into the text field would jump the show
            // around. Read after NewFrame so the key state is this frame's.
            if (g_show_on && !ImGui::GetIO().WantCaptureKeyboard) {
                for (int p = 0; p < (int)show::Phase::Count; ++p) {
                    if (ImGui::IsKeyPressed((ImGuiKey)(ImGuiKey_1 + p), false))
                        g_show.goTo((show::Phase)p);
                }
                if (ImGui::IsKeyPressed(ImGuiKey_5, false)) {
                    g_root_jump_on_entry = (int)RootSequence::Stage::Grow;
                    if (g_show.phase() != show::Phase::Roots) g_show.goTo(show::Phase::Roots);
                }
                if (ImGui::IsKeyPressed(ImGuiKey_6, false)) {
                    g_root_jump_on_entry = (int)RootSequence::Stage::Orbit;
                    if (g_show.phase() != show::Phase::Roots) g_show.goTo(show::Phase::Roots);
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

            // No UI, no cursor: a visitor should not see an arrow parked on
            // the piece. Told to ImGui every frame rather than to GLFW once,
            // because imgui_impl_glfw sets the GLFW cursor mode itself each
            // frame from this and would undo a direct glfwSetInputMode.
            if (!g_ui_visible) ImGui::SetMouseCursor(ImGuiMouseCursor_None);

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
            g_prof.mark("panel");

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
            g_prof.mark("present");

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
        g_prof.end(now - lastTime, now);
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
