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
    stage_ = 0;
    stage_changed_ = false;
    for (int i = 0; i < kChordVoices; ++i) {
        const float tgt = cfg_.root + cfg_.octave + kOffsets[0][i];
        v_.note[i] = tgt;
        v_.target[i] = tgt;
    }
    v_.stage = 0;
    v_.pluck_note = cfg_.root + cfg_.pluck_high;
    v_.comb_hz = NoteToHz(v_.pluck_note);
}

void Chord::update(float fit, float movement, float dt) {
    fit = std::clamp(fit, 0.f, 1.f);
    movement = std::clamp(movement, 0.f, 1.f);
    dt = std::max(0.f, dt);
    (void)dt;  // no glide left to time -- Wwise's ChordStage transition owns it

    // --- the checkpoint -----------------------------------------------------
    //
    // Forward only. The fit going back down -- a blink, a turn, a dropped frame
    // -- must not un-resolve the harmony; see the header. Advancing more than
    // one stage in a frame is allowed and deliberate: a fit that lands all at
    // once should land on the chord it earned, and Wwise's own transition is
    // what keeps that from being a jump.
    const int prev_stage = stage_;
    while (stage_ < kStages - 1 && fit >= kThresholds[stage_ + 1] + cfg_.hysteresis)
        ++stage_;
    stage_changed_ = (stage_ != prev_stage);

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
    // Continuous in the fit while the chord is stepped, and travelling upward
    // while the chord opens -- both now above the pad's register, so the pluck
    // never dips below the voice it is ringing against. The linear travel
    // between pluck_high and pluck_low is then snapped to the nearest tone of
    // the *current* chord: continuous motion, discrete landing, same as a
    // player's hand finding the nearest note on a fretboard.
    const float linear = cfg_.root + cfg_.pluck_high
                        + (cfg_.pluck_low - cfg_.pluck_high) * fit;
    v_.pluck_note = SnapToChordTone(linear, cfg_.root, stage_);
    v_.comb_hz = NoteToHz(v_.pluck_note);
}

}  // namespace mirror
