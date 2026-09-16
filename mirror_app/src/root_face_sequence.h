// RootFaceSequence — the visitor's own transition-time head movement,
// played back on the root scene's masks.
//
// Roots today shows a static face: either the single frozen instant a
// FaceCapture carries, or whatever the live tracker currently sees (usually
// not the same visitor any more). A FaceTrack (face_track.h) is the
// alternative -- the head pose and expression stream recorded while the
// visitor was still in front of the sensor, during Transition. This plays
// that stream back, looped, so the face on the masks keeps moving after the
// visitor has left. Mask 0 (RootFaceSequence) only plays through the
// sequence's mouth-open ramp and then holds, jaw open, for the rest of the
// sitting; the bank's masks (BankFacePlayback) keep moving.
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
// alongside RootSequence::step() -- same phaseTime()/dt convention. reset()
// at every Transition entry: a sequence left valid from the last sitting
// would otherwise keep stepping the previous visitor's recording onto mask
// 0 through the next visitor's whole Face stage, over the live fit.
//
// The bank's masks get the same treatment through BankFacePlayback (below):
// one FaceTrackPlayer per bank capture that has a track.bin, sampled and
// handed to RootScene::setBankFaceVerts, so every face in the hood moves the
// way its own sitter did rather than holding one frozen instant.
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

// One track, sampled: the ping-pong loop, the nearest-frame pick, the
// delta-from-mean rotation and the jaw override, producing a mesh in the
// fitter's model units. RootFaceSequence and BankFacePlayback are the two
// sinks (mask 0's setFittedFace, the bank's setBankFaceVerts).
class FaceTrackPlayer {
public:
    void begin(const mirror::FaceTrack& track, const mirror::FaceBasis& basis) {
        track_ = track;
        basis_ = &basis;
        valid_ = track_.valid() && basis_->valid();
        if (valid_) {
            computeMeanRot();
            // neutral + identity once; each frame only lays its expression
            // over this (FaceBasis::addExpression) -- see reconstructIdentity.
            basis_->reconstructIdentity(track_.alpha, identityBase_);
        }
        // Which mode the forced jaw-open (mouthOpenTarget below) drives --
        // see face_basis.h's jawOpenModeIndex. Looked up once per sitting
        // rather than logged here: main.mm logs the choice once at startup,
        // against the same basis.
        jawIdx_ = valid_ ? mirror::jawOpenModeIndex(*basis_) : -1;
    }
    void reset() { valid_ = false; track_ = mirror::FaceTrack{}; }

    // `mouthOpenTarget` is RootSequence::mouthOpenRamp(...) * mouth_open_amount
    // for this frame, precomputed by the caller (main.mm) -- this class does
    // not know about RootSequenceParams. Applied as
    // expr[jawOpen] = max(recorded, mouthOpenTarget): raises the jaw, never
    // clamps it, so a visitor caught mid-word on the recording still reads.
    // False (verts untouched) when there is nothing to play.
    bool sample(double phaseTime, float mouthOpenTarget, std::vector<float>& verts) {
        if (!valid_) return false;

        const double dur = double(track_.duration());
        if (dur <= 0.0) return false;
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

        // Copy-and-raise, not a mutation of the recorded frame: the track on
        // disk stays the visitor's own, untouched, recording.
        if (jawIdx_ >= 0 && mouthOpenTarget > 0.f) {
            exprScratch_ = frame.expr;
            if ((int)exprScratch_.size() <= jawIdx_) exprScratch_.resize(size_t(jawIdx_) + 1, 0.f);
            exprScratch_[size_t(jawIdx_)] = std::max(exprScratch_[size_t(jawIdx_)], mouthOpenTarget);
            basis_->addExpression(identityBase_, exprScratch_, verts);
        } else {
            basis_->addExpression(identityBase_, frame.expr, verts);
        }
        // Delta from the recording's own mean pose, not the frame's raw
        // (absolute) rotation -- see the file comment. rot' = frame.rot *
        // meanRot^T: identity when frame.rot == meanRot_, so a frame at
        // exactly the mean pose reconstructs unrotated, aligned with the
        // squared neutral the mask's nest was grown against.
        float delta[9];
        MatMulTranspose(frame.rot, meanRot_, delta);
        mirror::RotateAboutCentroid(verts, delta);
        return true;
    }

    bool valid() const { return valid_; }
    float duration() const { return track_.duration(); }

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
    std::vector<float> identityBase_;   // neutral + identity, once per begin()
    float meanRot_[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    int jawIdx_ = -1;                 // see begin()/jawOpenModeIndex
    std::vector<float> exprScratch_;   // scratch for the forced-open copy, see sample()
};

// Mask 0: the sitting that just came through Transition, replayed on the
// anchor through setFittedFace (which only ever touches mask 0).
class RootFaceSequence {
public:
    void begin(const mirror::FaceTrack& track, const mirror::FaceBasis& basis) {
        player_.begin(track, basis);
        basis_ = &basis;
        uploadedTris_ = false;
        held_ = false;
    }
    // Back to "nothing to play", so the live tracker drives mask 0 again.
    void reset() { player_.reset(); }

    // `mouthOpen` is the sequence's ramp having reached full: the mask is
    // sampled one last time, jaw open, and then holds that frame for the
    // rest of the sitting -- the roots leave a face the visitor has left,
    // not one still moving. The replay only ever runs through the ramp.
    void step(RootScene& roots, double phaseTime, double dt, float mouthOpenTarget = 0.f,
              bool mouthOpen = false) {
        (void)dt;
        if (held_) return;
        if (!player_.sample(phaseTime, mouthOpenTarget, verts_)) return;
        roots.setFittedFace(verts_, uploadedTris_ ? std::vector<int>() : basis_->triangles());
        uploadedTris_ = true;
        held_ = mouthOpen;
    }

    bool valid() const { return player_.valid(); }

private:
    FaceTrackPlayer player_;
    const mirror::FaceBasis* basis_ = nullptr;
    bool uploadedTris_ = false;
    bool held_ = false;
    std::vector<float> verts_;
};

// The bank's masks: one player per bank capture (index-parallel to the
// `bank` main.mm handed RootScene::assignBankFaces, so tracks[i] belongs to
// bankFaces_[i]), each sampled and handed to setBankFaceVerts. Only the
// faces RootScene reports as drawn *and lit* this frame are sampled
// (drawnBankFaces): a hood of a dozen structures wears getting on for
// eighty faces, and an expression pass over 2056 verts each, every frame,
// is real CPU -- so on top of that each face is refreshed every kStride
// frames, staggered, which at 60 fps is 20 Hz sample-and-hold on a head
// that turns over seconds. A face's own phase is offset by its index so a
// wall of them does not nod in unison.
class BankFacePlayback {
public:
    static constexpr int kStride = 3;

    void begin(const std::vector<mirror::FaceTrack>& tracks, const mirror::FaceBasis& basis) {
        players_.clear();
        players_.resize(tracks.size());
        for (size_t i = 0; i < tracks.size(); ++i) players_[i].begin(tracks[i], basis);
        frame_ = 0;
    }
    void reset() { players_.clear(); }

    void step(RootScene& roots, double phaseTime, double dt) {
        (void)dt;
        if (players_.empty()) return;
        roots.drawnBankFaces(drawn_);
        ++frame_;
        for (size_t i = 0; i < players_.size() && i < drawn_.size(); ++i) {
            if (!drawn_[i] || !players_[i].valid()) continue;
            if ((frame_ + int(i)) % kStride != 0) continue;
            if (!players_[i].sample(phaseTime + double(i) * 1.7, 0.f, verts_)) continue;
            roots.setBankFaceVerts(int(i), verts_);
        }
    }

    int playing() const {
        int n = 0;
        for (const auto& p : players_) n += p.valid() ? 1 : 0;
        return n;
    }

private:
    std::vector<FaceTrackPlayer> players_;
    std::vector<char> drawn_;
    std::vector<float> verts_;
    int frame_ = 0;
};
