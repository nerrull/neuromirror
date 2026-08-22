// The pond -> face hydro-dip transition.
//
// One pass, one pipeline. The scene is 3D from its first frame: a flat sheet
// sized to fill the frustum cross-section, and behind it the fitted mask. There
// is no screen-space half and therefore no swap between the two -- see
// transition_scene.h for why that was the whole difficulty in the previous
// version and why removing it removes the difficulty rather than hiding it.
//
// What used to be four shader entry points is one. `f_emerge` (a fullscreen
// pass that refracted and embossed the film by a face relief) and `f_relief`
// (which rasterised that relief) are both gone: the tenting is real geometry
// now, and the mask's depth is needed on the CPU for cloth contact rather than
// on the GPU for a fake.
#include <metal_stdlib>
using namespace metal;

struct Vertex {                 // matches the C++ Vertex (simd_float3 x2 + float2)
    float3 pos;
    float3 nrm;
    float2 uv;
};

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    float4 lightDir;            // xyz = light dir, w = mode (0 textured, 2 solid)
    float4 baseColor;
    float4 params;              // x = refraction of the film by the surface normal
};

struct VOut {
    float4 clip [[position]];
    float3 wnrm;
    float2 uv;
};

vertex VOut v_main(uint vid [[vertex_id]],
                   device const Vertex* verts [[buffer(0)]],
                   constant Uniforms& u [[buffer(1)]]) {
    VOut o;
    float3 p = verts[vid].pos;
    o.clip = u.mvp * float4(p, 1.0);
    o.wnrm = (u.model * float4(verts[vid].nrm, 0.0)).xyz;
    o.uv = verts[vid].uv;
    return o;
}

fragment float4 f_main(VOut in [[stage_in]],
                       constant Uniforms& u [[buffer(1)]],
                       texture2d<float> tex [[texture(0)]]) {
    // Two-sided, viewer-facing normal (the camera is fixed front-on). A flat
    // sheet then reads N=(0,0,1) and shades at full diffuse, which is what
    // makes the opening frame the pond and not a dim copy of it. Winding
    // otherwise leaves the flat cloth normal at -z (ndl=0), crushing it to
    // ambient -- a ~3x drop.
    float3 N = normalize(in.wnrm);
    if (N.z < 0.0) N = -N;
    float3 L = normalize(u.lightDir.xyz);
    float ndl = max(0.0, dot(N, L));
    // Shading as a *deviation* from the flat sheet, not an absolute.
    //
    // A flat surface reads exactly 1 whatever the light is doing, which is what
    // lets the opening frame be the pond rather than a dimmed copy of it, and
    // what frees the light to be as raking as the relief needs -- an absolute
    // formula would darken the whole film the moment the light came off-axis,
    // and the cut into this scene would flash. `params.y` then scales how far
    // the folds are allowed to swing either side of it: dividing through by the
    // flat response alone puts a lit fold at 1.7x and blows the film out.
    float flat = 0.30 + 0.85 * max(1e-3, L.z);
    float shade = 1.0 + u.params.y * ((0.30 + 0.85 * ndl) - flat) / flat;

    float mode = u.lightDir.w;
    float3 base;
    if (mode < 1.5) {
        constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
        // Refract the film where the fabric bends. Driven by the surface's own
        // normal, so it is identically zero on the flat sheet -- the rest state
        // has to *be* the pond, not a slightly displaced version of it -- and
        // it rises exactly where the sheet is stretched over the brow and the
        // nose, which is where a wet film would actually bend the image.
        float2 uv = in.uv + N.xy * u.params.x;
        base = tex.sample(smp, uv).rgb;
    } else {
        base = u.baseColor.rgb;
    }
    return float4(base * shade, 1.0);
}

// ---- the mask ---------------------------------------------------------------
//
// Shaded by `shadeFace` (face_shade.metal) -- the *same* material the root scene
// puts on it a moment later, driven by the same FaceParams/EnvParams values.
// That is the point: the transition ends with the mask alone on screen and the
// root scene begins with the mask in a tangle, and if the two shaded it
// separately the cut would land on a face that changed finish.
//
// The film keeps its own flat treatment (f_main above). The two halves of this
// scene are deliberately in different colour worlds: the film is the mirror's
// output, display-referred, and has to stay pixel-identical to the scene the
// piece cuts *from*; the mask is lit scene-referred radiance and goes through
// the same exposure + ACES + sRGB the root scene will apply, so it matches the
// scene the piece cuts *to*. The transition is where those two meet, and the
// mask being uncovered is exactly the moment the handover happens.

struct TransFaceX {
    float4 centre;      // mask centroid, transition world
    float4 lightPos;    // the mask's own light, already in shading space
    float  scale;       // transition world -> shading space
    float  exposure;
    int    tonemap;
    float  _pad;
};

struct MOut {
    float4 clip [[position]];
    float3 wpos;
    float3 nrm;
    float2 uv;
};

vertex MOut v_face(uint vid [[vertex_id]],
                   device const Vertex* verts [[buffer(0)]],
                   constant Uniforms& u [[buffer(1)]]) {
    MOut o;
    const float3 p = verts[vid].pos;
    o.clip = u.mvp * float4(p, 1.0);
    o.wpos = p;
    o.nrm  = verts[vid].nrm;
    o.uv   = verts[vid].uv;
    return o;
}

fragment float4 f_face(MOut in [[stage_in]],
                       constant RootFaceU& U [[buffer(1)]],
                       constant TransFaceX& X [[buffer(2)]],
                       texture2d<float> film [[texture(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    // The albedo is the film the mask is wearing, sampled at the projection that
    // placed the vertex -- so the mask carries away exactly the pixels that were
    // covering it. Taken as-is rather than linearised, because the root scene's
    // mask albedo (FaceFitter::sampleTexture, off the same mirror output) is
    // taken as-is too, and agreeing with the scene we hand over to matters more
    // here than the missing decode does.
    const float3 albedo = film.sample(smp, in.uv).rgb;

    // Into the shading space: the mask is about four world units across in the
    // root scene and about a third of that here, and the marble, the light
    // falloff and the spot cone are all world-space quantities tuned at that
    // size. One uniform scale about the mask's own centre puts every one of them
    // back where it was tuned, rather than re-tuning each against the other.
    const float3 P = (in.wpos - X.centre.xyz) * X.scale;

    float3 N = normalize(in.nrm);
    if (N.z < 0.0) N = -N;      // fixed front-on camera; the mask is an open shell

    const float4 lit = shadeFace(P, N, albedo, X.lightPos.xyz, U);

    float3 col = lit.rgb * X.exposure;
    col = (X.tonemap == 1) ? acesFitted(col) : saturate(col);
    return float4(srgbEncode(col), 1.0);
}
