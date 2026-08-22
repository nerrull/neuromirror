#include "transition_scene.h"
#include "metal_context.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

// Front-on camera. The sheet is sized so a *flat* sheet at z=0 exactly fills
// the frustum cross-section, which is what lets the first frame of the effect
// be the pond itself rather than a picture of it.
constexpr float CAM_D = 3.0f;
constexpr float CAM_FOV = 45.0f * float(M_PI) / 180.0f;
// Raking rather than frontal. A light down the view axis puts almost no shading
// gradient on a bulge facing the camera, so the whole press reads as nothing
// happening; from the side the tenting has somewhere to cast. Costs no
// brightness, because f_main normalises the flat-sheet response to 1.
constexpr simd_float4 LIGHT = {0.42f, 0.62f, 0.36f, 0.5f};

// The collider's resolution. The sheet is 72x72 and the mask covers maybe a
// third of the frame, so 160 gives the contact a couple of texels per cloth
// cell across the face -- enough for the nose and the brow to be separate
// features and not enough to be worth optimising.
constexpr int FIELD_RES = 160;

struct Vertex { simd_float3 pos; simd_float3 nrm; simd_float2 uv; };
// Mirrors TransFaceX in transition.metal.
struct TransFaceX {
    simd_float4 centre;
    simd_float4 lightPos;
    float scale;
    float exposure;
    int32_t tonemap;
    float _pad;
};
struct Uniforms {
    simd_float4x4 mvp;
    simd_float4x4 model;
    simd_float4 lightDir;    // xyz dir, w = mode (0 textured, 2 flat colour)
    simd_float4 baseColor;
    simd_float4 params;      // x = refraction of the film by the surface normal
};

float smoothstep01(float x) {
    x = std::clamp(x, 0.f, 1.f);
    return x * x * (3.f - 2.f * x);
}

simd_float4x4 perspective(float fovy, float aspect, float zn, float zf) {
    float f = 1.0f / std::tan(fovy * 0.5f);
    return simd_matrix(simd_make_float4(f / aspect, 0, 0, 0), simd_make_float4(0, f, 0, 0),
                       simd_make_float4(0, 0, zf / (zn - zf), -1),
                       simd_make_float4(0, 0, (zn * zf) / (zn - zf), 0));
}
simd_float4x4 lookAt(simd_float3 eye, simd_float3 c, simd_float3 up) {
    simd_float3 z = simd_normalize(eye - c), x = simd_normalize(simd_cross(up, z)), y = simd_cross(z, x);
    return simd_matrix(simd_make_float4(x.x, y.x, z.x, 0), simd_make_float4(x.y, y.y, z.y, 0),
                       simd_make_float4(x.z, y.z, z.z, 0),
                       simd_make_float4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1));
}
simd_float4x4 frontVP(float aspect) {
    return simd_mul(perspective(CAM_FOV, aspect, 0.05f, 50.0f),
                    lookAt(simd_make_float3(0, 0, CAM_D), simd_make_float3(0, 0, 0),
                           simd_make_float3(0, 1, 0)));
}

}  // namespace

struct TransitionScene::Impl {
    const MetalContext& ctx;
    int w = 0, h = 0;

    id<MTLRenderPipelineState> psoMain = nil, psoFace = nil;
    id<MTLDepthStencilState> dss = nil;
    id<MTLTexture> colorTex = nil, depthTex = nil, pondTex = nil, savedPondTex = nil;
    id<MTLBuffer> clothVB = nil, clothIB = nil, faceVB = nil, faceIB = nil;
    size_t clothIdx = 0, faceIdx = 0;

    Cloth cloth;
    MaskField field;
    std::vector<Vertex> clothVerts;

    // The mesh as it arrives (model units) and where the fit says each vertex
    // lands on screen, plus the world-space placement derived from the two.
    std::vector<float> modelVerts;
    std::vector<float> modelUV;        // 2/vertex, normalised frame, y-down
    std::vector<float> initialUV;      // 2/vertex, UV locked when mesh is first set
    std::vector<int>   faceTris;
    std::vector<Vertex> faceVerts;     // placed, with normals
    bool haveFace = false;
    bool haveUV = false;
    // Fallback normalisation, captured from the first mesh, for the no-uv path.
    // An expression changes the mesh extent, and re-deriving it per frame would
    // pump the face's size.
    bool normSet = false;
    float centre[3] = {0, 0, 0}, fallbackScale = 1.0f;

    float zFront = 0.f;                // world z of the mask's frontmost point
    float zBack  = 0.f;                // and its backmost, for the alignment hold
    float zOffset = 0.f;               // the press: how far the mask has advanced
    simd_float3 faceCentre = {0, 0, 0};   // placed centroid, for the shading space
    simd_float3 faceFacing = {0, 0, 1};   // mean normal: where its own light hangs
    float faceWorldW = 1.f;               // placed width, world units

    double t = 0.0;
    int builtRes = 0;
    float builtAspect = 0.f, builtOver = 0.f;
    float halfY = CAM_D * std::tan(CAM_FOV * 0.5f);
    float halfX = CAM_D * std::tan(CAM_FOV * 0.5f);
    bool textureCaptured = false;
    bool useSavedTexture = false;

    explicit Impl(const MetalContext& c) : ctx(c) {}

    bool buildPipelines(const std::string& shaderDir);
    void makeTargets(int W, int H);
    void ensureSheet(int res, float aspect, float over);
    void placeFace(float depthScale, const float regScale[2], const float regOff[2],
                   float yaw);
    void uploadFace();
    void rasteriseField();
    void packCloth();
};

bool TransitionScene::Impl::buildPipelines(const std::string& shaderDir) {
    // root_shared.h for RootFaceU, then the mask's material, then this scene's
    // own passes -- the same assembly the root renderer uses, because the mask
    // pass here is the root renderer's mask pass. The runtime compiler has no
    // include path, so shared code is prepended as text; see MetalContext.
    id<MTLLibrary> lib = ctx.newLibraryFromFiles(
        {std::string(MIRROR_APP_SRC_DIR) + "/root_shared.h",
         shaderDir + "/face_shade.metal",
         shaderDir + "/transition.metal"});
    if (!lib) return false;

    // RGBA16Float + Shared matches the rest of the app: the compositor samples
    // it and the headless shot path reads it back with getBytes, which a
    // Private texture cannot serve.
    auto make = [&](const char* vs, const char* fs) -> id<MTLRenderPipelineState> {
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:vs]];
        d.fragmentFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:fs]];
        if (!d.vertexFunction || !d.fragmentFunction) {
            std::fprintf(stderr, "transition: missing %s/%s\n", vs, fs);
            return nil;
        }
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        NSError* err = nil;
        id<MTLRenderPipelineState> p =
            [ctx.device() newRenderPipelineStateWithDescriptor:d error:&err];
        if (!p) std::fprintf(stderr, "transition: pipeline %s/%s: %s\n", vs, fs,
                             err.localizedDescription.UTF8String);
        return p;
    };
    psoMain = make("v_main", "f_main");
    psoFace = make("v_face", "f_face");
    if (!psoMain || !psoFace) return false;

    MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled = YES;
    dss = [ctx.device() newDepthStencilStateWithDescriptor:dd];
    return true;
}

void TransitionScene::Impl::makeTargets(int W, int H) {
    if (W == w && H == h && colorTex) return;
    w = W; h = H;
    auto tex = [&](MTLPixelFormat fmt, MTLTextureUsage usage, bool shared) {
        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                               width:W height:H mipmapped:NO];
        td.usage = usage;
        td.storageMode = shared ? MTLStorageModeShared : MTLStorageModePrivate;
        return [ctx.device() newTextureWithDescriptor:td];
    };
    const MTLTextureUsage rt = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    colorTex = tex(MTLPixelFormatRGBA16Float, rt, /*shared=*/true);
    depthTex = tex(MTLPixelFormatDepth32Float, MTLTextureUsageRenderTarget, false);
}

// The sheet has to fill the frustum cross-section *at the current aspect*, or
// the "flat sheet is the pond" identity that the whole opening rests on does
// not hold -- a square sheet on a portrait composition leaves the film short of
// the top and bottom edges.
void TransitionScene::Impl::ensureSheet(int res, float aspect, float over) {
    res = std::clamp(res, 16, 192);
    over = std::clamp(over, 1.f, 1.5f);
    if (res == builtRes && std::fabs(aspect - builtAspect) < 1e-4f &&
        std::fabs(over - builtOver) < 1e-4f) return;
    builtRes = res;
    builtAspect = aspect;
    builtOver = over;
    halfY = CAM_D * std::tan(CAM_FOV * 0.5f);
    halfX = halfY * aspect;
    cloth.buildSheet(res, res, 2.f * halfX * over, 2.f * halfY * over, /*borderCells=*/1);
    clothVerts.assign(cloth.pos.size(), Vertex{});
    // Normals before the first render, not just inside the sim step.
    // buildSheet leaves them zeroed, and a zero normal normalises to garbage --
    // the flat sheet then shades nothing like the pond it is supposed to be
    // indistinguishable from.
    cloth.computeNormals();
    packCloth();
    field.resize(FIELD_RES, FIELD_RES, halfX, halfY);
}

// Place every vertex so that *this* camera projects it back to the normalised
// frame position the fit put it at. Solving the projection rather than guessing
// a centre and a scale is what makes the film line up to the pixel: the mask
// lands on the pond's own face because it was placed by the same projection the
// pond was drawn with.
//
// clip.x = (f/aspect)*x, clip.w = CAM_D - z  =>  x = ndc.x * halfX * (CAM_D - z)/CAM_D
void TransitionScene::Impl::placeFace(float depthScale, const float regScale[2],
                                      const float regOff[2], float yaw) {
    const size_t n = modelVerts.size() / 3;
    if (!n) return;
    faceVerts.resize(n);

    // Model-space depth reference and the model->world scale. The scale is the
    // ratio of the projected extent to the model extent, so it tracks how big
    // the subject currently is on screen -- a face that walks closer to the
    // camera gets deeper as well as wider, which is the only self-consistent
    // answer.
    float xmin = 1e30f, xmax = -1e30f, zmin = 1e30f, zmax = -1e30f;
    double zsum = 0;
    for (size_t i = 0; i < n; ++i) {
        xmin = std::min(xmin, modelVerts[i * 3]);
        xmax = std::max(xmax, modelVerts[i * 3]);
        zmin = std::min(zmin, modelVerts[i * 3 + 2]);
        zmax = std::max(zmax, modelVerts[i * 3 + 2]);
        zsum += modelVerts[i * 3 + 2];
    }
    const float zref = float(zsum / double(n));

    // The registration correction, about the fit's own projected centre, so
    // scaling does not also walk the mask across the frame.
    double ucs = 0, vcs = 0;
    for (size_t i = 0; i < n; ++i) { ucs += modelUV[i * 2]; vcs += modelUV[i * 2 + 1]; }
    const float uc = float(ucs / double(n)), vc = float(vcs / double(n));
    auto fixU = [&](float u) { return uc + (u - uc) * regScale[0] + regOff[0]; };
    auto fixV = [&](float v) { return vc + (v - vc) * regScale[1] + regOff[1]; };

    float umin = 1e30f, umax = -1e30f;
    for (size_t i = 0; i < n; ++i) {
        const float u = fixU(modelUV[i * 2]);
        umin = std::min(umin, u);
        umax = std::max(umax, u);
    }
    const float modelW = std::max(1e-6f, xmax - xmin);
    const float worldW = std::max(1e-6f, (umax - umin) * 2.f * halfX);
    const float zScale = (worldW / modelW) * std::max(0.05f, depthScale);

    zFront = (zmax - zref) * zScale;
    zBack  = (zmin - zref) * zScale;

    for (size_t i = 0; i < n; ++i) {
        const float u = fixU(modelUV[i * 2]), v = fixV(modelUV[i * 2 + 1]);
        const float ndcx = u * 2.f - 1.f, ndcy = 1.f - v * 2.f;
        const float z = (modelVerts[i * 3 + 2] - zref) * zScale + zOffset;
        const float k = (CAM_D - z) / CAM_D;
        faceVerts[i].pos = simd_make_float3(ndcx * halfX * k, ndcy * halfY * k, z);
        // Geometry is positioned at corrected screen coords, but texture samples
        // from the initial UV so it stays locked to the frozen capture.
        if (useSavedTexture && i * 2 + 1 < initialUV.size()) {
            faceVerts[i].uv = simd_make_float2(initialUV[i * 2], initialUV[i * 2 + 1]);
        } else {
            faceVerts[i].uv = simd_make_float2(u, v);
        }
        faceVerts[i].nrm = simd_make_float3(0, 0, 1);
    }

    std::vector<simd_float3> nn(n, simd_make_float3(0, 0, 0));
    for (size_t t = 0; t + 2 < faceTris.size(); t += 3) {
        const int a = faceTris[t], b = faceTris[t + 1], c = faceTris[t + 2];
        if (a < 0 || b < 0 || c < 0 || size_t(a) >= n || size_t(b) >= n || size_t(c) >= n) continue;
        const simd_float3 fn = simd_cross(faceVerts[b].pos - faceVerts[a].pos,
                                          faceVerts[c].pos - faceVerts[a].pos);
        nn[a] += fn; nn[b] += fn; nn[c] += fn;
    }
    // The test yaw, about the mask's own vertical axis through its centre, so
    // turning it does not also walk it across the frame.
    if (yaw != 0.f) {
        simd_float3 c = simd_make_float3(0, 0, 0);
        for (size_t i = 0; i < n; ++i) c += faceVerts[i].pos;
        c /= float(n);
        const float cs = std::cos(yaw), sn = std::sin(yaw);
        for (size_t i = 0; i < n; ++i) {
            const simd_float3 d = faceVerts[i].pos - c;
            faceVerts[i].pos = c + simd_make_float3(cs * d.x + sn * d.z, d.y,
                                                    -sn * d.x + cs * d.z);
        }
    }

    simd_float3 nsum = simd_make_float3(0, 0, 0), psum = simd_make_float3(0, 0, 0);
    for (size_t i = 0; i < n; ++i) {
        const float l = simd_length(nn[i]);
        faceVerts[i].nrm = l > 1e-8f ? nn[i] / l : simd_make_float3(0, 0, 1);
        // Area-weighted, by using the un-normalised accumulation: the mask is an
        // open shell whose rim triangles face every which way, and a mean of the
        // unit normals is dragged around by however finely the rim happens to be
        // tessellated. What the light wants is the direction the *face* points.
        nsum += nn[i];
        psum += faceVerts[i].pos;
    }
    faceCentre = psum / float(n);
    const float nl = simd_length(nsum);
    faceFacing = nl > 1e-8f ? nsum / nl : simd_make_float3(0, 0, 1);
    if (faceFacing.z < 0.f) faceFacing = -faceFacing;   // toward the camera
    faceWorldW = worldW;
}

void TransitionScene::Impl::uploadFace() {
    if (faceVerts.empty() || faceTris.empty()) { faceIdx = 0; return; }
    const size_t bytes = faceVerts.size() * sizeof(Vertex);
    if (!faceVB || faceVB.length < bytes)
        faceVB = [ctx.device() newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    std::memcpy(faceVB.contents, faceVerts.data(), bytes);

    if (!faceIB || faceIdx != faceTris.size()) {
        std::vector<uint32_t> idx(faceTris.begin(), faceTris.end());
        faceIdx = idx.size();
        faceIB = [ctx.device() newBufferWithBytes:idx.data() length:faceIdx * sizeof(uint32_t)
                                          options:MTLResourceStorageModeShared];
    }
}

// The collider: the mask's front surface, as a depth map over the sheet's own
// (x, y). Kept in world x/y rather than in screen space, so contact is resolved
// where the cloth lives; the sheet sits within about a tenth of a unit of the
// mask against a camera distance of 3, so the parallax that ignores is under a
// twentieth of a texel and nothing in the drape can see it.
void TransitionScene::Impl::rasteriseField() {
    if (!field.valid()) return;
    field.clear();
    if (faceVerts.empty() || faceTris.size() < 3) return;

    const int fw = field.w, fh = field.h;
    auto toField = [&](simd_float3 p, float& fx, float& fy) {
        fx = (p.x + halfX) / (2.f * halfX) * float(fw - 1);
        fy = (halfY - p.y) / (2.f * halfY) * float(fh - 1);
    };

    for (size_t t = 0; t + 2 < faceTris.size(); t += 3) {
        const int ia = faceTris[t], ib = faceTris[t + 1], ic = faceTris[t + 2];
        if (ia < 0 || ib < 0 || ic < 0) continue;
        if (size_t(ia) >= faceVerts.size() || size_t(ib) >= faceVerts.size() ||
            size_t(ic) >= faceVerts.size()) continue;
        const simd_float3 A = faceVerts[ia].pos, B = faceVerts[ib].pos, C = faceVerts[ic].pos;
        float ax, ay, bx, by, cx, cy;
        toField(A, ax, ay); toField(B, bx, by); toField(C, cx, cy);

        const float area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        if (std::fabs(area) < 1e-9f) continue;
        const float inv = 1.f / area;

        int x0 = std::max(0, int(std::floor(std::min({ax, bx, cx}))));
        int x1 = std::min(fw - 1, int(std::ceil(std::max({ax, bx, cx}))));
        int y0 = std::max(0, int(std::floor(std::min({ay, by, cy}))));
        int y1 = std::min(fh - 1, int(std::ceil(std::max({ay, by, cy}))));

        for (int y = y0; y <= y1; ++y) {
            const float py = float(y) + 0.5f;
            for (int x = x0; x <= x1; ++x) {
                const float px = float(x) + 0.5f;
                float w0 = ((bx - ax) * (py - ay) - (by - ay) * (px - ax)) * inv;   // toward C
                float w1 = ((px - ax) * (cy - ay) - (py - ay) * (cx - ax)) * inv;   // toward B
                const float w2 = 1.f - w0 - w1;
                if (w0 < 0.f || w1 < 0.f || w2 < 0.f) continue;
                const float z = w2 * A.z + w1 * B.z + w0 * C.z;
                const size_t k = size_t(y) * size_t(fw) + size_t(x);
                // Front surface only: the sheet can never reach the back of the
                // mask from a camera that does not move.
                if (!field.cover[k] || z > field.z[k]) { field.z[k] = z; field.cover[k] = 1; }
            }
        }
    }

    // Conservative over one cloth cell. Contact is resolved at vertices and the
    // sheet is drawn as the flat triangles between them, so a vertex has to
    // clear the highest point of the mask that its own cell can span -- see
    // MaskField::dilate.
    const float texel = 2.f * halfX / float(std::max(1, field.w - 1));
    const float cell  = 2.f * halfX * (builtOver > 0.f ? builtOver : 1.f)
                      / float(std::max(1, cloth.nx - 1));
    field.dilate(int(std::ceil(cell / std::max(texel, 1e-6f))));
    // After the dilation, so contact reads the normal of the surface it is
    // actually resolved against rather than of the one underneath it.
    field.buildNormals();
}

void TransitionScene::Impl::packCloth() {
    // uv = the rest (flat) grid mapped to the *frame*, y-flipped to the film's
    // screen orientation. Over the frame's own extent this is exactly the
    // fullscreen pond, and it stays locked to the surface as the sheet
    // stretches and falls; the overhang runs past 0..1 and clamps.
    const float o = builtOver > 0.f ? builtOver : 1.f;
    for (int j = 0; j < cloth.ny; ++j)
        for (int i = 0; i < cloth.nx; ++i) {
            const int k = cloth.idx(i, j);
            clothVerts[size_t(k)].pos = cloth.pos[size_t(k)];
            clothVerts[size_t(k)].nrm = cloth.nrm[size_t(k)];
            clothVerts[size_t(k)].uv = simd_make_float2(
                0.5f + (i / float(cloth.nx - 1) - 0.5f) * o,
                0.5f - (j / float(cloth.ny - 1) - 0.5f) * o);
        }
    const size_t bytes = clothVerts.size() * sizeof(Vertex);
    if (!clothVB || clothVB.length < bytes)
        clothVB = [ctx.device() newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    std::memcpy(clothVB.contents, clothVerts.data(), bytes);

    if (!clothIB || clothIdx != cloth.tris.size()) {
        clothIdx = cloth.tris.size();
        if (clothIdx)
            clothIB = [ctx.device() newBufferWithBytes:cloth.tris.data()
                                                length:clothIdx * sizeof(uint32_t)
                                               options:MTLResourceStorageModeShared];
    }
}

// ---------------------------------------------------------------------------

TransitionScene::TransitionScene(const MetalContext& ctx, int w, int h)
    : impl_(new Impl(ctx)) {
    if (!impl_->buildPipelines(std::string(MIRROR_APP_SHADER_DIR))) return;
    impl_->makeTargets(std::max(2, w), std::max(2, h));
    impl_->ensureSheet(sheetRes, float(impl_->w) / float(std::max(1, impl_->h)), oversize);
}

TransitionScene::~TransitionScene() = default;

bool TransitionScene::valid() const { return impl_ && impl_->psoMain; }
int  TransitionScene::width() const { return impl_->w; }
int  TransitionScene::height() const { return impl_->h; }
void TransitionScene::ensureSize(int w, int h) { impl_->makeTargets(std::max(2, w), std::max(2, h)); }
const Cloth& TransitionScene::cloth() const { return impl_->cloth; }
bool TransitionScene::hasFace() const { return impl_->haveFace; }
double TransitionScene::clock() const { return impl_->t; }
void TransitionScene::setPondTexture(id<MTLTexture> pond) { impl_->pondTex = pond; }

bool TransitionScene::savePondTexture(const std::string& path) {
    if (!impl_->pondTex) return false;
    id<MTLTexture> tex = impl_->pondTex;
    const int W = tex.width, H = tex.height;
    std::vector<uint16_t> px((size_t)W * H * 4);
    [tex getBytes:px.data() bytesPerRow:W * 4 * sizeof(uint16_t)
       fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    FILE* fp = fopen(path.c_str(), "wb");
    if (!fp) return false;
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    auto h2f = [](uint16_t h) {
        uint32_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff, bits;
        if (e == 0) bits = (s << 31) | 0; else bits = (s << 31) | ((e + 112) << 23) | (m << 13);
        float f; __builtin_memcpy(&f, &bits, 4); return f;
    };
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            const uint16_t* p = &px[((size_t)y * W + x) * 4];
            for (int c = 0; c < 3; ++c) {
                float v = h2f(p[c]);
                v = v <= 0.f ? 0.f : (v >= 1.f ? 1.f : v);
                v = powf(v, 1.0f / 2.2f);
                fputc((unsigned char)(v * 255.0f + 0.5f), fp);
            }
        }
    }
    fclose(fp);
    printf("transition: saved pond texture to %s (%dx%d)\n", path.c_str(), W, H);
    return true;
}

bool TransitionScene::loadPondTexture(const std::string& path) {
    FILE* fp = fopen(path.c_str(), "rb");
    if (!fp) { fprintf(stderr, "transition: cannot open %s\n", path.c_str()); return false; }
    char magic[3] = {0, 0, 0};
    if (fscanf(fp, "%2s\n", magic) != 1 || magic[0] != 'P' || magic[1] != '6') {
        fprintf(stderr, "transition: %s is not a PPM P6 file\n", path.c_str());
        fclose(fp);
        return false;
    }
    int W, H, maxval;
    if (fscanf(fp, "%d %d\n%d\n", &W, &H, &maxval) != 3) {
        fprintf(stderr, "transition: %s header parse failed\n", path.c_str());
        fclose(fp);
        return false;
    }
    std::vector<unsigned char> rgb8((size_t)W * H * 3);
    if (fread(rgb8.data(), 1, rgb8.size(), fp) != rgb8.size()) {
        fprintf(stderr, "transition: %s read failed\n", path.c_str());
        fclose(fp);
        return false;
    }
    fclose(fp);
    std::vector<uint16_t> px16((size_t)W * H * 4);
    auto f2h = [](float f) -> uint16_t {
        f = std::pow(f, 2.2f);
        if (f <= 0.f) return 0;
        if (f >= 1.f) return 0x3c00;
        uint32_t bits; __builtin_memcpy(&bits, &f, 4);
        uint16_t s = (bits >> 31) & 1, e = ((bits >> 23) & 0xff) - 112, m = (bits >> 13) & 0x3ff;
        return (s << 15) | (e << 10) | m;
    };
    for (size_t i = 0; i < rgb8.size(); i += 3) {
        const size_t j = (i / 3) * 4;
        px16[j + 0] = f2h(rgb8[i + 0] / 255.f);
        px16[j + 1] = f2h(rgb8[i + 1] / 255.f);
        px16[j + 2] = f2h(rgb8[i + 2] / 255.f);
        px16[j + 3] = f2h(1.f);
    }
    MTLTextureDescriptor* td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                          width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    impl_->savedPondTex = [impl_->ctx.device() newTextureWithDescriptor:td];
    [impl_->savedPondTex replaceRegion:MTLRegionMake2D(0, 0, W, H)
                           mipmapLevel:0 withBytes:px16.data() bytesPerRow:W * 4 * sizeof(uint16_t)];
    printf("transition: loaded pond texture from %s (%dx%d)\n", path.c_str(), W, H);
    return true;
}

bool TransitionScene::hasSavedPondTexture() const { return impl_->savedPondTex != nil; }

void TransitionScene::setFaceMesh(const std::vector<float>& verts, const std::vector<int>& tris,
                                  const std::vector<float>& uv) {
    if (verts.size() < 9) return;
    if (!tris.empty()) impl_->faceTris = tris;
    if (impl_->faceTris.empty()) return;

    const size_t n = verts.size() / 3;
    impl_->modelVerts.assign(verts.begin(), verts.begin() + n * 3);

    if (uv.size() >= n * 2) {
        impl_->modelUV.assign(uv.begin(), uv.begin() + n * 2);
        impl_->initialUV.assign(uv.begin(), uv.begin() + n * 2);
        impl_->haveUV = true;
    } else {
        // No projection supplied: centre the mesh and normalise it by its own
        // extent, the way this scene used to place a mesh. Good enough to see
        // the gesture headless; it cannot make the film line up, because
        // nothing here knows where the pond drew the face.
        if (!impl_->normSet) {
            double cx = 0, cy = 0, cz = 0;
            for (size_t i = 0; i < n; ++i) {
                cx += verts[i * 3]; cy += verts[i * 3 + 1]; cz += verts[i * 3 + 2];
            }
            impl_->centre[0] = float(cx / n);
            impl_->centre[1] = float(cy / n);
            impl_->centre[2] = float(cz / n);
            float m = 1e-9f;
            for (size_t i = 0; i < n; ++i)
                m = std::max({m, std::fabs(verts[i * 3] - impl_->centre[0]),
                                 std::fabs(verts[i * 3 + 1] - impl_->centre[1])});
            impl_->fallbackScale = 0.55f / m;
            impl_->normSet = true;
        }
        impl_->modelUV.resize(n * 2);
        for (size_t i = 0; i < n; ++i) {
            const float x = (verts[i * 3]     - impl_->centre[0]) * impl_->fallbackScale;
            const float y = (verts[i * 3 + 1] - impl_->centre[1]) * impl_->fallbackScale;
            impl_->modelUV[i * 2]     = 0.5f + x * 0.5f;
            impl_->modelUV[i * 2 + 1] = 0.5f - y * 0.5f;
        }
        impl_->initialUV.assign(impl_->modelUV.begin(), impl_->modelUV.end());
        impl_->haveUV = false;
    }
    impl_->haveFace = true;
}

void TransitionScene::restart() {
    impl_->t = 0.0;
    impl_->zOffset = 0.f;
    impl_->builtRes = 0;             // force a fresh sheet: flat, fully held
    impl_->textureCaptured = false;  // allow texture capture on the next advance
    impl_->ensureSheet(sheetRes, float(impl_->w) / float(std::max(1, impl_->h)), oversize);
}

float TransitionScene::press() const {
    return std::clamp((float(impl_->t) - timing.hold) / std::max(1e-3f, timing.press), 0.f, 1.f);
}

float TransitionScene::release() const {
    const float t0 = timing.hold + timing.press + timing.settle;
    return std::clamp((float(impl_->t) - t0) / std::max(1e-3f, timing.release), 0.f, 1.f);
}

bool TransitionScene::done() const {
    return float(impl_->t) > timing.hold + timing.press + timing.settle +
                             timing.release + timing.fall;
}

const char* TransitionScene::phaseName() const {
    const float t = float(impl_->t);
    if (t < timing.hold) return "hold";
    if (t < timing.hold + timing.press) return "press";
    if (t < timing.hold + timing.press + timing.settle) return "settle";
    if (t < timing.hold + timing.press + timing.settle + timing.release) return "release";
    return "fall";
}

void TransitionScene::advance(double dt) {
    Impl& I = *impl_;
    I.t += dt;
    I.ensureSheet(sheetRes, float(I.w) / float(std::max(1, I.h)), oversize);

    // Capture and freeze the pond texture on the first frame
    if (!I.textureCaptured && I.pondTex) {
        const char* home = getenv("HOME");
        std::string texPath = home ? std::string(home) + "/.mirror/transition_mask.ppm" : "/tmp/transition_mask.ppm";
        fprintf(stderr, "transition: capturing texture to %s\n", texPath.c_str());
        if (savePondTexture(texPath) && loadPondTexture(texPath)) {
            useSavedPondTexture = true;
            I.useSavedTexture = true;
            fprintf(stderr, "transition: texture frozen and ready\n");
        }
        I.textureCaptured = true;
    }

    // The alignment hold: the mask fully through, the film flat behind it, the
    // timeline going nowhere. Both are on screen at once, which is the only
    // state in which the registration is judgeable.
    const float p = alignMask ? 1.f : smoothstep01(press());
    const float r = alignMask ? 0.f : release();

    if (I.haveFace) {
        // Place once with the press at zero to learn how deep the mask is, then
        // again at the offset that depth implies. Two passes because the travel
        // is expressed in the mask's own terms -- "starts entirely behind the
        // film, ends this far proud of it" -- and a face that turns or walks
        // closer changes what that means every frame.
        I.zOffset = 0.f;
        I.placeFace(depthScale, maskScale, maskOffset, maskYaw);
        const float startZ = -I.zFront - 0.05f;
        const float endZ   = pressProud;
        I.zOffset = startZ + (endZ - startZ) * p;
        // The alignment hold puts the *whole* mask in front of the film rather
        // than pressed through it. Pressed through, the film occludes
        // everything that is not proud of it and what is left on screen is a
        // slice -- the brow, the nose, the chin -- which is not a shape anyone
        // can align to a face.
        if (alignMask) I.zOffset = -I.zBack + 0.02f;
        I.placeFace(depthScale, maskScale, maskOffset, maskYaw);
        I.uploadFace();
        I.rasteriseField();
        I.cloth.collider = &I.field;
    } else {
        I.cloth.collider = nullptr;
    }

    // Nothing to solve while the film is flat and untouched, and solving it
    // anyway is how a sheet that should be perfectly still acquires a shimmer.
    // The alignment hold wants the sheet left flat for the same reason.
    if (alignMask || float(I.t) <= timing.hold) return;

    I.cloth.skin = skin;
    I.cloth.iterations = iterations;
    I.cloth.stretchMax = stretchMax;
    I.cloth.damping = damping;
    // The film sets while it is held, and behaves like a taut sheet once it is
    // let go. Both halves are needed and they want opposite materials.
    //
    // Under the press it has to be compliant and take a set, or it bridges the
    // face instead of wrapping it and then snaps off when the pins release.
    // After the release, that same material is what keeps it on: with gravity
    // straight back, nothing pushes the fabric sideways, so the only thing that
    // can carry it off the brow and the nose is the weight of the free sheet
    // pulling through the part still in contact. A compliant sheet stretches
    // instead of pulling, a plastic one has already given up the length, and
    // friction holds what is left -- so the film sits on the mask as a shroud
    // and stays there, which is exactly what it did before this.
    //
    // Note that the mask advancing cannot do this on its own: the placement
    // compensates perspective, so its silhouette does not change as it comes
    // through, and fabric draped on it is simply carried along. It sets the
    // shape; the tension takes it off.
    const float gr = smoothstep01(release());
    I.cloth.plastic     = plastic  * (1.f - gr);
    I.cloth.stretchGive = stretch  * (1.f - 0.85f * gr);
    I.cloth.friction    = friction * (1.f - 0.75f * gr);
    // The release front runs a little past 1 so the last pins -- the middles of
    // the edges -- actually reach zero rather than stopping at the feather.
    I.cloth.setRelease(r * 1.25f);
    // Gravity arrives with the release, not before it: a sheet pulled down
    // while every pin still holds only sags, and the press is supposed to read
    // as the mask doing the work.
    const float g = smoothstep01(r);
    I.cloth.gravity = simd_make_float3(0.f, -gravityDown * g, -gravityBack * g);

    const int ss = std::max(1, substeps);
    for (int i = 0; i < ss; ++i) I.cloth.step(float(dt) / float(ss));
    I.cloth.computeNormals();
    I.packCloth();
}

id<MTLTexture> TransitionScene::render(id<MTLCommandBuffer> cb) {
    if (!valid()) return nil;
    Impl& I = *impl_;
    const simd_float4x4 vp = frontVP(float(I.w) / float(std::max(1, I.h)));

    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = I.colorTex;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.02, 0.02, 0.03, 1.0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = I.depthTex;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.clearDepth = 1.0;
    rp.depthAttachment.storeAction = MTLStoreActionDontCare;

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:I.psoMain];
    [enc setDepthStencilState:I.dss];
    [enc setCullMode:MTLCullModeNone];
    [enc setTriangleFillMode:wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    id<MTLTexture> filmTex = (useSavedPondTexture && I.savedPondTex) ? I.savedPondTex : I.pondTex;
    [enc setFragmentTexture:filmTex atIndex:0];

    Uniforms u;
    u.mvp = vp;
    u.model = matrix_identity_float4x4;
    u.lightDir = simd_make_float4(LIGHT.x, LIGHT.y, LIGHT.z, 0.0f);
    u.baseColor = simd_make_float4(1, 1, 1, 1);

    // The mask first: it is opaque and mostly behind the film, so drawing it
    // ahead of the sheet lets the depth test reject the covered fragments
    // instead of shading them.
    if (showFace && I.haveFace && I.faceIdx && I.faceVB) {
        // One uniform scale about the mask's own centre puts the marble, the
        // light falloff and the spot cone back at the size they were tuned at in
        // the root scene, whatever size the fit put the mask on screen.
        const float k = shadeSpan / std::max(1e-4f, I.faceWorldW);

        RootFaceU fu = {};
        fu.viewProj = vp;
        fu.eye = simd_make_float4((simd_make_float3(0, 0, CAM_D) - I.faceCentre) * k, 0);
        float ld[3] = {keyDir[0], keyDir[1], keyDir[2]};
        const float ldn = std::sqrt(ld[0]*ld[0] + ld[1]*ld[1] + ld[2]*ld[2]);
        const float inv = ldn > 1e-6f ? 1.f / ldn : 1.f;
        fu.lightDir = simd_make_float4(ld[0]*inv, ld[1]*inv, ld[2]*inv, 0);
        fu.keyColor = simd_make_float4(env.keyColor[0] * env.keyIntensity,
                                       env.keyColor[1] * env.keyIntensity,
                                       env.keyColor[2] * env.keyIntensity, 0);
        fu.veinColor = simd_make_float4(faceMat.veinColor[0], faceMat.veinColor[1],
                                        faceMat.veinColor[2], 0);
        fu.lightIntensity = faceMat.lightIntensity;
        fu.lightFalloff   = faceMat.lightFalloff;
        fu.specStrength   = faceMat.specStrength;
        fu.veinScale      = faceMat.veinScale;
        fu.veinStrength   = 0.0f;
        fu.roughness      = faceMat.roughness;
        fu.metallic       = faceMat.metallic;
        fu.reliefStrength = faceMat.reliefStrength;
        fu.reliefScale    = faceMat.reliefScale;
        fu.spotLightDist  = faceMat.spotLightDist;
        // Same convention as the root renderer: 90 degrees outer means no cone.
        if (faceMat.spotOuterDeg >= 89.9f) {
            fu.spotCosOuter = -2.0f; fu.spotCosInner = -2.0f;
        } else {
            fu.spotCosOuter = std::cos(faceMat.spotOuterDeg * float(M_PI) / 180.f);
            fu.spotCosInner = std::cos(std::min(faceMat.spotInnerDeg, faceMat.spotOuterDeg)
                                       * float(M_PI) / 180.f);
        }
        fu.skyColor    = simd_make_float4(env.skyColor[0], env.skyColor[1], env.skyColor[2], 0);
        fu.groundColor = simd_make_float4(env.groundColor[0], env.groundColor[1],
                                          env.groundColor[2], 0);
        fu.sssTint     = simd_make_float4(env.sssTint[0], env.sssTint[1], env.sssTint[2], 0);
        fu.hemiStrength = env.hemiStrength;
        fu.envSpec      = env.envSpec;
        fu.rimStrength  = env.rimStrength;
        fu.sssWrap      = env.sssWrap;
        fu.sssTrans     = env.sssTrans;
        fu.sssPower     = env.sssPower;

        TransFaceX x = {};
        x.centre = simd_make_float4(I.faceCentre, 0);
        // The mask's own light, placed the way the root scene's mesh builder
        // places it: spotLightDist along the mask's facing from its centre. The
        // shader recovers the cone's axis from that distance, so this has to be
        // the same offset it is told about.
        x.lightPos = simd_make_float4(I.faceFacing * faceMat.spotLightDist, 0);
        x.scale = k;
        x.exposure = exposure;
        x.tonemap = tonemap ? 1 : 0;

        [enc setRenderPipelineState:I.psoFace];
        // Wireframe over the film, so the face underneath stays readable. A
        // solid mask in front of the film hides the very thing it is being
        // aligned to.
        if (alignMask) [enc setTriangleFillMode:MTLTriangleFillModeLines];
        [enc setVertexBuffer:I.faceVB offset:0 atIndex:0];
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc setFragmentBytes:&fu length:sizeof(fu) atIndex:1];
        [enc setFragmentBytes:&x length:sizeof(x) atIndex:2];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:I.faceIdx
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:I.faceIB
                 indexBufferOffset:0];
        [enc setRenderPipelineState:I.psoMain];
        if (alignMask)
            [enc setTriangleFillMode:wireframe ? MTLTriangleFillModeLines
                                               : MTLTriangleFillModeFill];
    }
    if (showCloth && I.clothIdx && I.clothVB) {
        u.params = simd_make_float4(refract, reliefShade, 0, 0);
        [enc setVertexBuffer:I.clothVB offset:0 atIndex:0];
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:I.clothIdx
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:I.clothIB
                 indexBufferOffset:0];
    }

    [enc endEncoding];
    return I.colorTex;
}
