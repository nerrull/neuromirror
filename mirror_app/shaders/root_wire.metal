// root_wire.metal — the harp's strings: one per string of the resolved
// window's strum, a hair-thin vertical line standing in the world on a
// circle around the anchor mask, at the azimuth the head's yaw plucks it
// (RootScene::setHarpWires, main.mm's strum). A plucked string widens and
// vibrates -- a standing wave, one node at each end, at a fraction of the
// note's frequency.
//
// Drawn after the fog, over its composite, against the geometry pass's
// depth: a string behind the mask is hidden by it, and what shows is an
// inversion of the *fogged* picture, which is what makes it readable --
// drawn before the fog, the inversion was fogged back toward the field and
// lost. It has no colour of its own: it inverts what is behind it, read
// straight from the target (framebuffer fetch, an Apple-GPU thing).
//
// A string is its two world ends. The vertex shader projects both, puts
// the vertex along the line between them (interpolated in clip space, so
// the line stays straight under perspective) and pushes each corner out,
// perpendicular to the line on screen, by the string's half-width plus the
// wave's displacement -- both in pixels, so the string stays a hair however
// far off it stands.
#include <metal_stdlib>
using namespace metal;

struct WireVertex {
    packed_float3 a;       // the string's bottom end, world
    packed_float3 b;       // its top end, world
    float         side;    // -1 / +1, which edge of the strip
    float         t;       // 0 = at a, 1 = at b
    float         width;   // half-width in output pixels
    float         wob;     // the wave's displacement at its belly, pixels, signed
};

struct WireVOut {
    float4 pos [[position]];
    float  side;
};

vertex WireVOut root_wire_vs(uint vid [[vertex_id]],
                             device const WireVertex* verts [[buffer(0)]],
                             constant RootWireU&      U     [[buffer(1)]]) {
    WireVertex v = verts[vid];
    const float4 ca = U.viewProj * float4(float3(v.a), 1.0);
    const float4 cb = U.viewProj * float4(float3(v.b), 1.0);
    float4 c = mix(ca, cb, v.t);
    // The line's direction on screen, in pixels, for the perpendicular.
    const float2 pa = ca.xy / max(ca.w, 1e-4) * U.res;
    const float2 pb = cb.xy / max(cb.w, 1e-4) * U.res;
    float2 d = pb - pa;
    d = length(d) > 1e-3 ? normalize(d) : float2(0.0, 1.0);
    const float2 n = float2(-d.y, d.x);
    // Pixels to NDC: 2/res, at the scene's supersample; in clip space, so x w.
    const float px = v.side * v.width + v.wob * sin(v.t * 3.14159265);
    c.xy += n * px * U.pxScale * 2.0 / U.res * c.w;
    WireVOut o;
    o.pos = float4(c.xy, (c.z + c.w) * 0.5, c.w);   // GL clip-z -> Metal, as root_face.metal
    o.side = v.side;
    return o;
}

fragment float4 root_wire_fs(WireVOut in [[stage_in]],
                             float4 dst [[color(0)]]) {
    // A filament: solid core, soft to the strip's edge, over an inversion
    // of what is there. The target's alpha (the fog's AO share) stays.
    const float k = saturate(1.0 - in.side * in.side);
    return float4(mix(dst.rgb, saturate(1.0 - dst.rgb), k * k), dst.a);
}
