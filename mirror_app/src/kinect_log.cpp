#include "kinect_log.h"

#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <mutex>

#include <sys/stat.h>

namespace mirror::kinectlog {

namespace {

std::string LogPath() {
    const char* home = getenv("HOME");
    return std::string(home ? home : "") + "/Library/Logs/mirror_app/kinect.log";
}

std::string Timestamp() {
    const time_t t = time(nullptr);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmv);
    return buf;
}

// Runs once: makes sure the log directory exists, and starts a fresh file if
// the existing one has grown past 5 MB. No rotation beyond that -- an
// install that fills 5 MB of Kinect diagnostics between restarts has bigger
// problems than a lost log tail.
void EnsureReady() {
    static std::once_flag once;
    std::call_once(once, [] {
        const std::string path = LogPath();
        const size_t slash = path.rfind('/');
        if (slash != std::string::npos) {
            // Both parents (~/Library/Logs) exist on every Mac; only the
            // mirror_app leaf itself needs making.
            mkdir(path.substr(0, slash).c_str(), 0755);
        }
        struct stat st;
        if (stat(path.c_str(), &st) == 0 &&
            st.st_size > 5 * 1024 * 1024) {
            FILE* f = fopen(path.c_str(), "w");  // truncate
            if (f) fclose(f);
        }
    });
}

}  // namespace

void Log(const std::string& line) {
    const std::string full = "[" + Timestamp() + "] " + line;
    fprintf(stderr, "%s\n", full.c_str());

    EnsureReady();
    FILE* f = fopen(LogPath().c_str(), "a");
    if (!f) return;
    fprintf(f, "%s\n", full.c_str());
    fclose(f);
}

std::string FormatDurationShort(double seconds) {
    if (seconds < 0) seconds = 0;
    const long total = (long)(seconds + 0.5);
    char buf[32];
    if (total >= 3600) {
        snprintf(buf, sizeof(buf), "%ldh%02ldm", total / 3600, (total / 60) % 60);
    } else if (total >= 60) {
        snprintf(buf, sizeof(buf), "%ldm%02lds", total / 60, total % 60);
    } else {
        snprintf(buf, sizeof(buf), "%lds", total);
    }
    return buf;
}

}  // namespace mirror::kinectlog
