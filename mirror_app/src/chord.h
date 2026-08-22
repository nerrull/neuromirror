// chord — the harmony of the mirror phase, as numbers Wwise can hold.
//
// The fitting phase has an arc: the piece starts not knowing who is in front of
// it and ends holding a converged face. This is that arc written as harmony —
// a dark stacked minor at the start, a wide open major at the end, and three
// checkpoints in between where one or two voices move and nothing else does.
//
// Deliberately no Wwise and no tracker: it takes a fit level, a movement
// signal and a dt, and produces four MIDI notes and one comb frequency. That is
// what lets `chord_test` walk a whole fit — including one that stalls, one that
// runs backwards and one that is abandoned halfway — without a camera or a
// sound engine, which is the only way to hear a bug in the voice leading before
// an exhibition does.
//
// ## Why the chord is here and not in Wwise
//
// The obvious Wwise answer is a staircase RTPC curve per voice: FitLevel in,
// pitch out, one step per checkpoint. It does work, and it was the first plan.
// Two things killed it.
//
// **A curve cannot be monotonic.** `fit_level` is a smoothed residual, and a
// residual goes back up — somebody blinks, turns, or the detector drops a frame
// and the fit briefly gets worse. A curve follows that down, so the major
// un-resolves and re-resolves while she stands still. Resolution is a thing
// that happens *to* you once; it does not flicker. The stage here only ever
// advances, and only resets when the room empties.
//
// **A curve's glide rate is the fit's rate.** With the pitch read straight off
// a curve, a fit that jumps from 0.2 to 0.8 in one frame jumps the chord with
// it. Gliding here, on a time constant, means the checkpoint is what *starts*
// the movement and the movement always takes the same musical amount of time.
//
// ## Why four separate voices
//
// One Macro Oscillator is one pitch, so a chord is four of them, and a chord
// *change* is four pitches moving by different intervals — which one `Key`
// parameter cannot express. Hence `Pad_Note1..4` in the project, one per voice,
// and hence the split of `Mirror_Pad` into a Blend Container of four. The glide
// is the whole reason: the minor third sliding up to the major third is the
// moment the piece turns, and it only reads as a turn if you can hear it move.

#pragma once

namespace mirror {

// How many voices the pad holds. Four is what the arc needs: a root that never
// moves, two inner voices that carry the minor-to-major turn, and a top that
// opens the voicing out.
inline constexpr int kChordVoices = 4;

// What the pad and the pluck are told to do this frame.
struct ChordVoicing {
    // MIDI note per voice, glided and detuned -- exactly what goes to
    // Pad_Note1..4. Fractional: the detune lives in the fraction.
    float note[kChordVoices] = {36.f, 46.f, 51.f, 58.f};
    // Where the glide is heading, undetuned. Diagnostics only -- the panel
    // shows both so "is it gliding" is answerable at a glance.
    float target[kChordVoices] = {36.f, 46.f, 51.f, 58.f};
    // The comb's centre frequency, Hz -- the pluck's pitch. Derived from the
    // same root as the chord, so the two can never drift out of tune.
    float comb_hz = 466.16f;
    // Which checkpoint is current, 0..kStages-1.
    int stage = 0;
    // The pluck's note, MIDI, before the conversion to Hz. Diagnostics.
    float pluck_note = 70.f;
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
        // The piece's key, MIDI note. Matches the `Key` game parameter's
        // default; the operator's key slider feeds this.
        float root = 48.f;

        // Where the pad sits relative to that key, in semitones. The key is the
        // piece's pitch, not the pad's register: at the key itself the voicing
        // ran from C3 up to E5, which is squarely where a face and a voice live
        // and left the chord sounding like a melody instrument playing high
        // rather than a room being harmonised. An octave down puts the bottom
        // voice at C2 and, with the final chord spanning 28 semitones, leaves
        // the stack spread from C2 to E4.
        //
        // Deliberately separate from `root` rather than folded into it: the
        // operator's key slider still means the piece's key, and the pluck
        // (which reads `root` directly) keeps its own register.
        float octave = -12.f;

        // Time constant of the glide between chords, seconds. Not a duration:
        // the voice covers ~63% of the interval in this long and settles after,
        // which is what a string section does and what a ramp does not.
        float glide_secs = 4.f;

        // Full-scale movement detune, cents, applied +/- alternately up the
        // stack. Small on purpose: at this depth neighbouring voices do not
        // sound out of tune, their coinciding harmonics just start to beat.
        float detune_cents = 4.f;

        // How far past a checkpoint the fit must get before the chord advances.
        // Guards the boundary: without it a fit sitting exactly on 0.25 walks
        // the chord back and forth every frame.
        float hysteresis = 0.03f;

        // Where the pluck ends up, semitones from the root. An octave below, so
        // it lands under the chord rather than doubling its bass voice.
        float pluck_low = -12.f;

        // Where the pluck starts: the top of the opening voicing. Kept separate
        // from the stage table because the pluck's travel is continuous in the
        // fit while the chord's is stepped -- that counter-motion is the point.
        float pluck_high = 22.f;
    };

    Chord() { reset(); }

    Config& config() { return cfg_; }
    const Config& config() const { return cfg_; }

    // Back to the opening voicing, glide and all. Called when the room empties:
    // the next person gets the piece unresolved, not wearing the last one's
    // ending.
    void reset();

    // One frame. `fit` is 0..1 (AudioParams::fit_level), `movement` is 0..1.
    void update(float fit, float movement, float dt);

    const ChordVoicing& voicing() const { return v_; }

    // The stage table, for the panel and the test.
    static const float* StageOffsets(int stage);
    static float StageThreshold(int stage);

private:
    Config cfg_;
    ChordVoicing v_;
    int   stage_ = 0;
    float cur_[kChordVoices] = {0.f, 0.f, 0.f, 0.f};  // glided, undetuned
    bool  primed_ = false;
    // The root+octave the glide state was last expressed against. A change to
    // either is a transposition of where the voices already are, not a new
    // glide target.
    float base_at_prime_ = 36.f;
};

}  // namespace mirror
