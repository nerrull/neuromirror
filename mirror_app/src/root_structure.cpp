#include "root_structure.h"

#include <sys/stat.h>

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "face_capture.h"   // CaptureDir(), the same id-safety rule

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

constexpr char kMagic[4] = {'M', 'R', 'S', '1'};
// A SimMask is 16 floats, written field by field below so a future padding
// change to the struct cannot silently change the file.
constexpr uint32_t kMaskFloats = 16;

bool WriteVec(FILE* f, const void* p, size_t bytes) {
    return bytes == 0 || fwrite(p, 1, bytes, f) == bytes;
}
bool ReadVec(FILE* f, void* p, size_t bytes) {
    return bytes == 0 || fread(p, 1, bytes, f) == bytes;
}

void PackMask(const rootsim::SimMask& m, float out[kMaskFloats]) {
    for (int c = 0; c < 3; ++c) {
        out[c]     = m.pos[c];
        out[3 + c] = m.normal[c];
        out[6 + c] = m.tangent[c];
        out[9 + c] = m.bitangent[c];
    }
    out[12] = m.rDepth; out[13] = m.rWidth; out[14] = m.rHeight; out[15] = m.faceUnit;
}

void UnpackMask(const float in[kMaskFloats], rootsim::SimMask& m) {
    for (int c = 0; c < 3; ++c) {
        m.pos[c]       = in[c];
        m.normal[c]    = in[3 + c];
        m.tangent[c]   = in[6 + c];
        m.bitangent[c] = in[9 + c];
    }
    m.rDepth = in[12]; m.rWidth = in[13]; m.rHeight = in[14]; m.faceUnit = in[15];
}

}  // namespace

bool SaveRootStructure(const RootStructure& s, std::string& err) {
    if (!SafeId(s.id)) { err = "bad structure id"; return false; }
    if (!s.valid())    { err = "structure is empty"; return false; }
    const size_t nn = s.nodes.size() / 3;
    for (int i : s.segs)
        if (i < 0 || size_t(i) >= nn) { err = "segment index out of range"; return false; }

    FILE* f = fopen((Dir(s.id) + "/roots.bin").c_str(), "wb");
    if (!f) { err = "cannot write roots.bin"; return false; }

    const uint32_t nNodes = uint32_t(nn);
    const uint32_t nSegs  = uint32_t(s.segs.size() / 2);
    const uint32_t nMasks = uint32_t(s.masks.size());
    bool ok = WriteVec(f, kMagic, 4) && WriteVec(f, &nNodes, 4) && WriteVec(f, &nSegs, 4) &&
              WriteVec(f, &nMasks, 4) &&
              WriteVec(f, s.nodes.data(), nn * 3 * sizeof(float)) &&
              WriteVec(f, s.segs.data(), size_t(nSegs) * 2 * sizeof(int)) &&
              WriteVec(f, s.radii.data(), size_t(nSegs) * sizeof(float));
    for (const auto& m : s.masks) {
        if (!ok) break;
        float packed[kMaskFloats];
        PackMask(m, packed);
        ok = WriteVec(f, packed, sizeof packed);
    }
    fclose(f);
    if (!ok) { err = "short write on roots.bin"; return false; }
    return true;
}

bool LoadRootStructure(const std::string& id, RootStructure& s, std::string& err) {
    err.clear();
    if (!SafeId(id)) return false;
    const std::string path = Dir(id) + "/roots.bin";

    struct stat st;
    if (stat(path.c_str(), &st) != 0) return false;   // no plant for this id -- not an error

    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    char magic[4];
    uint32_t nNodes = 0, nSegs = 0, nMasks = 0;
    if (!ReadVec(f, magic, 4) || std::memcmp(magic, kMagic, 4) != 0 ||
        !ReadVec(f, &nNodes, 4) || !ReadVec(f, &nSegs, 4) || !ReadVec(f, &nMasks, 4)) {
        fclose(f);
        err = id + ": roots.bin is not a root structure";
        return false;
    }
    // Sized by the header, so a corrupt header is bounded before it is trusted
    // (the file is at most a few MB; these are node counts, not bytes).
    if (nNodes > (1u << 24) || nSegs > (1u << 24) || nMasks > 4096u) {
        fclose(f);
        err = id + ": roots.bin header is implausible";
        return false;
    }
    RootStructure out;
    out.id = id;
    out.nodes.resize(size_t(nNodes) * 3);
    out.segs.resize(size_t(nSegs) * 2);
    out.radii.resize(size_t(nSegs));
    out.masks.resize(size_t(nMasks));
    bool ok = ReadVec(f, out.nodes.data(), out.nodes.size() * sizeof(float)) &&
              ReadVec(f, out.segs.data(), out.segs.size() * sizeof(int)) &&
              ReadVec(f, out.radii.data(), out.radii.size() * sizeof(float));
    for (uint32_t i = 0; ok && i < nMasks; ++i) {
        float packed[kMaskFloats];
        ok = ReadVec(f, packed, sizeof packed);
        if (ok) UnpackMask(packed, out.masks[i]);
    }
    fclose(f);
    if (!ok) { err = id + ": roots.bin is truncated"; return false; }
    for (int i : out.segs)
        if (i < 0 || uint32_t(i) >= nNodes) { err = id + ": roots.bin has a bad segment"; return false; }
    s = std::move(out);
    return true;
}

}  // namespace mirror
