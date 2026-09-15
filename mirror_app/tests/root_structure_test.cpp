// A sitting's plant, to disk and back (root_structure.h).
//
// The file is what a later hood is built from, so a field that silently
// round-trips wrong (a mask frame axis swapped, radii off by one segment)
// would show up minutes into a later visitor's Reveal as a structure
// leaning the wrong way, not here. Pure I/O -- no sim, no Metal. Writes and
// removes its own entry under captures/.
//
// Exit 0 on pass.

#include "root_structure.h"

#include <sys/stat.h>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "face_capture.h"

namespace {

int g_fail = 0;

void check(bool ok, const char* what) {
    std::printf("  [%s] %s\n", ok ? " ok " : "FAIL", what);
    if (!ok) ++g_fail;
}

mirror::RootStructure sample(const std::string& id) {
    mirror::RootStructure s;
    s.id = id;
    for (int i = 0; i < 40; ++i) {
        s.nodes.push_back(0.1f * i);
        s.nodes.push_back(-0.5f * i);
        s.nodes.push_back(std::sin(0.3f * i));
        if (i > 0) {
            s.segs.push_back(i - 1);
            s.segs.push_back(i);
            s.radii.push_back(0.05f + 0.001f * i);
        }
    }
    for (int m = 0; m < 3; ++m) {
        rootsim::SimMask k;
        for (int c = 0; c < 3; ++c) {
            k.pos[c] = 1.f * m + 0.1f * c;
            k.normal[c] = c == 2 ? 1.f : 0.f;
            k.tangent[c] = c == 0 ? 1.f : 0.f;
            k.bitangent[c] = c == 1 ? 1.f : 0.f;
        }
        k.rDepth = 2.f + m; k.rWidth = 3.f + m; k.rHeight = 4.f + m; k.faceUnit = 5.f + m;
        s.masks.push_back(k);
    }
    return s;
}

}  // namespace

int main() {
    const std::string id = "test-root-structure";
    const std::string dir = mirror::CaptureDir() + "/" + id;
    mkdir(mirror::CaptureDir().c_str(), 0755);
    mkdir(dir.c_str(), 0755);

    std::printf("root_structure_test\n");
    std::string err;
    mirror::RootStructure none;
    check(!mirror::LoadRootStructure(id, none, err) && err.empty(),
          "absent roots.bin loads false with no error");

    const mirror::RootStructure s = sample(id);
    check(s.valid(), "sample is valid");
    check(mirror::SaveRootStructure(s, err), "save");

    mirror::RootStructure r;
    check(mirror::LoadRootStructure(id, r, err), "load");
    check(r.id == id, "id round-trips");
    check(r.nodes == s.nodes, "nodes round-trip");
    check(r.segs == s.segs, "segs round-trip");
    check(r.radii == s.radii, "radii round-trip");
    bool masksOk = r.masks.size() == s.masks.size();
    for (size_t m = 0; masksOk && m < r.masks.size(); ++m) {
        const auto& a = r.masks[m];
        const auto& b = s.masks[m];
        for (int c = 0; c < 3; ++c)
            masksOk = masksOk && a.pos[c] == b.pos[c] && a.normal[c] == b.normal[c] &&
                      a.tangent[c] == b.tangent[c] && a.bitangent[c] == b.bitangent[c];
        masksOk = masksOk && a.rDepth == b.rDepth && a.rWidth == b.rWidth &&
                  a.rHeight == b.rHeight && a.faceUnit == b.faceUnit;
    }
    check(masksOk, "mask frames round-trip field for field");

    // A segment pointing past the nodes is refused on the way out...
    mirror::RootStructure bad = s;
    bad.segs[3] = 999;
    check(!mirror::SaveRootStructure(bad, err), "out-of-range segment refused on save");
    // ...and a truncated file is an error, not a silent partial plant.
    {
        FILE* f = fopen((dir + "/roots.bin").c_str(), "rb+");
        check(f != nullptr, "reopen for truncation");
        if (f) {
            fseek(f, 0, SEEK_END);
            const long len = ftell(f);
            fclose(f);
            check(truncate((dir + "/roots.bin").c_str(), len / 2) == 0, "truncate");
        }
        mirror::RootStructure t;
        check(!mirror::LoadRootStructure(id, t, err) && !err.empty(),
              "truncated roots.bin loads false with an error");
    }

    unlink((dir + "/roots.bin").c_str());
    rmdir(dir.c_str());
    std::printf("%s\n", g_fail ? "FAILED" : "PASS");
    return g_fail ? 1 : 0;
}
