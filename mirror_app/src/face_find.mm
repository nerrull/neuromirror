// face_find.mm — see face_find.h. Vision's VNDetectFaceRectanglesRequest
// over a CVPixelBuffer wrapped around the caller's bytes (no copy).
#include "face_find.h"

#import <Vision/Vision.h>
#import <CoreVideo/CoreVideo.h>

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace mirror {

struct FaceFinder::Impl {
    VNDetectFaceRectanglesRequest* request = nil;

    // The worker (submit/take). `job` is the frame handed over, `result`
    // the boxes it produced; `busy` while the worker holds the job.
    std::thread worker;
    std::mutex m;
    std::condition_variable cv;
    bool quit = false, busy = false, have_job = false, have_result = false;
    std::vector<unsigned char> job;
    int job_w = 0, job_h = 0, job_bpp = 0;
    std::vector<FaceBox> result;
    bool result_found = false;
    double result_ms = 0.0;
};

FaceFinder::FaceFinder() : impl_(new Impl) {
    impl_->request = [[VNDetectFaceRectanglesRequest alloc] init];
}

FaceFinder::~FaceFinder() {
    {
        std::lock_guard<std::mutex> lk(impl_->m);
        impl_->quit = true;
    }
    impl_->cv.notify_all();
    if (impl_->worker.joinable()) impl_->worker.join();
    impl_->request = nil;
    delete impl_;
}

bool FaceFinder::submit(const unsigned char* data, int w, int h, int bytes_per_px) {
    if (!data || w <= 0 || h <= 0) return false;
    Impl& I = *impl_;
    std::unique_lock<std::mutex> lk(I.m);
    if (I.busy || I.have_job) return false;
    I.job.assign(data, data + size_t(w) * h * bytes_per_px);
    I.job_w = w; I.job_h = h; I.job_bpp = bytes_per_px;
    I.have_job = true;
    if (!I.worker.joinable()) {
        I.worker = std::thread([this] {
            Impl& I = *impl_;
            std::vector<unsigned char> frame;
            std::vector<FaceBox> boxes;
            for (;;) {
                int w, h, bpp;
                {
                    std::unique_lock<std::mutex> lk(I.m);
                    I.cv.wait(lk, [&] { return I.quit || I.have_job; });
                    if (I.quit) return;
                    frame.swap(I.job);
                    w = I.job_w; h = I.job_h; bpp = I.job_bpp;
                    I.have_job = false;
                    I.busy = true;
                }
                const bool found = find(frame.data(), w, h, bpp, boxes);
                {
                    std::lock_guard<std::mutex> lk(I.m);
                    I.result = boxes;
                    I.result_found = found;
                    I.result_ms = last_ms_;
                    I.have_result = true;
                    I.busy = false;
                }
            }
        });
    }
    lk.unlock();
    I.cv.notify_one();
    return true;
}

bool FaceFinder::take(std::vector<FaceBox>& out, bool& found) {
    Impl& I = *impl_;
    std::lock_guard<std::mutex> lk(I.m);
    if (!I.have_result) return false;
    out = I.result;
    found = I.result_found;
    last_ms_ = I.result_ms;
    I.have_result = false;
    return true;
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
