// mic_level — the room's own ambient level, captured explicitly off the
// Kinect v2's own mic array (kinect_v2_validate/src/demo/audio_capture.h,
// model UID 045E:02C4) rather than whatever CoreAudio calls the "default
// input" device.
//
// That distinction matters here specifically: the Kinect's USB audio
// interface can drop off the bus and re-enumerate mid-session (its own
// depth/IR stream resetting the whole device is enough to do it -- see
// kinect_source.cpp), and if it was ever the system default input, a plain
// default-input tap has no way to tell "no mic" from "silent mic", and no
// way to recover once the sensor comes back. Binding to it by name lets
// start() poll through exactly that gap and never means "some other, wrong
// microphone" answers instead.
//
// Distinct from audio_pulse.h's AudioPulses: that reads a Wwise OnsetTap
// plug-in's shared memory, which is the level of a bus *inside the piece's
// own mix* -- what the sound engine is putting out. This reads the actual
// room, off the Kinect's own input device, independent of anything Wwise is
// doing. It exists for exactly one thing: driving the root scene's light
// responsivity (RootScene::setAmbientLevel) off how loud the room actually
// is, not off how loud the piece is being.
//
// No onset/threshold logic here, on purpose -- a level, smoothed, is all a
// light intensity needs, and audio_pulse.h already owns onset detection for
// anything that wants discrete hits.
#pragma once

#include <memory>
#include <string>

namespace mirror {

class MicLevel {
public:
    MicLevel();
    ~MicLevel();
    MicLevel(const MicLevel&) = delete;
    MicLevel& operator=(const MicLevel&) = delete;

    // Binds to the Kinect v2's mic array specifically and polls for it
    // briefly in case it is mid-reattach after a USB reset. Never falls back
    // to another input device -- a light driven by the wrong microphone is a
    // worse failure than a light that just stays still -- and logs a clear
    // error to stderr when the Kinect mic cannot be opened at all (no
    // freenect2 SDK built in, sensor unplugged, OS denied access, ...).
    // level() stays at 0 in that case, same as everything else in this app
    // degrading gracefully without its hardware.
    bool start(std::string& err);
    void stop();
    bool running() const;

    // 0..1, attack/release-smoothed and normalised here. floorDb/ceilDb set
    // what the normalisation calls "silent room" and "loud room", in dBFS; a
    // quiet gallery sits closer to -55 than to the 0 an on-axis shout would
    // hit, so the defaults are not symmetric around a nominal level the way a
    // meter's would be. Not const: it advances the smoothing filter by the
    // time elapsed since the last call, so it wants calling about once a
    // frame, not at arbitrary/reentrant points.
    float level();

    float floorDb = -55.f;
    float ceilDb  = -18.f;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    // Attack/release state, advanced once per level() call rather than once
    // per audio block (the previous AVAudioEngine tap's approach) -- this is
    // driving a light at the app's frame rate, not anything sample-accurate.
    float  smoothedDb_    = -100.f;
    double lastPollTime_  = -1.0;
};

}  // namespace mirror
