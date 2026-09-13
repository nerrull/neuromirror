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

float Chord::StageThreshold(int stage) const {
    return cfg_.thresholds[std::clamp(stage, 0, kStages - 1)];
}

float Chord::NearestNoteHz(float hz) {
    hz = std::max(1.f, hz);
    const float midi = 69.f + 12.f * std::log2(hz / 440.f);
    return NoteToHz(std::round(midi));
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
    v_.comb_hz = cfg_.pluck_center_override_enabled ? cfg_.pluck_center_hz
                                                     : NoteToHz(v_.pluck_note);

    // See the "pinned-pluck exploration" comment in chord.h: the wander's
    // clock restarts clean, and a fresh per-visitor offset is drawn whether
    // or not it's currently enabled.
    wander_time_ = 0.f;
    pluck_offset_semitones_ = cfg_.pluck_offset_max_semitones > 0
        ? std::uniform_int_distribution<int>(-cfg_.pluck_offset_max_semitones,
                                              cfg_.pluck_offset_max_semitones)(rng_)
        : 0;
    if (cfg_.pluck_offset_enabled)
        v_.comb_hz *= std::pow(2.f, pluck_offset_semitones_ / 12.f);
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
    // No chord glide left to time -- Wwise's ChordStage transition owns
    // that -- but dt still drives the pinned-pluck wander clock below.

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
        while (stage_ < kStages - 1 && fit >= cfg_.thresholds[stage_ + 1] + cfg_.hysteresis)
            ++stage_;
        while (stage_ > 0 && fit < cfg_.thresholds[stage_] - cfg_.hysteresis)
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

    // --- pinned-pluck exploration (see Config) ------------------------------
    //
    // Both read `comb_hz` after the snap above, so neither ever moves the
    // pluck off its chord tone -- they only shade the Hz sent to the comb.
    // Gated on `fit`, not `intensity`: intensity also folds in room movement,
    // which Presence reports as soon as a face is tracked at all -- i.e.
    // from the very first frame of Fitting, well before the pond has actually
    // started converging. Gating on that left this dead the instant a face
    // appeared. `fit` stays exactly zero until pond.beginFit() is training,
    // which is the real "fitting has started" this was meant to hand off at.
    if (fit <= 0.f) {
        if (cfg_.pluck_center_override_enabled)
            v_.comb_hz = cfg_.pluck_center_hz;
        if (cfg_.pluck_offset_enabled)
            v_.comb_hz *= std::pow(2.f, pluck_offset_semitones_ / 12.f);
        if (cfg_.pluck_wander_enabled) {
            wander_time_ += dt;
            const float t = wander_time_;
            const float rate_hz = 1.f / std::max(0.1f, cfg_.pluck_wander_period_s);
            const float wobble =
                0.6f * std::sin(2.f * (float)M_PI * rate_hz * t) +
                0.4f * std::sin(2.f * (float)M_PI * rate_hz * 2.17f * t + 1.3f);
            v_.comb_hz *= (1.f + cfg_.pluck_wander_depth * wobble);
        }
    } else {
        wander_time_ = 0.f;
    }
}

}  // namespace mirror
