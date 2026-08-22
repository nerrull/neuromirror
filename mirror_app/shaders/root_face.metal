// root_face.metal — Metal port of sdf_viewer's face.vert + face.frag.
//
// The mask-mesh mid-geometry pass: triangle meshes (the face masks) rasterized
// into the SAME colour + depth targets as the root capsules, between the capsule
// pass and the fog pass, so they depth-composite against the sphere-traced roots
// and are included in the fog. Marble veining + a per-face point light. Vertices
// arrive interleaved (pos3, normal3, color3, lightPos3) exactly as the GL VBO.
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
};

struct FaceVOut {
    float4 pos [[position]];
    float3 worldPos;
    float3 normal;
    float3 color;
    float3 lightPos;
};

vertex FaceVOut root_face_vs(uint vid [[vertex_id]],
                             device const FaceVertex* verts [[buffer(0)]],
                             constant RootFaceU&      U     [[buffer(1)]]) {
    FaceVertex v = verts[vid];
    FaceVOut o;
    o.worldPos = float3(v.pos);
    o.normal   = float3(v.normal);
    o.color    = float3(v.color);
    o.lightPos = float3(v.lightPos);
    float4 c = U.viewProj * float4(float3(v.pos), 1.0);
    c.z = (c.z + c.w) * 0.5;   // GL [-1,1] clip-z -> Metal [0,1], matches capsule depth
    o.pos = c;
    return o;
}

fragment float4 root_face_fs(FaceVOut in [[stage_in]],
                             constant RootFaceU& U [[buffer(1)]]) {
    // World position doubles as the marble's coordinate here: the root scene is
    // where veinScale was tuned, so it is the scene that defines what the
    // pattern's world size means.
    return shadeFace(in.worldPos, in.normal, in.color, in.lightPos, U);
}
