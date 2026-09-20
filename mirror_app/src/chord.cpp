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

// Snap a linear target to the nearest chord tone of `stage`, in whatever
// octave the target is in: each voice's offset is folded to the octave
// nearest the target, and the closest wins. This is what keeps the pluck
// sounding like it belongs to the chord instead of sliding across it on its
// own scale. A target that already *is* a chord tone (the visitor's note, an
// octave-multiple of the root by construction) comes back unchanged.
float SnapToChordTone(float linear_target, float root, int stage) {
    float best = linear_target;
    float best_dist = 1e9f;
    for (int i = 0; i < kChordVoices; ++i) {
        const float tone = root + kOffsets[stage][i];
        const float candidate = tone + 12.f * std::round((linear_target - tone) / 12.f);
        const float dist = std::fabs(candidate - linear_target);
        if (dist < best_dist) {
            best_dist = dist;
            best = candidate;
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

    const float base = effectiveRoot() + cfg_.octave;
    for (int i = 0; i < kChordVoices; ++i) {
        const float tgt = base + kOffsets[0][i];
        v_.note[i] = tgt;
        v_.target[i] = tgt;
    }
    v_.stage = 0;
    v_.pluck_note = visitorNote();
    v_.comb_hz = NoteToHz(v_.pluck_note);
    // The wander's clock restarts clean -- nothing about it should carry a
    // phase from one visitor's pin into the next.
    wander_time_ = 0.f;
}

void Chord::newVisitor() {
    pluck_offset_semitones_ = cfg_.pluck_offset_max_semitones > 0
        ? std::uniform_int_distribution<int>(0, cfg_.pluck_offset_max_semitones)(rng_)
        : 0;
}

void Chord::resolve() {
    const int prev_stage = stage_;
    stage_ = kStages - 1;
    resolved_ = true;
    // OR, not overwrite -- see stageChanged()'s comment in chord.h.
    stage_changed_ = stage_changed_ || (stage_ != prev_stage);

    const float base = effectiveRoot() + cfg_.octave;
    for (int i = 0; i < kChordVoices; ++i) {
        const float tgt = base + kOffsets[stage_][i];
        v_.target[i] = tgt;
        v_.note[i] = tgt;
    }
    v_.stage = stage_;
}

void Chord::update(float fit, float movement, float dt, bool present) {
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
    const float root = effectiveRoot();
    const float base = root + cfg_.octave;
    for (int i = 0; i < kChordVoices; ++i) {
        const float tgt = base + kOffsets[stage_][i];
        v_.target[i] = tgt;
        v_.note[i] = tgt + kDetuneDir[i] * movement * cfg_.detune_cents / 100.f;
    }
    v_.stage = stage_;

    // --- the pluck ----------------------------------------------------------
    //
    // Pinned on the visitor's note while the fit is at zero -- the whole idle
    // wait, and the first frames of Fitting before the pond is training --
    // dropped an octave under that while nobody is there (`present`), and,
    // once the fit is moving, lifted by the checkpoint: stage s of the last
    // one puts it s/4 of the way up `pluck_climb`, snapped to a tone of the
    // current chord. Stage 0 is the note itself (a chord tone of every
    // stage: the root, octaves up), so the first frame the fit leaves zero
    // nothing moves; the last stage lands on the resolved chord's top voice.
    // Movement is deliberately not in this any more -- the pluck's pitch
    // says where the fit is, nothing else. The drop to a very low register
    // at the Transition handoff is not a note at all -- it happens outside
    // Chord (see main.mm).
    if (fit <= 0.f) {
        const int octave = present ? cfg_.pluck_idle_octave : cfg_.pluck_empty_octave;
        v_.pluck_note = visitorNote() + 12.f * (float)octave;
        v_.comb_hz = NoteToHz(v_.pluck_note);
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
        const float climb = (float)stage_ / (float)(kStages - 1);
        const float linear = visitorNote() + climb * cfg_.pluck_climb;
        v_.pluck_note = SnapToChordTone(linear, root, stage_)
                      + 12.f * (float)cfg_.pluck_fit_octave;
        v_.comb_hz = NoteToHz(v_.pluck_note);
        wander_time_ = 0.f;
    }
}

}  // namespace mirror
