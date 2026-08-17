// presence — the person in front of the mirror, as numbers a synth can use.
//
// The tracker answers "where are the 478 landmarks"; Wwise wants "how close is
// she, how much is she moving, which way is she leaning". This is the module in
// between, and it exists separately from both for two reasons.
//
// **It is where the smoothing lives.** Landmarks arrive at whatever rate the
// camera manages, jitter by a pixel or two at rest, and drop out entirely for a
// frame when the detector misses. Feeding that straight into an RTPC is audible:
// a filter cutoff driven by raw proximity buzzes, and a movement signal that
// spikes on a dropped frame reads as somebody lunging. Every signal here is
// asymmetrically smoothed -- quick to rise, slow to fall -- because that is what
// the ear expects of a room: a sound answers you immediately and settles slowly.
//
// **It is the only place the geometry conventions are written down.** "Head
// angle" is not a thing MediaPipe hands over; it is a choice about which
// landmarks to measure between. Making that choice once, here, with the
// reasoning attached, is what keeps it from being re-derived slightly
// differently in the audio path and the visual one.
//
// Deliberately no Wwise and no Metal: it takes a FaceResult and a dt and
// produces floats, which is what makes `presence_test` able to drive it through
// a whole approach-and-leave without a camera.
//
// ## Why these five
//
// They are the axes a person actually has in front of a mirror, and they stay
// meaningful whether or not the fit has converged:
//
//   * **proximity**  how much of the frame the face fills -- walking up to it.
//   * **movement**   how much the face is travelling, in its own widths, so
//                    leaning in does not read as movement.
//   * **centering**  left/right in frame, signed, for a sound that follows.
//   * **yaw**        turning away from your reflection.
//   * **tilt**       the head cocked to one side.
//
// Scale-normalising movement is the subtle one: measured in pixels, somebody
// close to the camera produces several times the movement of the same gesture
// made further back, so the signal would mostly be reporting proximity again.

#pragma once

#include "face_tracker.h"

namespace mirror {

// What the piece sends onward. All smoothed, all in fixed ranges that match the
// Game Parameters declared in the Wwise project (see wwise_audio.h) -- the
// mapping from these to a filter or an oscillator lives in Wwise, not here.
struct PresenceSignals {
    bool  present   = false;  // a face was seen this frame
    float proximity = 0.f;    // 0 far .. 1 at the mirror
    float movement  = 0.f;    // 0 still .. 1 moving fast
    float centering = 0.f;    // -1 frame left .. +1 frame right
    float head_yaw  = 0.f;    // degrees, + = nose toward frame right
    float head_tilt = 0.f;    // degrees, + = head cocked toward frame right
};

class Presence {
public:
    struct Config {
        // The normalised face height (fraction of frame) that reads as "far
        // away" and as "right at the mirror". Defaults measured off the Kinect
        // at the install's framing; they are the two numbers worth retuning per
        // room, which is why they are first.
        float far_span  = 0.12f;
        float near_span = 0.45f;
        // Landmark travel, in face widths per second, that counts as movement
        // 1.0. A slow turn of the head is around 0.3; a step sideways is well
        // past 1.
        float move_full = 1.2f;
        // Full-scale yaw and tilt, in degrees. Signals are clamped to these, so
        // they double as the RTPC range.
        float yaw_full  = 60.f;
        float tilt_full = 45.f;
        // Asymmetric smoothing time constants, seconds. Rise is short so the
        // room answers you; fall is long so it does not flinch at a dropped
        // frame or a blink-length detection gap.
        float rise_tau  = 0.12f;
        float fall_tau  = 0.55f;
        // How long a face may be missing before the signals are released toward
        // zero rather than held. Shorter than the show timeline's own
        // face-absent debounce on purpose: the sound should start receding
        // while the piece is still deciding whether she left.
        float hold_secs = 0.35f;
    };

    Config& config() { return cfg_; }
    const Config& config() const { return cfg_; }

    // `aspect` is the tracker frame's width/height. Landmarks are normalised
    // per axis, so an angle measured between two of them is wrong by exactly
    // this factor unless it is put back -- which is the whole reason it is a
    // parameter rather than assumed 1.
    void update(const FaceResult& r, float aspect, float dt);

    // Back to a still, empty room. Called when the piece lets go, so the next
    // person does not inherit the last one's movement.
    void reset();

    const PresenceSignals& signals() const { return sig_; }

    // Unsmoothed values, for the panel: seeing the raw and the smoothed side by
    // side is how the time constants get tuned.
    const PresenceSignals& raw() const { return raw_; }

private:
    Config cfg_;
    PresenceSignals sig_;
    PresenceSignals raw_;
    std::vector<FaceLandmark> prev_;   // last frame's landmarks, for movement
    float since_seen_ = 1e9f;          // seconds since the last valid face
};

}  // namespace mirror
