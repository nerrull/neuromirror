// kinect_target — the Kinect v2 colour camera as a live fitting target.
//
// Wraps kinect_v2_validate's KinectSource rather than reimplementing it. That
// module already handles the parts that are easy to get wrong and expensive to
// rediscover: the USB reset policy, independent latest-wins listeners per
// stream (a SyncMultiFrameListener would gate depth on colour), and per-stream
// poll-rate control. See kinect_v2_validate/src/demo/kinect_source.h.
//
// Compiled only when freenect2 is available (MIRROR_HAVE_KINECT); the app
// builds and runs without it, with this target simply absent from the UI.

#pragma once

#include "fit_target.h"

#include <memory>
#include <string>

namespace mirror {

class KinectFitTarget : public FitTarget {
public:
    KinectFitTarget();
    ~KinectFitTarget() override;

    // Opens the sensor. Returns false with `err` set if it is missing, already
    // held by another process, or fails to start.
    bool open(std::string& err);
    void close();
    bool isOpen() const;

    // The colour camera is 1920x1080; the fit grid is a few hundred px, so
    // frames are box-filtered down (see DownsampleRGB8). Returns false when no
    // new sensor frame has arrived since the last call -- the caller should
    // keep training on the previous target rather than treating it as an error.
    bool poll(int w, int h, std::vector<float>& rgb) override;
    // The same, resampling only `fill` of the destination. Everything outside
    // it keeps whatever it held -- see DstRect.
    bool poll(int w, int h, std::vector<float>& rgb, const DstRect& fill);

    // Advance the retained snapshot and nothing else. Returns true if a new
    // sensor frame arrived.
    //
    // For the callers that want the *frame* fresh but do not want a resampling
    // of it: with the live fit disarmed, the overlay was calling poll() into a
    // scratch buffer purely to move the snapshot along, which paid for a full
    // 1920x1080 box filter and then dropped the result on the floor.
    bool pump();

    // The most recently polled frame as RGB8 at (w, h), for the face tracker.
    //
    // Deliberately reads the *retained* snapshot rather than pulling a new one:
    // a second pollColor() here would race the fit path for frames, and the two
    // would end up looking at different moments -- the mask would then be a
    // face outline from one frame applied to the pixels of another, which shows
    // up as the fit smearing whenever anyone moves. Returns false before the
    // first successful poll().
    // `filtered` box-filters the source footprint; false takes one pixel per
    // destination pixel. The tracker wants the filter -- its landmarks become
    // the mask, the crop and the region, and sampling noise there turns into
    // geometry that jitters. The camera overlay does not: it is a thumbnail
    // nothing measures.
    bool lastFrameRGB8(int w, int h, std::vector<unsigned char>& rgb,
                       bool filtered = true) const;
    // The same over an explicit rect of the sensor frame instead of the
    // feed crop's -- the tracker takes the whole frame. Same retained
    // snapshot, same mirroring.
    bool lastFrameRGB8(const SrcRect& rect, int w, int h,
                       std::vector<unsigned char>& rgb, bool filtered = true) const;
    // The retained colour frame's size (1920x1080 on the v2). False
    // before the first frame.
    bool frameSize(int& w, int& h) const;

    // The retained frame as float in [0,1], with optional partial fill. Same as
    // lastFrameRGB8 but returns floats. Used by the fitter to ensure it works
    // from the same retained snapshot as the tracker, not a fresh poll that would
    // consume the frame twice.
    bool lastFrameRGBF(int w, int h, std::vector<float>& rgb,
                       const DstRect& fill = {}) const;

    const char* name() const override { return "kinect"; }
    std::string error() const override;
    uint64_t frames() const override;

    // Whether the presented image behaves like a mirror: move left, see
    // yourself move left. On by default.
    //
    // This is *not* "flip the frame" -- confirmed empirically with
    // --feedshot (dev_tools.mm), the Kinect v2's colour frame arrives from
    // libfreenect2 already mirror-flipped relative to a normal camera (the
    // sensor does not hand back what a photograph taken from the same spot
    // would show). So mirrored(true), the default, leaves the raw frame
    // alone; mirrored(false) is what applies the horizontal flip, undoing
    // the sensor's own mirroring for the rare case that needs a true camera
    // view instead. The naming used to be backwards -- setMirrored(true)
    // flipped an already-mirrored frame, which produced exactly the "camera
    // view, not a mirror" symptom this comment now exists to prevent
    // regressing.
    void setMirrored(bool m);
    bool mirrored() const;

    // How the 16:9 sensor is cropped into the frame's aspect (see FeedCrop).
    // Set from the app, because which rect to keep is a framing decision about
    // the installation and not a property of the sensor. Applied identically to
    // poll() and lastFrameRGB8(), so the tracker and the fit keep seeing the
    // same image -- landmarks are normalised to whatever was handed over, and a
    // crop applied to only one of the two would put the mask somewhere the face
    // is not.
    void setCrop(const FeedCrop& c);
    FeedCrop crop() const;

    // Cap how often frames are pulled. The sensor free-runs at 30 Hz; pulling
    // less often costs freshness, not stability.
    void setRateHz(float hz);

    std::string deviceInfo() const;

    // --- watchdog: recovering from a Kinect that drops off USB mid-run -----
    //
    // The installation has nobody at the panel to notice a dead feed and
    // press "open sensor" again. If the colour stream goes quiet for
    // `setStallSeconds()` while it is open and nobody deliberately paused or
    // slowed it down, libfreenect2 itself reports the USB transport gone
    // (see kinect_source.h's UsbErrorSeen -- a faster, direct signal that
    // beats waiting the stall out), or a USB detach was directly observed
    // (see kinect_usb_watch.h), the device is declared lost and handed to a
    // background worker: it closes the dead source and retries open() on a
    // backoff (1s, 2s, 4s, ... capped at 15s) until it comes back, then hands
    // the reopened source back for tick() to swap in. Closing and reopening
    // a dead device are each libfreenect2/libusb calls that can take single-
    // digit seconds -- see the worker note below for why none of that runs
    // on the render thread. The re-enumeration this waits for is real: on
    // the installation the sensor is alone on its own XHCI controller.
    //
    // A user-initiated close() (the panel's "close sensor") does not arm
    // this -- only a loss the watchdog itself declared gets auto-retried.

    enum class SensorState { kClosed, kOpen, kLost };

    // How long the colour stream may go quiet (while actively polled, not
    // paused or rate-limited below what that implies) before the sensor is
    // declared lost. Default matches PANEL.md's "kinect stall s", 3 seconds.
    void setStallSeconds(float s);

    // Call once per frame, unconditionally -- whether or not anything polled
    // a frame this frame, and whether or not the sensor is even open. This
    // never blocks: declaring a loss only moves a pointer and wakes the
    // worker thread (see the Impl comment in kinect_target.cpp), and picking
    // up a recovered source is the same pointer swap in the other direction.
    // All of the actual close()/open() I/O happens off this thread.
    //
    // `show_phase` and `usb_detach_time` (steady-clock seconds, < 0 if none
    // seen) are for the log line only -- they let it say whether the loss
    // looks like a USB/power event (a detach was observed) or a firmware
    // wedge (the device stayed enumerated but the colour stream still died).
    // A detach observed *after* the current open() also skips the stall
    // wait entirely -- there is nothing to learn by waiting it out.
    void tick(const char* show_phase, double usb_detach_time = -1.0);

    SensorState state() const;
    // Seconds until the next reopen attempt, or 0 if not currently retrying.
    float retryInSeconds() const;

    // Diagnostics only (the USB attach/detach log lines assembled in
    // main.mm, next to kinect_usb_watch's observer). 0 while closed.
    double secondsSinceLastFrame() const;
    double uptimeSeconds() const;

    // Hidden dev hook for exercising the recovery path without physically
    // unplugging anything: --kinect-drop-test (see main.mm) calls this a few
    // seconds into a run to force the same "declare lost, hand to worker"
    // path a real stall or USB error would. Cheap and harmless to leave in
    // -- a no-op unless something calls it, and it takes the exact same code
    // path recovery always takes.
    void forceLossForTest();

private:
    // Both tick() and forceLossForTest() declare a loss the same way: detach
    // the current source, hand it to the worker, arm auto-retry, log.
    void declareLost(const std::string& log_line);

    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Installs a libfreenect2 logger that timestamps every line, prefixes it
// "kinect/fn2:", routes it through kinect_log (stderr + the rolling
// ~/Library/Logs/mirror_app/kinect.log file), and still feeds
// NoteFreenect2LogLine so the watchdog's direct USB-error signal keeps
// working. Overrides kinect_source.cpp's own quiet default logger -- call
// once at startup, before the first open(). Level is Info: that is what
// keeps libfreenect2's device-enumeration line ("[Freenect2Impl] found ...")
// visible; Debug stays off.
void InstallKinectDiagnosticLogger();

// USB attach/detach bookkeeping: fed by kinect_usb_watch's callback in
// main.mm on a detach, and read both by tick() (to tell a USB/power loss
// apart from a firmware wedge in its log line) and by main.mm's own log
// lines (to say how long the device was gone). Free functions rather than
// methods on KinectFitTarget because the USB device and the fit target are
// two different things noticing two different failures -- kept here only so
// both agree on the same clock (NowSeconds(), from kinect_source.h).
void NoteKinectUsbDetach();
// < 0 if no detach has been observed yet this run.
double KinectUsbDetachTime();
// NowSeconds() - KinectUsbDetachTime(), or < 0 if none observed yet.
double SecondsSinceKinectUsbDetach();

}  // namespace mirror
