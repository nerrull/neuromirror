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
// ## Why four separate voices
//
// One Macro Oscillator is one pitch, so a chord is four of them, and a chord
// *change* is four pitches moving by different intervals — which one `Key`
// parameter cannot express. Hence one `ChordStage` Pitch override per voice,
// and hence the split of `Mirror_Pad` into a Blend Container of four.

#pragma once

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
        //
        // `root=48, octave=-12, pluck_high=+22, pluck_low=-12` was the config
        // that shipped before the voicing moved into Wwise -- spreads the final
        // voicing C2 to E4. That is the register the transition/roots phase
        // still wants; kept here as a reference. The mirror phase itself now
        // uses a higher register, set on the Wwise side: see the `Key -> Pitch`
        // curve on `Pad_V1..V4\Osc` in the WwiseProject.
        float octave = -12.f;

        // Full-scale movement detune, cents, applied +/- alternately up the
        // stack, to the diagnostic `note[]` only -- see its comment above.
        float detune_cents = 4.f;

        // How far past a checkpoint the fit must get to advance, and how far
        // back below it the fit must fall to retreat -- the gap between the
        // two guards the boundary: without it a fit sitting exactly on 0.25
        // walks the chord back and forth every frame.
        float hysteresis = 0.03f;

        // Where the pluck sits, semitones from the root, before the snap to
        // the nearest chord tone (see Update's pluck section) -- the base it
        // is pinned to throughout Fitting, at zero intensity. Kept separate
        // from the stage table because the pluck's register is fixed while
        // the chord's is stepped. Raised from the old -12 so the pluck stays
        // above the pad's register (see the `octave` comment above) instead
        // of dipping under its bass voice.
        float pluck_high = 34.f;

        // How far above `pluck_high`, semitones, full intensity can push the
        // pluck before the snap. Intensity is the fit converging and the room
        // moving (see Update's pluck section) -- it opens the pluck's
        // register upward without ever taking it out of the chord, since the
        // snap still lands it on a real tone. The very-low register the
        // pluck drops to at the Transition handoff is not a note at all and
        // is not reached through this range -- see main.mm.
        float pluck_intensity_range = 12.f;
    };

    Chord() { reset(); }

    Config& config() { return cfg_; }
    const Config& config() const { return cfg_; }

    // Back to the opening checkpoint. Called when the room empties: the next
    // person gets the piece unresolved, not wearing the last one's ending.
    void reset();

    // Jump straight to the final checkpoint (wide, open, done) and hold it
    // there regardless of what `update()` is fed afterwards -- until the next
    // `reset()`. For the two ways a sitting can end without the fit ever
    // earning that chord on its own: the fit timing out before it converges,
    // and the visitor leaving mid-fit. Either way the piece still closes with
    // a resolution instead of leaving the harmony stranded wherever the fit
    // happened to be, or silently forgotten.
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

    // The stage table, for the panel and the test.
    static const float* StageOffsets(int stage);
    static float StageThreshold(int stage);

private:
    Config cfg_;
    ChordVoicing v_;
    int  stage_ = 0;
    bool stage_changed_ = false;
    // Set by resolve(), cleared by reset(): while true, update() holds the
    // final checkpoint instead of tracking `fit`.
    bool resolved_ = false;
};

}  // namespace mirror
