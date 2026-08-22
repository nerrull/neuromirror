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

    // The retained frame as float in [0,1], with optional partial fill. Same as
    // lastFrameRGB8 but returns floats. Used by the fitter to ensure it works
    // from the same retained snapshot as the tracker, not a fresh poll that would
    // consume the frame twice.
    bool lastFrameRGBF(int w, int h, std::vector<float>& rgb,
                       const DstRect& fill = {}) const;

    const char* name() const override { return "kinect"; }
    std::string error() const override;
    uint64_t frames() const override;

    // Mirror the image horizontally. On by default: a mirror should show you
    // your own left hand on your left, and the sensor does not do that.
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

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace mirror
