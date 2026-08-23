#include "show_timeline.h"

#include <algorithm>

namespace show {

// --- the graph ---------------------------------------------------------------
//
// The piece, as a table. Read it as prose: idle waits for someone; fitting
// either captures them or gives up when they leave; the transition ends itself;
// roots run until the room empties.
//
// Edge order is priority order. In `fitting` the fit is checked before the
// absence, so a frame where the fit lands as the person steps back reads as a
// capture -- which is the generous interpretation, and the right one.
namespace {

const Edge kIdleEdges[] = {
    {Event::FacePresent, Phase::Fitting, "face_hold", 1.5f},
};
const Edge kFittingEdges[] = {
    {Event::FitConverged, Phase::Transition, "fit_hold", 1.5f},
    {Event::FaceAbsent, Phase::Idle, "absent_hold", 2.5f},
};
const Edge kTransitionEdges[] = {
    // No debounce by default: the scene reports done once and means it.
    {Event::SceneDone, Phase::Roots, "done_hold", 0.f},
};
const Edge kRootsEdges[] = {
    {Event::FaceAbsent, Phase::Idle, "absent_hold", 8.f},
};

const PhaseGraph kGraph[(int)Phase::Count] = {
    // edges,          n, timeout,       min,  max
    {kIdleEdges,       1, Phase::Idle,    8.f,  0.f},
    {kFittingEdges,    2, Phase::Idle,    2.f, 30.f},
    {kTransitionEdges, 1, Phase::Roots,   0.f, 12.f},
    {kRootsEdges,      1, Phase::Idle,   40.f,  0.f},
};

static_assert(sizeof(kFittingEdges) / sizeof(Edge) <= kMaxEdges,
              "kMaxEdges must cover the widest phase");

const char* kPhaseNames[(int)Phase::Count] = {"idle", "fitting", "transition",
                                              "roots"};
const char* kEventNames[(int)Event::Count] = {
    "phase_start", "face_present", "face_absent", "fit_converged", "fit_lost",
    "scene_done"};

float clamp01(float v) { return v < 0.f ? 0.f : (v > 1.f ? 1.f : v); }

}  // namespace

const PhaseGraph& Graph(Phase p) {
    const int i = (int)p;
    return kGraph[(i >= 0 && i < (int)Phase::Count) ? i : 0];
}

const char* PhaseName(Phase p) {
    const int i = (int)p;
    return (i >= 0 && i < (int)Phase::Count) ? kPhaseNames[i] : "?";
}

bool ParsePhase(const std::string& s, Phase& out) {
    for (int i = 0; i < (int)Phase::Count; ++i) {
        if (s == kPhaseNames[i]) { out = (Phase)i; return true; }
    }
    return false;
}

const char* EventName(Event e) {
    const int i = (int)e;
    return (i >= 0 && i < (int)Event::Count) ? kEventNames[i] : "?";
}

bool ParseEvent(const std::string& s, Event& out) {
    for (int i = 0; i < (int)Event::Count; ++i) {
        if (s == kEventNames[i]) { out = (Event)i; return true; }
    }
    return false;
}

// --- runtime -----------------------------------------------------------------

Timeline::Timeline() {
    for (int i = 0; i < (int)Phase::Count; ++i) {
        const PhaseGraph& g = kGraph[i];
        min_time_[i] = g.min_time;
        max_time_[i] = g.max_time;
        for (int e = 0; e < g.edge_count; ++e) hold_[i][e] = g.edges[e].hold;
    }
    restart();
}

void Timeline::setTiming(Phase p, float min_time, float max_time) {
    const int i = (int)p;
    if (i < 0 || i >= (int)Phase::Count) return;
    min_time_[i] = min_time;
    max_time_[i] = max_time;
}

void Timeline::setHold(Phase p, int edge_index, float hold) {
    const int i = (int)p;
    if (i < 0 || i >= (int)Phase::Count) return;
    if (edge_index < 0 || edge_index >= kMaxEdges) return;
    hold_[i][edge_index] = hold;
}

void Timeline::restart() { enter(Phase::Idle, "restart"); }

void Timeline::goTo(Phase p) { enter(p, "forced"); }

void Timeline::go() {
    // Edge 0 is the forward path, so "go" means the same thing in every phase
    // without the operator having to know which event it is short-circuiting.
    const PhaseGraph& g = Graph(phase_);
    if (g.edge_count > 0) enter(g.edges[0].target, "cue: go");
}

void Timeline::enter(Phase p, const std::string& reason) {
    phase_ = p;
    t_ = 0.0;
    reason_ = reason;
    scene_done_ = false;
    ++entries_;

    for (int i = 0; i < kMaxEdges; ++i) held_[i] = 0.f;
}

bool Timeline::eventLevel(Event e) const {
    switch (e) {
        case Event::PhaseStart:   return true;
        case Event::FacePresent:  return sig_.face_present;
        case Event::FaceAbsent:   return !sig_.face_present;
        case Event::FitConverged: return sig_.fit_converged;
        case Event::FitLost:      return !sig_.fit_converged;
        case Event::SceneDone:    return scene_done_;
        default:                  return false;
    }
}

void Timeline::advance(double dt) {
    const float fdt = (float)std::max(0.0, dt);
    t_ += fdt;

    const int pi = (int)phase_;
    const PhaseGraph& g = Graph(phase_);

    for (int i = 0; i < g.edge_count; ++i) {
        const Edge& e = g.edges[i];
        const bool level = eventLevel(e.event);
        held_[i] = level ? held_[i] + fdt : 0.f;
        if (!level || held_[i] < hold_[pi][i]) continue;

        // The floor gates the conditions the room produces on its own. It does
        // not gate a scene reporting itself finished: holding a completed
        // transition on screen to satisfy a minimum would just be a freeze.
        if (t_ < min_time_[pi] && e.event != Event::SceneDone) continue;

        enter(e.target,
              std::string(PhaseName(e.target)) + " on " + EventName(e.event));
        return;
    }

    // The ceiling, after the edges: an event that fires on the same frame the
    // timeout expires is the more specific answer.
    if (max_time_[pi] > 0.f && t_ >= max_time_[pi]) {
        enter(g.timeout, std::string(PhaseName(g.timeout)) + " on timeout");
        return;
    }
}

float Timeline::phaseProgress() const {
    const float mx = max_time_[(int)phase_];
    if (mx <= 0.f) return 0.f;
    return clamp01((float)(t_ / mx));
}

}  // namespace show
