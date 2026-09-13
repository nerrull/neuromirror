#include "chord.h"

#include <algorithm>
#include <cmath>

namespace mirror {
namespace {

// Semitone offsets from the root, one row per checkpoint. See the table in
// chord.h for what each row is called. Read down a column to see a voice's
// path: voice 0 never moves, voice 1 makes one move (b7 -> 5th), voice 2 makes
// the one that matters (b3 -> 3rd), voice 3 opens the top out twice.
const float kOffsets[Chord::kStages][kChordVoices] = {
    { 0.f, 10.f, 15.f, 22.f },   // Cm7(b13)
    { 0.f, 10.f, 15.f, 26.f },   // Cm9
    { 0.f,  7.f, 15.f, 26.f },   // Cm(add9)
    { 0.f,  7.f, 16.f, 26.f },   // Cmaj9
    { 0.f,  7.f, 16.f, 28.f },   // Cmaj
};

// The fit level at which each stage becomes current. The last one is 0.95, not
// 1.0, deliberately: `fit_level` is half-scale at the residual the show waits
// on and keeps climbing after, so it does reach 0.95 in a good fit but lands on
// exactly 1.0 only by accident. A resolution the piece can only reach by
// accident is not a resolution.
const float kThresholds[Chord::kStages] = { 0.f, 0.25f, 0.50f, 0.75f, 0.95f };

// Alternating up the stack, so that voices whose harmonics coincide -- the root
// and its fifth, the root and the two-octave third -- are pulled apart rather
// than together. Detuning them all the same way would transpose the chord and
// beat against nothing.
const float kDetuneDir[kChordVoices] = { 1.f, -1.f, 1.f, -1.f };

float NoteToHz(float midi) {
    return 440.f * std::pow(2.f, (midi - 69.f) / 12.f);
}

// Snap a linear target to the nearest actual chord tone of `stage`, searching
// each voice's offset across the octave above and below (never wider -- see
// the header on `Comb_Tuning`'s range). This is what keeps the pluck sounding
// like it belongs to the chord instead of sliding across it on its own scale.
float SnapToChordTone(float linear_target, float root, int stage) {
    static const int kOctaveShift[3] = {-12, 0, 12};
    float best = linear_target;
    float best_dist = 1e9f;
    for (int i = 0; i < kChordVoices; ++i) {
        for (int shift : kOctaveShift) {
            const float candidate = root + kOffsets[stage][i] + (float)shift;
            const float dist = std::fabs(candidate - linear_target);
            if (dist < best_dist) {
                best_dist = dist;
                best = candidate;
            }
        }
    }
    return best;
}

}  // namespace

const float* Chord::StageOffsets(int stage) {
    return kOffsets[std::clamp(stage, 0, kStages - 1)];
}

float Chord::StageThreshold(int stage) {
    return kThresholds[std::clamp(stage, 0, kStages - 1)];
}

void Chord::reset() {
    const int prev_stage = stage_;
    stage_ = 0;
    // OR, not overwrite: see stageChanged()'s comment in chord.h. A reset()
    // called right after a resolve() (the Idle -> Fitting handoff, both
    // within the same on-screen frame) must not lose resolve()'s edge, and a
    // reset() that itself moves the stage (the usual case: undoing a
    // resolved Stage4 back to Stage0 for the next visitor) must post its own
    // edge too, or Wwise is left holding the old chord's ChordStage state
    // forever with no SetState ever telling it otherwise.
    stage_changed_ = stage_changed_ || (stage_ != prev_stage);
    resolved_ = false;
    for (int i = 0; i < kChordVoices; ++i) {
        const float tgt = cfg_.root + cfg_.octave + kOffsets[0][i];
        v_.note[i] = tgt;
        v_.target[i] = tgt;
    }
    v_.stage = 0;
    v_.pluck_note = cfg_.root + cfg_.pluck_high;
    v_.comb_hz = NoteToHz(v_.pluck_note);
}

void Chord::resolve() {
    const int prev_stage = stage_;
    stage_ = kStages - 1;
    resolved_ = true;
    // OR, not overwrite -- see stageChanged()'s comment in chord.h.
    stage_changed_ = stage_changed_ || (stage_ != prev_stage);

    const float base = cfg_.root + cfg_.octave;
    for (int i = 0; i < kChordVoices; ++i) {
        const float tgt = base + kOffsets[stage_][i];
        v_.target[i] = tgt;
        v_.note[i] = tgt;
    }
    v_.stage = stage_;
}

void Chord::update(float fit, float movement, float dt) {
    fit = std::clamp(fit, 0.f, 1.f);
    movement = std::clamp(movement, 0.f, 1.f);
    dt = std::max(0.f, dt);
    (void)dt;  // no glide left to time -- Wwise's ChordStage transition owns it

    // --- the checkpoint -----------------------------------------------------
    //
    // Two-sided: the fit is a live loss now, not a one-shot residual, and it
    // can genuinely get worse -- she turns away, walks off, tracking degrades
    // -- so the chord retreats when it does, rather than staying pinned at a
    // resolution the room no longer earns. Each side has its own threshold,
    // offset by `hysteresis` from the checkpoint boundary (a Schmitt trigger),
    // so a fit sitting exactly on a boundary doesn't flicker the chord every
    // frame. Advancing (or retreating) more than one stage in a frame is
    // allowed and deliberate: a fit that lands all at once should land on the
    // chord it earned, and Wwise's own transition is what keeps that from
    // being a jump.
    //
    // Unless resolve() has already declared the sitting over: the fit level
    // fed in after that (typically dropping to 0 as the pond stops training)
    // would otherwise retreat the chord straight back to the dark opening the
    // instant the checkpoint was supposed to be holding its resolution.
    const int prev_stage = stage_;
    if (!resolved_) {
        while (stage_ < kStages - 1 && fit >= kThresholds[stage_ + 1] + cfg_.hysteresis)
            ++stage_;
        while (stage_ > 0 && fit < kThresholds[stage_] - cfg_.hysteresis)
            --stage_;
    }
    // OR, not overwrite -- see stageChanged()'s comment in chord.h. Without
    // the OR, a resolve()/reset() call earlier this same on-screen frame
    // (main.mm's phase-entry switch runs before this update()) would have
    // its edge silently overwritten back to false here, since by the time
    // update() runs `stage_` already *is* the post-resolve/reset value and
    // so looks unchanged from this call's own point of view.
    stage_changed_ = stage_changed_ || (stage_ != prev_stage);

    // --- the voicing (diagnostics only) -------------------------------------
    //
    // Stepped directly, no smoothing: the actual glide now happens inside
    // Wwise's `ChordStage` state transition, driven by the `SetState` the
    // caller posts on `stageChanged()`. `note`/`target` exist so the panel can
    // still show the checkpoint's voicing at a glance.
    const float base = cfg_.root + cfg_.octave;
    for (int i = 0; i < kChordVoices; ++i) {
        const float tgt = base + kOffsets[stage_][i];
        v_.target[i] = tgt;
        v_.note[i] = tgt + kDetuneDir[i] * movement * cfg_.detune_cents / 100.f;
    }
    v_.stage = stage_;

    // --- the pluck ----------------------------------------------------------
    //
    // Pinned to the current chord (root + pluck_high, snapped to the nearest
    // tone of the current stage) rather than travelling with the fit -- the
    // pluck belongs to the chord throughout Fitting, it does not slide away
    // from it. What fit and movement drive is "intensity": how far above that
    // base the pluck rings, so a converging fit and a moving room open the
    // pluck's register without ever taking it out of key. The drop to a very
    // low register is not a note at all -- it happens outside Chord, at the
    // Transition handoff (see main.mm).
    const float intensity = std::clamp(0.5f * (fit + movement), 0.f, 1.f);
    const float linear = cfg_.root + cfg_.pluck_high
                        + intensity * cfg_.pluck_intensity_range;
    v_.pluck_note = SnapToChordTone(linear, cfg_.root, stage_);
    v_.comb_hz = NoteToHz(v_.pluck_note);
}

}  // namespace mirror
