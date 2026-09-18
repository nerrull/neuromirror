// root_face.metal — Metal port of sdf_viewer's face.vert + face.frag.
//
// The mask-mesh mid-geometry pass: triangle meshes (the face masks) rasterized
// into the SAME colour + depth targets as the root capsules, between the capsule
// pass and the fog pass, so they depth-composite against the sphere-traced roots
// and are included in the fog. Lit skin + a per-face spotlight. Vertices
// arrive interleaved (pos3, normal3, color3, lightPos3, lit) -- the GL VBO's
// layout plus one float: whether the mask is lit (1) or standing dark (0). One
// mesh holds every structure's masks, so a per-structure state has to ride on
// the vertices; see RootScene::uploadFaceFromMasks.
//
// Depth: the capsule pass writes custom depth = (clip.z/clip.w)*0.5+0.5 (GL
// convention). These triangles use the hardware rasterizer's depth, so the vertex
// shader remaps GL clip-z [-1,1] into Metal's [0,1] (z = (z+w)/2) — after the
// perspective divide that yields the identical value, so the two passes composite.
// The material itself is not here: it lives in face_shade.metal, because the
// transition draws the same mask a moment earlier and the two must not be able
// to drift apart. This file is the pass — geometry in, `shadeFace` out.
#include <metal_stdlib>
using namespace metal;

struct FaceVertex {
    packed_float3 pos;
    packed_float3 normal;
    packed_float3 color;
    packed_float3 lightPos;
    float         lit;
};

struct FaceVOut {
    float4 pos [[position]];
    float3 worldPos;
    float3 normal;
    float3 color;
    float3 lightPos;
    float  lit;
};

// Integer hash (lowbias32) for the glitch's per-triangle draw.
static uint glitchHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

vertex FaceVOut root_face_vs(uint vid [[vertex_id]],
                             device const FaceVertex* verts [[buffer(0)]],
                             constant RootFaceU&      U     [[buffer(1)]]) {
    FaceVertex v = verts[vid];
    // The pluck flash's glitch: inside a flashed mask's run, a share of the
    // triangles have their vertex indices randomised -- each corner reads
    // the position of some other vertex of the same mask, keeping its own
    // normal and colour -- so the face tears into long shards strung
    // between its own points; a share of those corners are then pushed
    // off by a random offset. Which triangles, where their corners go and
    // how far, is a hash of the triangle, the corner and the seed; the
    // host reseeds every frame, and the thresholds following the glitch's
    // envelope let the set swell and shrink smoothly rather than blink.
    if (U.glitchCount > 0 && U.glitchLevel > 0.0) {
        for (int i = 0; i < U.glitchCount; ++i) {
            const int first = U.glitchRun[i].x, n = U.glitchRun[i].y;
            if (int(vid) < first || int(vid) >= first + n || n < 6) continue;
            const uint local = vid - uint(first);
            const uint tri = local / 3u, corner = local % 3u;
            const uint h = glitchHash(tri * 7919u + uint(U.glitchSeed) * 104729u + 1u);
            if (float(h & 0xffffu) * (1.0 / 65535.0) < U.glitchLevel) {
                const uint hc = glitchHash(h + corner * 0x9E3779B9u);
                v.pos = verts[uint(first) + hc % uint(n)].pos;
                if (float(hc >> 16) * (1.0 / 65535.0) < U.glitchNoiseShare) {
                    const uint hx = glitchHash(hc), hy = glitchHash(hx), hz = glitchHash(hy);
                    const float3 r = float3(hx & 0xffffu, hy & 0xffffu, hz & 0xffffu)
                                   * (2.0 / 65535.0) - 1.0;
                    v.pos = float3(v.pos) + r * U.glitchNoise;
                }
            }
            break;
        }
    }
    FaceVOut o;
    o.worldPos = float3(v.pos);
    o.normal   = float3(v.normal);
    o.color    = float3(v.color);
    o.lightPos = float3(v.lightPos);
    o.lit      = v.lit;
    float4 c = U.viewProj * float4(float3(v.pos), 1.0);
    c.z = (c.z + c.w) * 0.5;   // GL [-1,1] clip-z -> Metal [0,1], matches capsule depth
    o.pos = c;
    return o;
}

fragment float4 root_face_fs(FaceVOut in [[stage_in]],
                             constant RootFaceU& U [[buffer(1)]]) {
    float4 c = shadeFace(in.worldPos, in.normal, in.color, in.lightPos, U);
    // A dark mask keeps a sliver of its radiance and nothing else -- the same
    // rule as the capsules' RootDrawU::lit, and like there the alpha (the
    // indirect share) is a ratio and stays as it was.
    c.rgb *= mix(U.unlitLevel, 1.0, saturate(in.lit));
    return c;
}
