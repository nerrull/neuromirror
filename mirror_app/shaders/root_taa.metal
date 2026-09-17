// root_taa.metal — temporal anti-aliasing, two passes between the fog
// composite and root_post.metal.
//
// The capsules have no coverage to resolve (their edge is a discard), so the
// supersample box in root_post.metal was the whole of the anti-aliasing, and
// at 2x or 3x it leaves the long thick roots crawling as the orbit moves:
// the edge of a root sits at a different sub-sample each frame, and so does
// the specular highlight along it. This spreads that sampling over time
// instead. Every frame the projection is jittered by a fraction of an output
// pixel (RootGeomU::jitter, a Halton pair chosen by the host), and the result
// is blended with the previous frame's, fetched from where this pixel *was*
// according to the camera-reprojection motion field root_glitch.metal
// already computes for the datamosh. Over a dozen frames the blend has seen a
// dozen sub-pixel positions of every edge -- a supersample the grid alone
// could not afford.
//
// The history is only trusted within the colour range of the current frame's
// 3x3 neighbourhood (mean +- clipGamma standard deviations, in YCoCg): a
// pixel the reprojection got wrong -- a disocclusion, a mask lighting up,
// the cloth's own motion which the camera field knows nothing about -- lands
// outside that range and is pulled back to the edge of it, so the worst
// case is a frame of ghosting, not a smear. The fetch is Catmull-Rom rather
// than bilinear so a slow orbit does not blur the accumulated picture a
// little more every frame.
#include <metal_stdlib>
using namespace metal;

struct TaaVOut { float4 pos [[position]]; };

vertex TaaVOut root_taa_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    TaaVOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// --- pass 1: supersample resolve --------------------------------------------
// The same box root_post.metal's resolveScene4 applies, to an output-sized
// target so the neighbourhood below is 9 fetches rather than 9 boxes. Alpha
// comes through untouched: the post pass reads the cloth's film weight from
// it (root_cloth.metal), and that is a per-frame fact, not one to accumulate.
fragment float4 root_taa_resolve_fs(TaaVOut in [[stage_in]],
                                    constant RootTaaU& U        [[buffer(0)]],
                                    texture2d<float>   sceneTex [[texture(0)]]) {
    constexpr sampler linSmp(mag_filter::linear, min_filter::linear,
                             address::clamp_to_edge);
    const float2 uv = in.pos.xy / U.res;
    if (U.ssaa <= 1) return sceneTex.sample(linSmp, uv);
    const float inv = 1.0 / float(U.ssaa);
    float4 acc = float4(0.0);
    for (int y = 0; y < 4; ++y) {
        if (y >= U.ssaa) break;
        for (int x = 0; x < 4; ++x) {
            if (x >= U.ssaa) break;
            const float2 o = (float2(x, y) + 0.5) * inv - 0.5;
            acc += sceneTex.sample(linSmp, uv + o * U.srcTexel);
        }
    }
    return acc / float(U.ssaa * U.ssaa);
}

// --- pass 2: the blend --------------------------------------------------------
static float3 toYCoCg(float3 c) {
    return float3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
                  0.5 * c.r - 0.5 * c.b,
                  -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}
static float3 fromYCoCg(float3 c) {
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// Bicubic Catmull-Rom in 5 bilinear fetches (the corner taps dropped, the
// usual approximation): sharper than bilinear, and unlike bilinear it does
// not turn a sub-pixel motion into a low-pass filter applied every frame.
static float3 sampleHistory(texture2d<float> tex, sampler smp, float2 uv, float2 res) {
    const float2 pos = uv * res;
    const float2 center = floor(pos - 0.5) + 0.5;
    const float2 f = pos - center;
    const float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    const float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    const float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    const float2 w3 = f * f * (-0.5 + 0.5 * f);
    const float2 w12 = w1 + w2;
    const float2 off12 = w2 / w12;
    const float2 tc0  = (center - 1.0) / res;
    const float2 tc3  = (center + 2.0) / res;
    const float2 tc12 = (center + off12) / res;
    float3 acc = float3(0.0);
    float  wsum = 0.0;
    acc += tex.sample(smp, float2(tc12.x, tc0.y)).rgb  * w12.x * w0.y;  wsum += w12.x * w0.y;
    acc += tex.sample(smp, float2(tc0.x,  tc12.y)).rgb * w0.x  * w12.y; wsum += w0.x  * w12.y;
    acc += tex.sample(smp, float2(tc12.x, tc12.y)).rgb * w12.x * w12.y; wsum += w12.x * w12.y;
    acc += tex.sample(smp, float2(tc3.x,  tc12.y)).rgb * w3.x  * w12.y; wsum += w3.x  * w12.y;
    acc += tex.sample(smp, float2(tc12.x, tc3.y)).rgb  * w12.x * w3.y;  wsum += w12.x * w3.y;
    return max(acc / wsum, 0.0);
}

fragment float4 root_taa_fs(TaaVOut in [[stage_in]],
                            constant RootTaaU& U         [[buffer(0)]],
                            texture2d<float>   curTex    [[texture(0)]],   // this frame, resolved
                            texture2d<float>   histTex   [[texture(1)]],   // last frame's output
                            texture2d<float>   motionTex [[texture(2)]]) { // uv_now - uv_prev
    constexpr sampler pt(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);
    constexpr sampler linSmp(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    const float2 uv = in.pos.xy / U.res;
    const float4 cur = curTex.sample(pt, uv);
    if (U.histValid == 0) return cur;

    const float2 puv = uv - motionTex.sample(pt, uv).xy;
    if (any(puv < 0.0) || any(puv > 1.0)) return cur;   // came in from off screen

    // Neighbourhood statistics, 3x3 around this pixel.
    float3 m1 = float3(0.0), m2 = float3(0.0);
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x) {
            const float3 c = toYCoCg(curTex.sample(pt, uv + float2(x, y) / U.res).rgb);
            m1 += c; m2 += c * c;
        }
    const float3 mean  = m1 / 9.0;
    const float3 sigma = sqrt(max(m2 / 9.0 - mean * mean, 0.0));
    const float3 lo = mean - U.clipGamma * sigma;
    const float3 hi = mean + U.clipGamma * sigma;

    // Clip the history towards the current colour, to the box's surface: the
    // whole of the blend then stays inside what this frame can vouch for.
    const float3 c = toYCoCg(cur.rgb);
    float3 h = toYCoCg(sampleHistory(histTex, linSmp, puv, U.res));
    {
        const float3 centre = 0.5 * (hi + lo);
        const float3 extent = 0.5 * (hi - lo) + 1e-4;
        const float3 d = h - centre;
        const float3 unit = abs(d / extent);
        const float  m = max(unit.x, max(unit.y, unit.z));
        if (m > 1.0) h = centre + d / m;
    }
    const float3 outC = fromYCoCg(mix(h, c, U.blend));
    return float4(max(outC, 0.0), cur.a);
}
