// face_track — the visitor's head movement and expression during the
// transition, on disk, under the same id as their face_capture.
//
// A FaceCapture is one instant: the mesh at the moment the film locked. The
// transition runs for several seconds before that instant, and the whole
// time the fitted mesh is being recomputed every frame and thrown away (see
// main.mm's Transition render branch) -- the head keeps turning, the
// expression keeps changing, and none of it survives past the frame it was
// drawn in. A FaceTrack is that stream, kept: not the raw mesh (which would
// duplicate the identity shape every frame for nothing), but the two things
// that actually change frame to frame -- expression weights and head
// rotation -- plus the identity coefficients once, since those are fit only
// once per visitor and held fixed for the whole sitting. Replayed later
// (root_face_sequence.h), the identity + expression + rotation triple
// reconstructs the same mesh FaceFitter::update() would have produced.
//
//     captures/<id>/track.bin    alpha once, then {t, expr, rot} per frame
//
// A capture and its track are independent files under the same directory:
// an old capture with no track.bin still loads fine (LoadFaceTrack returns
// false, not an error the caller need surface), and a track is meaningless
// without the capture's mesh/film/colours next to it.

#pragma once

#include <string>
#include <vector>

namespace mirror {

class FaceFitter;

struct FaceTrackFrame {
    float t = 0.f;                // seconds since Transition entry
    std::vector<float> expr;      // basis().expressionModes() floats
    float rot[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};   // row-major 3x3
};

struct FaceTrack {
    std::string id;
    std::vector<float> alpha;              // identity coeffs, fit once
    std::vector<FaceTrackFrame> frames;    // time-ordered; frames.back().t is the duration

    bool valid() const { return frames.size() >= 2; }
    float duration() const { return frames.empty() ? 0.f : frames.back().t; }
};

bool SaveFaceTrack(const FaceTrack& t, std::string& err);
// False (with err left empty) if track.bin simply doesn't exist for this id
// -- that's the ordinary case for a capture made before this feature, or
// one where the visitor never produced a usable fit during Transition -- and
// an actual error string if the file exists but is unreadable/corrupt.
bool LoadFaceTrack(const std::string& id, FaceTrack& t, std::string& err);

// Accumulates frames across a whole sitting: begin() at Transition entry,
// record() once per frame a valid fit exists -- through the rest of
// Transition and into Roots, for as long as the same visitor is still
// tracked -- and finish() once they've been continuously absent for the
// same debounce show::Timeline itself uses to decide "the visitor has left"
// (see main.mm's g_track_absent_t). This is deliberately decoupled from
// buildCapture()'s single-instant FaceCapture snapshot, which still fires at
// the press-start lock instant, near the very beginning of the sitting.
class FaceTrackRecorder {
public:
    void begin() { frames_.clear(); }
    void record(double t, const FaceFitter& fitter);
    // Moves the accumulated frames (and the fitter's current identity) into
    // `out`. False, leaving `out` untouched, if fewer than two frames were
    // recorded -- a track needs at least a start and an end to play back.
    bool finish(const FaceFitter& fitter, FaceTrack& out);
    // Frames recorded so far this sitting.
    size_t frames() const { return frames_.size(); }

private:
    std::vector<FaceTrackFrame> frames_;
};

}  // namespace mirror
