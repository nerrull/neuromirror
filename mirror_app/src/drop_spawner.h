// drop_spawner — when a raindrop lands, where, and how big.
//
// Split out of the ripple field itself because the two answer different
// questions. mirror_render decides what one impact *looks* like (a ring train
// riding its wavefront); this decides what a drop *is* once something outside
// has said one lands: trigger() -- a Wwise marker callback off the pluck bed,
// or the panel's button.
//
// A drop is an *event with a lifetime*, not a slot in a periodic table: it is
// born when it is born, carries the character it was born with, and is retired
// once its rings have left the frame. That is what lets a marker land the
// instant the transient does, instead of at the next multiple of some period.
// (There used to be an internal rain scheduler alongside trigger(); the show
// never used it, and it went with the OnsetTap path.)
#pragma once

#include <cstdint>
#include <random>
#include <vector>

#include "mirror_render.h"

namespace mirror {

// Every knob on the spawner. Defaults are believable rain: landing anywhere,
// with enough spread in size and strength that no two read as the same event.
struct DropSpawnParams {
    // --- where they land ----------------------------------------------------
    // Fractions of the frame, so a drop lands inside
    // (bias +- area * half-extent) on each axis. area 0 puts every drop on the
    // same spot, which is a legitimate setting (a dripping tap) rather than a
    // degenerate one.
    float area_x = 1.f, area_y = 1.f;
    float bias_x = 0.f, bias_y = 0.f;

    // --- what they are like -------------------------------------------------
    // Each jitter is a +-fraction of its own value, drawn per drop. They are
    // separate rather than one "randomness" control because they are separately
    // legible: size scatter reads as different-sized drops, strength scatter as
    // near and far ones, speed scatter as the surface not being uniform.
    float amp = 1.f,    amp_jitter = 0.3f;
    float width = 0.14f, width_jitter = 0.35f;
    float speed = 1.f,  speed_jitter = 0.15f;   // multiplies the pond's speed

    // Below this amplitude a candidate drop -- after jitter and any hit
    // scaling -- is discarded outright rather than
    // spawned faint. A rejection, not a floor: quieter than this and it never
    // appears at all, doesn't count toward `max_active`, and doesn't advance
    // `spawnCount()`. 0 disables rejection, the old behaviour.
    float reject_below_amp = 0.f;

    // How much faster a drop's rings fade with radius the quieter it is,
    // relative to `amp`: a drop at or above `amp` decays at the pond's own
    // rate (multiplier 1, unchanged); one at amplitude 0 decays at
    // `1 + weak_decay_gain` times that rate. 0 disables the effect -- every
    // drop decays the same, the old behaviour. See RippleSource's decay
    // multiplier in mirror_render.h.
    float weak_decay_gain = 1.f;

    // A drop is retired once its wavefront has left the frame; `life` is only
    // the backstop for a drop so slow it would otherwise sit there forever.
    float life = 8.f;
    int   max_active = 12;       // budget; the oldest drop yields to a new one

    // --- what an external trigger does --------------------------------------
    // trigger() carries a 0..1 strength and a -1..1 pan. These say how much of
    // the drop those two are allowed to decide, so audio can drive anything from
    // "the beat spawns identical drops" to "every property follows the hit".
    float hit_amp = 0.7f;        // strength -> amplitude, 0 = ignore strength
    float hit_width = 0.5f;      // strength -> packet width
    float hit_pan = 0.f;         // pan -> x position, 0 = land anywhere
};

// One drop in flight. Public because the panel draws them and the tests read
// them; nothing outside the spawner may change them.
struct Drop {
    double birth = 0.0;
    float  cx = 0.f, cy = 0.f;
    float  amp = 1.f;
    float  width = 0.14f;
    float  speed = 1.f;          // multiplier on the pond's ripple speed
    // Multiplier on the pond's ripple decay for this drop's rings alone (see
    // RippleSource in mirror_render.h). Set once at spawn from `amp` and
    // `weak_decay_gain`; fixed for the drop's whole life, same as amp/width.
    float  decay_mult = 1.f;
};

class DropSpawner {
public:
    explicit DropSpawner(uint32_t seed = 11) : rng_(seed) {}

    void reseed(uint32_t seed) { rng_.seed(seed); }

    // Spawn one drop at the next update(). Strength and pan are 0..1 and -1..1;
    // pass strength < 0 to mean "no opinion" and let the spawner draw its own.
    //
    // Queued rather than spawned on the spot because the spawner does not know
    // what time it is until update() -- and an audio onset arrives on whatever
    // thread polled the tap, between frames, with no clock the drops share.
    void trigger(float strength = -1.f, float pan = 0.f) {
        pending_.push_back({strength, pan});
    }

    // Advance to time `t`: spawn what trigger() queued, retire what has left
    // the frame, and rebuild the live source list. `speed` and `ring_freq` are
    // the pond's, needed to convert a drop's age into the phase the renderer
    // reads its wavefront radius off.
    const std::vector<RippleSource>& update(double t, float asp, float ring_freq,
                                            float speed, const DropSpawnParams& p);

    // The live drops, newest last.
    const std::vector<Drop>& drops() const { return drops_; }
    // Sources from the last update(), in the same order as drops().
    const std::vector<RippleSource>& sources() const { return src_; }
    // Drops spawned since the counter was last read; the panel shows a rate.
    int spawnCount() const { return spawns_; }

    void clear() {
        drops_.clear();
        src_.clear();
        pending_.clear();
    }

private:
    struct Pending { float strength; float pan; };

    float uniform(float lo, float hi) {
        return lo + (hi - lo) * std::generate_canonical<float, 24>(rng_);
    }
    // A +-jitter fraction around `v`, clamped at zero: `jitter` of 1 means the
    // draw spans 0..2v.
    float scatter(float v, float jitter) {
        return v * (1.f + jitter * uniform(-1.f, 1.f));
    }

    Drop makeDrop(double t, float asp, const DropSpawnParams& p,
                  float strength, float pan);
    void retire(double t, float ring_freq, float speed, const DropSpawnParams& p);

    std::mt19937 rng_;
    std::vector<Drop> drops_;
    std::vector<RippleSource> src_;
    std::vector<Pending> pending_;
    int    spawns_ = 0;
};

}  // namespace mirror
