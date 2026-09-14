// kinect_log — a shared, timestamped diagnostic trail for the Kinect subsystem.
//
// The watchdog (kinect_target.cpp) and the USB attach/detach observer
// (kinect_usb_watch.mm) both want the same thing when the sensor misbehaves:
// a line on stderr for whoever is watching the console, and the same line
// kept somewhere an operator can read *after* the fact, once the install is
// unattended. This is that "somewhere" -- one small file instead of each
// caller reimplementing its own.

#pragma once

#include <string>

namespace mirror::kinectlog {

// Prints `line` to stderr with a timestamp prefix, and best-effort appends
// the same to ~/Library/Logs/mirror_app/kinect.log (created if missing,
// truncated at startup if it has grown past 5 MB -- no rotation beyond that).
// A failure to write the file is silent: losing the history is not worth
// losing the live line over.
void Log(const std::string& line);

// A short human duration -- "45s", "12m34s", "3h12m" -- for the "uptime
// since open" note in the USB attach/detach log lines.
std::string FormatDurationShort(double seconds);

}  // namespace mirror::kinectlog
