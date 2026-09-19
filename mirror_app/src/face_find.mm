// face_find.mm — see face_find.h. Vision's VNDetectFaceRectanglesRequest
// over a CVPixelBuffer wrapped around the caller's bytes (no copy).
#include "face_find.h"

#import <Vision/Vision.h>
#import <CoreVideo/CoreVideo.h>

#include <chrono>

namespace mirror {

struct FaceFinder::Impl {
    VNDetectFaceRectanglesRequest* request = nil;
};

FaceFinder::FaceFinder() : impl_(new Impl) {
    impl_->request = [[VNDetectFaceRectanglesRequest alloc] init];
}

FaceFinder::~FaceFinder() {
    impl_->request = nil;
    delete impl_;
}

bool FaceFinder::find(const unsigned char* data, int w, int h, int bytes_per_px,
                      std::vector<FaceBox>& out) {
    out.clear();
    if (!data || w <= 0 || h <= 0) return false;
    const auto t0 = std::chrono::steady_clock::now();
    bool found = false;
    @autoreleasepool {
        OSType fmt;
        if (bytes_per_px == 4) fmt = kCVPixelFormatType_32BGRA;
        else if (bytes_per_px == 3) fmt = kCVPixelFormatType_24RGB;
        else return false;
        CVPixelBufferRef pb = nullptr;
        // Wrapped, not copied: the frame outlives the request (it runs
        // synchronously here) and Vision reads it in place.
        if (CVPixelBufferCreateWithBytes(kCFAllocatorDefault, (size_t)w, (size_t)h, fmt,
                                         (void*)data, (size_t)w * bytes_per_px,
                                         nullptr, nullptr, nullptr, &pb) != kCVReturnSuccess || !pb)
            return false;
        VNImageRequestHandler* handler =
            [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
        NSError* err = nil;
        if ([handler performRequests:@[impl_->request] error:&err]) {
            for (VNFaceObservation* o in impl_->request.results) {
                // Vision's boxes are bottom-left origin; the frame is top-left.
                const CGRect b = o.boundingBox;
                FaceBox f;
                f.x = (float)b.origin.x;
                f.y = (float)(1.0 - b.origin.y - b.size.height);
                f.w = (float)b.size.width;
                f.h = (float)b.size.height;
                f.confidence = o.confidence;
                out.push_back(f);
            }
            found = !out.empty();
        }
        CVPixelBufferRelease(pb);
    }
    last_ms_ = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - t0).count();
    return found;
}

}  // namespace mirror
