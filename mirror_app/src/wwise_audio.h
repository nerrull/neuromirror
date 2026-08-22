// wwise_audio — the Wwise sound engine, running inside this app.
//
// The piece's sound is a Wwise project (`../WwiseProject`): two ambient scenes,
// a bus each with its own reverb, a Macro Oscillator pad whose pitch follows a
// `Key` parameter, and a set of Game Parameters the room drives. This is the
// half of that which runs at showtime -- the engine is initialised here, the
// generated bank is loaded here, and the events and RTPCs the piece needs are
// posted from here.
//
// ## Why the engine is embedded rather than driven over WAAPI
//
// Wwise Authoring on this machine is a Windows application under CrossOver, and
// it can absolutely be made to play the project live and be poked over WAAPI.
// That is a fine way to *design* sound and a bad way to run an installation:
// the audio then depends on a Wine process staying up for the length of an
// exhibition, on a socket, and on Authoring's own idea of when to render. With
// the engine linked in, showtime needs no Wwise at all -- just `Racine.bnk` and
// this app -- and the parameters arrive on the same thread that computed them,
// in the same frame.
//
// The cost is the two halves of the plug-ins. The authoring DLLs (Windows) are
// what makes Macro Oscillator appear in the Wwise UI; the macOS static libs are
// what makes it make sound here. Both are built from `../wwise_plugins`, and
// they are independent: retuning a preset in Authoring changes the bank, not
// this binary, and rebuilding this binary does not update Authoring.
//
// ## What the bank expects
//
// Names, not IDs, deliberately: the string overloads hash at runtime, which
// costs nothing at these rates and means a rename in Wwise shows up as an
// audible failure rather than a wrong sound. Everything below must exist in the
// project with exactly these names.
//
//   Events  Play_FirePlucker / Stop_FirePlucker   the mirror phase's pluck
//           Play_Pad        / Stop_Pad            the mirror phase's chord
//           Play_Amb_Roots  / Stop_Amb_Roots      the root scene's bed
//           Play_Transition / Stop_Transition     the handoff
//           Play_Pluck, Play_Bell, Play_Drop      one-shots
//           Play_Amb_Mirror / Stop_Amb_Mirror     the old mirror bed, unused by
//                                                 the show since the phase
//                                                 became pluck + pad
//   RTPCs   Proximity, Movement, Centering, HeadYaw, HeadTilt   (the room)
//           FitLevel, SceneProgress                             (the piece)
//           Key, Intensity                                      (the operator)
//           Pad_Note1..4, Comb_Tuning                           (the harmony)
//   States  Phase = Idle | Fitting | Transition | Roots
//
// ## Without the SDK
//
// Built only when the Wwise SDK is present (MIRROR_HAVE_WWISE), exactly like
// the Kinect and MediaPipe subsystems: the class is always declared and always
// callable, and without the SDK every method is a no-op that reports why. An
// app that will not launch on a machine with no Wwise install would be a bad
// trade for a feature that is silent by definition.

#pragma once

#include <string>

namespace mirror {

// Everything continuous the piece sends to Wwise, in one struct, so the call
// site is "here is the state of the world" rather than nine setters. Ranges
// match the Game Parameters in the project; values outside them are clamped by
// Wwise itself, not here.
struct AudioParams {
    float proximity = 0.f;      // 0..1
    float movement = 0.f;       // 0..1
    float centering = 0.f;      // -1..1
    float head_yaw = 0.f;       // -60..60 degrees
    float head_tilt = 0.f;      // -45..45 degrees
    float fit_level = 0.f;      // 0..1, how well the face has been captured
    float scene_progress = 0.f; // 0..1 through the current phase
    float key = 48.f;           // MIDI note, 24..84 -- the piece's base pitch
    float intensity = 1.f;      // 0..1 master, on the main bus

    // The mirror phase's harmony, computed by `chord` (see chord.h). Four MIDI
    // notes, one per pad voice, and the comb frequency the pluck rings at.
    // Sent every frame like everything else: the glide *is* these numbers
    // moving, so a frame that skipped them would be a frame the pad did not
    // glide through.
    float pad_note[4] = {48.f, 58.f, 63.f, 70.f};  // MIDI, 24..96
    float comb_hz = 466.16f;                       // Hz, 20..2000
};

class WwiseAudio {
public:
    WwiseAudio() = default;
    ~WwiseAudio();

    WwiseAudio(const WwiseAudio&) = delete;
    WwiseAudio& operator=(const WwiseAudio&) = delete;

    // Starts the engine and loads Init.bnk + Racine.bnk from `bank_dir`.
    // Returns false with `err` set; the app is expected to carry on silently.
    // Safe to call again after a failure -- that is what the panel's "retry"
    // does once somebody has generated the banks.
    bool init(const std::string& bank_dir, std::string& err);
    void term();
    bool ready() const { return ready_; }

    // Once a frame, in this order: push whatever changed, then let the engine
    // consume it. RenderAudio() is what actually hands the audio thread the
    // messages queued since the last call, so a frame that sets RTPCs without
    // calling this has not really set them.
    void update(const AudioParams& p);

    // One-shots and beds. No-ops when the engine is not up, so call sites do
    // not branch.
    void post(const char* event_name);
    void setState(const char* group, const char* state);
    void stopAll();

    // Record the main output to a WAV at an absolute path. The engine's own
    // capture, so it is what the room hears including every bus effect -- which
    // makes it the only honest answer to "is this actually making a sound", a
    // question the event and RTPC calls all return success to either way.
    bool startCapture(const std::string& abs_wav_path);
    void stopCapture();

    // Where the banks were looked for, and what went wrong if anything did.
    const std::string& bankDir() const { return bank_dir_; }
    const std::string& lastError() const { return err_; }

    // For the panel: what was last sent, and how many events have gone out --
    // enough to see at a glance whether the piece is talking to the engine.
    const AudioParams& lastSent() const { return sent_; }
    unsigned long eventsPosted() const { return posted_; }

    // The default bank directory: the WwiseProject's Mac output, resolved
    // against the source tree the way presets and shows are.
    static std::string DefaultBankDir();

private:
    bool ready_ = false;
    bool sent_any_ = false;
    std::string bank_dir_;
    std::string err_;
    AudioParams sent_;
    unsigned long posted_ = 0;
};

}  // namespace mirror
