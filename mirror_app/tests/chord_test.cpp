// chord_test — the harmony of the fitting phase, without a fit.
//
// Everything this module can get wrong is inaudible as a number and obvious as
// music: a chord that un-resolves while somebody stands still, a glide that
// arrives instantly because a checkpoint also reset it, a pluck that walks out
// of tune with the pad because the two read different roots. None of those show
// up in a single frame's output, so what is driven here is whole fits — one
// that converges, one that wobbles backwards, one that stalls halfway, one that
// is abandoned and restarted — at a plausible frame rate.
//
// The fit levels are a fabrication and that is the point: the arithmetic
// between a fit level and a chord is what is under test, not the fitter.

#include "chord.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>

namespace {

int failures = 0;

void check(bool ok, const char* what) {
    if (!ok) { std::printf("FAIL: %s\n", what); ++failures; }
}

constexpr float kDt = 1.f / 60.f;

// Run the chord at 60 fps with a held fit level, for `secs`.
void hold(mirror::Chord& c, float fit, float movement, float secs) {
    const int n = (int)(secs / kDt);
    for (int i = 0; i < n; ++i) c.update(fit, movement, kDt);
}

float NoteToHz(float midi) { return 440.f * std::pow(2.f, (midi - 69.f) / 12.f); }

// A chord with a known tuning: centre on C5 (72) with no per-visitor offset
// and the chord two octaves under it, so the root is 48 and the pad opens on
// 36 + offsets.
// Everything below that isn't about the draw itself uses this.
mirror::Chord makeChord() {
    mirror::Chord c;
    c.config().pluck_center_note = 72.f;
    c.config().pluck_offset_max_semitones = 0;
    c.config().chord_octave = -2;
    c.newVisitor();
    c.reset();
    return c;
}

}  // namespace

int main() {
    // --- the opening voicing ------------------------------------------------
    {
        mirror::Chord c = makeChord();
        const mirror::ChordVoicing& v = c.voicing();
        check(v.stage == 0, "starts at the first checkpoint");
        const float* o = mirror::Chord::StageOffsets(0);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(v.note[i] - (36.f + o[i])) < 1e-3f,
                  "opens on the stage-0 voicing, an octave under the key, already "
                  "there rather than gliding to it");
        check(v.note[0] < 40.f, "the bottom voice is down in the bass, not at the key");
        // The dark stack: a minor third and a minor seventh present, no major third.
        check(std::fabs(v.note[2] - v.note[0] - 15.f) < 1e-3f, "opens minor (b3 + octave)");
    }

    // --- a fit that converges walks the whole arc ---------------------------
    {
        mirror::Chord c = makeChord();
        int seen_stage = 0;
        for (float fit = 0.f; fit <= 1.001f; fit += 0.002f) {
            c.update(fit, 0.f, kDt);
            check(c.voicing().stage >= seen_stage, "the stage never goes backwards");
            seen_stage = c.voicing().stage;
        }
        check(seen_stage == mirror::Chord::kStages - 1,
              "a fit that reaches 1.0 reaches the last checkpoint");

        // ...and given time, lands on the resolved major.
        hold(c, 1.f, 0.f, 60.f);
        const mirror::ChordVoicing& v = c.voicing();
        const float* o = mirror::Chord::StageOffsets(mirror::Chord::kStages - 1);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(v.note[i] - (36.f + o[i])) < 0.05f,
                  "the glide settles on the final voicing");
        check(v.note[3] - v.note[0] > 24.f, "the final chord is spread over two octaves");
        check(std::fabs(v.note[2] - v.note[0] - 16.f) < 0.05f, "ends major (natural 3rd)");
    }

    // --- the wobble: a fit that genuinely degrades retreats, a small dip ----
    // --- (inside the hysteresis band) does not -------------------------------
    //
    // fit_level is a live loss now, not a one-shot residual: it can really get
    // worse (she turns away, tracking degrades), and when it does the chord
    // has to follow it back down rather than stay pinned at a resolution the
    // room no longer earns. What still has to hold is that a fit sitting near
    // a boundary doesn't chatter -- that's what the hysteresis gap is for.
    {
        mirror::Chord c = makeChord();
        hold(c, 0.80f, 0.f, 2.f);
        check(c.voicing().stage == 3, "0.80 reaches the fourth checkpoint");
        // A small dip that stays above stage 3's retreat threshold (0.75 -
        // 0.03 = 0.72) must not move the chord.
        hold(c, 0.73f, 0.f, 2.f);
        check(c.voicing().stage == 3, "a dip that stays inside the hysteresis band holds");
        // Past the retreat threshold, but not past the next one down (0.50 -
        // 0.03 = 0.47): retreats exactly one checkpoint, not further.
        hold(c, 0.60f, 0.f, 2.f);
        check(c.voicing().stage == 2, "clearing one retreat threshold steps back by one");
        // And the voicing actually follows -- no glide left in code (Wwise
        // owns that now), so it lands on the new checkpoint's exact target.
        const float* o2 = mirror::Chord::StageOffsets(2);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().target[i] - (36.f + o2[i])) < 1e-3f,
                  "the retreat's glide target lands on the checkpoint it fell back to");
        // A fit that collapses all the way retreats all the way, same as a
        // fit that arrives all at once advances all the way (see below).
        hold(c, 0.10f, 0.f, 2.f);
        check(c.voicing().stage == 0, "a fit collapsing to 0.10 retreats to the first checkpoint");
    }

    // --- hysteresis: sitting exactly on a boundary does not chatter, ---------
    // --- either direction ------------------------------------------------
    {
        mirror::Chord c = makeChord();
        hold(c, 0.25f, 0.f, 1.f);
        check(c.voicing().stage == 0,
              "a fit resting exactly on the 0.25 boundary has not advanced yet");
        hold(c, 0.25f + 0.031f, 0.f, 1.f);
        check(c.voicing().stage == 1, "clearing the boundary by the hysteresis advances");
        // Coming back down to exactly the boundary is not enough to retreat --
        // it has to clear the *retreat* threshold, hysteresis below the
        // boundary, the same gap in the other direction.
        hold(c, 0.25f, 0.f, 1.f);
        check(c.voicing().stage == 1, "resting back on the boundary alone does not retreat");
        hold(c, 0.25f - 0.031f, 0.f, 1.f);
        check(c.voicing().stage == 0, "clearing the boundary by the hysteresis retreats");
    }

    // --- a checkpoint steps the voicing instantly, no glide left in code ----
    //
    // The glide is Wwise's `ChordStage` state transition now; what is left
    // here is that `note`/`target` land on the checkpoint's exact voicing the
    // same frame it fires, with nothing in between.
    {
        mirror::Chord c = makeChord();
        // Straight to the last stage in one frame -- the worst case, a fit that
        // lands all at once.
        c.update(1.f, 0.f, kDt);
        check(c.voicing().stage == mirror::Chord::kStages - 1, "jumped to the last stage");
        const float* o = mirror::Chord::StageOffsets(mirror::Chord::kStages - 1);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().note[i] - (36.f + o[i])) < 1e-3f,
                  "the voicing lands on the checkpoint's exact target the same frame");
        // Holding steady afterwards changes nothing -- there is no settling left.
        hold(c, 1.f, 0.f, 4.f);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().note[i] - (36.f + o[i])) < 1e-3f,
                  "and it stays exactly there, not just close");
    }

    // --- stageChanged() is the edge, not the level --------------------------
    {
        mirror::Chord c = makeChord();
        check(!c.stageChanged(), "no checkpoint has fired before the first update");
        c.update(0.10f, 0.f, kDt);
        check(!c.stageChanged() && c.stage() == 0,
              "0.10 has not reached the first checkpoint yet");
        c.update(0.30f, 0.f, kDt);
        check(c.stageChanged() && c.stage() == 1,
              "crossing 0.25 fires the checkpoint edge");
        c.update(0.30f, 0.f, kDt);
        check(!c.stageChanged() && c.stage() == 1,
              "holding at the same fit does not re-fire it");
    }

    // --- detune: movement beats, stillness does not -------------------------
    {
        mirror::Chord c = makeChord();
        c.config().detune_cents = 4.f;
        hold(c, 0.f, 0.f, 2.f);
        const float still[4] = {c.voicing().note[0], c.voicing().note[1],
                                c.voicing().note[2], c.voicing().note[3]};
        c.update(0.f, 1.f, kDt);
        const mirror::ChordVoicing& v = c.voicing();
        // Alternating up the stack: neighbouring voices pull apart, so their
        // coinciding harmonics beat instead of the chord transposing.
        check(v.note[0] > still[0] && v.note[1] < still[1],
              "adjacent voices detune in opposite directions");
        check(std::fabs(v.note[0] - still[0] - 0.04f) < 1e-3f, "4 cents at full movement");
        // And it is instant, not glided -- the beating has to answer the room.
        check(std::fabs(v.note[3] - still[3]) > 0.03f, "the detune is not smoothed away");
    }

    // --- the pluck is pinned to the chord, and intensity opens it upward ----
    {
        mirror::Chord c = makeChord();
        // At fit 0 it rings the visitor's note itself -- the root two
        // octaves up, a chord tone of every stage, so no snap moves it.
        c.update(0.f, 0.f, kDt);
        check(std::fabs(c.voicing().pluck_note - 72.f) < 1e-3f,
              "the pluck starts on the visitor's note");
        check(std::fabs(c.voicing().comb_hz - NoteToHz(72.f)) < 0.1f,
              "and the comb frequency is that note in Hz");
        // At fit=1 the chord resolves in the same frame (stage jumps straight
        // to 4, see the checkpoint test above), which is the top of the
        // climb: 72 + 16 = 88, which is the resolved chord's top voice (48 +
        // 28 + 12) -- a chord tone already, so the snap leaves it.
        c.update(1.f, 0.f, kDt);
        check(std::fabs(c.voicing().pluck_note - 88.f) < 1e-3f,
              "the last checkpoint lifts the pluck to the chord's top voice");
        check(c.voicing().comb_hz > NoteToHz(72.f),
              "and the comb frequency rises with it, not falls");
        // The climb is by checkpoint, monotonic, one chord tone per stage.
        mirror::Chord cs = makeChord();
        float prev = 72.f;
        const float fits[4] = {0.30f, 0.55f, 0.80f, 1.f};
        for (int s = 0; s < 4; ++s) {
            cs.update(fits[s], 0.f, kDt);
            check(cs.voicing().stage == s + 1, "the fit reached the next checkpoint");
            check(cs.voicing().pluck_note > prev, "each checkpoint lifts the pluck");
            prev = cs.voicing().pluck_note;
        }
        // Movement alone, with the fit at 0, is the pin: the pluck stays on
        // the visitor's note whatever the room is doing, so the idle wait
        // rings one note and the handoff into Fitting has nothing to jump to.
        mirror::Chord cm = makeChord();
        cm.update(0.f, 1.f, kDt);
        check(cm.voicing().stage == 0, "movement alone does not advance the checkpoint");
        check(std::fabs(cm.voicing().pluck_note - 72.f) < 1e-3f,
              "movement alone never moves the pinned pluck");
        // Movement does not move the pluck at all any more -- its pitch says
        // where the fit is, nothing else.
        mirror::Chord cb = makeChord();
        cb.update(1.f, 1.f, kDt);
        check(std::fabs(cb.voicing().pluck_note - c.voicing().pluck_note) < 1e-3f,
              "movement adds nothing to the pluck's climb");
        // The comb's range must stay inside the game parameter's 20..2000 Hz.
        for (float fit = 0.f; fit <= 1.f; fit += 0.01f) {
            for (float mv = 0.f; mv <= 1.f; mv += 0.5f) {
                mirror::Chord cr = makeChord();
                cr.update(fit, mv, kDt);
                check(cr.voicing().comb_hz > 20.f && cr.voicing().comb_hz < 2000.f,
                      "the comb frequency stays inside the Comb_Tuning range");
            }
        }
    }

    // --- the pluck always lands on a real chord tone -------------------------
    //
    // At every fit, for whatever stage is current, pluck_note mod 12 must
    // match one of that stage's offsets mod 12 -- the snap must never leave a
    // note that is not actually in the chord.
    {
        mirror::Chord c = makeChord();
        for (float fit = 0.f; fit <= 1.f; fit += 0.01f) {
            c.update(fit, fit, kDt);
            const float* o = mirror::Chord::StageOffsets(c.voicing().stage);
            const float pc = std::fmod(std::fmod(c.voicing().pluck_note, 12.f) + 12.f, 12.f);
            bool matches = false;
            for (int i = 0; i < mirror::kChordVoices; ++i) {
                const float oc = std::fmod(std::fmod(o[i], 12.f) + 12.f, 12.f);
                if (std::fabs(pc - oc) < 1e-2f) { matches = true; break; }
            }
            check(matches, "the pluck's pitch class is one of the chord's own");
        }
    }

    // --- the chord octave transposes, it does not glide ---------------------
    //
    // The operator moving the octave slider is not a chord change: every
    // voice should follow immediately, and the pluck's note is not its
    // business.
    {
        mirror::Chord c = makeChord();
        hold(c, 0.f, 0.f, 1.f);
        c.config().chord_octave = -1;
        c.update(0.f, 0.f, kDt);
        check(std::fabs(c.effectiveRoot() - 60.f) < 1e-3f,
              "the octave slider moves the root by whole octaves");
        const float* o = mirror::Chord::StageOffsets(0);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().note[i] - (60.f - 12.f + o[i])) < 1e-3f,
                  "and every voice at once");
        check(std::fabs(c.voicing().pluck_note - 72.f) < 1e-3f,
              "the pinned pluck stays on the visitor's note");
        // What Wwise sees: `Key` is the visitor's note in the bank's authored
        // register, untouched by the slider -- it reaches the pluck, the
        // drone and the drops -- and the chord's octave rides on `PadOctave`
        // alone, so the pad still lands on the root.
        check(std::fabs(c.keyNote() - (72.f - 36.f)) < 1e-3f,
              "Key is the visitor's note, chord octave excluded");
        check(std::fabs(c.padOctave() - (60.f - 36.f)) < 1e-3f,
              "PadOctave carries the pad the rest of the way to the root");
        c.config().chord_octave = -3;
        check(std::fabs(c.keyNote() - 36.f) < 1e-3f,
              "and Key does not move when the slider does");
        check(std::fabs(c.padOctave() - 0.f) < 1e-3f,
              "-3 is the bank's own register: no pad offset at all");
        c.config().chord_octave = -1;
        // At the default -1 the climb's top is the chord's own top voice.
        c.update(1.f, 0.f, kDt);
        check(std::fabs(c.voicing().pluck_note - (60.f + 28.f)) < 1e-3f,
              "an octave down, the pluck's climb ends on the chord's top voice");
    }

    // --- the octave slider transposes the pad, and only the pad -------------
    //
    // It moves the pad's register without moving the piece's key, so the pluck
    // -- which reads the key directly -- must stay exactly where it was.
    {
        mirror::Chord c = makeChord();
        hold(c, 0.f, 0.f, 1.f);
        const float pluck_before = c.voicing().pluck_note;
        c.config().octave = -24.f;
        c.update(0.f, 0.f, kDt);
        const float* o = mirror::Chord::StageOffsets(0);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().note[i] - (48.f - 24.f + o[i])) < 1e-3f,
                  "the octave slider transposes every voice at once");
        check(std::fabs(c.voicing().pluck_note - pluck_before) < 1e-3f,
              "and leaves the pluck's register alone");
    }

    // --- an abandoned fit resets -------------------------------------------
    //
    // Somebody walks off halfway. The next person must get the piece unresolved.
    {
        mirror::Chord c = makeChord();
        hold(c, 0.9f, 0.f, 5.f);
        check(c.voicing().stage == 3, "walked most of the arc");
        c.reset();
        check(c.voicing().stage == 0, "reset returns to the opening chord");
        const float* o = mirror::Chord::StageOffsets(0);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().note[i] - (36.f + o[i])) < 1e-3f,
                  "reset puts the voices there rather than gliding them back");
    }

    // --- resolve() forces the ending and holds it against the fit -----------
    //
    // The two ways a sitting ends without earning the final chord on its own:
    // the fit times out partway, or the visitor leaves mid-fit. Either way the
    // piece still has to close, and the pond's fit level dropping back to 0
    // right afterwards (see main.mm's Idle entry) must not immediately drag
    // the chord back down with it.
    {
        mirror::Chord c = makeChord();
        hold(c, 0.6f, 0.f, 2.f);
        check(c.voicing().stage == 2, "stalled short of the final checkpoint");
        c.resolve();
        check(c.stageChanged() && c.stage() == mirror::Chord::kStages - 1,
              "resolve() jumps straight to the final checkpoint and fires the edge");
        const float* o = mirror::Chord::StageOffsets(mirror::Chord::kStages - 1);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().note[i] - (36.f + o[i])) < 1e-3f,
                  "resolve() lands the voicing on the final chord immediately");
        // The fit collapsing to 0, as it does the instant the pond stops
        // training, must not retreat a resolved chord.
        hold(c, 0.f, 0.f, 5.f);
        check(c.voicing().stage == mirror::Chord::kStages - 1,
              "a resolved chord holds against the fit dropping to 0");
        // Only reset() lets the fit drive the checkpoint again.
        c.reset();
        check(c.voicing().stage == 0, "reset() clears the resolved hold too");
        c.update(0.6f, 0.f, kDt);
        check(c.stage() >= 1, "and the checkpoint tracks the fit again after reset()");
    }

    // --- the second progression ---------------------------------------------
    //
    // Switching the table mid-sitting is a chord change on the same stage
    // number: the edge fires so the caller reposts the state, the state name
    // is the modes row, and the diagnostic voicing and the pluck's snap both
    // read the modes table from then on.
    {
        mirror::Chord c = makeChord();
        hold(c, 0.6f, 0.f, 2.f);
        check(c.stage() == 2, "the modes test starts from stage 2");
        (void)c.stageChanged();
        c.config().progression = mirror::Chord::kProgModes;
        c.update(0.6f, 0.f, kDt);
        check(c.stageChanged(), "switching progression fires the stage edge");
        check(std::string(c.stateName()) == "Modes2", "and names the modes row's state");
        check(!c.stageChanged(), "the edge is consumed like any other");
        const float* o = mirror::Chord::StageOffsets(2, mirror::Chord::kProgModes);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().note[i] - (36.f + o[i])) < 1e-3f,
                  "the voicing reads the modes table");
        // The pluck's snap is to a tone of the *modes* chord: fold the
        // pluck's offset from the root to one octave and it must match one.
        const float rel = std::fmod(c.voicing().pluck_note - c.effectiveRoot() + 1200.f, 12.f);
        bool on_tone = false;
        for (int i = 0; i < mirror::kChordVoices; ++i)
            if (std::fabs(rel - std::fmod(o[i], 12.f)) < 1e-3f) on_tone = true;
        check(on_tone, "the pluck snaps to a tone of the modes chord");
        hold(c, 1.f, 0.f, 1.f);
        check(std::string(c.stateName()) == "Modes4", "the modes row resolves to Modes4");
        // Back to the arc: another edge, the arc's name again.
        c.config().progression = mirror::Chord::kProgArc;
        c.update(1.f, 0.f, kDt);
        check(c.stageChanged() && std::string(c.stateName()) == "Stage4",
              "switching back is an edge onto the arc's row");
    }

    // The last three modes chords climb: from stage 2 on, no voice falls.
    {
        for (int st = 2; st < mirror::Chord::kStages - 1; ++st) {
            const float* a = mirror::Chord::StageOffsets(st, mirror::Chord::kProgModes);
            const float* b = mirror::Chord::StageOffsets(st + 1, mirror::Chord::kProgModes);
            for (int i = 0; i < mirror::kChordVoices; ++i)
                check(b[i] >= a[i], "the modes' last three chords rise voice by voice");
        }
    }

    // --- the pinned pluck's drop has a refractory period --------------------
    //
    // A face lost for a blink must not bounce the pluck an octave down and
    // back; the drop waits `pluck_empty_delay_s`, the lift is immediate.
    {
        mirror::Chord c = makeChord();
        c.config().pluck_empty_delay_s = 2.f;
        const float idle  = c.visitorNote() + 12.f * (float)c.config().pluck_idle_octave;
        const float empty = c.visitorNote() + 12.f * (float)c.config().pluck_empty_octave;
        c.update(0.f, 0.f, kDt, true);
        check(std::fabs(c.voicing().pluck_note - idle) < 1e-3f, "present: the idle octave");
        for (int i = 0; i < 60; ++i) c.update(0.f, 0.f, kDt, false);   // 1 s gone
        check(std::fabs(c.voicing().pluck_note - idle) < 1e-3f,
              "a second's absence has not dropped the pluck yet");
        c.update(0.f, 0.f, kDt, true);                                 // back for a frame
        for (int i = 0; i < 90; ++i) c.update(0.f, 0.f, kDt, false);   // 1.5 s gone
        check(std::fabs(c.voicing().pluck_note - idle) < 1e-3f,
              "a reappearance restarts the wait");
        for (int i = 0; i < 60; ++i) c.update(0.f, 0.f, kDt, false);   // 2.5 s gone
        check(std::fabs(c.voicing().pluck_note - empty) < 1e-3f,
              "past the delay the pluck drops to the empty-room octave");
        c.update(0.f, 0.f, kDt, true);
        check(std::fabs(c.voicing().pluck_note - idle) < 1e-3f, "the lift on arrival is immediate");
    }

    // --- one note per visitor: the pluck's pin and the chord's root agree --
    //
    // The G5 default with a +/-5 draw: whatever newVisitor() lands on, the
    // pinned pluck rings exactly that note, the root is the same pitch class
    // in the key's octave, and the first Fitting frame changes nothing.
    {
        mirror::Chord c;
        c.config().pluck_center_note = 79.f;
        c.config().pluck_offset_max_semitones = 5;
        bool saw_nonzero = false;
        for (int visitor = 0; visitor < 40; ++visitor) {
            c.newVisitor();
            const float n = c.visitorNote();
            check(n >= 74.f && n <= 84.f, "the draw stays inside the offset range");
            if (n != 79.f) saw_nonzero = true;
            // Idle: resolved, fit at 0.
            c.resolve();
            hold(c, 0.f, 0.3f, 2.f);
            check(std::fabs(c.voicing().pluck_note - n) < 1e-3f,
                  "idle rings the visitor's note");
            check(std::fabs(c.voicing().comb_hz - NoteToHz(n)) < 0.1f,
                  "as Hz, exactly");
            // The root: the note itself, an octave down.
            const float root = c.effectiveRoot();
            check(std::fabs(root - (n - 12.f)) < 1e-3f,
                  "the root is the visitor's note an octave down");
            // The handoff: reset(), then the first frames of Fitting with the
            // fit still at 0 and the room moving -- nothing moves.
            c.reset();
            c.update(0.f, 0.5f, kDt);
            check(std::fabs(c.voicing().pluck_note - n) < 1e-3f,
                  "the pluck does not move at the Idle -> Fitting handoff");
            check(std::fabs(c.effectiveRoot() - root) < 1e-3f,
                  "nor does the root");
            // And the moment the fit leaves zero, the snap starts from the
            // note itself: a tiny fit is a tiny push, snapped back onto it.
            c.update(0.01f, 0.f, kDt);
            check(std::fabs(c.voicing().pluck_note - n) < 1e-3f,
                  "a fit barely off zero leaves the pluck on its note");
        }
        check(saw_nonzero, "40 draws over +/-5 semitones were not all zero");
    }

    // --- wander shades the Hz, never the note or the root -------------------
    {
        mirror::Chord c = makeChord();
        c.config().pluck_wander_enabled = true;
        c.config().pluck_wander_period_s = 1.f;
        c.config().pluck_wander_depth = 0.3f;
        c.resolve();
        hold(c, 0.f, 0.f, 0.37f);
        check(std::fabs(c.voicing().comb_hz - NoteToHz(72.f)) > 1.f,
              "the wander actually moved the pinned comb Hz");
        check(std::fabs(c.voicing().pluck_note - 72.f) < 1e-3f,
              "but not the note");
        check(std::fabs(c.effectiveRoot() - 48.f) < 1e-3f, "nor the root");
        // It stops the moment the fit moves the pluck.
        c.reset();
        c.update(0.5f, 0.f, kDt);
        check(std::fabs(c.voicing().comb_hz - NoteToHz(c.voicing().pluck_note)) < 0.01f,
              "a moving fit rings the snapped note with no wander on it");
    }

    if (failures == 0) std::printf("chord_test: OK\n");
    return failures == 0 ? 0 : 1;
}
