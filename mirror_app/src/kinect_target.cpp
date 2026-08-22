#include "kinect_target.h"

#include "kinect_source.h"

#include <algorithm>

namespace mirror {

// One resampling of the retained frame, kept so the same one is not recomputed.
//
// The sensor free-runs at 30 Hz while the render loop is well above it, and
// within a single frame two callers (the tracker and the preview) each ask for
// their own size. Neither of those needed the filter re-run: the source frame
// had not changed. Keyed on the frame counter as well as the geometry, so a new
// sensor frame invalidates every slot without anyone having to remember to.
struct DownsampleCache {
    int w = 0, h = 0;
    uint64_t frame_id = 0;
    bool mirrored = false;
    FeedCrop crop;
    std::vector<unsigned char> rgb;
    bool valid = false;

    bool filtered = true;

    bool matches(int qw, int qh, uint64_t id, bool mir, const FeedCrop& c,
                 bool filt) const {
        return valid && w == qw && h == qh && frame_id == id && mirrored == mir &&
               filtered == filt &&
               crop.cx == c.cx && crop.cy == c.cy && crop.zoom == c.zoom;
    }
};

struct KinectFitTarget::Impl {
    KinectSource src;
    FrameSnapshot frame;      // most recent colour frame, kept across polls
    std::string err;
    uint64_t frames = 0;
    bool mirrored = true;
    bool have_frame = false;
    FeedCrop crop;
    // Two slots: the tracker's frame and the preview's are different sizes and
    // are both asked for every frame, so a single slot would thrash between
    // them and cache nothing.
    mutable DownsampleCache cache[2];
    mutable int cache_next = 0;
};

KinectFitTarget::KinectFitTarget() : impl_(new Impl()) {}
KinectFitTarget::~KinectFitTarget() { close(); }

bool KinectFitTarget::open(std::string& err) {
    if (impl_->src.isOpen()) return true;
    // OpenGL depth pipeline and the USB reset are both the defaults from the
    // validator. The reset is what clears a sensor left wedged by a previous
    // run, which matters here because this app and kinect_v2_demo cannot hold
    // the device at the same time.
    // Colour only. The fit target is the RGB image; starting the depth stream
    // would run libfreenect2's OpenGL depth pipeline on the same GPU as the
    // training kernels for a result nothing reads.
    const bool ok = impl_->src.open(/*use_opengl=*/true,
                                    KinectSource::UsbReset::kReset, err,
                                    /*want_depth=*/false);
    if (!ok) {
        impl_->err = err;
        return false;
    }
    impl_->err.clear();
    impl_->src.setColorRate(30.f);
    return true;
}

void KinectFitTarget::close() {
    if (impl_ && impl_->src.isOpen()) impl_->src.close();
}

bool KinectFitTarget::isOpen() const { return impl_->src.isOpen(); }
std::string KinectFitTarget::error() const { return impl_->err; }
uint64_t KinectFitTarget::frames() const { return impl_->frames; }
void KinectFitTarget::setMirrored(bool m) { impl_->mirrored = m; }
bool KinectFitTarget::mirrored() const { return impl_->mirrored; }
void KinectFitTarget::setCrop(const FeedCrop& c) { impl_->crop = c; }
FeedCrop KinectFitTarget::crop() const { return impl_->crop; }
void KinectFitTarget::setRateHz(float hz) { impl_->src.setColorRate(hz); }

std::string KinectFitTarget::deviceInfo() const {
    if (!impl_->src.isOpen()) return "not open";
    return impl_->src.serial() + "  fw " + impl_->src.firmware() + "  " +
           impl_->src.pipelineName();
}

bool KinectFitTarget::pump() {
    if (!impl_->src.isOpen()) return false;
    if (!impl_->src.pollColor(impl_->frame)) return false;
    if (!impl_->frame.valid || impl_->frame.data.empty()) return false;
    impl_->have_frame = true;
    ++impl_->frames;
    return true;
}

bool KinectFitTarget::lastFrameRGB8(int w, int h,
                                    std::vector<unsigned char>& rgb,
                                    bool filtered) const {
    if (!impl_->have_frame || w <= 0 || h <= 0) return false;
    const FrameSnapshot& f = impl_->frame;
    if (!f.valid || f.data.empty()) return false;

    for (const DownsampleCache& c : impl_->cache) {
        if (!c.matches(w, h, impl_->frames, impl_->mirrored, impl_->crop,
                       filtered)) continue;
        rgb = c.rgb;                       // a copy of the result, not of the work
        return true;
    }

    const bool rgbx = (f.format == libfreenect2::Frame::RGBX);
    const SrcRect r = ComputeFeedRect(f.width, f.height, w, h, impl_->crop);
    // Mirrored to match what poll() produced, so landmark coordinates line up
    // with the fit target's pixels.
    if (filtered) {
        DownsampleRectToRGB8(f.data.data(), f.width, f.height, f.bytes_per_pixel,
                             rgbx ? 0 : 2, rgbx ? 2 : 0, r, w, h, rgb,
                             DstRect{}, impl_->mirrored);
    } else {
        PointSampleRectToRGB8(f.data.data(), f.width, f.height, f.bytes_per_pixel,
                              rgbx ? 0 : 2, rgbx ? 2 : 0, r, w, h, rgb,
                              impl_->mirrored);
    }

    DownsampleCache& slot = impl_->cache[impl_->cache_next];
    impl_->cache_next = (impl_->cache_next + 1) % 2;
    slot.w = w; slot.h = h;
    slot.frame_id = impl_->frames;
    slot.mirrored = impl_->mirrored;
    slot.crop = impl_->crop;
    slot.filtered = filtered;
    slot.rgb = rgb;
    slot.valid = true;
    return true;
}

bool KinectFitTarget::lastFrameRGBF(int w, int h, std::vector<float>& rgb,
                                    const DstRect& fill) const {
    if (!impl_->have_frame || w <= 0 || h <= 0) return false;
    const FrameSnapshot& f = impl_->frame;
    if (!f.valid || f.data.empty()) return false;

    const bool rgbx = (f.format == libfreenect2::Frame::RGBX);
    const SrcRect r = ComputeFeedRect(f.width, f.height, w, h, impl_->crop);
    DownsampleRectRGB8(f.data.data(), f.width, f.height, f.bytes_per_pixel,
                       rgbx ? 0 : 2, rgbx ? 2 : 0, r, w, h, rgb, fill,
                       impl_->mirrored);
    return true;
}

bool KinectFitTarget::poll(int w, int h, std::vector<float>& rgb) {
    return poll(w, h, rgb, DstRect{});
}

bool KinectFitTarget::poll(int w, int h, std::vector<float>& rgb,
                           const DstRect& fill) {
    if (!impl_->src.isOpen() || w <= 0 || h <= 0) return false;

    // A new sensor frame is not required every call: the colour camera runs at
    // 30 Hz (15 under long auto-exposure) while the render loop may be well
    // above that, so most frames legitimately have nothing new. Returning false
    // leaves the caller training against the previous target, which is correct
    // -- the alternative would be a stutter in the fit every other frame.
    if (!impl_->src.pollColor(impl_->frame)) return false;
    if (!impl_->frame.valid || impl_->frame.data.empty()) return false;
    impl_->have_frame = true;
    ++impl_->frames;

    const FrameSnapshot& f = impl_->frame;
    // libfreenect2 delivers BGRX or RGBX depending on pipeline; bytes_per_pixel
    // is 4 either way. Guessing wrong swaps red and blue, which on a face is
    // unmistakable but easy to leave in, so it is keyed off the reported format
    // rather than assumed.
    const bool rgbx = (f.format == libfreenect2::Frame::RGBX);
    const int r_off = rgbx ? 0 : 2;
    const int b_off = rgbx ? 2 : 0;

    // Mirroring is folded into the source rect rather than done as a second
    // pass over the output. A partial fill makes the old in-place row reversal
    // wrong as well as wasteful: it swaps a column with its opposite number,
    // and with only part of the frame written the opposite number is stale.
    // Reading the source columns backwards produces the same image and touches
    // only the pixels being filled.
    DownsampleRectRGB8(f.data.data(), f.width, f.height, f.bytes_per_pixel,
                       r_off, b_off,
                       ComputeFeedRect(f.width, f.height, w, h, impl_->crop),
                       w, h, rgb, fill, impl_->mirrored);
    return true;
}

}  // namespace mirror
