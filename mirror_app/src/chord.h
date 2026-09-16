// chord — the harmony of the mirror phase, as numbers Wwise can hold.
//
// The fitting phase has an arc: the piece starts not knowing who is in front of
// it and ends holding a converged face. This is that arc written as harmony —
// a dark stacked minor at the start, a wide open major at the end, and three
// checkpoints in between where one or two voices move and nothing else does.
//
// Deliberately no Wwise and no tracker: it takes a fit level, a movement
// signal and a dt, and produces a checkpoint. That is what lets `chord_test`
// walk a whole fit — including one that stalls, one that runs backwards and
// one that is abandoned halfway — without a camera or a sound engine, which is
// the only way to hear a bug in the voice leading before an exhibition does.
//
// ## Why the checkpoint is here and not in Wwise
//
// The obvious Wwise answer is a staircase RTPC curve per voice: FitLevel in,
// pitch out, one step per checkpoint. It does work for the voicing, and the
// voicing itself now *is* that curve — a `ChordStage` State Group with one
// Pitch override per voice per state, authored on the Sound objects directly.
// What stays here, in code, is the one thing a State Group cannot do:
//
// **A curve needs a gate with hysteresis, not just a threshold.** `fit_level`
// is a live neural fit's loss, and it can genuinely get worse -- she turns
// away, walks off, the tracking degrades enough that the loss climbs back up
// -- and when it does, the chord should walk back down with it rather than
// stay pinned at a resolution the room no longer earns. What a bare threshold
// per checkpoint would do instead is flicker at the boundary: a fit sitting
// right on 0.5 walks the chord forward and back every frame. `Chord` owns the
// gate -- two thresholds per checkpoint, offset by `hysteresis`, one for the
// advance and one for the retreat (a Schmitt trigger) -- and posts
// `SetState("ChordStage", ...)`; Wwise owns the glide between states (its own
// transition time/curve on the State Group) and the per-voice Pitch table.
//
// ## Tuning: one note per visitor
//
// Everything is tuned from one note, drawn once per visitor: the pinned
// pluck's centre (`pluck_center_note`, G5 by default) plus a random offset of
// up to `pluck_offset_max_semitones` either way. The pluck rings exactly that
// note through the whole idle wait, and the chord's root is that note
// `chord_octave` octaves down -- so when Fitting begins the chord starts *on*
// the note the room has been hearing, and the pluck does not move. From there
// the pluck climbs the chord: each checkpoint lifts it a step of the way from
// the base note to `pluck_climb` semitones above it, snapped to a tone of the
// current chord, so it ends on the resolved chord's top voice. `keyNote()` is
// what the caller sends Wwise as `Key` (the visitor's note, chord octave
// excluded -- `Key` reaches the pluck too); `padOctave()` is what shifts the
// pad alone onto the chord's root.
//
// ## Why four separate voices
//
// One Macro Oscillator is one pitch, so a chord is four of them, and a chord
// *change* is four pitches moving by different intervals — which one `Key`
// parameter cannot express. Hence one `ChordStage` Pitch override per voice,
// and hence the split of `Mirror_Pad` into a Blend Container of four.

#pragma once

#include <random>

namespace mirror {

// How many voices the pad holds. Four is what the arc needs: a root that never
// moves, two inner voices that carry the minor-to-major turn, and a top that
// opens the voicing out.
inline constexpr int kChordVoices = 4;

// What the pad and the pluck are told to do this frame.
struct ChordVoicing {
    // The stepped target per voice, undetuned -- diagnostics only. The actual
    // voicing lives in Wwise's `ChordStage` Pitch table now, stepped instantly
    // (no C++ glide any more; Wwise's own state transition owns the glide), so
    // `note` and `target` always agree. Neither is sent to the bank -- kept
    // for the panel and for the pluck's chord-tone snap below.
    float note[kChordVoices] = {36.f, 46.f, 51.f, 58.f};
    float target[kChordVoices] = {36.f, 46.f, 51.f, 58.f};
    // The comb's centre frequency, Hz -- the pluck's pitch. Derived from the
    // same root as the chord, so the two can never drift out of tune.
    float comb_hz = 783.99f;
    // Which checkpoint is current, 0..kStages-1.
    int stage = 0;
    // The pluck's note, MIDI, before the conversion to Hz. Diagnostics.
    float pluck_note = 79.f;
};

class Chord {
public:
    // The five checkpoints. Offsets are semitones from the root.
    //
    //   stage 0   0 10 15 22   Cm7(b13)   dark, stacked
    //   stage 1   0 10 15 26   Cm9        the top opens to the 9th
    //   stage 2   0  7 15 26   Cm(add9)   the b7 resolves to the 5th
    //   stage 3   0  7 16 26   Cmaj9      Eb -> E, the turn
    //   stage 4   0  7 16 28   Cmaj       wide, open, done
    static constexpr int kStages = 5;

    struct Config {
        // Where the chord's root sits relative to the visitor's note, in
        // octaves. -1 puts the chord an octave under the pluck, so its
        // resolved top voice (+28) ends up a major third over the pluck's
        // base note -- which is where `pluck_climb` = 16 sends the pluck.
        int chord_octave = -1;

        // Where the pad sits relative to the root, in semitones. Diagnostic
        // `note[]` only -- the mirror phase's register is set on the Wwise
        // side (the `Key -> Pitch` curve on `Pad_V1..V4\Osc`).
        float octave = -12.f;

        // Full-scale movement detune, cents, applied +/- alternately up the
        // stack, to the diagnostic `note[]` only -- see its comment above.
        float detune_cents = 4.f;

        // How far past a checkpoint the fit must get to advance, and how far
        // back below it the fit must fall to retreat -- the gap between the
        // two guards the boundary: without it a fit sitting exactly on 0.25
        // walks the chord back and forth every frame.
        float hysteresis = 0.03f;

        // The fit level at which each checkpoint becomes current -- tunable
        // per-instance so the panel can dial in where each chord change
        // lands against how the live fit actually climbs. thresholds[0] is
        // never read (stage 0 is always where a reset starts); the last one
        // is 0.95, not 1.0, deliberately -- a resolution only reachable by
        // accident is not a resolution.
        float thresholds[kStages] = { 0.f, 0.25f, 0.50f, 0.75f, 0.95f };

        // The pinned pluck's centre, MIDI note. 79 is G5, 784 Hz. Every
        // visitor's note is this plus their offset below; the chord's root is
        // the same pitch class.
        float pluck_center_note = 79.f;

        // How many semitones, at most, the per-visitor draw can land from the
        // centre -- e.g. 3 means uniformly anywhere from -3 to +3 semitones.
        // Drawn at newVisitor(), held for the whole sitting.
        int pluck_offset_max_semitones = 3;

        // How far above the visitor's note, semitones, the last checkpoint
        // lifts the pluck -- the top of its climb, before the snap to a chord
        // tone (see update()). 16 with `chord_octave` -1 is exactly the
        // resolved chord's top voice. Wwise's Comb_Tuning stops at 2000 Hz
        // (MIDI ~99): a G5 centre, +5 offset and 16 up brushes that.
        float pluck_climb = 16.f;

        // Wander: a slow, continuous drift of the comb Hz while the pluck is
        // pinned (fit at 0), gone the moment the fit starts moving it. An
        // LFO on the comb's own Frequency in Wwise would have been simpler,
        // but Wwise won't run an RTPC and an LFO on the same property at once,
        // so this lives here instead, as a sum of two sines rather than noise
        // so it never repeats on a beat. Ear noise around the note, never the
        // note itself: the chord's root ignores it.
        bool  pluck_wander_enabled = false;
        // Peak wander, as a fraction of the pinned frequency (0.03 = +/-3%).
        float pluck_wander_depth = 0.03f;
        // The wander's slower component, as a cycle time in seconds. The
        // faster component runs at 1/2.17 of this period so the two never
        // fall into a visible shared cycle.
        float pluck_wander_period_s = 12.5f;
    };

    Chord() { newVisitor(); reset(); }

    Config& config() { return cfg_; }
    const Config& config() const { return cfg_; }

    // Back to the opening checkpoint, on this visitor's root. The Idle ->
    // Fitting handoff: the next person gets the piece unresolved, not wearing
    // the last one's ending. Does not redraw the visitor's note -- see
    // newVisitor().
    void reset();

    // Draws this visitor's note offset. Call once at the Roots -> Idle
    // handoff, when a new visitor is *about* to be waited for, so the note
    // the pluck rings through the whole idle wait is the note the chord then
    // starts on. The constructor calls it once so the very first Chord has a
    // draw too.
    void newVisitor();

    // Jump straight to the final checkpoint (wide, open, done) and hold it
    // there regardless of what `update()` is fed afterwards -- until the next
    // `reset()`. For the two ways a sitting can end without the fit ever
    // earning that chord on its own: the fit timing out before it converges,
    // and the visitor leaving mid-fit.
    void resolve();

    // One frame. `fit` is 0..1 (AudioParams::fit_level), `movement` is 0..1.
    // A no-op on the checkpoint itself after `resolve()`, until `reset()`.
    void update(float fit, float movement, float dt);

    const ChordVoicing& voicing() const { return v_; }

    // The current checkpoint, and whether the stage moved since this was last
    // checked -- lets the caller post SetState("ChordStage", ...) only on the
    // edge. Consuming, not a level read: it clears on every call (even a
    // false one), because reset()/resolve()/update() can each touch the
    // stage within the same on-screen frame (an entry-point call followed by
    // that frame's own update()), and only the *first* of those to be read
    // should count as "changed" -- see the OR-not-overwrite comment on each
    // of their `stage_changed_` assignments in chord.cpp.
    int stage() const { return v_.stage; }
    bool stageChanged() {
        const bool changed = stage_changed_;
        stage_changed_ = false;
        return changed;
    }

    // The stage table, for the panel and the test. Offsets are fixed (the
    // voicing itself is not something a fit level should be able to detune),
    // but the threshold is `cfg_.thresholds` -- see Config.
    static const float* StageOffsets(int stage);
    float StageThreshold(int stage) const;

    // This visitor's note: the pinned pluck's centre plus their offset. What
    // the pluck rings while pinned, and the pitch class the root is built on.
    float visitorNote() const { return cfg_.pluck_center_note + (float)pluck_offset_semitones_; }

    // This visitor's root: visitorNote() dropped by `chord_octave` octaves.
    // What the voicing and the pluck snap are built from. Read live, so the
    // octave slider moves the chord mid-sitting.
    float effectiveRoot() const { return visitorNote() + 12.f * (float)cfg_.chord_octave; }

    // What the caller sends Wwise as `Key`. `Key` drives every emitter (the
    // pluck, the bell, the drops, the sweep, the drone) at the register each
    // was authored in, so it must NOT carry `chord_octave` -- only the
    // visitor's note, brought down to the bank's authored register (48 for
    // the default G5 centre). The chord's own octave rides on `PadOctave`
    // instead, which reaches only the pad containers.
    float keyNote() const { return visitorNote() - 36.f; }

    // Semitones the pad containers are pitched away from what `Key` gives
    // them, so the pad lands on effectiveRoot() while the pluck stays put.
    // Wwise's `PadOctave` game parameter stops at +/-24 (its Pitch curve),
    // which is why the panel's chord octave slider runs -5..-1.
    float padOctave() const { return effectiveRoot() - keyNote(); }

private:
    Config cfg_;
    ChordVoicing v_;
    int  stage_ = 0;
    bool stage_changed_ = false;
    // Set by resolve(), cleared by reset(): while true, update() holds the
    // final checkpoint instead of tracking `fit`.
    bool resolved_ = false;

    // The wander's own clock, zeroed whenever the fit leaves zero so it never
    // carries a phase into the next pin.
    float wander_time_ = 0.f;
    int   pluck_offset_semitones_ = 0;
    std::mt19937 rng_{std::random_device{}()};
};

}  // namespace mirror
