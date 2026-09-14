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
// Pose is applied as a delta from the recording's own mean rotation, not
// absolute: the anchor mask is squared to whatever head tilt the fitter had
// at the instant the sequence left Face (main.mm's onLeaveFace/
// squareAnchorMaskOnLeavingFace, the same rule autoCaptureAtCut uses for a
// saved capture), so the nest the sim grew is square to *that* orientation,
// not to identity. Replaying a frame's raw rot would fight it -- the mask
// would sit askew in its nest by however far that frame's head turn was from
// the frozen one. Instead each frame's rotation is composed with the
// inverse of the track's own mean rotation (begin() computes it once), so
// played back it oscillates *around* identity -- aligned with the squared
// neutral -- rather than around wherever the head happened to be pointed
// through the recording.
//
// Usage: begin() once per entry into the phase, with whatever track belongs
// to the visitor now on the masks (empty/invalid tracks are fine -- valid()
// then reads false and step() is a no-op, leaving the masks exactly as
// whatever else drove them). step() once per rendered frame after that,
// alongside RootSequence::step() -- same phaseTime()/dt convention.
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
        if (valid_) computeMeanRot();
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
        // Delta from the recording's own mean pose, not the frame's raw
        // (absolute) rotation -- see the class comment. rot' = frame.rot *
        // meanRot^T: identity when frame.rot == meanRot_, so a frame at
        // exactly the mean pose reconstructs unrotated, aligned with the
        // squared neutral the mask's nest was grown against.
        float delta[9];
        MatMulTranspose(frame.rot, meanRot_, delta);
        mirror::RotateAboutCentroid(verts_, delta);

        roots.setFittedFace(verts_, uploadedTris_ ? std::vector<int>() : basis_->triangles());
        uploadedTris_ = true;
    }

    bool valid() const { return valid_; }

private:
    // out = a * transpose(b), row-major 3x3 rotations.
    static void MatMulTranspose(const float a[9], const float b[9], float out[9]) {
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j) {
                float s = 0.f;
                for (int k = 0; k < 3; ++k) s += a[i * 3 + k] * b[j * 3 + k];
                out[i * 3 + j] = s;
            }
    }

    // Nearest proper rotation to the element-wise mean of every recorded
    // frame's rotation: a linear average of nearby rotations is not itself
    // orthonormal, so this re-derives a right-handed orthonormal frame from
    // it (Gram-Schmidt on the first two rows, the third as their cross
    // product rather than its own projection, which is what guarantees
    // det = +1 -- a proper rotation, not just an orthonormal one). Head pose
    // across one sitting varies gently enough that this is a good enough
    // "mean" without a real SO(3) average (which would need an eigen
    // decomposition this file has no reason to carry).
    void computeMeanRot() {
        float m[9] = {0};
        for (const mirror::FaceTrackFrame& f : track_.frames)
            for (int i = 0; i < 9; ++i) m[i] += f.rot[i];
        const float n = float(std::max<size_t>(1, track_.frames.size()));
        for (int i = 0; i < 9; ++i) m[i] /= n;

        auto dot3 = [](const float* a, const float* b) {
            return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
        };
        auto norm3 = [&](float* v) {
            const float len = std::sqrt(dot3(v, v));
            if (len > 1e-8f) { v[0] /= len; v[1] /= len; v[2] /= len; }
        };
        float* r0 = &m[0];
        float* r1 = &m[3];
        norm3(r0);
        const float d = dot3(r1, r0);
        r1[0] -= d * r0[0]; r1[1] -= d * r0[1]; r1[2] -= d * r0[2];
        norm3(r1);
        // r2 = r0 x r1, not a projection of the mean's own third row: this is
        // what keeps the result a proper (det +1) rotation.
        meanRot_[0] = r0[0]; meanRot_[1] = r0[1]; meanRot_[2] = r0[2];
        meanRot_[3] = r1[0]; meanRot_[4] = r1[1]; meanRot_[5] = r1[2];
        meanRot_[6] = r0[1] * r1[2] - r0[2] * r1[1];
        meanRot_[7] = r0[2] * r1[0] - r0[0] * r1[2];
        meanRot_[8] = r0[0] * r1[1] - r0[1] * r1[0];
    }

    mirror::FaceTrack track_;
    const mirror::FaceBasis* basis_ = nullptr;
    bool valid_ = false;
    bool uploadedTris_ = false;
    std::vector<float> verts_;
    float meanRot_[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
};
