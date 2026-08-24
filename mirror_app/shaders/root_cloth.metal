// The draped pond/cloth sheet, as a mid-geometry pass in RootScene's own
// renderer -- see metal_root_renderer.mm's render(), which draws this between
// the leaf pass and [ge endEncoding], sharing the scene's camera/depth with
// the capsules, the face mask and the leaves.
//
// Ported from transition_scene's f_main (shaders/transition.metal), which drew
// the sheet in TransitionScene's own fixed front-on camera. That fixed frame
// is gone -- the cloth is built and simulated in the anchor mask's own frame
// (see RootScene::rasteriseClothField/packClothMesh) and rendered here in
// RootScene's orbiting camera, sharing viewProj/lightDir with the rest of the
// scene via RootClothU rather than a second, scene-local uniform block.
#include <metal_stdlib>
using namespace metal;

// Piecewise sRGB, matching face_shade.metal's srgbEncode (this pass compiles
// against root_shared.h alone, so it cannot share that one).
static float3 srgbDecode(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

// Matches RootScene::packClothMesh's interleave: ten tightly packed floats per
// vertex, the same convention root_face.metal and root_leaf.metal use.
//
// `packed_` is load-bearing, not decoration. MSL's `float3` is sixteen bytes
// with sixteen-byte alignment, so the obvious spelling of this struct is
// forty-eight bytes against the forty the CPU actually writes -- every vertex
// after the first reads eight bytes further into the buffer than the last, and
// the sheet arrives as a skewed fan of enormous triangles with the film sliding
// across it. transition.metal spells the same struct with plain `float3`
// because its C++ side is simd_float3/simd_float2, which really is that
// layout; this pass is fed a std::vector<float> instead, and porting the
// declaration across unchanged is what produced the spike burst this fixes.
struct ClothVertex {
    packed_float3 pos;
    packed_float3 nrm;
    packed_float2 uv;
    packed_float2 aux;          // x = curvature along the normal, y = z off rest
};

struct ClothVOut {
    float4 clip [[position]];
    float3 wnrm;
    float2 uv;
    float2 aux;
};

vertex ClothVOut root_cloth_vs(uint vid [[vertex_id]],
                               device const ClothVertex* verts [[buffer(0)]],
                               constant RootClothU& u [[buffer(1)]]) {
    ClothVOut o;
    float3 p = verts[vid].pos;
    o.clip = u.viewProj * float4(p, 1.0);
    o.wnrm = verts[vid].nrm;
    o.uv = verts[vid].uv;
    o.aux = verts[vid].aux;
    return o;
}

fragment float4 root_cloth_fs(ClothVOut in [[stage_in]],
                              constant RootClothU& u [[buffer(1)]],
                              texture2d<float> pond [[texture(0)]]) {
    // The sheet's own normal is expressed in the anchor mask's local frame
    // (tangent/bitangent/normal -> x/y/z), which by construction (see
    // root_sim.cpp's anchor-first placement) is the frame the mask faces the
    // camera square-on in, so N.z >= 0 reads the same way "toward the camera"
    // did in TransitionScene's fixed rig.
    float3 N = normalize(in.wnrm);
    if (N.z < 0.0) N = -N;
    float3 L = normalize(u.lightDir.xyz);
    float ndl = max(0.0, dot(N, L));
    // Shading as a deviation from the flat sheet -- see transition.metal's
    // f_main for the full reasoning; unchanged here.
    float flat = 0.30 + 0.85 * max(1e-3, L.z);
    float shade = 1.0 + u.reliefShade * ((0.30 + 0.85 * ndl) - flat) / flat;

    float bulge = clamp(abs(in.aux.y) * 6.0, 0.0, 1.0);
    float curv  = tanh(in.aux.x * 3.0);
    shade *= 1.0 + u.reliefSharp * curv * bulge;

    float3 V = float3(0.0, 0.0, 1.0);
    float3 Hv = normalize(L + V);
    float spec = pow(max(0.0, dot(N, Hv)), 48.0);
    shade += u.sheen * spec * bulge;

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = in.uv + N.xy * u.refract * bulge;
    // Decoded to linear radiance, not used as-is.
    //
    // The film arrives display-referred (it is the mirror's output, the literal
    // image the Mirror phase puts on screen). While passThrough is 1 that does
    // not matter -- root_post.metal hands the pixel straight back. But as
    // passThrough falls and the sheet becomes an object in the room, whatever
    // is in this buffer is read as radiance by exposure, the bloom threshold
    // and the tonemap, and sRGB 0.8 read as linear radiance is enormously
    // brighter than 0.8 of the display: the film blows out the instant it
    // starts to be graded. Decoding here means the buffer holds real radiance
    // in both regimes, and the pass-through simply re-encodes it -- which
    // round-trips to the original pixel, so nothing is lost by doing it.
    float3 base = srgbDecode(pond.sample(smp, uv).rgb);
    // Alpha carries two things, by sign. The geometry passes write the AO
    // weight in [0,1] (see root_geom.metal, read by root_fog.metal); the film
    // writes *negative* alpha to say "this pixel is already a finished picture,
    // hand it back to the display untouched", with the magnitude as the
    // pass-through weight. Negative also disables AO for free, since the fog
    // pass clamps the weight it multiplies by -- which is what the film wants
    // anyway: ambient occlusion on a photograph is a category error.
    return float4(base * max(0.0, shade), -u.passThrough);
}
