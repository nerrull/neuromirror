// root_wire.metal — the harp's wires: fine luminescent lines, one per string
// of the resolved window's strum, standing on an arc around the anchor mask
// where the head plucks them (RootScene::setHarpWires, main.mm's strum).
//
// Same targets and depth convention as the other mid-geometry passes (face,
// leaf, cloth) so the wires depth-composite against the mask and roots and
// are fogged with them -- but unlit: a wire is a light, not a lit object.
// Blended over, not added: the show's
// field behind the mask is near white, and a light added to white is
// nothing, so the wire replaces what is behind it with its own colour --
// dark against the field at rest, bright and wide when plucked.
//
// A wire is two world endpoints and a screen-space width. The vertex shader
// projects both ends and pushes each corner out perpendicular to the wire's
// screen direction by the wire's `width` pixels, so the wire stays a hair
// thin however far the camera is; `side` (-1..1 across it) reaches the
// fragment shader as the filament's profile.
#include <metal_stdlib>
using namespace metal;

struct WireVertex {
    packed_float3 a;      // the wire's foot
    packed_float3 b;      // its head
    float         side;   // -1 / +1, which edge of the strip
    float         t;      // 0 = a, 1 = b
    float         glow;   // brightness this frame, 0 = off
    float         width;  // half-width in output pixels
};

struct WireVOut {
    float4 pos [[position]];
    float  side;
    float  t;
    float  glow;
};

vertex WireVOut root_wire_vs(uint vid [[vertex_id]],
                             device const WireVertex* verts [[buffer(0)]],
                             constant RootWireU&      U     [[buffer(1)]]) {
    WireVertex v = verts[vid];
    float4 ca = U.viewProj * float4(float3(v.a), 1.0);
    float4 cb = U.viewProj * float4(float3(v.b), 1.0);
    // The wire's direction on screen, from the two ends' NDC.
    const float2 sa = ca.xy / max(ca.w, 1e-4), sb = cb.xy / max(cb.w, 1e-4);
    float2 d = (sb - sa) * U.res * 0.5;
    d = dot(d, d) > 1e-8 ? normalize(d) : float2(0.0, 1.0);
    const float2 n = float2(-d.y, d.x);
    float4 c = mix(ca, cb, v.t);
    // `width` pixels either side: NDC moves by px * 2/res, clip by that x w.
    c.xy += n * v.side * v.width * U.pxScale * (2.0 / U.res) * c.w;
    c.z = (c.z + c.w) * 0.5;   // GL [-1,1] clip-z -> Metal [0,1], matches the capsule depth
    WireVOut o;
    o.pos = c;
    o.side = v.side;
    o.t = v.t;
    o.glow = v.glow;
    return o;
}

fragment float4 root_wire_fs(WireVOut in [[stage_in]],
                             constant RootWireU& U [[buffer(1)]]) {
    // A filament: solid core, soft to the strip's edge. The alpha here is
    // only the blend's coverage -- the colour mask keeps the target's own
    // alpha (the fog's AO share) as the surface beneath.
    // Its ends fade over the last fifth, so it hangs rather than stands.
    const float k = saturate(1.0 - in.side * in.side);
    const float ends = saturate((1.0 - abs(2.0 * in.t - 1.0)) * 5.0);
    return float4(U.color.xyz * in.glow, k * k * ends);
}
