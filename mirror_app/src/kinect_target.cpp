#include "kinect_target.h"

#include "kinect_log.h"
#include "kinect_source.h"

#include <libfreenect2/logger.h>

#include <algorithm>
#include <cstdio>

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

    // The rate last requested via setRateHz(), reapplied on every open() --
    // KinectSource itself keeps color_hz_/color_paused_ across a close/open
    // (they are not reset by KinectSource::close()), but open() used to stomp
    // them back to a hard-coded 30 Hz. Kept here so a reopen after a watchdog
    // recovery honours whatever the panel last asked for.
    float rate_hz = 30.f;

    // --- watchdog -----------------------------------------------------
    float stall_s = 3.f;
    double last_ok_time = 0;          // NowSeconds() of the last colour frame
    double opened_at = 0;              // NowSeconds() of the current open()
    KinectFitTarget::SensorState state = KinectFitTarget::SensorState::kClosed;
    bool auto_retry = false;          // the watchdog (not the user) closed it
    double next_retry_time = 0;
    double backoff_s = 1.0;
    double outage_start = 0;
    int attempts = 0;                 // failed reopen attempts this outage

    void noteFrameOk() { last_ok_time = NowSeconds(); }
};

KinectFitTarget::KinectFitTarget() : impl_(new Impl()) {}
KinectFitTarget::~KinectFitTarget() { close(); }

bool KinectFitTarget::open(std::string& err) {
    if (impl_->src.isOpen()) return true;
    // The USB reset is the validator's default: it clears a sensor left
    // wedged by a previous run, which matters here because this app and
    // kinect_v2_demo cannot hold the device at the same time.
    // Colour only. The fit target is the RGB image, and passing
    // want_depth=false also means KinectSource picks the CPU packet pipeline
    // over the OpenGL one (see kinect_source.cpp) -- the OpenGL pipeline only
    // decodes depth any differently; colour goes through the same decoder
    // either way, so there is no GPU depth pipeline left running for a result
    // nothing reads, and no GL context for a reopen to trip over.
    const bool ok = impl_->src.open(/*use_opengl=*/true,
                                    KinectSource::UsbReset::kReset, err,
                                    /*want_depth=*/false);
    if (!ok) {
        impl_->err = err;
        return false;
    }
    impl_->err.clear();
    // Reapply rather than a hard-coded default: KinectSource itself carries
    // color_hz_ across a close()/open() (see kinect_source.h), but this used
    // to stomp it back to 30 -- silently undoing a panel-set rate every time
    // the watchdog recovered the sensor.
    impl_->src.setColorRate(impl_->rate_hz);
    impl_->noteFrameOk();   // don't start the stall clock already behind
    impl_->opened_at = NowSeconds();
    impl_->state = SensorState::kOpen;
    impl_->auto_retry = false;
    impl_->backoff_s = 1.0;
    return true;
}

void KinectFitTarget::close() {
    if (impl_ && impl_->src.isOpen()) impl_->src.close();
    if (impl_) {
        // A deliberate close (the panel's "close sensor") is not something
        // the watchdog should try to undo.
        impl_->auto_retry = false;
        impl_->state = SensorState::kClosed;
    }
}

bool KinectFitTarget::isOpen() const { return impl_->src.isOpen(); }
std::string KinectFitTarget::error() const { return impl_->err; }
uint64_t KinectFitTarget::frames() const { return impl_->frames; }
void KinectFitTarget::setMirrored(bool m) { impl_->mirrored = m; }
bool KinectFitTarget::mirrored() const { return impl_->mirrored; }
void KinectFitTarget::setCrop(const FeedCrop& c) { impl_->crop = c; }
FeedCrop KinectFitTarget::crop() const { return impl_->crop; }
void KinectFitTarget::setRateHz(float hz) {
    impl_->rate_hz = hz;
    impl_->src.setColorRate(hz);
}
void KinectFitTarget::setStallSeconds(float s) { impl_->stall_s = s; }
KinectFitTarget::SensorState KinectFitTarget::state() const { return impl_->state; }

float KinectFitTarget::retryInSeconds() const {
    if (impl_->src.isOpen() || !impl_->auto_retry) return 0.f;
    const double remain = impl_->next_retry_time - NowSeconds();
    return remain > 0.0 ? (float)remain : 0.f;
}

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
    impl_->noteFrameOk();
    return true;
}

void KinectFitTarget::tick(const char* show_phase, double usb_detach_time) {
    const double now = NowSeconds();

    if (impl_->src.isOpen()) {
        // The direct signal first: libfreenect2 already told us, via its
        // logger, that the USB transport is gone. This can fire well inside
        // one stall window.
        const bool usb_err = UsbErrorSeen();
        bool stalled = false;
        if (!usb_err) {
            if (impl_->src.colorPaused()) {
                // Deliberately quiet -- not a stall. Keep the clock from
                // accumulating so un-pausing doesn't immediately trip it.
                impl_->noteFrameOk();
            } else {
                const float rate = impl_->src.colorRateHz();
                // A poll rate slower than the stall window is not a fault --
                // extend the allowance to what that rate actually implies
                // (with slack) instead of raising a false alarm on a
                // deliberately down-rated stream.
                const float effective_stall =
                    (rate > 0.f) ? std::max(impl_->stall_s, 2.f / rate)
                                 : impl_->stall_s;
                stalled = (now - impl_->last_ok_time) > effective_stall;
            }
        }

        if (usb_err || stalled) {
            const double elapsed = now - impl_->last_ok_time;
            std::string reason;
            char buf[256];
            if (usb_err) {
                snprintf(buf, sizeof(buf),
                         "kinect: USB transport error reported by libfreenect2 "
                         "(phase %s, %.1fs since last colour frame) -- "
                         "closing and retrying",
                         show_phase ? show_phase : "?", elapsed);
            } else if (usb_detach_time >= 0.0 &&
                       (now - usb_detach_time) < elapsed + 5.0) {
                snprintf(buf, sizeof(buf),
                         "kinect: stalled -- %.1fs since last colour frame "
                         "(phase %s); USB detach seen %.1fs ago -- USB/power. "
                         "closing and retrying",
                         elapsed, show_phase ? show_phase : "?",
                         now - usb_detach_time);
            } else {
                snprintf(buf, sizeof(buf),
                         "kinect: stalled -- %.1fs since last colour frame "
                         "(phase %s); no USB detach seen -- device still "
                         "enumerated, likely a firmware wedge. closing and "
                         "retrying",
                         elapsed, show_phase ? show_phase : "?");
            }
            kinectlog::Log(buf);

            impl_->src.close();
            impl_->state = SensorState::kLost;
            impl_->auto_retry = true;
            impl_->backoff_s = 1.0;
            impl_->outage_start = now;
            impl_->attempts = 0;
            impl_->next_retry_time = now + impl_->backoff_s;
        }
        return;
    }

    // Not open. Only a loss the watchdog itself declared is retried
    // automatically -- a user-pressed "close sensor" waits for the button.
    if (!impl_->auto_retry) return;
    if (now < impl_->next_retry_time) return;

    // One attempt per tick: open() is synchronous and can take ~1-2s, which
    // is a one-time hitch in the render loop on the frame a retry lands --
    // acceptable at a 1-15s backoff cadence, and simpler than moving open()
    // onto a helper thread for a hitch this rare and this short.
    std::string err;
    ++impl_->attempts;
    if (open(err)) {
        char buf[192];
        snprintf(buf, sizeof(buf),
                 "kinect: recovered after %.1fs (%d attempt%s) -- %s",
                 now - impl_->outage_start, impl_->attempts,
                 impl_->attempts == 1 ? "" : "s", deviceInfo().c_str());
        kinectlog::Log(buf);
        return;
    }
    impl_->err = err;
    impl_->backoff_s = std::min(impl_->backoff_s * 2.0, 15.0);
    impl_->next_retry_time = now + impl_->backoff_s;
    char buf[256];
    snprintf(buf, sizeof(buf),
             "kinect: reopen attempt %d failed (%s) -- retrying in %.0fs",
             impl_->attempts, err.c_str(), impl_->backoff_s);
    kinectlog::Log(buf);
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
    impl_->noteFrameOk();

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

double KinectFitTarget::secondsSinceLastFrame() const {
    if (!impl_->src.isOpen()) return 0.0;
    return NowSeconds() - impl_->last_ok_time;
}

double KinectFitTarget::uptimeSeconds() const {
    if (!impl_->src.isOpen()) return 0.0;
    return NowSeconds() - impl_->opened_at;
}

namespace {

// Routes libfreenect2's own logging through kinect_log so the
// "LIBUSB_ERROR_NO_DEVICE" lines the operator cares about land with a
// timestamp, on stderr and in the rolling file, next to everything else this
// subsystem logs -- and still calls NoteFreenect2LogLine so the watchdog's
// direct USB-error signal (see kinect_source.h's UsbErrorSeen) keeps working
// no matter which logger is installed.
class AppFreenect2Logger : public libfreenect2::Logger {
public:
    AppFreenect2Logger() { level_ = Info; }
    void log(Level, const std::string& message) override {
        kinectlog::Log("kinect/fn2: " + message);
        NoteFreenect2LogLine(message);
    }
};

double g_last_usb_detach_time = -1.0;

}  // namespace

void InstallKinectDiagnosticLogger() {
    libfreenect2::setGlobalLogger(new AppFreenect2Logger());
}

void NoteKinectUsbDetach() { g_last_usb_detach_time = NowSeconds(); }
double KinectUsbDetachTime() { return g_last_usb_detach_time; }

double SecondsSinceKinectUsbDetach() {
    return g_last_usb_detach_time < 0.0 ? -1.0
                                        : NowSeconds() - g_last_usb_detach_time;
}

}  // namespace mirror
