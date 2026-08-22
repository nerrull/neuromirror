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

}  // namespace

const float* Chord::StageOffsets(int stage) {
    return kOffsets[std::clamp(stage, 0, kStages - 1)];
}

float Chord::StageThreshold(int stage) {
    return kThresholds[std::clamp(stage, 0, kStages - 1)];
}

void Chord::reset() {
    stage_ = 0;
    primed_ = false;
    for (int i = 0; i < kChordVoices; ++i) {
        cur_[i] = cfg_.root + cfg_.octave + kOffsets[0][i];
        v_.note[i] = cur_[i];
        v_.target[i] = cur_[i];
    }
    v_.stage = 0;
    v_.pluck_note = cfg_.root + cfg_.pluck_high;
    v_.comb_hz = NoteToHz(v_.pluck_note);
}

void Chord::update(float fit, float movement, float dt) {
    fit = std::clamp(fit, 0.f, 1.f);
    movement = std::clamp(movement, 0.f, 1.f);
    dt = std::max(0.f, dt);

    // A change of key *or* of the pad's octave is a transposition, not a chord
    // change: it should take every voice with it immediately rather than glide,
    // or the pad spends four seconds arriving at a register nobody is listening
    // for any more. Both are folded into one base, so moving either slider is
    // the same operation.
    const float base = cfg_.root + cfg_.octave;
    if (!primed_) {
        for (int i = 0; i < kChordVoices; ++i) cur_[i] = base + kOffsets[stage_][i];
        primed_ = true;
        base_at_prime_ = base;
    } else if (base != base_at_prime_) {
        const float shift = base - base_at_prime_;
        for (int i = 0; i < kChordVoices; ++i) cur_[i] += shift;
        base_at_prime_ = base;
    }

    // --- the checkpoint -----------------------------------------------------
    //
    // Forward only. The fit going back down -- a blink, a turn, a dropped frame
    // -- must not un-resolve the harmony; see the header. Advancing more than
    // one stage in a frame is allowed and deliberate: a fit that lands all at
    // once should land on the chord it earned, and the glide below is what
    // keeps that from being a jump.
    while (stage_ < kStages - 1 && fit >= kThresholds[stage_ + 1] + cfg_.hysteresis)
        ++stage_;

    // --- the glide ----------------------------------------------------------
    //
    // Exponential toward the target rather than a fixed-length ramp: it starts
    // at the moment of the checkpoint, which is what makes the change audible,
    // and it settles rather than arriving, which is what keeps four voices
    // moving different intervals from sounding mechanically synchronised.
    const float k = (cfg_.glide_secs > 1e-4f)
        ? (1.f - std::exp(-dt / cfg_.glide_secs))
        : 1.f;

    for (int i = 0; i < kChordVoices; ++i) {
        const float tgt = base + kOffsets[stage_][i];
        cur_[i] += (tgt - cur_[i]) * k;
        v_.target[i] = tgt;
        // Detune added *after* the glide, never inside it: folded in before,
        // the glide's time constant would smooth the movement signal into
        // nothing, and the beating is supposed to answer the room immediately.
        v_.note[i] = cur_[i] + kDetuneDir[i] * movement * cfg_.detune_cents / 100.f;
    }
    v_.stage = stage_;

    // --- the pluck ----------------------------------------------------------
    //
    // Continuous in the fit while the chord is stepped, and travelling downward
    // while the chord opens upward. Both ends are offsets from the same root as
    // the chord, so the comb is in tune with the pad by construction rather
    // than by two numbers being kept in agreement by hand.
    v_.pluck_note = cfg_.root + cfg_.pluck_high
                  + (cfg_.pluck_low - cfg_.pluck_high) * fit;
    v_.comb_hz = NoteToHz(v_.pluck_note);
}

}  // namespace mirror
