// RootFaceSequence — the visitor's own transition-time head movement,
// played back on the root scene's masks.
//
// Roots today shows a static face: either the single frozen instant a
// FaceCapture carries, or whatever the live tracker currently sees (usually
// not the same visitor any more). A FaceTrack (face_track.h) is the
// alternative -- the head pose and expression stream recorded while the
// visitor was still in front of the sensor, during Transition. This plays
// that stream back, looped, so the face on the masks keeps moving after the
// visitor has left.
//
// The loop is a ping-pong (forward, then backward, then forward again)
// rather than a jump back to frame 0: exactly continuous at the turn-around
// with no blending needed, since velocity simply reverses instead of
// snapping. Playback is sample-and-hold, not interpolated -- the track was
// recorded at app frame rate, so picking the nearest frame produces no
// visible stepping, and it sidesteps having to re-orthonormalize a lerped
// rotation matrix.
//
// Usage: begin() once per entry into the phase, with whatever track belongs
// to the visitor now on the masks (empty/invalid tracks are fine -- valid()
// then reads false and step() is a no-op, leaving the masks exactly as
// whatever else drove them). step() once per rendered frame after that,
// alongside RootCameraSequence::step() -- same phaseTime()/dt convention.
#pragma once
#ifndef __OBJC__
#error "root_face_sequence.h is ObjC++ only"
#endif

#include "face_basis.h"
#include "face_fit.h"
#include "face_track.h"
#include "root_scene.h"

#include <algorithm>
#include <cmath>
#include <vector>

class RootFaceSequence {
public:
    void begin(const mirror::FaceTrack& track, const mirror::FaceBasis& basis) {
        track_ = track;
        basis_ = &basis;
        uploadedTris_ = false;
        valid_ = track_.valid() && basis_->valid();
    }

    void step(RootScene& roots, double phaseTime, double dt) {
        (void)dt;
        if (!valid_) return;

        const double dur = double(track_.duration());
        if (dur <= 0.0) return;
        const double period = 2.0 * dur;
        double m = std::fmod(phaseTime, period);
        if (m < 0.0) m += period;
        const double localT = (m <= dur) ? m : (period - m);

        // Nearest frame by time, via binary search on the sorted t's.
        const auto& frames = track_.frames;
        size_t lo = 0, hi = frames.size() - 1;
        while (lo < hi) {
            const size_t mid = lo + (hi - lo) / 2;
            if (double(frames[mid].t) < localT) lo = mid + 1; else hi = mid;
        }
        if (lo > 0 && std::abs(double(frames[lo - 1].t) - localT) <
                          std::abs(double(frames[lo].t) - localT))
            --lo;
        const mirror::FaceTrackFrame& frame = frames[lo];

        basis_->reconstruct(track_.alpha, frame.expr, verts_);
        mirror::RotateAboutCentroid(verts_, frame.rot);

        roots.setFittedFace(verts_, uploadedTris_ ? std::vector<int>() : basis_->triangles());
        uploadedTris_ = true;
    }

    bool valid() const { return valid_; }

private:
    mirror::FaceTrack track_;
    const mirror::FaceBasis* basis_ = nullptr;
    bool valid_ = false;
    bool uploadedTris_ = false;
    std::vector<float> verts_;
};
