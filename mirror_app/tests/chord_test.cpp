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

}  // namespace

int main() {
    // --- the opening voicing ------------------------------------------------
    {
        mirror::Chord c;
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
        mirror::Chord c;
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

    // --- the wobble: a fit that goes backwards must not un-resolve ----------
    //
    // This is the whole reason the stage lives here and not in an RTPC curve.
    // A blink or a dropped frame drives fit_level back down; the harmony has to
    // ignore that, because resolution is not a thing that flickers.
    {
        mirror::Chord c;
        hold(c, 0.80f, 0.f, 2.f);
        const int high = c.voicing().stage;
        check(high == 3, "0.80 reaches the fourth checkpoint");
        hold(c, 0.10f, 0.f, 2.f);
        check(c.voicing().stage == high, "a fit falling back to 0.10 holds the chord");
        // And the voices stay put rather than gliding back down.
        const float* o = mirror::Chord::StageOffsets(high);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().target[i] - (36.f + o[i])) < 1e-3f,
                  "the glide target holds too");
    }

    // --- hysteresis: sitting exactly on a boundary does not chatter ---------
    {
        mirror::Chord c;
        hold(c, 0.25f, 0.f, 1.f);
        check(c.voicing().stage == 0,
              "a fit resting exactly on the 0.25 boundary has not advanced yet");
        hold(c, 0.25f + 0.031f, 0.f, 1.f);
        check(c.voicing().stage == 1, "clearing the boundary by the hysteresis advances");
    }

    // --- the glide is a glide, not a jump -----------------------------------
    {
        mirror::Chord c;
        c.config().glide_secs = 4.f;
        // Straight to the last stage in one frame -- the worst case, a fit that
        // lands all at once.
        c.update(1.f, 0.f, kDt);
        check(c.voicing().stage == mirror::Chord::kStages - 1, "jumped to the last stage");
        // Voice 3 has to travel 16 - 15 = 1 semitone and voice 1 seven - ten = -3.
        // After one frame it must have moved, but nowhere near arrived.
        const float moved = std::fabs(c.voicing().note[1] - (36.f + 10.f));
        check(moved > 0.f, "the voice started moving on the frame the checkpoint fired");
        check(moved < 0.2f, "and did not jump there");
        // Roughly one time constant in, it should be about two thirds of the way.
        hold(c, 1.f, 0.f, 4.f);
        const float travelled = (36.f + 10.f) - c.voicing().note[1];   // of 3 semitones
        check(travelled > 1.6f && travelled < 2.4f,
              "about 63% of the interval covered in one time constant");
    }

    // --- detune: movement beats, stillness does not -------------------------
    {
        mirror::Chord c;
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

    // --- the pluck stays in tune with the pad -------------------------------
    {
        mirror::Chord c;
        // At the very start it rings on the top of the opening voicing...
        c.update(0.f, 0.f, kDt);
        check(std::fabs(c.voicing().pluck_note - (48.f + 22.f)) < 1e-3f,
              "the pluck starts on the chord's top note");
        check(std::fabs(c.voicing().comb_hz - NoteToHz(48.f + 22.f)) < 0.1f,
              "and the comb frequency is that note in Hz");
        // ...and at a converged fit, an octave under the root.
        c.update(1.f, 0.f, kDt);
        check(std::fabs(c.voicing().pluck_note - (48.f - 12.f)) < 1e-3f,
              "the pluck ends a bass octave below the root");
        // The comb's range must stay inside the game parameter's 20..2000 Hz.
        for (float fit = 0.f; fit <= 1.f; fit += 0.01f) {
            c.update(fit, 0.f, kDt);
            check(c.voicing().comb_hz > 20.f && c.voicing().comb_hz < 2000.f,
                  "the comb frequency stays inside the Comb_Tuning range");
        }
    }

    // --- a key change transposes, it does not glide -------------------------
    //
    // The operator moving the key slider is not a chord change: every voice
    // should follow immediately, or the pad spends a glide arriving at a key
    // nobody is listening for any more.
    {
        mirror::Chord c;
        hold(c, 0.f, 0.f, 1.f);
        c.config().root = 55.f;
        c.update(0.f, 0.f, kDt);
        const float* o = mirror::Chord::StageOffsets(0);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().note[i] - (55.f - 12.f + o[i])) < 1e-3f,
                  "a key change moves every voice at once");
        check(std::fabs(c.voicing().pluck_note - (55.f + 22.f)) < 1e-3f,
              "the pluck follows the key too");
    }

    // --- the octave slider transposes the pad, and only the pad -------------
    //
    // It moves the pad's register without moving the piece's key, so the pluck
    // -- which reads the key directly -- must stay exactly where it was.
    {
        mirror::Chord c;
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
        mirror::Chord c;
        hold(c, 0.9f, 0.f, 5.f);
        check(c.voicing().stage == 3, "walked most of the arc");
        c.reset();
        check(c.voicing().stage == 0, "reset returns to the opening chord");
        const float* o = mirror::Chord::StageOffsets(0);
        for (int i = 0; i < mirror::kChordVoices; ++i)
            check(std::fabs(c.voicing().note[i] - (36.f + o[i])) < 1e-3f,
                  "reset puts the voices there rather than gliding them back");
    }

    if (failures == 0) std::printf("chord_test: OK\n");
    return failures == 0 ? 0 : 1;
}
