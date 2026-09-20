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
//           Play_Strum                            the resolved window's harp, one shot per note
//           Play_Amb_Mirror / Stop_Amb_Mirror     the old mirror bed, unused by
//                                                 the show since the phase
//                                                 became pluck + pad
//   RTPCs   Proximity, Movement, Centering, HeadYaw, HeadTilt, HeadPitch   (the room)
//           FitLevel, SceneProgress                             (the piece)
//           Key, Intensity, Transpose                            (the operator)
//           Comb_Tuning, Comb_Glide, FlangerRate, FlangerMix        (the harmony)
//           Strum_Tuning                                          (the harp, per voice)
//           Strum_Velocity 0..1, Strum_Glide ms                  (the harp, per voice: loudness, portamento)
//           PluckMute 0..1                                       (the FirePlucker's volume, faded)
//   States  Phase      = Idle | Fitting | Transition | Roots
//           ChordStage = Stage0..Stage4 | Modes0..Modes4  (one row per progression, see chord.h)
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
#include <vector>

namespace mirror {

// One cue-point hit from a marker-carrying event -- see postFirePlucker().
// `strength` is 0..1, taken from the cue's label text (a plain float baked
// in by tools/embed_pluck_markers.py at analysis time); an unlabeled cue
// reports 1.
struct MarkerHit {
    float strength = 1.f;
};

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
    float head_pitch = 0.f;     // -30..30 degrees, + = chin up
    float fit_level = 0.f;      // 0..1, how well the face has been captured
    float scene_progress = 0.f; // 0..1 through the current phase
    float key = 48.f;           // MIDI note, 24..84 -- the piece's base pitch
    float intensity = 1.f;      // 0..1 master, on the main bus
    float transpose = 0.f;      // semitones, -24..24 -- offsets every emitter
    float pad_octave = 0.f;     // semitones, -24..24 -- offsets the pad alone (Chord::padOctave)

    // The pluck's pitch, as the comb's centre frequency. The pad's own voicing
    // no longer travels through here: it lives entirely in Wwise now, driven
    // by `Key`, `Transpose`, and the `ChordStage` state (see chord.h and
    // `setState`). Only the comb, which has no State Group of its own, still
    // needs a value pushed every frame.
    float comb_hz = 466.16f;    // Hz, 20..4000

    // The comb's portamento between Comb_Tuning steps, on Metallic_Ring's
    // Glide. Authored default 265ms; main.mm shortens this while the resolved
    // chord's pluck is arpeggiating, so the steps land in tune rather than
    // sliding through them.
    float comb_glide_ms = 265.f;  // ms, 0..2000

    // The pad's flanger, Hz -- how fast the LFO sweeps. Computed in main.mm as
    // a lerp between the panel's min/max sliders, driven by fit_level, so the
    // sweep speeds up as the fit converges. A plain 1:1 RTPC curve on the
    // Wwise side (see Mirror_Pad_Flanger's ModFrequency binding), because the
    // shaping -- where between min and max the current fit lands -- is
    // already a decision made in code, not something a second curve should
    // remake.
    float flanger_rate = 0.1f;  // Hz, 0..5

    // The pad's flanger, wet/dry mix on Mirror_Pad_Flanger's WetDryMix.
    // Authored default 54; main.mm fades this to 0 while the resolved chord
    // holds, so the pad clears as the chord settles.
    float flanger_mix = 54.f;  // 0..100

    // The FirePlucker's mute (PluckMute -> its Volume, 1 = -96 dB), with the
    // fade Wwise runs it over. main.mm raises it while the harp plays so the
    // two combs don't compete, and drops it as the roots start.
    float pluck_mute = 0.f;         // 0..1
    float pluck_mute_fade_ms = 500.f;
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

    // Play_FirePlucker, with its Wwise cue markers (see
    // tools/embed_pluck_markers.py) wired to a callback that feeds
    // pollFirePluckerMarkers(). The bed loops for the whole Idle/Fitting
    // phase on one Play_, so this is a drop-in replacement for
    // post("Play_FirePlucker") at those two call sites -- no per-frame
    // re-registration needed.
    void postFirePlucker();

    // The resolved window's strum: a one-shot per note (Play_Strum) at `hz`,
    // via its own small pool of game objects rather than kRacineObj -- the
    // strum's comb is instanced per voice (Strum_Ring, on the Strum sound),
    // so each ringing note needs its own game object to hold its own
    // Strum_Tuning, unlike the FirePlucker's single shared comb.
    void postStrum(float hz, float velocity = 1.f);   // velocity 0..1 -> Strum_Velocity (loudness)
    // Every strum voice, ringing or not: open its glide to `glide_ms` and
    // retune it to `hz`, so whatever is sounding slides there together. The
    // next postStrum on a voice puts its glide back to 0.
    void dropStrums(float glide_ms, float hz);

    // Marker hits queued since the last call. Call every frame regardless of
    // phase: the callback keeps queuing while the bed plays, and leaving it
    // undrained would land a whole phase's worth of hits at once the next
    // time somebody asks.
    std::vector<MarkerHit> pollFirePluckerMarkers();

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
    unsigned strum_next_ = 0;  // round-robins the strum voice pool, see postStrum()
};

}  // namespace mirror
