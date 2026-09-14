#include "kinect_usb_watch.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

#include <chrono>
#include <cstdio>
#include <vector>

namespace mirror {

namespace {

constexpr long kVendorMicrosoft = 0x045e;

// The Kinect v2 sensor's own camera/audio controller (0x02c4, "Xbox NUI
// Sensor") plus the two ids the bundled USB3 adapter/hub is known to
// enumerate as. Best-effort: see the header -- a wrong id here only means a
// missed diagnostic line, never a missed disconnect as far as the watchdog
// itself (kinect_target.cpp's tick()) is concerned, since that reacts to the
// stall timer and libfreenect2's own log lines, not to this.
bool IsKinectProduct(long pid) {
    return pid == 0x02c4 || pid == 0x02d8 || pid == 0x02d9;
}

long NumberProp(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    if (!v) return -1;
    long out = -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &out);
    }
    CFRelease(v);
    return out;
}

std::string SpeedName(long speed) {
    // IOUSBHostFamily's kUSBDeviceSpeed* values.
    switch (speed) {
        case 0: return "USB1.1 (low)";
        case 1: return "USB1.1 (full)";
        case 2: return "USB2";
        case 3: return "USB3";
        case 4: return "USB3.1+";
        default: return "speed?";
    }
}

}  // namespace

struct KinectUsbWatch::Impl {
    IONotificationPortRef port = nullptr;
    io_iterator_t matched_host = 0, terminated_host = 0;
    io_iterator_t matched_legacy = 0, terminated_legacy = 0;
    std::function<void(bool, const std::string&)> cb;

    // Debounces one real transition being reported more than once. This
    // watcher matches both "IOUSBHostDevice" and "IOUSBDevice" (see start()
    // -- which class name a given macOS/driver combination actually
    // publishes for the Kinect's controller isn't pinned down), so a device
    // that satisfies both class matches gets IOKit's notification twice for
    // the same physical event, with the same sessionID both times. A
    // genuine re-enumeration gets a new sessionID from IOKit, so this never
    // collapses real flapping -- only the duplicate delivery of one event.
    struct Recent { long session; bool attached; std::chrono::steady_clock::time_point at; };
    std::vector<Recent> recent;

    bool ShouldEmit(long session, bool attached) {
        const auto now = std::chrono::steady_clock::now();
        for (size_t i = 0; i < recent.size();) {
            if (now - recent[i].at > std::chrono::seconds(2)) {
                recent[i] = recent.back();
                recent.pop_back();
                continue;
            }
            if (recent[i].session == session && recent[i].attached == attached) {
                return false;
            }
            ++i;
        }
        recent.push_back({session, attached, now});
        return true;
    }

    // Drains an iterator IOKit handed back (both the arming call and every
    // later notification use the same shape), releasing each io_service_t as
    // required regardless of whether it matched the Kinect.
    static void Drain(void* refcon, io_iterator_t it, bool attached) {
        auto* self = static_cast<Impl*>(refcon);
        io_service_t svc;
        while ((svc = IOIteratorNext(it))) {
            const long vid = NumberProp(svc, CFSTR("idVendor"));
            const long pid = NumberProp(svc, CFSTR("idProduct"));
            if (vid == kVendorMicrosoft && IsKinectProduct(pid) && self->cb) {
                const long loc = NumberProp(svc, CFSTR("locationID"));
                const long sess = NumberProp(svc, CFSTR("sessionID"));
                const long speed = NumberProp(svc, CFSTR("Device Speed"));
                if (self->ShouldEmit(sess, attached)) {
                    char buf[192];
                    snprintf(buf, sizeof(buf),
                             "pid 0x%04lx locationID 0x%lx sessionID 0x%lx %s",
                             pid, loc, sess, SpeedName(speed).c_str());
                    self->cb(attached, buf);
                }
            }
            IOObjectRelease(svc);
        }
    }
    static void OnMatched(void* refcon, io_iterator_t it) { Drain(refcon, it, true); }
    static void OnTerminated(void* refcon, io_iterator_t it) { Drain(refcon, it, false); }
};

KinectUsbWatch::KinectUsbWatch() = default;
KinectUsbWatch::~KinectUsbWatch() { stop(); }

bool KinectUsbWatch::start(
    std::function<void(bool attached, const std::string& detail)> on_event) {
    stop();
    impl_.reset(new Impl());
    impl_->cb = std::move(on_event);

    impl_->port = IONotificationPortCreate(kIOMainPortDefault);
    if (!impl_->port) {
        impl_.reset();
        return false;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(),
                        IONotificationPortGetRunLoopSource(impl_->port),
                        kCFRunLoopDefaultMode);

    bool any = false;
    for (const char* cls : {"IOUSBHostDevice", "IOUSBDevice"}) {
        io_iterator_t matched = 0, terminated = 0;
        CFMutableDictionaryRef m1 = IOServiceMatching(cls);
        CFMutableDictionaryRef m2 = IOServiceMatching(cls);
        if (m1 &&
            IOServiceAddMatchingNotification(impl_->port, kIOFirstMatchNotification,
                                             m1, &Impl::OnMatched, impl_.get(),
                                             &matched) == KERN_SUCCESS) {
            // First-match only fires for devices that show up *after* this
            // call; arm it by draining whatever is already present.
            Impl::OnMatched(impl_.get(), matched);
            any = true;
        }
        if (m2 &&
            IOServiceAddMatchingNotification(impl_->port, kIOTerminatedNotification,
                                             m2, &Impl::OnTerminated, impl_.get(),
                                             &terminated) == KERN_SUCCESS) {
            Impl::OnTerminated(impl_.get(), terminated);
            any = true;
        }
        if (std::string(cls) == "IOUSBHostDevice") {
            impl_->matched_host = matched;
            impl_->terminated_host = terminated;
        } else {
            impl_->matched_legacy = matched;
            impl_->terminated_legacy = terminated;
        }
    }
    if (!any) {
        stop();
        return false;
    }
    return true;
}

void KinectUsbWatch::stop() {
    if (!impl_) return;
    for (io_iterator_t it : {impl_->matched_host, impl_->terminated_host,
                             impl_->matched_legacy, impl_->terminated_legacy}) {
        if (it) IOObjectRelease(it);
    }
    if (impl_->port) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              IONotificationPortGetRunLoopSource(impl_->port),
                              kCFRunLoopDefaultMode);
        IONotificationPortDestroy(impl_->port);
    }
    impl_.reset();
}

}  // namespace mirror
