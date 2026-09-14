// show_timeline_test — the running order, headlessly.
//
// The timeline's failure modes are all invisible until they happen in the room
// and are then unreproducible: a phase that advances one frame early because a
// floor was checked against the wrong clock, a debounce that a single dropped
// tracker frame defeats. None of that shows in a screenshot and none of it is
// worth discovering with a person standing in front of the piece, so the whole
// state machine is driven here at a fixed step instead.
//
// The graph is code, so it is checked as code: the tests below assert the shape
// of the piece (idle -> fitting -> transition -> roots -> idle) and that
// setTiming/setHold retime it without touching the shape.

#include "show_timeline.h"

#include <cmath>
#include <cstdio>

namespace {

int failures = 0;

void check(bool ok, const char* what) {
    if (!ok) { std::printf("FAIL: %s\n", what); ++failures; }
}

bool near(float a, float b, float tol) { return std::fabs(a - b) <= tol; }

// Frames at 60 Hz, with the signals held.
void run(show::Timeline& tl, double seconds, show::Signals sig) {
    const double dt = 1.0 / 60.0;
    const int n = (int)std::lround(seconds / dt);
    for (int i = 0; i < n; ++i) {
        tl.setSignals(sig);
        tl.advance(dt);
    }
}

}  // namespace

int main() {
    using namespace show;

    const Signals kNothing;
    Signals kFace;  kFace.face_present = true;
    Signals kFit;   kFit.face_present = true; kFit.fit_converged = true;

    // --- the graph is the piece ---------------------------------------------
    {
        // Every phase can be left, or the installation can strand.
        for (int i = 0; i < (int)Phase::Count; ++i) {
            const PhaseGraph& g = Graph((Phase)i);
            check(g.edge_count > 0 || g.max_time > 0.f,
                  "every phase has a way out");
            check(g.edge_count <= kMaxEdges, "edge count fits Timeline::hold_");
            for (int e = 0; e < g.edge_count; ++e)
                check(g.edges[e].target != (Phase)i, "no edge to itself");
        }
        // The forward path, which is what the operator's "go" takes.
        check(Graph(Phase::Idle).edges[0].target == Phase::Fitting, "idle -> fitting");
        check(Graph(Phase::Fitting).edges[0].target == Phase::Transition,
              "fitting -> transition");
        check(Graph(Phase::Transition).edges[0].target == Phase::Roots,
              "transition -> roots");
        check(Graph(Phase::Roots).edges[0].target == Phase::Idle, "roots -> idle");
        // Fitting checks the fit before the absence: a fit landing as the
        // person steps back reads as a capture.
        check(Graph(Phase::Fitting).edges[0].event == Event::FitConverged &&
                  Graph(Phase::Fitting).edges[1].event == Event::FaceAbsent,
              "fitting prefers the capture");
        check(Graph(Phase::Fitting).timeout == Phase::Transition,
              "a fit that never converges is carried on rather than reset");
    }

    // --- a fresh timeline is the designed piece ------------------------------
    {
        Timeline d;
        for (int i = 0; i < (int)Phase::Count; ++i) {
            const Phase p = (Phase)i;
            check(near(d.minTime(p), Graph(p).min_time, 1e-6f), "min from the graph");
            check(near(d.maxTime(p), Graph(p).max_time, 1e-6f), "max from the graph");
            for (int e = 0; e < Graph(p).edge_count; ++e)
                check(near(d.hold(p, e), Graph(p).edges[e].hold, 1e-6f),
                      "hold from the graph");
        }

        // And it runs end to end.
        Timeline tl;
        run(tl, 12.0, kFace);
        check(tl.phase() == Phase::Fitting, "a face moves it to fitting");
        run(tl, 4.0, kFit);
        check(tl.phase() == Phase::Transition, "a converged fit hands off");
        tl.sceneDone();
        run(tl, 0.1, kFit);
        check(tl.phase() == Phase::Roots, "the transition ends itself");
        run(tl, 60.0, kNothing);
        check(tl.phase() == Phase::Idle, "it resets when the room empties");
    }

    // --- setTiming/setHold retime without restarting -------------------------
    {
        Timeline tl;
        check(near(tl.minTime(Phase::Idle), Graph(Phase::Idle).min_time, 1e-6f),
              "starts at the graph default");
        tl.setTiming(Phase::Idle, 5.f, Graph(Phase::Idle).max_time);
        tl.setHold(Phase::Idle, 0, 0.5f);
        check(near(tl.minTime(Phase::Idle), 5.f, 1e-6f), "min applied");
        check(near(tl.hold(Phase::Idle, 0), 0.5f, 1e-6f), "hold applied");
        // Untouched phases keep the graph's defaults.
        check(near(tl.minTime(Phase::Roots), Graph(Phase::Roots).min_time, 1e-6f),
              "an unset phase is unchanged");
    }

    // --- floors: an event cannot fire before `min` --------------------------
    {
        Timeline tl;
        tl.setTiming(Phase::Idle, 5.f, Graph(Phase::Idle).max_time);
        tl.setHold(Phase::Idle, 0, 1.f);
        run(tl, 4.0, kFace);
        check(tl.phase() == Phase::Idle, "held below the floor despite the event");
        run(tl, 1.5, kFace);
        check(tl.phase() == Phase::Fitting, "fires once the floor is cleared");
        // The hold ran concurrently with the floor rather than after it: a face
        // present the whole time advances at `min`, not at min + hold.
        check(tl.phaseTime() < 1.0, "no double wait");
    }

    // --- Idle's min is 0: face_hold alone gates Fitting, not a floor --------
    {
        Timeline tl;
        check(near(tl.minTime(Phase::Idle), 0.f, 1e-6f),
              "idle's min defaults to 0 -- face_hold is the only Idle timing knob");
        tl.setHold(Phase::Idle, 0, 1.f);   // well under the old 8s Idle floor
        run(tl, 1.05, kFace);              // a hair past 1s, clear of float roundoff
        check(tl.phase() == Phase::Fitting,
              "a 1s face_hold fires at t~1s, inside the old 8s Idle minimum");
    }

    // --- grace: a dropped face frame does not reset the accumulating hold ---
    {
        Timeline tl;
        tl.setHold(Phase::Idle, 0, 1.5f);
        tl.setGrace(Phase::Idle, 0, 0.5f);
        run(tl, 1.0, kFace);
        check(tl.phase() == Phase::Idle, "not yet -- only 1.0s of the 1.5s hold");
        run(tl, 0.2, kNothing);   // a dropped frame, well inside the 0.5s grace
        check(tl.phase() == Phase::Idle, "still waiting, the grace hasn't run out");
        run(tl, 0.6, kFace);      // resumes; 1.0 + 0.6 = 1.6 >= 1.5
        check(tl.phase() == Phase::Fitting,
              "accumulation resumed across the drop and cleared the hold");

        // Grace 0 is the old all-or-nothing behaviour: the same drop resets it.
        Timeline tl0;
        tl0.setHold(Phase::Idle, 0, 1.5f);
        tl0.setGrace(Phase::Idle, 0, 0.f);
        run(tl0, 1.0, kFace);
        run(tl0, 0.2, kNothing);
        run(tl0, 0.6, kFace);
        check(tl0.phase() == Phase::Idle,
              "with no grace the drop resets the hold: 0.6s alone isn't 1.5s");
    }

    // --- grace: an absence longer than grace resets the hold -----------------
    {
        Timeline tl;
        tl.setHold(Phase::Idle, 0, 1.5f);
        tl.setGrace(Phase::Idle, 0, 0.5f);
        run(tl, 1.0, kFace);
        run(tl, 0.6, kNothing);   // longer than the 0.5s grace
        run(tl, 1.0, kFace);      // fresh accumulation, well under 1.5s alone
        check(tl.phase() == Phase::Idle,
              "an absence past grace resets held_, so 1.0s alone isn't enough");
        run(tl, 0.55, kFace);     // 1.0 + 0.55, a hair past 1.5s from the reset
        check(tl.phase() == Phase::Fitting, "and it fires once that baseline hits 1.5s");
    }

    // --- debounce: a dropped tracker frame is not somebody leaving ----------
    {
        Timeline tl;
        tl.setTiming(Phase::Roots, 0.f, Graph(Phase::Roots).max_time);
        tl.setHold(Phase::Roots, 0, 3.f);
        tl.goTo(Phase::Roots);
        run(tl, 2.0, kNothing);
        check(tl.phase() == Phase::Roots, "not yet");
        run(tl, 1.0 / 60.0 * 2, kFace);      // two frames of re-detection
        run(tl, 2.5, kNothing);
        check(tl.phase() == Phase::Roots, "the accumulator reset on re-detection");
        run(tl, 1.0, kNothing);
        check(tl.phase() == Phase::Idle, "leaves after a clean 3s absence");
    }

    // --- ceilings, and edge priority on the same frame ----------------------
    {
        Timeline tl;
        tl.setTiming(Phase::Fitting, 0.f, 10.f);
        tl.setHold(Phase::Fitting, 0, 0.f);
        tl.goTo(Phase::Fitting);
        run(tl, 12.0, kFace);
        check(tl.phase() == Phase::Transition,
              "timeout carries a failed fit into transition rather than resetting");

        Timeline tl2;
        tl2.setTiming(Phase::Fitting, 0.f, 10.f);
        tl2.setHold(Phase::Fitting, 0, 0.f);
        tl2.goTo(Phase::Fitting);
        run(tl2, 0.2, kFit);
        check(tl2.phase() == Phase::Transition, "the event beats the ceiling");
    }

    // --- scene_done, and that it bypasses the floor -------------------------
    {
        Timeline tl;
        tl.setTiming(Phase::Transition, 30.f, Graph(Phase::Transition).max_time);
        tl.goTo(Phase::Transition);
        run(tl, 1.0, kNothing);
        check(tl.phase() == Phase::Transition, "still running");
        tl.sceneDone();
        run(tl, 0.1, kNothing);
        check(tl.phase() == Phase::Roots,
              "a finished scene is not held back by the phase floor");
    }

    // --- clear_margin: the ceiling extends past clearance -------------------
    {
        // Before ClothCleared, the graph's own max_time is the safety net.
        Timeline tl;
        tl.goTo(Phase::Transition);
        check(near(tl.maxTime(Phase::Transition), Graph(Phase::Transition).max_time,
                   1e-6f),
              "transition starts with the pre-clearance ceiling");
        run(tl, Graph(Phase::Transition).max_time + 1.0, kNothing);
        check(tl.phase() == Phase::Roots,
              "never-clears still times out at the graph's max_time");

        // Once cleared, the fixed 30s no longer applies -- a hold well past
        // it, ending in SceneDone, is not cut short.
        Timeline tl2;
        Signals cleared; cleared.cloth_cleared = true;
        tl2.goTo(Phase::Transition);
        run(tl2, 5.0, cleared);   // clears at t=5
        run(tl2, Graph(Phase::Transition).max_time - 1.0, kNothing);
        check(tl2.phase() == Phase::Transition,
              "clearance replaces the 30s ceiling -- still running past it");
        tl2.sceneDone();
        run(tl2, 0.1, kNothing);
        check(tl2.phase() == Phase::Roots,
              "and the real edge (SceneDone) still ends it normally");

        // The extended ceiling is still a genuine safety net: if SceneDone
        // never comes even after clearance, clear_margin (45s past the
        // clock clearance was seen) times it out.
        Timeline tl3;
        tl3.goTo(Phase::Transition);
        run(tl3, 5.0, cleared);
        run(tl3, 45.1, cleared);   // 5 + 45.1 > clear_at (5) + clear_margin (45)
        check(tl3.phase() == Phase::Roots,
              "clear_margin itself is a safety net when SceneDone never fires");
    }

    // --- the operator ------------------------------------------------------
    {
        Timeline tl;
        tl.setTiming(Phase::Idle, 600.f, Graph(Phase::Idle).max_time);
        run(tl, 1.0, kNothing);
        tl.go();
        check(tl.phase() == Phase::Fitting, "go takes the forward edge past the floor");
        tl.go();
        check(tl.phase() == Phase::Transition, "and means the same thing everywhere");

        const unsigned e0 = tl.entries();
        run(tl, 0.5, kNothing);
        check(tl.entries() == e0, "no entry without a transition");
        tl.goTo(Phase::Roots);
        check(tl.entries() == e0 + 1, "goTo counts as an entry");
        check(tl.phaseTime() == 0.0, "and resets the clock");
    }

    if (failures == 0) std::printf("show_timeline_test: OK\n");
    else std::printf("show_timeline_test: %d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
