#include "fit_target.h"

#include <dispatch/dispatch.h>

#include <algorithm>
#include <cmath>

namespace mirror {

namespace {

// The box filter itself. Two callers want the same resampling with different
// output types -- the fit target wants floats in [0,1], MediaPipe wants bytes
// -- and having them share this is what keeps the two from drifting apart and
// giving the tracker a subtly different image from the one being fitted.
//
// ## Why this is threaded
//
// It is the single most expensive thing on the CPU side of a frame. The colour
// camera is 1920x1080 and every call reads *every source pixel in the rect
// once* -- around 1.5M pixels at 4 bytes -- and a frame runs it more than once:
// once for the fit target, once for the tracker's larger frame, once more for
// the preview when the overlay is up. That was several milliseconds of a 16 ms
// budget spent on one core while seven idled.
//
// Destination rows are independent by construction -- each reads a disjoint
// half-open span of source rows and writes only its own output row -- so this
// parallelises with no coordination at all. dispatch_apply rather than a thread
// pool because the work is already on a per-frame cadence and libdispatch's
// pool is the one the rest of the system is scheduling against.
//
// Below a threshold the dispatch costs more than it saves; small destinations
// (the 320px preview) stay on the calling thread.
constexpr int kParallelMinRows = 64;

// Resize without clobbering, so a partial fill can leave the rest of the buffer
// alone. A buffer that had to grow (or is new) starts zeroed; one that is
// already the right size keeps its contents.
template <typename T>
void EnsureSize(std::vector<T>& dst, size_t n) {
    if (dst.size() == n) return;
    dst.assign(n, T(0));
}

// Clamp a fill rect to the destination. An empty one means everything.
DstRect ClampFill(DstRect f, int dst_w, int dst_h) {
    if (f.w <= 0 || f.h <= 0) return DstRect{0, 0, dst_w, dst_h};
    f.x = std::min(std::max(f.x, 0), dst_w);
    f.y = std::min(std::max(f.y, 0), dst_h);
    f.w = std::min(f.w, dst_w - f.x);
    f.h = std::min(f.h, dst_h - f.y);
    return f;
}

template <typename T, typename Store>
void BoxDownsample(const unsigned char* src, int src_w, int src_h,
                   int stride_px, int r_off, int b_off, SrcRect rect,
                   int dst_w, int dst_h, std::vector<T>& dst, Store store,
                   DstRect fill = {}, bool filter = true, bool mirror = false) {
    EnsureSize(dst, size_t(dst_w) * dst_h * 3);
    if (!src || src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0) return;

    // The rect may overhang the image -- a feed zoom under 1 asks for more
    // than the sensor has (ComputeFeedRect) -- so it is not clamped here;
    // instead each destination pixel's footprint is clipped to the image
    // below, and one that falls wholly outside is written black. Only the
    // size is trusted, so the spans are never empty.
    rect.w = std::max(rect.w, 1);
    rect.h = std::max(rect.h, 1);

    fill = ClampFill(fill, dst_w, dst_h);
    if (fill.w <= 0 || fill.h <= 0) return;
    const int fx0 = fill.x, fx1 = fill.x + fill.w;

    const int g_off = (r_off + b_off) / 2;   // green sits between them either way

    T* out = dst.data();
    auto do_row = [=](int dy) {
        // Source rows covered by this destination row. Computed as a half-open
        // span so every source pixel lands in exactly one box -- rounding both
        // ends independently would double-count or drop rows.
        const int y0 = rect.y + int(int64_t(dy) * rect.h / dst_h);
        const int y1 = std::max(y0 + 1, rect.y + int(int64_t(dy + 1) * rect.h / dst_h));
        // The footprint's centre (point sampling) and its clip to the image
        // (the box); a row off the image is black across.
        const int yc = (y0 + y1) / 2;
        const int cy0 = std::max(y0, 0), cy1 = std::min(y1, src_h);
        for (int dx = fx0; dx < fx1; ++dx) {
            // Which source column this destination column is of. Mirroring is
            // just reading them backwards.
            const int sx = mirror ? (dst_w - 1 - dx) : dx;
            const int x0 = rect.x + int(int64_t(sx) * rect.w / dst_w);
            const int x1 = std::max(x0 + 1, rect.x + int(int64_t(sx + 1) * rect.w / dst_w));
            const int xc = (x0 + x1) / 2;
            const int cx0 = std::max(x0, 0), cx1 = std::min(x1, src_w);
            T* o = out + (size_t(dy) * dst_w + dx) * 3;

            // Point sampling takes the middle of the footprint the box would
            // have averaged, so the two agree on *where* a destination pixel
            // comes from and differ only in how much of it they look at.
            if (!filter) {
                if (yc < 0 || yc >= src_h || xc < 0 || xc >= src_w) {
                    o[0] = o[1] = o[2] = store(0.f);
                    continue;
                }
                const unsigned char* px = src + (size_t(yc) * src_w + size_t(xc)) * stride_px;
                o[0] = store(float(px[r_off]));
                o[1] = store(float(px[g_off]));
                o[2] = store(float(px[b_off]));
                continue;
            }

            if (cy0 >= cy1 || cx0 >= cx1) {
                o[0] = o[1] = o[2] = store(0.f);
                continue;
            }
            uint32_t acc_r = 0, acc_g = 0, acc_b = 0, n = 0;
            for (int y = cy0; y < cy1; ++y) {
                const unsigned char* srow = src + size_t(y) * src_w * stride_px;
                for (int x = cx0; x < cx1; ++x) {
                    const unsigned char* px = srow + size_t(x) * stride_px;
                    acc_r += px[r_off];
                    acc_g += px[g_off];
                    acc_b += px[b_off];
                    ++n;
                }
            }
            if (!n) continue;
            o[0] = store(float(acc_r) / n);
            o[1] = store(float(acc_g) / n);
            o[2] = store(float(acc_b) / n);
        }
    };

    const int fy0 = fill.y;
    if (fill.h >= kParallelMinRows) {
        dispatch_apply(size_t(fill.h),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                       ^(size_t i) { do_row(fy0 + int(i)); });
    } else {
        for (int i = 0; i < fill.h; ++i) do_row(fy0 + i);
    }
}

}  // namespace

namespace {
inline auto StoreF() { return [](float v) { return v * (1.f / 255.f); }; }
inline auto StoreU8() {
    return [](float v) {
        return (unsigned char)(v < 0.f ? 0.f : (v > 255.f ? 255.f : v) + 0.5f);
    };
}
inline SrcRect WholeImage(int w, int h) { return SrcRect{0, 0, w, h}; }
}  // namespace

SrcRect ComputeFeedRect(int src_w, int src_h, int dst_w, int dst_h,
                        const FeedCrop& c) {
    SrcRect r;
    if (src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0) return r;

    const double want = double(dst_w) / double(dst_h);
    // The largest rect of the output's aspect that fits in the source.
    double w = src_w, h = src_h;
    if (double(src_w) / double(src_h) > want) w = h * want;
    else h = w / want;

    const double zoom = std::min(std::max(double(c.zoom), 1e-2), 50.0);
    w /= zoom;
    h /= zoom;
    // A zoom under 1 asks for more than the sensor has: the rect overhangs
    // it (the whole 16:9 width across a portrait frame, say) and the
    // resamplers write the overhang black. The picture keeps its aspect;
    // what it shows is a band of the frame.

    // Shifted inside rather than shrunk: the framing controls asked for this
    // scale, and quietly widening the rect at the edge of travel would change
    // how big the person is as they walk across the frame. A rect bigger
    // than the source is shifted the other way, so the source stays inside
    // it -- the panning has no travel to give, and the picture sits centred.
    double x = double(c.cx) * src_w - w * 0.5;
    double y = double(c.cy) * src_h - h * 0.5;
    const double xs = double(src_w) - w, ys = double(src_h) - h;
    x = std::min(std::max(x, std::min(0.0, xs)), std::max(0.0, xs));
    y = std::min(std::max(y, std::min(0.0, ys)), std::max(0.0, ys));

    r.x = int(std::lround(x));
    r.y = int(std::lround(y));
    r.w = std::max(1, int(std::lround(w)));
    r.h = std::max(1, int(std::lround(h)));
    return r;
}

float FeedZoomFullWidth(int src_w, int src_h, int dst_w, int dst_h) {
    if (src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0) return 1.f;
    // The zoom-1 rect's width, unrounded (as ComputeFeedRect starts).
    const double want = double(dst_w) / double(dst_h);
    const double w = (double(src_w) / double(src_h) > want) ? double(src_h) * want : double(src_w);
    return float(std::min(1.0, w / double(src_w)));
}

void DownsampleRGB8(const unsigned char* src, int src_w, int src_h,
                    int stride_px, int r_off, int b_off,
                    int dst_w, int dst_h, std::vector<float>& dst) {
    BoxDownsample(src, src_w, src_h, stride_px, r_off, b_off,
                  WholeImage(src_w, src_h), dst_w, dst_h, dst, StoreF());
}

void DownsampleToRGB8(const unsigned char* src, int src_w, int src_h,
                      int stride_px, int r_off, int b_off,
                      int dst_w, int dst_h, std::vector<unsigned char>& dst) {
    BoxDownsample(src, src_w, src_h, stride_px, r_off, b_off,
                  WholeImage(src_w, src_h), dst_w, dst_h, dst, StoreU8());
}

void DownsampleRectRGB8(const unsigned char* src, int src_w, int src_h,
                        int stride_px, int r_off, int b_off, const SrcRect& rect,
                        int dst_w, int dst_h, std::vector<float>& dst,
                        const DstRect& fill, bool mirror) {
    BoxDownsample(src, src_w, src_h, stride_px, r_off, b_off, rect,
                  dst_w, dst_h, dst, StoreF(), fill, /*filter=*/true, mirror);
}

void DownsampleRectToRGB8(const unsigned char* src, int src_w, int src_h,
                          int stride_px, int r_off, int b_off,
                          const SrcRect& rect, int dst_w, int dst_h,
                          std::vector<unsigned char>& dst,
                          const DstRect& fill, bool mirror) {
    BoxDownsample(src, src_w, src_h, stride_px, r_off, b_off, rect,
                  dst_w, dst_h, dst, StoreU8(), fill, /*filter=*/true, mirror);
}

void PointSampleRectToRGB8(const unsigned char* src, int src_w, int src_h,
                           int stride_px, int r_off, int b_off,
                           const SrcRect& rect, int dst_w, int dst_h,
                           std::vector<unsigned char>& dst, bool mirror) {
    BoxDownsample(src, src_w, src_h, stride_px, r_off, b_off, rect,
                  dst_w, dst_h, dst, StoreU8(), DstRect{}, /*filter=*/false,
                  mirror);
}

void MirrorRGB8(int w, int h, std::vector<unsigned char>& rgb) {
    if (w <= 1 || h <= 0 || rgb.size() != size_t(w) * h * 3) return;
    for (int y = 0; y < h; ++y) {
        unsigned char* row = &rgb[size_t(y) * w * 3];
        for (int x = 0; x < w / 2; ++x) {
            unsigned char* a = row + size_t(x) * 3;
            unsigned char* b = row + size_t(w - 1 - x) * 3;
            for (int c = 0; c < 3; ++c) std::swap(a[c], b[c]);
        }
    }
}

void ShiftRGBF(int w, int h, int dx, int dy, std::vector<float>& rgb,
               const DstRect& fill_in) {
    if (w <= 0 || h <= 0 || rgb.size() != size_t(w) * h * 3) return;
    if (dx == 0 && dy == 0) return;

    const DstRect f = ClampFill(fill_in, w, h);
    if (f.w <= 0 || f.h <= 0) return;

    // Only the source rows this output rect reads are copied aside. Whole-buffer
    // was two 2.7 MB passes over a frame of which, under a face crop, a few
    // percent is ever looked at again.
    const int sy0 = std::min(h - 1, std::max(0, f.y - dy));
    const int sy1 = std::min(h - 1, std::max(0, f.y + f.h - 1 - dy));
    const int rows = sy1 - sy0 + 1;
    static std::vector<float> tmp;
    tmp.assign(rgb.begin() + size_t(sy0) * w * 3,
               rgb.begin() + size_t(sy1 + 1) * w * 3);

    // A source outside the frame is black, not the nearest edge pixel: with
    // the head moved in from the side of a crop, the edge would otherwise be
    // smeared across the fill -- and, worse, across whatever was left there by
    // an earlier, smaller fill.
    for (int y = f.y; y < f.y + f.h; ++y) {
        const int sy = y - dy;
        float* drow = &rgb[size_t(y) * w * 3];
        if (sy < 0 || sy >= h) {
            std::fill(drow + size_t(f.x) * 3, drow + size_t(f.x + f.w) * 3, 0.f);
            continue;
        }
        const float* srow = &tmp[size_t(sy - sy0) * w * 3];
        for (int x = f.x; x < f.x + f.w; ++x) {
            const int sx = x - dx;
            float* d = drow + size_t(x) * 3;
            if (sx < 0 || sx >= w) { d[0] = d[1] = d[2] = 0.f; continue; }
            const float* s = srow + size_t(sx) * 3;
            d[0] = s[0]; d[1] = s[1]; d[2] = s[2];
        }
    }
}

void PlaceRGBF(int w, int h, float src_cx, float src_cy, float scale,
               float dst_cx, float dst_cy,
               std::vector<float>& rgb, const DstRect& fill_in) {
    if (w <= 1 || h <= 1 || rgb.size() != size_t(w) * h * 3) return;
    if (scale <= 1e-4f) return;

    const DstRect f = ClampFill(fill_in, w, h);
    if (f.w <= 0 || f.h <= 0) return;

    // Bilinear reads scattered source rows, so this one keeps the whole-buffer
    // copy; bounding the *write* is still most of the saving.
    static std::vector<float> tmp;
    tmp = rgb;
    const float inv = 1.f / scale;
    for (int y = f.y; y < f.y + f.h; ++y) {
        // Destination normalised -> source normalised. The inverse map, so
        // every destination pixel is written exactly once; forward-mapping
        // would leave holes wherever scale > 1.
        const float v = (float(y) + 0.5f) / float(h);
        const float sv = (v - dst_cy) * inv + src_cy;
        const float fy = sv * float(h) - 0.5f;
        float* drow = &rgb[size_t(y) * w * 3];
        // Off the frame is black, as in ShiftRGBF.
        if (fy < -0.5f || fy > float(h) - 0.5f) {
            std::fill(drow + size_t(f.x) * 3, drow + size_t(f.x + f.w) * 3, 0.f);
            continue;
        }
        const float cy = std::min(std::max(fy, 0.f), float(h - 1));
        const int y0 = int(cy), y1 = std::min(y0 + 1, h - 1);
        const float ty = cy - float(y0);
        for (int x = f.x; x < f.x + f.w; ++x) {
            const float u = (float(x) + 0.5f) / float(w);
            const float su = (u - dst_cx) * inv + src_cx;
            const float fx = su * float(w) - 0.5f;
            float* d = drow + size_t(x) * 3;
            if (fx < -0.5f || fx > float(w) - 0.5f) { d[0] = d[1] = d[2] = 0.f; continue; }
            const float cx = std::min(std::max(fx, 0.f), float(w - 1));
            const int x0 = int(cx), x1 = std::min(x0 + 1, w - 1);
            const float tx = cx - float(x0);

            for (int c = 0; c < 3; ++c) {
                const float a = tmp[(size_t(y0) * w + x0) * 3 + c];
                const float b = tmp[(size_t(y0) * w + x1) * 3 + c];
                const float e = tmp[(size_t(y1) * w + x0) * 3 + c];
                const float f = tmp[(size_t(y1) * w + x1) * 3 + c];
                d[c] = (a + (b - a) * tx) + ((e + (f - e) * tx) - (a + (b - a) * tx)) * ty;
            }
        }
    }
}

bool StaticFitTarget::poll(int w, int h, std::vector<float>& out) {
    if (w <= 0 || h <= 0 || rgb_.empty()) return false;
    if (w == w_ && h == h_) {
        out = rgb_;
    } else {
        // Nearest-neighbour is fine here: the source was already decoded at a
        // requested size, so this only runs when the fit grid changed mid-session.
        out.assign(size_t(w) * h * 3, 0.f);
        for (int y = 0; y < h; ++y) {
            const int sy = std::min(h_ - 1, int(int64_t(y) * h_ / h));
            for (int x = 0; x < w; ++x) {
                const int sx = std::min(w_ - 1, int(int64_t(x) * w_ / w));
                const float* s = &rgb_[(size_t(sy) * w_ + sx) * 3];
                float* d = &out[(size_t(y) * w + x) * 3];
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2];
            }
        }
    }
    ++frames_;
    return true;
}

}  // namespace mirror
