// root_structure — the plant a sitting grew, on disk, under the same id as
// its face_capture and face_track.
//
// The hood of other structures Reveal stands around the live plant used to be
// "variations": throwaway RootSim runs at seed+1..seed+K, the *parameters'*
// plants rather than anybody's. This is the alternative -- the geometry the
// live sim actually produced for one visitor (nodes, segments, radii, in the
// same anchor-at-origin render space every variation already used) plus the
// planned mask layout it grew through, kept once the growth is done. Dealt
// back out later (RootScene::setBankPlants), structure k of the hood is the
// plant of the very sitting whose face is on its mask 0, so the piece really
// is made of previous visitors.
//
//     captures/<id>/roots.bin    counts, then nodes, segs, radii, masks
//
// Independent of the capture and the track under the same directory: a
// capture with no roots.bin (from before this feature, or a sitting that
// never finished Grow) simply falls back to a seeded variation --
// LoadRootStructure returns false with err empty for that, an error string
// only when the file exists and is unreadable.

#pragma once

#include <string>
#include <vector>

#include "root_sim.h"   // rootsim::SimMask, a POD

namespace mirror {

struct RootStructure {
    std::string id;
    std::vector<float> nodes;               // 3/node, render space
    std::vector<int>   segs;                // 2/segment, indices into nodes
    std::vector<float> radii;               // 1/segment
    std::vector<rootsim::SimMask> masks;    // the planned layout, mask 0 first

    bool valid() const {
        return nodes.size() >= 6 && segs.size() >= 2 && radii.size() * 2 == segs.size() &&
               !masks.empty();
    }
    size_t nodeCount() const { return nodes.size() / 3; }
};

bool SaveRootStructure(const RootStructure& s, std::string& err);
// False with err empty if roots.bin does not exist for this id; an error
// string if it exists but is not a root structure or is truncated.
bool LoadRootStructure(const std::string& id, RootStructure& s, std::string& err);

}  // namespace mirror
