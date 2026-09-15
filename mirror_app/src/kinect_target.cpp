#include "kinect_target.h"

#include "kinect_log.h"
#include "kinect_source.h"

#include <libfreenect2/logger.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>

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
    // The colour source, owned by whichever side currently holds it: the
    // main thread while streaming normally, or the worker while it is
    // closing a dead device and/or retrying open() on it. Ownership itself
    // is what keeps two threads from ever touching one KinectSource at
    // once -- there is no lock around the calls into it, only around the
    // handoff of the pointer. Null means "the worker has it" (a loss is
    // being recovered from) or "never opened / deliberately closed".
    std::unique_ptr<KinectSource> src{new KinectSource()};

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

    // --- watchdog (main-thread state) --------------------------------------
    float stall_s = 3.f;
    double last_ok_time = 0;          // NowSeconds() of the last colour frame
    double opened_at = 0;              // NowSeconds() of the current open()
    double last_handled_detach = -1.0; // a detach already acted on -- see tick()
    KinectFitTarget::SensorState state = KinectFitTarget::SensorState::kClosed;
    bool auto_retry = false;           // a loss is being recovered by the worker
    double outage_start = 0;

    void noteFrameOk() { last_ok_time = NowSeconds(); }

    // --- recovery worker ----------------------------------------------
    //
    // KinectSource::close()/open() are synchronous libfreenect2/libusb calls.
    // Against an already-dead device each one alone measured several
    // seconds in the field (close(): ~4s waiting on doomed USB transfers to
    // time out; open(): ~1-3s enumerating and starting streams) -- long
    // enough that doing this inline in tick(), on the render thread, froze
    // the whole app for the duration. This worker exists to own that I/O
    // instead: the render thread only ever moves a unique_ptr and locks
    // `mu` for as long as the swap itself takes.
    //
    // One thread for the object's whole lifetime, parked on `cv` between
    // jobs. A "job" is one dead KinectSource to close and then retry open()
    // on; there is at most one in flight (tick() only ever hands off a new
    // one once the previous outage's source has already been picked up as
    // `recovered`, since isOpen() is false / auto_retry is true the whole
    // time in between).
    std::thread worker;
    mutable std::mutex mu;   // guards every field below this line
    std::condition_variable cv;
    bool stop = false;
    bool have_job = false;                     // main -> worker: a source is waiting
    std::unique_ptr<KinectSource> job;          // "
    std::unique_ptr<KinectSource> recovered;    // worker -> main: reopened, ready to swap in
    int attempts_done = 0;                      // attempts taken by the job now in `recovered`
    double next_retry_time = 0;                 // for the panel's countdown only

    void startWorker() {
        worker = std::thread([this] { workerMain(); });
    }

    void workerMain() {
        for (;;) {
            std::unique_ptr<KinectSource> dead;
            {
                std::unique_lock<std::mutex> lk(mu);
                cv.wait(lk, [&] { return stop || have_job; });
                if (stop) return;
                dead = std::move(job);
                have_job = false;
            }

            // From here `dead` is this thread's alone until it is handed
            // back (or dropped) below -- no lock needed to call into it.
            //
            // close()'s own NO_DEVICE line (libusb reliably prints one when
            // releasing interfaces on a device that already left the bus)
            // is suppressed from setting UsbErrorSeen by kinect_source.cpp's
            // close() itself (it brackets the call with SetClosingForLog).
            // Without that, the very first tick() after this job succeeds
            // would see a stale flag and declare a fresh loss immediately --
            // which is exactly what produced the repeated close/reopen loop
            // this worker was written to fix.
            dead->close();

            double backoff = 1.0;
            int local_attempts = 0;
            bool ok = false;
            for (;;) {
                std::string open_err;
                // No USB reset on a recovery reopen: the sensor is here
                // because its link dropped and it re-enumerated itself
                // (kernel: "terminateDevice ... link change interrupt"), so a
                // reset only forces a second detach/attach and about a
                // second more of dead feed. open() still falls back to a
                // reset if the plain open fails.
                ok = dead->open(/*use_opengl=*/true, KinectSource::UsbReset::kSkip,
                                open_err, /*want_depth=*/false);
                ++local_attempts;
                if (ok) break;

                char buf[256];
                snprintf(buf, sizeof(buf),
                         "kinect: reopen attempt %d failed (%s) -- retrying in %.0fs",
                         local_attempts, open_err.c_str(), backoff);
                kinectlog::Log(buf);

                std::unique_lock<std::mutex> lk(mu);
                next_retry_time = NowSeconds() + backoff;
                cv.wait_for(lk, std::chrono::duration<double>(backoff),
                           [&] { return stop; });
                if (stop) break;
                lk.unlock();
                backoff = std::min(backoff * 2.0, 15.0);
            }

            std::lock_guard<std::mutex> lk(mu);
            if (stop) {
                if (ok) dead->close();  // opened just as shutdown began;
                                        // nobody is left to claim it.
                return;
            }
            if (ok) {
                // Discard anything UsbErrorSeen() picked up from this
                // device's own close()/retry history -- see the comment on
                // dead->close() above for why a stale flag here would
                // immediately relose the very device that just recovered.
                UsbErrorSeen();
                recovered = std::move(dead);
                attempts_done = local_attempts;
            }
            // ok is always true here (the loop only exits via `break` on
            // success or on `stop`, and `stop` already returned above).
        }
    }
};

KinectFitTarget::KinectFitTarget() : impl_(new Impl()) {
    impl_->startWorker();
}

KinectFitTarget::~KinectFitTarget() {
    if (impl_) {
        std::unique_ptr<KinectSource> orphan;
        {
            std::lock_guard<std::mutex> lk(impl_->mu);
            impl_->stop = true;
            if (impl_->have_job) {
                // The worker never got to this one -- safe to close it here,
                // nothing else can be touching it.
                orphan = std::move(impl_->job);
                impl_->have_job = false;
            }
        }
        impl_->cv.notify_all();
        // Bounded by whatever the worker is doing right now -- at most one
        // in-flight open() or close() call, the same single hitch tick()
        // itself used to pay before this worker existed. Nothing better to
        // do at shutdown than wait for it.
        if (impl_->worker.joinable()) impl_->worker.join();
        if (orphan) orphan->close();
    }
    close();  // the still-open source, if any -- deliberate and synchronous;
              // see close()'s own comment on the cost against a dead device.
}

bool KinectFitTarget::open(std::string& err) {
    if (impl_->src && impl_->src->isOpen()) return true;
    if (impl_->auto_retry) {
        // The worker owns the only KinectSource instance right now, mid
        // close/reopen. Racing it with a second open() here would mean two
        // libfreenect2 contexts reaching for the same physical device --
        // let the worker finish (the panel already shows "sensor lost --
        // retrying").
        err = "recovery already in progress -- see the sensor state above";
        return false;
    }
    if (!impl_->src) impl_->src.reset(new KinectSource());

    // The USB reset is the validator's default: it clears a sensor left
    // wedged by a previous run, which matters here because this app and
    // kinect_v2_demo cannot hold the device at the same time.
    // Colour only. The fit target is the RGB image, and passing
    // want_depth=false also means KinectSource picks the CPU packet pipeline
    // over the OpenGL one (see kinect_source.cpp) -- the OpenGL pipeline only
    // decodes depth any differently; colour goes through the same decoder
    // either way, so there is no GPU depth pipeline left running for a result
    // nothing reads, and no GL context for a reopen to trip over.
    const bool ok = impl_->src->open(/*use_opengl=*/true,
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
    impl_->src->setColorRate(impl_->rate_hz);
    // Discard anything stale before starting the clock -- see the worker's
    // own note on why a leftover UsbErrorSeen flag must never survive an
    // open() it didn't just report on.
    UsbErrorSeen();
    impl_->noteFrameOk();   // don't start the stall clock already behind
    impl_->opened_at = NowSeconds();
    impl_->state = SensorState::kOpen;
    impl_->auto_retry = false;
    return true;
}

void KinectFitTarget::close() {
    if (!impl_) return;
    if (impl_->src && impl_->src->isOpen()) {
        // Deliberate and synchronous -- this runs at quit or from the
        // panel's "close sensor", never from the watchdog. Against an
        // already-dead device it can still take several seconds (libusb
        // waiting out doomed transfers); see the worker in Impl for why the
        // *automatic* recovery path does not pay this on the render thread.
        impl_->src->close();
    }
    impl_->auto_retry = false;
    impl_->state = SensorState::kClosed;
}

bool KinectFitTarget::isOpen() const {
    return impl_->src && impl_->src->isOpen();
}
std::string KinectFitTarget::error() const { return impl_->err; }
uint64_t KinectFitTarget::frames() const { return impl_->frames; }
void KinectFitTarget::setMirrored(bool m) { impl_->mirrored = m; }
bool KinectFitTarget::mirrored() const { return impl_->mirrored; }
void KinectFitTarget::setCrop(const FeedCrop& c) { impl_->crop = c; }
FeedCrop KinectFitTarget::crop() const { return impl_->crop; }
void KinectFitTarget::setRateHz(float hz) {
    impl_->rate_hz = hz;
    if (impl_->src) impl_->src->setColorRate(hz);
}
void KinectFitTarget::setStallSeconds(float s) { impl_->stall_s = s; }
KinectFitTarget::SensorState KinectFitTarget::state() const { return impl_->state; }

float KinectFitTarget::retryInSeconds() const {
    if ((impl_->src && impl_->src->isOpen()) || !impl_->auto_retry) return 0.f;
    std::lock_guard<std::mutex> lk(impl_->mu);
    const double remain = impl_->next_retry_time - NowSeconds();
    return remain > 0.0 ? (float)remain : 0.f;
}

std::string KinectFitTarget::deviceInfo() const {
    if (!impl_->src || !impl_->src->isOpen()) return "not open";
    return impl_->src->serial() + "  fw " + impl_->src->firmware() + "  " +
           impl_->src->pipelineName();
}

bool KinectFitTarget::pump() {
    if (!impl_->src || !impl_->src->isOpen()) return false;
    if (!impl_->src->pollColor(impl_->frame)) return false;
    if (!impl_->frame.valid || impl_->frame.data.empty()) return false;
    impl_->have_frame = true;
    ++impl_->frames;
    impl_->noteFrameOk();
    return true;
}

void KinectFitTarget::declareLost(const std::string& log_line) {
    std::unique_ptr<KinectSource> dead = std::move(impl_->src);
    impl_->src.reset();   // isOpen()/pump() see "no source" from this line on
    impl_->state = SensorState::kLost;
    impl_->auto_retry = true;
    impl_->outage_start = NowSeconds();
    {
        std::lock_guard<std::mutex> lk(impl_->mu);
        impl_->job = std::move(dead);
        impl_->have_job = true;
        impl_->next_retry_time = NowSeconds();  // "retrying" from now
    }
    impl_->cv.notify_one();
    kinectlog::Log(log_line);
}

void KinectFitTarget::forceLossForTest() {
    if (!(impl_->src && impl_->src->isOpen())) return;
    declareLost("kinect: --kinect-drop-test forcing a simulated loss");
}

void KinectFitTarget::tick(const char* show_phase, double usb_detach_time) {
    const double now = NowSeconds();

    // Pick up a recovered source, if the worker finished one since the last
    // tick -- the only place recovery touches impl_->src, and the only
    // thing tick() ever blocks on (a same-thread pointer swap under an
    // uncontended lock).
    {
        std::unique_ptr<KinectSource> got;
        int attempts_done = 0;
        {
            std::lock_guard<std::mutex> lk(impl_->mu);
            if (impl_->recovered) {
                got = std::move(impl_->recovered);
                attempts_done = impl_->attempts_done;
            }
        }
        if (got) {
            impl_->src = std::move(got);
            impl_->src->setColorRate(impl_->rate_hz);
            impl_->noteFrameOk();
            impl_->opened_at = now;
            impl_->last_handled_detach = usb_detach_time;
            impl_->state = SensorState::kOpen;
            impl_->auto_retry = false;
            char buf[192];
            snprintf(buf, sizeof(buf),
                     "kinect: recovered after %.1fs (%d attempt%s) -- %s",
                     now - impl_->outage_start, attempts_done,
                     attempts_done == 1 ? "" : "s", deviceInfo().c_str());
            kinectlog::Log(buf);
        }
    }

    if (!(impl_->src && impl_->src->isOpen())) {
        // Either deliberately closed, or the worker is mid-recovery -- both
        // handled above/elsewhere. Nothing to check on this thread.
        return;
    }

    // The direct signal first: libfreenect2 already told us, via its
    // logger, that the USB transport is gone. This can fire well inside
    // one stall window.
    const bool usb_err = UsbErrorSeen();
    // A detach observed during *this* open session that tick() has not
    // already acted on -- no reason to wait out the stall timer for
    // something already known.
    const bool fresh_detach = usb_detach_time >= 0.0 &&
                              usb_detach_time > impl_->opened_at &&
                              usb_detach_time > impl_->last_handled_detach;
    bool stalled = false;
    if (!usb_err && !fresh_detach) {
        if (impl_->src->colorPaused()) {
            // Deliberately quiet -- not a stall. Keep the clock from
            // accumulating so un-pausing doesn't immediately trip it.
            impl_->noteFrameOk();
        } else {
            const float rate = impl_->src->colorRateHz();
            // A poll rate slower than the stall window is not a fault --
            // extend the allowance to what that rate actually implies
            // (with slack) instead of raising a false alarm on a
            // deliberately down-rated stream. This same allowance is also
            // what gives a fresh open() its start-up grace: last_ok_time is
            // reset to "now" at open (see open() / the recovery swap
            // above), and the device takes a couple of seconds to start
            // streaming (USB negotiation -- see the "status 0x090000"
            // lines), which a shorter grace would read as an instant stall.
            const float effective_stall =
                (rate > 0.f) ? std::max(impl_->stall_s, 2.f / rate)
                             : impl_->stall_s;
            stalled = (now - impl_->last_ok_time) > effective_stall;
        }
    }

    if (usb_err || fresh_detach || stalled) {
        const double elapsed = now - impl_->last_ok_time;
        char buf[320];
        if (usb_err) {
            snprintf(buf, sizeof(buf),
                     "kinect: USB transport error reported by libfreenect2 "
                     "(phase %s, %.1fs since last colour frame) -- "
                     "closing and retrying",
                     show_phase ? show_phase : "?", elapsed);
        } else if (fresh_detach) {
            snprintf(buf, sizeof(buf),
                     "kinect: USB detach observed (phase %s, %.1fs since "
                     "last colour frame) -- closing and retrying "
                     "immediately rather than waiting out the stall timer",
                     show_phase ? show_phase : "?", elapsed);
            impl_->last_handled_detach = usb_detach_time;
        } else {
            snprintf(buf, sizeof(buf),
                     "kinect: stalled -- %.1fs since last colour frame "
                     "(phase %s); no USB detach seen -- device still "
                     "enumerated, likely a firmware wedge. closing and "
                     "retrying",
                     elapsed, show_phase ? show_phase : "?");
        }
        declareLost(buf);
    }
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
    // The resampler's own `mirror` flag means "flip the raw frame"; ours
    // means "behave like a mirror" -- and libfreenect2's raw frame already
    // does (see setMirrored's comment in the header), so the two are
    // inverses of each other. Matches poll() below, so landmark coordinates
    // line up with the fit target's pixels.
    const bool flip = !impl_->mirrored;
    if (filtered) {
        DownsampleRectToRGB8(f.data.data(), f.width, f.height, f.bytes_per_pixel,
                             rgbx ? 0 : 2, rgbx ? 2 : 0, r, w, h, rgb,
                             DstRect{}, flip);
    } else {
        PointSampleRectToRGB8(f.data.data(), f.width, f.height, f.bytes_per_pixel,
                              rgbx ? 0 : 2, rgbx ? 2 : 0, r, w, h, rgb,
                              flip);
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
    // See the "flip" comment in lastFrameRGB8 above -- inverted for the same
    // reason.
    DownsampleRectRGB8(f.data.data(), f.width, f.height, f.bytes_per_pixel,
                       rgbx ? 0 : 2, rgbx ? 2 : 0, r, w, h, rgb, fill,
                       !impl_->mirrored);
    return true;
}

bool KinectFitTarget::poll(int w, int h, std::vector<float>& rgb) {
    return poll(w, h, rgb, DstRect{});
}

bool KinectFitTarget::poll(int w, int h, std::vector<float>& rgb,
                           const DstRect& fill) {
    if (!impl_->src || !impl_->src->isOpen() || w <= 0 || h <= 0) return false;

    // A new sensor frame is not required every call: the colour camera runs at
    // 30 Hz (15 under long auto-exposure) while the render loop may be well
    // above that, so most frames legitimately have nothing new. Returning false
    // leaves the caller training against the previous target, which is correct
    // -- the alternative would be a stutter in the fit every other frame.
    if (!impl_->src->pollColor(impl_->frame)) return false;
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
    //
    // Inverted: libfreenect2's raw frame already reads like a mirror (see
    // setMirrored's comment in the header), so mirrored=true -- the default,
    // "behave like a mirror" -- must leave it alone, and it is mirrored=false
    // that asks for the column reversal.
    DownsampleRectRGB8(f.data.data(), f.width, f.height, f.bytes_per_pixel,
                       r_off, b_off,
                       ComputeFeedRect(f.width, f.height, w, h, impl_->crop),
                       w, h, rgb, fill, !impl_->mirrored);
    return true;
}

double KinectFitTarget::secondsSinceLastFrame() const {
    if (!impl_->src || !impl_->src->isOpen()) return 0.0;
    return NowSeconds() - impl_->last_ok_time;
}

double KinectFitTarget::uptimeSeconds() const {
    if (!impl_->src || !impl_->src->isOpen()) return 0.0;
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
