// root_wire.metal — the harp's strings: one per string of the resolved
// window's strum, a hair-thin vertical line pinned to the top and bottom of
// the screen, standing at the anchor mask's depth beside it where the head
// plucks it (RootScene::setHarpWires, main.mm's strum). A plucked string
// widens and vibrates -- a standing wave, one node at each end, at a
// fraction of the note's frequency.
//
// Same colour + depth targets as the other mid-geometry passes, so a string
// hides behind what is nearer and the fog takes it at the mask's distance
// (its depth is written for that). It has no colour of its own: it inverts
// what is behind it, read straight from the target (framebuffer fetch, an
// Apple-GPU thing) -- dark across the field, light across the mask.
//
// A string is a world anchor (the mask), an offset from the anchor's
// screen x in NDC, and a width in pixels. The vertex shader projects the
// anchor, puts the string at that x, runs it -1..1 in y, and pushes each
// corner out by the string's half-width plus the wave's displacement.
#include <metal_stdlib>
using namespace metal;

struct WireVertex {
    packed_float3 anchor;  // the mask, for the string's depth and screen x
    float         xoff;    // from the anchor's screen x, NDC
    float         side;    // -1 / +1, which edge of the strip
    float         t;       // 0 = screen bottom, 1 = top
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
    float4 ca = U.viewProj * float4(float3(v.anchor), 1.0);
    const float3 ndc = ca.xyz / max(ca.w, 1e-4);
    // Pixels to NDC: 2/res, at the scene's supersample.
    const float px = v.side * v.width + v.wob * sin(v.t * 3.14159265);
    WireVOut o;
    o.pos = float4(ndc.x + v.xoff + px * U.pxScale * 2.0 / U.res.x,
                   mix(-1.0, 1.0, v.t),
                   (ndc.z + 1.0) * 0.5,   // GL [-1,1] -> Metal [0,1], matches the capsule depth
                   1.0);
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
