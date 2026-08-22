// face_capture — a locked fit, on disk, under a name.
//
// The transition's whole trick is that at one instant the film stops being live
// and becomes a picture, and every vertex of the mask is nailed to the texel it
// was covering at that instant. That pair -- the frozen film and the uv that
// indexes it -- is the person. Everything downstream (the drape, the root
// scene's masks) is a way of showing it.
//
// Before this, the pair only existed in memory, and only for as long as the
// transition was on screen: the film was written to one fixed path that the
// next sitter overwrote, and the uv was recomputed from the live projection
// every frame, which is the same as not locking it at all. So a capture is
// given an id and written as a directory:
//
//     captures/<id>/film.ppm    the frozen film, sRGB P6
//     captures/<id>/mesh.bin    verts + tris + locked uv + baked colours
//     captures/<id>/meta        id, when, sizes -- readable without a decoder
//
// `colors` is the film already sampled at `uv`, per vertex. It is redundant
// with the other two and stored anyway, because the root scene wears the mask
// as vertex colour rather than as a texture (RootScene::setFaceColors), so the
// common case of "load this person onto the masks" is then a read and an
// upload with no resampling and no film in memory at all.

#pragma once

#include <string>
#include <vector>

namespace mirror {

struct FaceCapture {
    std::string id;
    std::string created;              // ISO-ish local time, for the picker

    int filmW = 0, filmH = 0;
    std::vector<unsigned char> film;  // filmW*filmH*3, sRGB-encoded RGB8

    std::vector<float> verts;         // 3/vertex, fitter model units
    std::vector<int>   tris;          // 3/triangle, indices into verts
    std::vector<float> uv;            // 2/vertex, normalised film coords, y-down
    std::vector<float> colors;        // 3/vertex, [0,1], film sampled at uv

    bool valid() const {
        return !verts.empty() && !tris.empty() && uv.size() * 3 == verts.size() * 2;
    }
    size_t vertexCount() const { return verts.size() / 3; }
};

// Where captures live: a sibling of presets/, in the source tree, for the same
// reason presets are -- an installation is edited where it is checked out.
std::string CaptureDir();

// A fresh id: local date-time to the second, plus a two-digit disambiguator if
// that second is already taken. Sorts chronologically as a string, which is
// what the picker wants, and says when it was taken without opening anything.
std::string NewCaptureId();

// Ids on disk, oldest first.
std::vector<std::string> ListCaptures();

bool SaveCapture(const FaceCapture& c, std::string& err);
bool LoadCapture(const std::string& id, FaceCapture& c, std::string& err);
bool DeleteCapture(const std::string& id, std::string& err);

// Bilinear sample of `film` at every uv, into 3 floats/vertex. Clamped at the
// edges, the way every other sampler here is: a vertex whose projection lands
// outside the film takes the nearest pixel rather than black.
void BakeCaptureColors(FaceCapture& c);

}  // namespace mirror
