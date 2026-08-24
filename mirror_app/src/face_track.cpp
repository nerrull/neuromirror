#include "face_track.h"

#include <sys/stat.h>

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "face_capture.h"   // CaptureDir(), the same id-safety rule
#include "face_fit.h"

namespace mirror {

namespace {

std::string Dir(const std::string& id) { return CaptureDir() + "/" + id; }

// Mirrors face_capture.cpp's SafeId() -- an id is a directory name and goes
// straight into a path.
bool SafeId(const std::string& id) {
    if (id.empty() || id.size() > 64) return false;
    for (char ch : id)
        if (!(std::isalnum((unsigned char)ch) || ch == '-' || ch == '_')) return false;
    return true;
}

constexpr char kMagic[4] = {'M', 'F', 'T', '1'};

bool WriteVec(FILE* f, const void* p, size_t bytes) {
    return bytes == 0 || fwrite(p, 1, bytes, f) == bytes;
}
bool ReadVec(FILE* f, void* p, size_t bytes) {
    return bytes == 0 || fread(p, 1, bytes, f) == bytes;
}

}  // namespace

void FaceTrackRecorder::record(double t, const FaceFitter& fitter) {
    if (!fitter.valid()) return;
    FaceTrackFrame f;
    f.t = float(t);
    f.expr = fitter.expression();
    std::memcpy(f.rot, fitter.rotation(), sizeof f.rot);
    frames_.push_back(std::move(f));
}

bool FaceTrackRecorder::finish(const FaceFitter& fitter, FaceTrack& out) {
    if (frames_.size() < 2) return false;
    out.alpha = fitter.alpha();
    out.frames = std::move(frames_);
    frames_.clear();
    return true;
}

bool SaveFaceTrack(const FaceTrack& t, std::string& err) {
    if (!SafeId(t.id)) { err = "bad track id"; return false; }
    if (!t.valid())    { err = "track has fewer than two frames"; return false; }
    const size_t n_expr = t.frames.front().expr.size();

    FILE* f = fopen((Dir(t.id) + "/track.bin").c_str(), "wb");
    if (!f) { err = "cannot write track.bin"; return false; }

    const uint32_t na = uint32_t(t.alpha.size());
    const uint32_t ne = uint32_t(n_expr);
    const uint32_t nf = uint32_t(t.frames.size());
    bool ok = WriteVec(f, kMagic, 4) && WriteVec(f, &na, 4) && WriteVec(f, &ne, 4) &&
              WriteVec(f, &nf, 4) &&
              WriteVec(f, t.alpha.data(), t.alpha.size() * sizeof(float));
    for (const auto& frame : t.frames) {
        if (!ok) break;
        // A track with per-frame expression vectors of varying length would
        // be unplayable (nothing downstream re-checks per frame), so it's
        // caught here rather than trusted.
        if (frame.expr.size() != n_expr) { ok = false; break; }
        ok = WriteVec(f, &frame.t, sizeof frame.t) &&
             WriteVec(f, frame.expr.data(), frame.expr.size() * sizeof(float)) &&
             WriteVec(f, frame.rot, sizeof frame.rot);
    }
    fclose(f);
    if (!ok) { err = "short write on track.bin"; return false; }
    return true;
}

bool LoadFaceTrack(const std::string& id, FaceTrack& t, std::string& err) {
    err.clear();
    if (!SafeId(id)) return false;
    const std::string path = Dir(id) + "/track.bin";

    struct stat st;
    if (stat(path.c_str(), &st) != 0) return false;   // no track for this id -- not an error

    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    char magic[4];
    uint32_t na = 0, ne = 0, nf = 0;
    if (!ReadVec(f, magic, 4) || std::memcmp(magic, kMagic, 4) != 0 ||
        !ReadVec(f, &na, 4) || !ReadVec(f, &ne, 4) || !ReadVec(f, &nf, 4)) {
        fclose(f);
        err = id + ": track.bin is not a face track";
        return false;
    }
    FaceTrack out;
    out.id = id;
    out.alpha.resize(na);
    bool ok = ReadVec(f, out.alpha.data(), out.alpha.size() * sizeof(float));
    out.frames.resize(nf);
    for (uint32_t i = 0; ok && i < nf; ++i) {
        FaceTrackFrame& frame = out.frames[i];
        frame.expr.resize(ne);
        ok = ReadVec(f, &frame.t, sizeof frame.t) &&
             ReadVec(f, frame.expr.data(), frame.expr.size() * sizeof(float)) &&
             ReadVec(f, frame.rot, sizeof frame.rot);
    }
    fclose(f);
    if (!ok) { err = id + ": track.bin is truncated"; return false; }
    t = std::move(out);
    return true;
}

}  // namespace mirror
