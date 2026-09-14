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
float HzToNote(float hz) { return 69.f + 12.f * std::log2(hz / 440.f); }

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

    // --- the wobble: a fit that genuinely degrades retreats, a small dip ----
    // --- (inside the hysteresis band) does not -------------------------------
    //
    // fit_level is a live loss now, not a one-shot residual: it can really get
    // worse (she turns away, tracking degrades), and when it does the chord
    // has to follow it back down rather than stay pinned at a resolution the
    // room no longer earns. What still has to hold is that a fit sitting near
    // a boundary doesn't chatter -- that's what the hysteresis gap is for.
    {
        mirror::Chord c;
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
        mirror::Chord c;
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
        mirror::Chord c;
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
        mirror::Chord c;
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

    // --- the pluck is pinned to the chord, and intensity opens it upward ----
    {
        mirror::Chord c;
        // At zero intensity it rings on the top of the opening voicing, an
        // octave up -- 48 + 22 (stage 0's top voice) + 12 lands exactly on
        // pluck_high (34), so the snap is a no-op here by construction.
        c.update(0.f, 0.f, kDt);
        check(std::fabs(c.voicing().pluck_note - (48.f + 34.f)) < 1e-3f,
              "the pluck starts on the chord's top note, an octave up");
        check(std::fabs(c.voicing().comb_hz - NoteToHz(48.f + 34.f)) < 0.1f,
              "and the comb frequency is that note in Hz");
        // At fit=1 the chord resolves in the same frame (stage jumps straight
        // to 4, see the checkpoint test above), and intensity is 0.5 (fit and
        // movement averaged, movement=0 here) -- the raw target, root + 34 +
        // 0.5*12 = root + 40, lands exactly on stage 4's top voice an octave
        // up (28 + 12), so the snap is again a no-op by construction. Higher
        // than the fit=0 case: intensity opens the pluck upward, it does not
        // glide it down.
        c.update(1.f, 0.f, kDt);
        check(std::fabs(c.voicing().pluck_note - (48.f + 40.f)) < 1e-3f,
              "full fit opens the pluck upward, still on a chord tone");
        check(c.voicing().comb_hz > NoteToHz(48.f + 34.f),
              "and the comb frequency rises with it, not falls");
        // Movement alone (fit held at 0, so the checkpoint never advances --
        // see the checkpoint test above) is the same 0.5 intensity as the
        // fit=1 case above, just against stage 0's own, narrower voicing:
        // it must not be lower than the zero-intensity baseline.
        mirror::Chord cm;
        cm.update(0.f, 1.f, kDt);
        check(cm.voicing().stage == 0, "movement alone does not advance the checkpoint");
        check(cm.voicing().comb_hz >= NoteToHz(48.f + 34.f) - 0.1f,
              "movement alone never pulls the pluck below the zero-intensity base");
        // Full fit and full movement together is the same intensity (1.0
        // averages to 1.0 either way) as full fit alone would be if the
        // checkpoint gate let intensity exceed what fit alone reaches --
        // here it must be at least as high as the fit=1-alone case, since
        // stage and intensity can only add register, never remove it.
        mirror::Chord cb;
        cb.update(1.f, 1.f, kDt);
        check(cb.voicing().comb_hz >= c.voicing().comb_hz - 0.1f,
              "fit and movement together open the pluck at least as far as fit alone");
        // The comb's range must stay inside the game parameter's 20..2000 Hz.
        for (float fit = 0.f; fit <= 1.f; fit += 0.01f) {
            for (float mv = 0.f; mv <= 1.f; mv += 0.5f) {
                mirror::Chord cr;
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
        mirror::Chord c;
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
        check(std::fabs(c.voicing().pluck_note - (55.f + 34.f)) < 1e-3f,
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

    // --- resolve() forces the ending and holds it against the fit -----------
    //
    // The two ways a sitting ends without earning the final chord on its own:
    // the fit times out partway, or the visitor leaves mid-fit. Either way the
    // piece still has to close, and the pond's fit level dropping back to 0
    // right afterwards (see main.mm's Idle entry) must not immediately drag
    // the chord back down with it.
    {
        mirror::Chord c;
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

    // --- root follows idle tuning --------------------------------------------
    //
    // Simulate an idle wait: fit held at 0 (idle never trains the pond) with
    // wander on -- and on with a large amplitude, deliberately, so a bug that
    // let the root pick up the wander's drift (rather than the pluck's target
    // note, ignoring it) would show up unmistakably. reset() -- the Idle ->
    // Fitting handoff for the next visitor -- should carry the pluck's
    // *target* note (`pluck_note`, the snapped chord tone -- unaffected by
    // wander, which only shades the Hz the comb rings with), transposed by
    // whole octaves into the pad's register, as this visitor's root.
    {
        mirror::Chord c;
        check(c.config().root_follows_idle_tuning, "on by default");
        c.config().pluck_wander_enabled = true;
        c.config().pluck_wander_period_s = 1.f;
        c.config().pluck_wander_depth = 0.3f;  // large: up to +/-30% of the pinned Hz
        hold(c, 0.f, 0.3f, 3.f);
        const float pluck_note = c.voicing().pluck_note;
        const float idle_hz = c.voicing().comb_hz;
        check(std::fabs(idle_hz - NoteToHz(pluck_note)) > 5.f,
              "the wander actually moved the pinned pluck well off its target note");

        c.reset();
        const float octaves = std::round((pluck_note - c.config().root) / 12.f);
        const float want_root = pluck_note - octaves * 12.f;
        check(std::fabs(c.voicing().note[0] - (want_root + c.config().octave)) < 1e-2f,
              "with the flag on, reset()'s root voice continues the pluck's target "
              "note (not the wandered Hz), octave-shifted into the pad's register");

        // With the flag off, the old behaviour: reset() always lands on the
        // configured root, no matter what the pluck was doing beforehand.
        mirror::Chord c2;
        c2.config().root_follows_idle_tuning = false;
        c2.config().pluck_wander_enabled = true;
        c2.config().pluck_wander_period_s = 1.f;
        hold(c2, 0.f, 0.3f, 3.f);
        c2.reset();
        check(std::fabs(c2.voicing().note[0] - (c2.config().root + c2.config().octave)) < 1e-3f,
              "with the flag off, reset() still uses the configured root");
    }

    // --- root follows idle tuning: the per-visitor offset IS carried --------
    //
    // Unlike wander (above), the per-visitor pluck offset is a real pitch --
    // "this visitor's tuning" -- not ear noise around the pinned note (see
    // its comment in chord.h), so reset() should fold it into the continued
    // root exactly, on top of `pluck_note`. Redraw Chords until the RNG lands
    // a nonzero offset (bounded -- the +/-3 semitone range makes this settle
    // in a handful of tries) so the assertion below can't pass by accident on
    // a 0 draw.
    {
        mirror::Chord c;
        c.config().pluck_offset_enabled = true;
        c.config().pluck_offset_max_semitones = 3;
        c.config().pluck_wander_enabled = false;
        float offset = 0.f;
        float pluck_note = 0.f;
        for (int tries = 0; tries < 50 && offset == 0.f; ++tries) {
            c.reset();
            hold(c, 0.f, 0.f, 0.05f);
            pluck_note = c.voicing().pluck_note;
            offset = 12.f * std::log2(c.voicing().comb_hz / NoteToHz(pluck_note));
        }
        check(offset != 0.f, "the per-visitor offset draw landed nonzero within a few tries");

        // `offset` and `pluck_note` above are exactly the idle state this
        // reset() call is about to read -- nothing has run update() since.
        c.reset();
        const float idle_note = pluck_note + offset;
        const float octaves = std::round((idle_note - c.config().root) / 12.f);
        const float want_root = idle_note - octaves * 12.f;
        check(std::fabs(c.voicing().note[0] - (want_root + c.config().octave)) < 1e-2f,
              "the per-visitor offset -- possibly fractional -- is carried into the "
              "continued root exactly, unlike wander/override");
    }

    // --- root follows idle tuning: the center override IS the continued -----
    // centre (not excluded like wander)
    //
    // Unlike wander, the pinned pluck's center-frequency override is a
    // deliberate choice of centre, not ear noise -- see the Config comment on
    // `pluck_center_override_enabled`. With the override on, offset off, and
    // wander on (to prove wander really is excluded even when it's the only
    // other thing shading `comb_hz`), reset()'s continued root should be
    // `HzToNote(pluck_center_hz)`, transposed by whole octaves into the pad's
    // register -- not the snapped chord tone `pluck_note` would otherwise
    // give, and not the wander-shaded Hz either.
    {
        mirror::Chord c;
        c.config().pluck_center_override_enabled = true;
        c.config().pluck_center_hz = 100.f;  // deliberately not a chord tone
        c.config().pluck_offset_enabled = false;
        c.config().pluck_wander_enabled = true;
        c.config().pluck_wander_period_s = 1.f;
        c.config().pluck_wander_depth = 0.3f;
        hold(c, 0.f, 0.3f, 3.f);
        check(std::fabs(c.voicing().comb_hz - 100.f) > 1.f,
              "wander actually moved comb_hz well off the override's 100 Hz");

        c.reset();
        const float centre_note = HzToNote(100.f);
        const float octaves = std::round((centre_note - c.config().root) / 12.f);
        const float want_root = centre_note - octaves * 12.f;
        check(std::fabs(c.voicing().note[0] - (want_root + c.config().octave)) < 1e-3f,
              "with the override on, reset()'s root continues HzToNote(pluck_center_hz) "
              "-- the override IS the chosen centre -- transposed into the pad's "
              "register, ignoring wander entirely");
    }

    if (failures == 0) std::printf("chord_test: OK\n");
    return failures == 0 ? 0 : 1;
}
