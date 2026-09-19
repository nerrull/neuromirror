#include "face_capture.h"

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>

namespace mirror {

namespace {

bool MkDirP(const std::string& path) {
    if (path.empty()) return false;
    std::string acc;
    size_t i = 0;
    if (path[0] == '/') { acc = "/"; i = 1; }
    while (i <= path.size()) {
        const size_t s = path.find('/', i);
        const std::string part = path.substr(i, s == std::string::npos ? s : s - i);
        if (!part.empty()) {
            acc += part;
            if (mkdir(acc.c_str(), 0755) != 0) {
                struct stat st;
                if (stat(acc.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) return false;
            }
            acc += "/";
        }
        if (s == std::string::npos) break;
        i = s + 1;
    }
    return true;
}

std::string Dir(const std::string& id) { return CaptureDir() + "/" + id; }

// An id is a directory name and goes straight into a path, so it is checked
// rather than trusted: nothing outside CaptureDir() should be reachable by
// naming a capture, however the name got here.
bool SafeId(const std::string& id) {
    if (id.empty() || id.size() > 64) return false;
    for (char ch : id)
        if (!(std::isalnum((unsigned char)ch) || ch == '-' || ch == '_')) return false;
    return true;
}

constexpr char kMagic[4] = {'M', 'F', 'C', '1'};

bool WriteVec(FILE* f, const void* p, size_t bytes) {
    return bytes == 0 || fwrite(p, 1, bytes, f) == bytes;
}
bool ReadVec(FILE* f, void* p, size_t bytes) {
    return bytes == 0 || fread(p, 1, bytes, f) == bytes;
}

bool SavePPM(const std::string& path, int w, int h, const std::vector<unsigned char>& rgb) {
    if (w <= 0 || h <= 0 || rgb.size() != size_t(w) * size_t(h) * 3) return false;
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    const bool ok = WriteVec(f, rgb.data(), rgb.size());
    fclose(f);
    return ok;
}

bool LoadPPM(const std::string& path, int& w, int& h, std::vector<unsigned char>& rgb) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    char magic[3] = {0, 0, 0};
    int maxval = 0;
    if (fscanf(f, "%2s", magic) != 1 || magic[0] != 'P' || magic[1] != '6' ||
        fscanf(f, "%d %d %d", &w, &h, &maxval) != 3 || w <= 0 || h <= 0) {
        fclose(f);
        return false;
    }
    fgetc(f);   // the single whitespace byte after the header
    rgb.resize(size_t(w) * size_t(h) * 3);
    const bool ok = ReadVec(f, rgb.data(), rgb.size());
    fclose(f);
    return ok;
}

}  // namespace

std::string CaptureDir() {
    return std::string(MIRROR_APP_SRC_DIR) + "/../captures";
}

std::string NewCaptureId() {
    std::time_t now = std::time(nullptr);
    std::tm tm{};
    localtime_r(&now, &tm);
    char base[32];
    std::strftime(base, sizeof base, "%Y%m%d-%H%M%S", &tm);
    std::string id = base;
    struct stat st;
    for (int n = 1; n < 100 && stat(Dir(id).c_str(), &st) == 0; ++n) {
        char suffix[8];
        std::snprintf(suffix, sizeof suffix, "-%02d", n);
        id = std::string(base) + suffix;
    }
    return id;
}

std::vector<std::string> ListCaptures() {
    std::vector<std::string> out;
    DIR* d = opendir(CaptureDir().c_str());
    if (!d) return out;
    while (struct dirent* e = readdir(d)) {
        const std::string n = e->d_name;
        if (n == "." || n == ".." || !SafeId(n)) continue;
        struct stat st;
        // A capture is its mesh: a directory with no mesh.bin is a half-written
        // one, and offering it in the picker only produces a failure later.
        if (stat((Dir(n) + "/mesh.bin").c_str(), &st) == 0 && S_ISREG(st.st_mode))
            out.push_back(n);
    }
    closedir(d);
    std::sort(out.begin(), out.end());
    return out;
}

bool SaveCapture(const FaceCapture& c, std::string& err) {
    if (!SafeId(c.id)) { err = "bad capture id"; return false; }
    if (!c.valid())    { err = "capture has no mesh"; return false; }
    const std::string dir = Dir(c.id);
    if (!MkDirP(dir)) { err = "cannot create " + dir; return false; }

    if (c.filmW > 0 && c.filmH > 0 &&
        !SavePPM(dir + "/film.ppm", c.filmW, c.filmH, c.film)) {
        err = "cannot write film.ppm";
        return false;
    }

    FILE* f = fopen((dir + "/mesh.bin").c_str(), "wb");
    if (!f) { err = "cannot write mesh.bin"; return false; }
    const uint32_t nv = uint32_t(c.vertexCount()), ni = uint32_t(c.tris.size());
    const uint32_t nc = uint32_t(c.colors.size() / 3);
    bool ok = WriteVec(f, kMagic, 4) && WriteVec(f, &nv, 4) && WriteVec(f, &ni, 4) &&
              WriteVec(f, &nc, 4) &&
              WriteVec(f, c.verts.data(), c.verts.size() * sizeof(float)) &&
              WriteVec(f, c.uv.data(), c.uv.size() * sizeof(float)) &&
              WriteVec(f, c.colors.data(), c.colors.size() * sizeof(float));
    if (ok) {
        std::vector<int32_t> tris(c.tris.begin(), c.tris.end());
        ok = WriteVec(f, tris.data(), tris.size() * sizeof(int32_t));
    }
    fclose(f);
    if (!ok) { err = "short write on mesh.bin"; return false; }

    if (FILE* m = fopen((dir + "/meta").c_str(), "wb")) {
        // `colours = linear` marks the convention the baked colours are stored
        // in (see BakeCaptureColors); a meta without the line predates it and
        // holds the film's encoded values, which LoadCapture decodes.
        fprintf(m, "id = %s\ncreated = %s\nvertices = %u\ntriangles = %u\nfilm = %dx%d\n"
                   "colours = linear\n",
                c.id.c_str(), c.created.c_str(), nv, ni / 3, c.filmW, c.filmH);
        fclose(m);
    }
    return true;
}

bool LoadCapture(const std::string& id, FaceCapture& c, std::string& err) {
    if (!SafeId(id)) { err = "bad capture id"; return false; }
    const std::string dir = Dir(id);

    FILE* f = fopen((dir + "/mesh.bin").c_str(), "rb");
    if (!f) { err = "no capture " + id; return false; }
    char magic[4];
    uint32_t nv = 0, ni = 0, nc = 0;
    if (!ReadVec(f, magic, 4) || std::memcmp(magic, kMagic, 4) != 0 ||
        !ReadVec(f, &nv, 4) || !ReadVec(f, &ni, 4) || !ReadVec(f, &nc, 4) ||
        nv == 0 || ni == 0 || ni % 3 != 0) {
        fclose(f);
        err = id + ": mesh.bin is not a capture";
        return false;
    }
    c = FaceCapture{};
    c.id = id;
    c.verts.resize(size_t(nv) * 3);
    c.uv.resize(size_t(nv) * 2);
    c.colors.resize(size_t(nc) * 3);
    std::vector<int32_t> tris(ni);
    const bool ok = ReadVec(f, c.verts.data(), c.verts.size() * sizeof(float)) &&
                    ReadVec(f, c.uv.data(), c.uv.size() * sizeof(float)) &&
                    ReadVec(f, c.colors.data(), c.colors.size() * sizeof(float)) &&
                    ReadVec(f, tris.data(), tris.size() * sizeof(int32_t));
    fclose(f);
    if (!ok) { err = id + ": mesh.bin is truncated"; return false; }
    c.tris.assign(tris.begin(), tris.end());
    for (int t : c.tris)
        if (t < 0 || size_t(t) >= size_t(nv)) { err = id + ": mesh.bin index out of range"; return false; }

    // The film is optional: a capture whose colours are already baked is
    // loadable onto the root scene's masks without it, and that is the only
    // consumer that has to work when the mirror is not running.
    LoadPPM(dir + "/film.ppm", c.filmW, c.filmH, c.film);
    if (c.film.size() != size_t(std::max(0, c.filmW)) * size_t(std::max(0, c.filmH)) * 3) {
        c.film.clear();
        c.filmW = c.filmH = 0;
    }
    bool linear = false;
    if (FILE* m = fopen((dir + "/meta").c_str(), "rb")) {
        char line[256];
        while (fgets(line, sizeof line, m)) {
            char v[128];
            if (sscanf(line, "created = %127[^\n]", v) == 1) c.created = v;
            else if (sscanf(line, "colours = %127s", v) == 1) linear = std::strcmp(v, "linear") == 0;
        }
        fclose(m);
    }
    // The colours are linear (what the masks wear, see BakeCaptureColors).
    // A capture from before the meta said so stored the film's own encoded
    // values: re-bake from the film where it is still there, else decode the
    // stored ones in place -- either way the caller sees one convention.
    if (c.colors.size() != c.verts.size() || (!linear && !c.film.empty())) {
        BakeCaptureColors(c);
    } else if (!linear) {
        for (float& v : c.colors) v = std::pow(std::clamp(v, 0.f, 1.f), 2.2f);
    }
    return true;
}

bool DeleteCapture(const std::string& id, std::string& err) {
    if (!SafeId(id)) { err = "bad capture id"; return false; }
    const std::string dir = Dir(id);
    remove((dir + "/film.ppm").c_str());
    remove((dir + "/mesh.bin").c_str());
    remove((dir + "/meta").c_str());
    if (rmdir(dir.c_str()) != 0) { err = "cannot remove " + dir; return false; }
    return true;
}

void BakeCaptureColors(FaceCapture& c) {
    const size_t n = c.vertexCount();
    c.colors.assign(n * 3, 0.5f);
    if (c.filmW <= 0 || c.filmH <= 0 || c.film.empty() || c.uv.size() < n * 2) return;

    const int W = c.filmW, H = c.filmH;
    // Decoded to linear per texel before the bilinear blend: the film is the
    // mirror's linear output encoded with 1/2.2 for 8 bits (freezeFilm /
    // autoCaptureAtCut), and the masks wear these as the same linear values
    // the live path samples straight off the mirror (g_face_colors).
    float lut[256];
    for (int i = 0; i < 256; ++i) lut[i] = std::pow(float(i) / 255.f, 2.2f);
    auto at = [&](int x, int y, int ch) -> float {
        x = std::clamp(x, 0, W - 1);
        y = std::clamp(y, 0, H - 1);
        return lut[c.film[(size_t(y) * size_t(W) + size_t(x)) * 3 + size_t(ch)]];
    };
    for (size_t i = 0; i < n; ++i) {
        const float fx = c.uv[i * 2] * float(W) - 0.5f;
        const float fy = c.uv[i * 2 + 1] * float(H) - 0.5f;
        const int x0 = int(std::floor(fx)), y0 = int(std::floor(fy));
        const float tx = fx - float(x0), ty = fy - float(y0);
        for (int ch = 0; ch < 3; ++ch) {
            const float a = at(x0, y0, ch) * (1 - tx) + at(x0 + 1, y0, ch) * tx;
            const float b = at(x0, y0 + 1, ch) * (1 - tx) + at(x0 + 1, y0 + 1, ch) * tx;
            c.colors[i * 3 + size_t(ch)] = a * (1 - ty) + b * ty;
        }
    }
}

float FaceColorLuma(const std::vector<float>& rgb) {
    const size_t n = rgb.size() / 3;
    if (n == 0) return 0.f;
    double acc = 0.0;
    for (size_t i = 0; i < n; ++i)
        acc += 0.2126 * rgb[i * 3] + 0.7152 * rgb[i * 3 + 1] + 0.0722 * rgb[i * 3 + 2];
    return float(acc / double(n));
}

float FaceLevelGain(float luma, float level) {
    if (level <= 0.f || luma <= 0.f) return 1.f;
    return std::clamp(level / luma, 0.25f, 6.f);
}

float SquareCaptureToNeutral(FaceCapture& c, const std::vector<float>& neutral) {
    const size_t n = c.vertexCount();
    if (n < 3 || neutral.size() != c.verts.size()) return 0.f;
    // Both about their own centroids: the pose is a rotation about the
    // mesh's centroid (RotateAboutCentroid) plus whatever offset the fit
    // carried, and neither is wanted.
    double cv[3] = {0, 0, 0}, cn[3] = {0, 0, 0};
    for (size_t i = 0; i < n; ++i)
        for (int k = 0; k < 3; ++k) { cv[k] += c.verts[i * 3 + k]; cn[k] += neutral[i * 3 + k]; }
    for (int k = 0; k < 3; ++k) { cv[k] /= double(n); cn[k] /= double(n); }

    // R, row-major, starting at the identity; each pass solves the 3x3
    // normal equations for the small rotation w that best reduces
    // sum |R p_i - q_i|^2 (d(R p)/dw = -[R p]x), and composes it on.
    double R[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    for (int pass = 0; pass < 12; ++pass) {
        double A[9] = {0}, b[3] = {0};
        for (size_t i = 0; i < n; ++i) {
            const double p[3] = {c.verts[i * 3] - cv[0], c.verts[i * 3 + 1] - cv[1], c.verts[i * 3 + 2] - cv[2]};
            const double q[3] = {neutral[i * 3] - cn[0], neutral[i * 3 + 1] - cn[1], neutral[i * 3 + 2] - cn[2]};
            double rp[3];
            for (int r = 0; r < 3; ++r) rp[r] = R[r * 3] * p[0] + R[r * 3 + 1] * p[1] + R[r * 3 + 2] * p[2];
            const double res[3] = {rp[0] - q[0], rp[1] - q[1], rp[2] - q[2]};
            // J = -[rp]x:  rows ( 0, rp2, -rp1 ), ( -rp2, 0, rp0 ), ( rp1, -rp0, 0 )
            const double J[9] = {0, rp[2], -rp[1], -rp[2], 0, rp[0], rp[1], -rp[0], 0};
            for (int r = 0; r < 3; ++r)
                for (int s = 0; s < 3; ++s) {
                    for (int t = 0; t < 3; ++t) A[r * 3 + s] += J[t * 3 + r] * J[t * 3 + s];
                }
            for (int r = 0; r < 3; ++r)
                for (int t = 0; t < 3; ++t) b[r] -= J[t * 3 + r] * res[t];
        }
        // Solve A w = b (A symmetric positive definite for any non-degenerate mesh).
        const double det = A[0] * (A[4] * A[8] - A[5] * A[7]) - A[1] * (A[3] * A[8] - A[5] * A[6]) +
                           A[2] * (A[3] * A[7] - A[4] * A[6]);
        if (std::fabs(det) < 1e-12) break;
        const double inv[9] = {
            (A[4] * A[8] - A[5] * A[7]) / det, (A[2] * A[7] - A[1] * A[8]) / det, (A[1] * A[5] - A[2] * A[4]) / det,
            (A[5] * A[6] - A[3] * A[8]) / det, (A[0] * A[8] - A[2] * A[6]) / det, (A[2] * A[3] - A[0] * A[5]) / det,
            (A[3] * A[7] - A[4] * A[6]) / det, (A[1] * A[6] - A[0] * A[7]) / det, (A[0] * A[4] - A[1] * A[3]) / det};
        double w[3];
        for (int r = 0; r < 3; ++r) w[r] = inv[r * 3] * b[0] + inv[r * 3 + 1] * b[1] + inv[r * 3 + 2] * b[2];
        const double th = std::sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]);
        if (th < 1e-9) break;
        // Rodrigues: dR = I + sin(th) K + (1 - cos(th)) K^2, K = [w/th]x.
        const double k[3] = {w[0] / th, w[1] / th, w[2] / th};
        const double sn = std::sin(th), cs = 1.0 - std::cos(th);
        const double K[9] = {0, -k[2], k[1], k[2], 0, -k[0], -k[1], k[0], 0};
        double dR[9];
        for (int r = 0; r < 3; ++r)
            for (int s = 0; s < 3; ++s) {
                double kk = 0;
                for (int t = 0; t < 3; ++t) kk += K[r * 3 + t] * K[t * 3 + s];
                dR[r * 3 + s] = (r == s ? 1.0 : 0.0) + sn * K[r * 3 + s] + cs * kk;
            }
        double Rn[9];
        for (int r = 0; r < 3; ++r)
            for (int s = 0; s < 3; ++s) {
                double acc = 0;
                for (int t = 0; t < 3; ++t) acc += dR[r * 3 + t] * R[t * 3 + s];
                Rn[r * 3 + s] = acc;
            }
        std::copy(Rn, Rn + 9, R);
        if (th < 1e-6) break;
    }
    // The angle of R, and R applied about the capture's own centroid.
    const double tr = std::clamp((R[0] + R[4] + R[8] - 1.0) * 0.5, -1.0, 1.0);
    const float deg = float(std::acos(tr) * 180.0 / M_PI);
    for (size_t i = 0; i < n; ++i) {
        const double p[3] = {c.verts[i * 3] - cv[0], c.verts[i * 3 + 1] - cv[1], c.verts[i * 3 + 2] - cv[2]};
        for (int r = 0; r < 3; ++r)
            c.verts[i * 3 + size_t(r)] = float(R[r * 3] * p[0] + R[r * 3 + 1] * p[1] + R[r * 3 + 2] * p[2] + cv[r]);
    }
    return deg;
}

}  // namespace mirror
