// show_timeline — the piece's running order: which of the four phases is up,
// and when it ends.
//
// The installation is not a demo with a scene radio button. It idles as a
// mirror until someone walks up to it, fits their face, falls through the
// transition and grows roots out of them, and then lets go when they leave.
//
// ## The shape is code; the timing is data
//
// That sequence is the piece. It is not a thing to be configured: idle waits
// for someone, fitting captures them, the transition hands off, roots grow, and
// an empty room resets it. A format that let you rewire *that* would be a
// format in which the piece could be described wrongly, and every one of its
// edges would need a runtime error for the case where it was.
//
// So the graph below is a fixed table -- phases, the events that move between
// them, and which way each edge points. What an install actually needs to
// change is *when*: how long the idle floor is, how long a face must be gone
// before the piece lets go. Those are durations, and they are plain floats a
// caller sets directly -- from the panel, from a preset, from a test -- rather
// than a script file. Every one has a default here, seeded from the graph, so
// a caller that sets nothing still runs the piece.
//
// ## Time and events, composed
//
// A phase advances on either, and the two compose:
//
//   * **`min`** is a floor. The events the room produces on its own -- a face
//     arriving, a fit converging -- cannot advance the phase below it, so
//     someone walking past cannot retrigger the piece every few seconds.
//   * **`max`** is a ceiling with a target fixed in the graph: the escape hatch
//     for a fit that never converges, so a person in a hat cannot strand the
//     piece.
//   * Between them the events decide, each debounced by its own `hold` -- a
//     dropped tracker frame is not somebody leaving the room.
//
// Two things ignore the floor, both deliberately: an edge whose event is a
// scene reporting itself finished, and an operator cue. Holding a completed
// transition on screen to satisfy a minimum is a freeze, not a beat.
//
// ## What this module is not
//
// It holds no Metal, no scenes and no textures: it is a state machine over
// durations and booleans, which is what makes it testable headlessly. The host
// (main.mm) reads `phase()` to pick what to render and watches `entries()` to
// know a phase just started -- that is where TransitionScene::restart() goes.
// Signals go the other way, once a frame.
#pragma once

#include <string>
#include <vector>

namespace show {

// The running order. The values are stable: presets and MIDI mappings refer to
// them by name, but the UI indexes by number.
enum class Phase : int {
    Idle = 0,        // the neural mirror alone, waiting
    Fitting = 1,     // a face is present and the morphable fit is converging
    Transition = 2,  // the hydro-dip handoff
    Roots = 3,       // roots growing through the fitted face
    Count = 4,
};

const char* PhaseName(Phase p);
bool ParsePhase(const std::string& s, Phase& out);

// What an edge waits for.
//
// The `_present`/`_absent` pairs are edges *derived from a level*: the host sets
// a boolean every frame and this decides when it has been steady long enough to
// count. A tracker that drops one frame out of thirty must not read as somebody
// leaving the room, which is what `hold` is for.
enum class Event : int {
    PhaseStart = 0, // true from the moment the phase opens
    FacePresent,    // a face has been tracked for `hold` seconds
    FaceAbsent,     // no face for `hold` seconds
    FitConverged,   // the fit has been settled for `hold` seconds
    FitLost,        // the fit stopped being settled
    SceneDone,      // the phase's own scene reported completion
    Count,
};

const char* EventName(Event e);
bool ParseEvent(const std::string& s, Event& out);

// --- the graph ---------------------------------------------------------------
// Fixed. `key` names this edge's debounce, for the panel label.
struct Edge {
    Event event;
    Phase target;
    const char* key;
    float hold;          // default debounce, seconds
    // Grace, seconds: while the level is false, `held_` survives up to this
    // long before it resets, so one dropped tracker frame does not throw away
    // an accumulating hold. 0 (the default) is the old all-or-nothing
    // behaviour. Only meaningful for level-derived events (see eventLevel());
    // PhaseStart/SceneDone ignore it.
    float grace = 0.f;
};

// A phase's outgoing edges, in priority order: they are checked in this order
// and the first match on a frame wins, so an ambiguous moment resolves the way
// the graph reads. Index 0 is the **forward path** through the piece -- the one
// an operator's "go" cue takes.
struct PhaseGraph {
    const Edge* edges;
    int edge_count;
    Phase timeout;       // where `max` sends it
    float min_time;      // default floor
    float max_time;      // default ceiling, 0 = none
};

const PhaseGraph& Graph(Phase p);
// Longest edge list of any phase, so Timeline can hold its holds inline.
constexpr int kMaxEdges = 4;

// --- runtime -----------------------------------------------------------------

// Level signals, set by the host once a frame. Levels rather than edges because
// the host has them as booleans anyway and edge detection with debounce is
// exactly what this module should own.
struct Signals {
    bool face_present = false;
    bool fit_converged = false;
};

class Timeline {
public:
    Timeline();

    // Back to Idle with every clock cleared.
    void restart();

    // Set a phase's floor/ceiling. Takes effect on the next `advance()`; does
    // not touch the running clock, so a panel slider dragged mid-phase retimes
    // it live rather than restarting it.
    void setTiming(Phase p, float min_time, float max_time);
    // Set one edge's debounce. `edge_index` indexes Graph(p).edges.
    void setHold(Phase p, int edge_index, float hold);
    // Set one edge's hysteresis grace, seconds. `edge_index` indexes
    // Graph(p).edges. See Edge::grace.
    void setGrace(Phase p, int edge_index, float grace);

    float minTime(Phase p) const { return min_time_[(int)p]; }
    float maxTime(Phase p) const { return max_time_[(int)p]; }
    float hold(Phase p, int edge_index) const {
        return hold_[(int)p][edge_index];
    }
    float grace(Phase p, int edge_index) const {
        return grace_[(int)p][edge_index];
    }

    void setSignals(const Signals& s) { sig_ = s; }
    // The phase's own scene finished (TransitionScene::done(), and anything
    // else that owns its duration). Latched until the phase changes, so a host
    // that reports it every frame after completion behaves the same as one that
    // reports it once.
    void sceneDone() { scene_done_ = true; }
    // The operator's "go": take the phase's forward edge now, whatever it was
    // waiting for and whatever its floor says. A MIDI CC, a key, a UI button.
    void go();

    // Forces a phase now, ignoring floors and ceilings. The operator override;
    // it counts as an entry, so the host restarts scenes for it.
    void goTo(Phase p);

    void advance(double dt);

    Phase phase() const { return phase_; }
    double phaseTime() const { return t_; }
    // Incremented on every phase entry, including the first and including
    // goTo(). The host keeps its own copy and compares: a change means "this
    // phase just started", which is where scene restarts belong.
    unsigned entries() const { return entries_; }

    // 0..1 through the phase's `max`, or 0 when it has none. For the UI.
    float phaseProgress() const;

    // Why the last transition happened, for the UI and for logs.
    const std::string& lastReason() const { return reason_; }

private:
    void enter(Phase p, const std::string& reason);
    bool eventLevel(Event e) const;

    Phase phase_ = Phase::Idle;
    double t_ = 0.0;
    unsigned entries_ = 0;
    std::string reason_ = "start";

    // Seeded from Graph()'s defaults in the constructor; setTiming/setHold move
    // these directly, no script object in between.
    float min_time_[(int)Phase::Count] = {};
    float max_time_[(int)Phase::Count] = {};
    float hold_[(int)Phase::Count][kMaxEdges] = {};
    float grace_[(int)Phase::Count][kMaxEdges] = {};

    Signals sig_;
    bool scene_done_ = false;

    float held_[kMaxEdges] = {};      // per-edge continuous-true accumulator
    float absent_[kMaxEdges] = {};    // per-edge continuous-false accumulator,
                                       // for the grace above
};

}  // namespace show
