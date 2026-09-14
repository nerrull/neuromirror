// kinect_usb_watch — knows whether the Kinect v2's USB device is on the bus.
//
// Diagnostic only: nothing here drives KinectFitTarget's own reopen/backoff
// logic (see kinect_target.h's watchdog, tick()). This exists to put a
// *reason* next to a stall in the log -- "the sensor genuinely left the bus"
// versus "it's still enumerated and the colour stream just died", which look
// identical from a stalled colour stream alone but point at different fixes
// (a cable/power/hub problem versus a firmware wedge that a reset clears).
//
// Built on IOKit's matching notifications rather than anything freenect2
// exposes -- libfreenect2 has no "the device left" callback of its own.

#pragma once

#include <functional>
#include <memory>
#include <string>

namespace mirror {

class KinectUsbWatch {
public:
    KinectUsbWatch();
    ~KinectUsbWatch();

    // `on_event(attached, detail)` fires on the main run loop (via IOKit's
    // notification port, added to CFRunLoopGetMain() in kCFRunLoopDefaultMode)
    // whenever a USB device matching the Kinect v2's vendor/product ids
    // appears or disappears. `attached` is false for a disconnect. `detail`
    // is a plain description (product id, locationID, sessionID, USB speed)
    // with no timestamp or app context -- the caller adds that.
    //
    // Caveat: this only fires while something pumps that run loop -- here,
    // glfwPollEvents() via Cocoa's own event dispatch, once per render-loop
    // iteration. A notification queued while nothing serviced the loop (the
    // loop itself is blocked, or several are queued back-to-back) is
    // delivered in a burst the next time it is serviced, all stamped with
    // whatever "now" is at that point rather than when each one actually
    // happened. Recovery itself no longer risks this (see kinect_target.h's
    // worker -- close()/open() no longer block this thread), but a genuinely
    // slow frame elsewhere still could.
    //
    // Firing is best-effort: which IOKit class name (IOUSBHostDevice vs the
    // legacy IOUSBDevice) actually carries the Kinect's controller on a given
    // macOS version is not something this pins down definitively, so both
    // are matched -- and deduplicated (same sessionID, same direction, within
    // 2s) so one physical event does not produce two calls. Missing an event
    // here only means the log stays quiet about the *reason* for a drop -- it
    // does not affect whether the watchdog notices or recovers.
    //
    // Returns false if IOKit setup failed outright (never fatal to the app).
    bool start(std::function<void(bool attached, const std::string& detail)> on_event);
    void stop();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace mirror
