#include "kinect_source.h"

#include <chrono>
#include <cstdlib>
#include <cstring>

#include <libfreenect2/logger.h>
#include <libfreenect2/packet_pipeline.h>

namespace {
constexpr double kRateWindow = 0.5;  // seconds per rate-estimate window

std::atomic<bool> g_usb_error_seen{false};
std::atomic<bool> g_closing_for_log{false};

// libfreenect2's default logger is Info level, which makes the RGB decoder
// (VTRgbPacketProcessor on macOS, TurboJpegRgbPacketProcessor elsewhere) print
// an "avg. time / Hz" line every second. Warning still surfaces real problems
// (USB stalls, decode failures) without the steady-state spam.
//
// A thin subclass rather than createConsoleLogger() directly: every message
// is also fed to NoteFreenect2LogLine, so a caller that never installs its
// own logger still gets the watchdog hook below. mirror_app installs a
// louder logger of its own at startup (see kinect_target.cpp / main.mm's
// AppLogger) that overrides this one and forwards the same way.
class QuietFreenect2Logger : public libfreenect2::Logger {
 public:
  QuietFreenect2Logger() : inner_(libfreenect2::createConsoleLogger(Warning)) {
    level_ = Warning;
  }
  ~QuietFreenect2Logger() override { delete inner_; }
  void log(Level level, const std::string& message) override {
    if (inner_) inner_->log(level, message);
    NoteFreenect2LogLine(message);
  }

 private:
  libfreenect2::Logger* inner_;
};

struct InstallQuietFreenect2Logger {
  InstallQuietFreenect2Logger() {
    libfreenect2::setGlobalLogger(new QuietFreenect2Logger());
  }
} g_install_quiet_freenect2_logger;
}  // namespace

void NoteFreenect2LogLine(const std::string& message) {
  // Closing a device that has already left the bus reliably prints this
  // exact family of lines itself (see close(), below) -- during that window
  // they are expected, not news, and must not set the flag: a watchdog that
  // just finished closing a dead device would otherwise see a stale
  // "transport error" the instant it looked again, and relose the device it
  // had not even finished reopening yet.
  if (g_closing_for_log.load()) return;

  // The three lines libusb prints when the sensor drops off the bus mid-
  // stream (see kinect_target.cpp's watchdog for the failure this exists to
  // catch): a dead device that isOpen() still reports as open. Catching the
  // message directly is faster than waiting out a stall timeout, and does
  // not depend on the render loop still asking for frames.
  if (message.find("NO_DEVICE") != std::string::npos ||
      message.find("bulk transfer failed") != std::string::npos ||
      message.find("failed to set ir interface state") != std::string::npos) {
    g_usb_error_seen.store(true);
  }
}

bool UsbErrorSeen() { return g_usb_error_seen.exchange(false); }

void SetClosingForLog(bool closing) { g_closing_for_log.store(closing); }

double NowSeconds() {
  using Clock = std::chrono::steady_clock;
  static const Clock::time_point origin = Clock::now();
  return std::chrono::duration<double>(Clock::now() - origin).count();
}

// --- LatestFrameListener -----------------------------------------------------

LatestFrameListener::~LatestFrameListener() {
  std::lock_guard<std::mutex> lk(mu_);
  delete color_.frame;
  delete depth_.frame;
  color_.frame = depth_.frame = nullptr;
}

LatestFrameListener::Slot* LatestFrameListener::slotFor(
    libfreenect2::Frame::Type type) {
  if (type == libfreenect2::Frame::Color) return &color_;
  if (type == libfreenect2::Frame::Depth) return &depth_;
  return nullptr;
}

const LatestFrameListener::Slot* LatestFrameListener::slotFor(
    libfreenect2::Frame::Type type) const {
  if (type == libfreenect2::Frame::Color) return &color_;
  if (type == libfreenect2::Frame::Depth) return &depth_;
  return nullptr;
}

bool LatestFrameListener::onNewFrame(libfreenect2::Frame::Type type,
                                    libfreenect2::Frame* frame) {
  if ((accepted_ & static_cast<unsigned int>(type)) == 0) {
    return false;  // decline (e.g. IR): libfreenect2 recycles it for us
  }

  std::lock_guard<std::mutex> lk(mu_);
  Slot* s = slotFor(type);
  if (!s) return false;

  // Real transport loss shows as a hole in the device sequence counter. Because
  // we never gate one stream on another, a gap here is a genuine gap.
  if (s->seq_seen && frame->sequence > s->last_seq + 1) {
    s->seq_gaps += frame->sequence - s->last_seq - 1;
  }
  s->last_seq = frame->sequence;
  s->seq_seen = true;

  ++s->delivered;
  ++s->win_delivered;
  if (s->fresh) ++s->skipped;  // we're superseding a frame the UI never took

  const double now = NowSeconds();
  if (s->win_start == 0) s->win_start = now;
  const double elapsed = now - s->win_start;
  if (elapsed >= kRateWindow) {
    s->delivered_hz = s->win_delivered / elapsed;
    s->polled_hz = s->win_polled / elapsed;
    s->win_delivered = s->win_polled = 0;
    s->win_start = now;
  }

  delete s->frame;  // drop the superseded frame
  s->frame = frame;
  s->fresh = true;
  return true;  // we took ownership
}

bool LatestFrameListener::take(libfreenect2::Frame::Type type,
                               FrameSnapshot& out) {
  std::lock_guard<std::mutex> lk(mu_);
  Slot* s = slotFor(type);
  if (!s || !s->fresh || !s->frame) return false;

  const libfreenect2::Frame* f = s->frame;
  const size_t bytes = f->width * f->height * f->bytes_per_pixel;
  out.data.resize(bytes);
  std::memcpy(out.data.data(), f->data, bytes);
  out.width = static_cast<int>(f->width);
  out.height = static_cast<int>(f->height);
  out.bytes_per_pixel = static_cast<int>(f->bytes_per_pixel);
  out.format = f->format;
  out.sequence = f->sequence;
  out.timestamp = f->timestamp;
  out.exposure = f->exposure;
  out.gain = f->gain;
  out.gamma = f->gamma;
  out.valid = true;

  s->fresh = false;  // keep the Frame allocated; it dies on the next delivery
  ++s->polled;
  ++s->win_polled;
  return true;
}

StreamStats LatestFrameListener::stats(libfreenect2::Frame::Type type) const {
  std::lock_guard<std::mutex> lk(mu_);
  StreamStats out;
  const Slot* s = slotFor(type);
  if (!s) return out;
  out.delivered = s->delivered;
  out.polled = s->polled;
  out.skipped = s->skipped;
  out.seq_gaps = s->seq_gaps;
  out.delivered_hz = s->delivered_hz;
  out.polled_hz = s->polled_hz;
  return out;
}

// --- KinectSource ------------------------------------------------------------

KinectSource::~KinectSource() { close(); }

bool KinectSource::open(bool use_opengl, UsbReset reset, std::string& err,
                        bool want_depth) {
  const bool want_reset = (reset == UsbReset::kReset);

  if (openOnce(use_opengl, want_reset, err, want_depth)) {
    used_usb_reset_ = want_reset;
    return true;
  }

  // Whichever policy was asked for, the other is worth one try: a reset can
  // fail on a sensor that a no-reset open still drives fine, and vice versa.
  std::string other_err;
  if (openOnce(use_opengl, !want_reset, other_err, want_depth)) {
    used_usb_reset_ = !want_reset;
    return true;
  }

  err = std::string("open with") + (want_reset ? "" : "out") +
        " USB reset failed (" + err + "); retry with" +
        (want_reset ? "out" : "") + " reset also failed (" + other_err + ")";
  return false;
}

bool KinectSource::openOnce(bool use_opengl, bool with_reset,
                            std::string& err, bool want_depth) {
  // Consumed by our local libfreenect2 patch (patches/) inside openDevice().
  ::setenv("FREENECT2_NO_RESET", with_reset ? "0" : "1", /*overwrite=*/1);

  if (fn2_.enumerateDevices() == 0) {
    err = "No Kinect v2 found. Check the USB3 adapter/power brick, then "
          "unplug/replug and restart.";
    return false;
  }
  serial_ = fn2_.getDefaultDeviceSerialNumber();

  libfreenect2::PacketPipeline* pipeline = nullptr;
#if defined(LIBFREENECT2_WITH_OPENGL_SUPPORT)
  // The OpenGL pipeline only buys anything for the *depth* decode -- the RGB
  // path is the same turbojpeg-based decoder on either pipeline (see
  // packet_pipeline.cpp: OpenGLPacketPipeline and CpuPacketPipeline both
  // construct their RgbPacketProcessor the same way). With want_depth=false
  // there is no depth stream to decode, so an OpenGL pipeline here would only
  // be spending a GL context -- and the GLFW context the OpenGL depth
  // processor owns internally is what prints "GLFW error 65537 the GLFW
  // library is not initialized" when a caller closes and reopens the device
  // repeatedly (a watchdog retrying a dropped sensor, for instance): its own
  // glfwInit()/glfwTerminate() pair does not coordinate with the host app's.
  // CPU sidesteps that failure mode entirely, not just papers over it.
  if (use_opengl && want_depth) {
    pipeline = new libfreenect2::OpenGLPacketPipeline();
    pipeline_name_ = "OpenGL";
  }
#endif
  if (!pipeline) {
    pipeline = new libfreenect2::CpuPacketPipeline();
    pipeline_name_ = "CPU";
  }

  // openDevice takes ownership of `pipeline` on success; on failure it frees it.
  dev_ = fn2_.openDevice(serial_, pipeline);
  if (!dev_) {
    err = "openDevice failed for serial " + serial_;
    return false;
  }

  // We display color + depth only. IR is declined in the listener so the
  // decoder can recycle those buffers instead of us copying them.
  listener_.setAccepted(want_depth ? (libfreenect2::Frame::Color |
                                      libfreenect2::Frame::Depth)
                                   : libfreenect2::Frame::Color);
  dev_->setColorFrameListener(&listener_);
  if (want_depth) dev_->setIrAndDepthFrameListener(&listener_);

  // startStreams rather than start(): declining the depth stream outright is
  // what actually stops the depth pipeline from decoding, which pausing the
  // poll does not.
  if (!dev_->startStreams(/*rgb=*/true, /*depth=*/want_depth)) {
    err = "device start failed";
    dev_->close();
    dev_ = nullptr;
    return false;
  }
  firmware_ = dev_->getFirmwareVersion();
  serial_ = dev_->getSerialNumber();

  // Only valid once streaming has started (the params come off the device).
  const libfreenect2::Freenect2Device::IrCameraParams ir =
      dev_->getIrCameraParams();
  intrinsics_.fx = ir.fx;
  intrinsics_.fy = ir.fy;
  intrinsics_.cx = ir.cx;
  intrinsics_.cy = ir.cy;
  intrinsics_.valid = (ir.fx > 1.f && ir.fy > 1.f);
  return true;
}

void KinectSource::close() {
  if (!dev_) return;
  // See SetClosingForLog's comment: closing a device that already left the
  // bus is expected to print a NO_DEVICE line of its own, and that must not
  // be mistaken for a fresh transport failure by whoever is watching
  // UsbErrorSeen().
  SetClosingForLog(true);
  dev_->stop();
  dev_->close();
  dev_ = nullptr;
  SetClosingForLog(false);
}

bool KinectSource::pollStream(libfreenect2::Frame::Type type,
                              FrameSnapshot& out, std::atomic<float>& hz,
                              std::atomic<bool>& paused, double& next_due) {
  if (!dev_ || paused.load()) return false;

  const float rate = hz.load();
  const double now = NowSeconds();
  if (rate > 0.f) {
    if (now < next_due) return false;
    const double period = 1.0 / rate;
    // Re-base rather than accumulate, so a stall (window drag, breakpoint)
    // can't queue up a burst of catch-up polls.
    next_due = (now - next_due > period) ? now + period : next_due + period;
  }

  if (!listener_.take(type, out)) {
    // Nothing new yet. Retry on the next UI frame instead of waiting out a
    // whole period, so a slow stream still shows up promptly.
    if (rate > 0.f) next_due = now;
    return false;
  }
  return true;
}

bool KinectSource::pollColor(FrameSnapshot& out) {
  return pollStream(libfreenect2::Frame::Color, out, color_hz_, color_paused_,
                    color_next_due_);
}

bool KinectSource::pollDepth(FrameSnapshot& out) {
  return pollStream(libfreenect2::Frame::Depth, out, depth_hz_, depth_paused_,
                    depth_next_due_);
}
