// root_glitch.metal — the three passes that sit after the composite: camera
// reprojection motion vectors, a pixel sort, and the datamosh + bitcrush that
// finish the frame.
//
// Everything upstream of here is trying to make a photograph. This file is
// trying to make a *broken copy* of one, so it works on the finished,
// display-referred frame root_post.metal handed over and on the frame before
// it -- never on radiance.
//
// Datamosh, briefly: a video codec sends a keyframe and then, for a while,
// only the motion of blocks within it. Drop the keyframes and the decoder
// keeps pushing the last picture it had around the screen along vectors that
// no longer describe it, and the image dissolves into smeared blocks that
// still, unmistakably, move like the scene. The two halves of that here are a
// feedback buffer (last frame's *output*, so the smear accumulates) and a
// motion field the host stops updating the moment the effect starts -- which
// is what "the vectors stay fixed" means: the picture keeps being dragged
// along a motion that has already finished happening.
#include <metal_stdlib>
using namespace metal;

struct GlitchVOut { float4 pos [[position]]; };

vertex GlitchVOut root_glitch_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    GlitchVOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// GL-convention depth (see root_geom.metal) -> positive view-space distance.
static float linearDepth(float d, float nearZ, float farZ) {
    const float ndcZ = d * 2.0 - 1.0;
    return (2.0 * nearZ * farZ) / (farZ + nearZ - ndcZ * (farZ - nearZ));
}

// --- pass 1: motion vectors ------------------------------------------------
// Output is (uv_now - uv_prev): where this pixel *was*, as an offset, which is
// the form the resample below wants. Written to an RG16F target at output
// resolution; the depth it reads is the scene's, which may be supersampled --
// normalised coordinates make that a non-issue.
fragment float4 root_motion_fs(GlitchVOut in [[stage_in]],
                               constant RootMotionU& U       [[buffer(0)]],
                               depth2d<float>        depthTex [[texture(0)]]) {
    // Point-sampled: a linear fetch across a silhouette averages the near and
    // the far depth into a distance that is neither, and the vector built from
    // it points somewhere no surface is.
    constexpr sampler pt(mag_filter::nearest, min_filter::nearest,
                         address::clamp_to_edge);

    const float2 uv = in.pos.xy / U.res;
    const float  d  = depthTex.sample(pt, uv);

    // The same ray reconstruction as root_fog/root_ao, so all three passes
    // agree about where a pixel is in the world.
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - 2.0 * uv.y);
    ndc.x *= U.res.x / U.res.y;
    const float3 dirV = float3(ndc * tan(U.fov), 1.0);   // view space, +Z fwd
    const float  ze = (d >= 0.9999) ? U.bgDepth : linearDepth(d, U.nearZ, U.farZ);
    const float3 world = U.eye.xyz + (U.cam * dirV) * ze;

    const float4 clip = U.prevViewProj * float4(world, 1.0);
    if (clip.w <= 1e-5) return float4(0.0);   // behind the previous camera
    const float3 pndc = clip.xyz / clip.w;
    const float2 puv = float2(pndc.x * 0.5 + 0.5, 0.5 - pndc.y * 0.5);
    return float4(uv - puv, 0.0, 0.0);
}

static float lumaOf(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// --- pass 2: pixel sort ----------------------------------------------------
// One step of an odd-even transposition sort, run on the sort state (last
// frame's step) with the live frame fed into it. Two texture reads of each
// buffer and no loop: the convergence is spread over frames instead of being
// paid for in one.
//
// The pairing alternates with `parity`, which the host flips every pass -- pass
// n pairs (0,1)(2,3)..., pass n+1 pairs (1,2)(3,4)..., and it is that
// alternation, not the comparison, that lets a value travel further than one
// pixel.
fragment float4 root_sort_fs(GlitchVOut in [[stage_in]],
                             constant RootSortU& U       [[buffer(0)]],
                             texture2d<float>    stateTex [[texture(0)]],
                             texture2d<float>    curTex   [[texture(1)]]) {
    constexpr sampler pt(mag_filter::nearest, min_filter::nearest,
                         address::clamp_to_edge);

    const float2 uv = in.pos.xy / U.res;
    // Which way is "along the span", as a one-texel step and as this pixel's
    // index in that direction.
    const float2 step = (U.axis == 0) ? float2(0.0, 1.0 / U.res.y)
                                      : float2(1.0 / U.res.x, 0.0);
    const int idx = int((U.axis == 0) ? in.pos.y : in.pos.x);

    // The state, with a little of the live frame fed back in so a sorted
    // picture keeps following the scene instead of freezing solid. On the first
    // frame of a run there is no state to read.
    float3 me, nb;
    const float2 dir = (((idx + U.parity) & 1) == 0) ? step : -step;
    const float3 curMe = curTex.sample(pt, uv).rgb;
    const float3 curNb = curTex.sample(pt, uv + dir).rgb;
    if (U.seed == 1) {
        me = curMe; nb = curNb;
    } else {
        me = mix(stateTex.sample(pt, uv).rgb,       curMe, U.feed);
        nb = mix(stateTex.sample(pt, uv + dir).rgb, curNb, U.feed);
    }

    // The pinned pixels are what make this read as sorted *spans* rather than
    // as a sorted screen: a run of in-band pixels can only ever rearrange
    // itself between the out-of-band pixels that bound it.
    const float lMe = lumaOf(me), lNb = lumaOf(nb);
    const bool inBand = (lMe >= U.lo && lMe <= U.hi) && (lNb >= U.lo && lNb <= U.hi);
    if (!inBand) return float4(me, 1.0);

    // `dir` points at the partner; a positive step means this pixel is the
    // earlier of the pair and should be holding the smaller luminance.
    const bool iAmFirst = (dir.x + dir.y) > 0.0;
    const bool wantSwap = U.descending == 1 ? (iAmFirst ? (lMe < lNb) : (lMe > lNb))
                                            : (iAmFirst ? (lMe > lNb) : (lMe < lNb));
    return float4(wantSwap ? nb : me, 1.0);
}

// 4x4 ordered Bayer, normalised to [0,1). Ordered rather than the interleaved
// gradient noise the rest of the chain uses: at four or five levels per channel
// a blue-noise dither reads as noise, and the recognisable thing about a
// crushed image is its *pattern* -- the cross-hatch is the point.
static float bayer4(float2 p) {
    const int x = int(p.x) & 3, y = int(p.y) & 3;
    const int m[16] = { 0,  8,  2, 10,
                       12,  4, 14,  6,
                        3, 11,  1,  9,
                       15,  7, 13,  5 };
    return float(m[y * 4 + x]) * (1.0 / 16.0);
}

// --- pass 3: datamosh + bitcrush -------------------------------------------
fragment float4 root_glitch_fs(GlitchVOut in [[stage_in]],
                               constant RootGlitchU& U       [[buffer(0)]],
                               texture2d<float>      srcTex   [[texture(0)]],
                               texture2d<float>      histTex  [[texture(1)]],
                               texture2d<float>      mvTex    [[texture(2)]],
                               texture2d<float>      sortTex  [[texture(3)]]) {
    constexpr sampler linSmp(mag_filter::linear, min_filter::linear,
                             address::clamp_to_edge);
    constexpr sampler ptSmp(mag_filter::nearest, min_filter::nearest,
                            address::clamp_to_edge);

    const float2 uv = in.pos.xy / U.res;

    // The crush's block size drives *where* everything below reads from, not
    // what it does to the colour afterwards: one sample per block, shared by
    // every pixel in it, is what makes this a resolution drop rather than a
    // blur. It also means the mosh feedback is resampled at the low rate too,
    // so the two effects compound the way a bad decode of a low-bitrate stream
    // does instead of sitting in separate layers.
    const float crush = saturate(U.crush);
    const float blk   = mix(1.0, max(U.crushBlock, 1.0), crush);
    const float2 suv  = (blk > 1.0) ? (floor(in.pos.xy / blk) + 0.5) * blk / U.res
                                    : uv;

    float3 col = srcTex.sample(linSmp, suv).rgb;

    // The sort first: it is a rearrangement of *this* picture, so the mosh's
    // feedback should be dragging the sorted image around, not sorting a
    // dragged one.
    if (U.sortOn == 1)
        col = mix(col, sortTex.sample(linSmp, suv).rgb, saturate(U.sortAmount));

    if (U.moshOn == 1) {
        // Quantise the lookup of the motion field to macroblocks. A codec's
        // vectors are per-block, and it is that quantisation -- one vector
        // dragging a whole square of picture -- that gives datamosh its
        // signature torn rectangles rather than a smooth optical-flow warp.
        const float mb = max(U.moshBlock, 1.0);
        const float2 buv = (floor(suv * U.res / mb) + 0.5) * mb / U.res;
        const float2 mv = mvTex.sample(ptSmp, buv).xy * U.moshGain;
        // histTex is the previous frame's *output* of this pass, so each frame
        // re-warps an already-warped picture and the displacement accumulates.
        const float3 hist = histTex.sample(linSmp, suv - mv).rgb;
        col = mix(col, hist, saturate(U.moshAmount));
    }

    if (crush > 0.0) {
        // 256 at crush = 0 so the dial's bottom end is the 8-bit output the
        // drawable was going to quantise to anyway -- i.e. off, exactly.
        const float L = mix(256.0, max(U.crushLevels, 2.0), crush);
        if (U.crushDither > 0.0)
            col += (bayer4(in.pos.xy) - 0.5) * (U.crushDither / L);
        col = floor(saturate(col) * (L - 1.0) + 0.5) / (L - 1.0);
    }

    return float4(col, 1.0);
}
