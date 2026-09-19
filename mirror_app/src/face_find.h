// face_find — a cheap face *detector* on the full-size frame, ahead of the
// landmarker.
//
// MediaPipe's face landmarker finds the face itself, but on its own input
// shrunk to a couple of hundred pixels: a visitor at the far side of a
// 1920-wide sensor is a dozen pixels of face there and is never found. So
// the full-resolution frame goes to Apple's Vision face-rectangle request
// first (Neural Engine, a few ms, finds small faces), and the landmarker is
// handed a crop of the full-resolution frame around what it found -- a face
// filling its input, whatever the room. See main.mm's tracking block.
#pragma once

#include <vector>

namespace mirror {

// A face's box, normalised to the frame it was found in, top-left origin.
struct FaceBox {
    float x = 0, y = 0, w = 0, h = 0;   // left, top, size
    float confidence = 0.f;
};

class FaceFinder {
public:
    FaceFinder();
    ~FaceFinder();
    // Every face in an 8-bit interleaved frame: `bytes_per_px` 3 (RGB) or 4
    // (BGRX, the Kinect's colour frame). Which one to follow is the caller's
    // call (main.mm keeps the one it had). False when none.
    bool find(const unsigned char* data, int w, int h, int bytes_per_px,
              std::vector<FaceBox>& out);
    // The last call's cost, ms.
    double lastMs() const { return last_ms_; }
private:
    struct Impl;
    Impl* impl_ = nullptr;
    double last_ms_ = 0.0;
};

}  // namespace mirror
