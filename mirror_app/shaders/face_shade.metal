// face_shade.metal — the mask's material, shared by every pass that draws it.
//
// The mask is the one object the piece hands from scene to scene: the
// transition uncovers it, and the root scene then grows around it. If the two
// shaded it separately they would drift, and the cut between them would land on
// a face that changed finish — which is exactly the sort of seam this codebase
// spends its comments avoiding. So the material lives here, once, and both
// passes call `shadeFace`. `root_face.metal` and `transition.metal` keep only
// their own entry points and the geometry that feeds them.
//
// Prepended (as plain text, like root_shared.h — the runtime compiler has no
// include path) to the face and transition libraries; see MetalContext::
// newLibraryFromFiles. It reads `RootFaceU` from root_shared.h, which is
// therefore always concatenated ahead of it.
//
// Also holds the display transform (ACES + sRGB), because the mask is the one
// surface that needs it outside the root post chain: the transition's film is
// display-referred already (it is the mirror's own output) and must not be
// touched, while the mask is lit scene-referred radiance and has to go through
// the same curve the root scene will put it through a moment later.
#include <metal_stdlib>
using namespace metal;

constant float kFacePI = 3.14159265359;

// ---- Cook-Torrance ---------------------------------------------------------
// The same model the roots use. The mask used to run a bare pow(NdotH, 60)
// lobe, which gives one hard highlight dot of a fixed size no matter how the
// surface is angled -- the classic tell of a shader that has a specular
// exponent instead of a roughness.

static float D_GGX(float NdotH, float a2) {
    const float d = (NdotH * NdotH) * (a2 - 1.0) + 1.0;
    return a2 / (kFacePI * d * d);
}
static float G_Smith(float NdotV, float NdotL, float k) {
    const float gv = NdotV / (NdotV * (1.0 - k) + k);
    const float gl = NdotL / (NdotL * (1.0 - k) + k);
    return gv * gl;
}
static float3 F_Schlick(float c, float3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - c, 0.0, 1.0), 5.0);
}
static float3 ggx(float3 N, float3 V, float3 L, float3 albedo,
                  float metallic, float roughness) {
    const float NdotL = max(dot(N, L), 0.0);
    if (NdotL < 1e-4) return float3(0.0);
    const float3 H = normalize(V + L);
    const float NdotH = max(dot(N, H), 0.0);
    const float NdotV = max(dot(N, V), 1e-4);
    const float VdotH = max(dot(V, H), 0.0);
    const float a = roughness * roughness;
    const float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    const float3 F0 = mix(float3(0.04), albedo, metallic);
    const float3 F = F_Schlick(VdotH, F0);
    const float3 spec = (D_GGX(NdotH, a * a) * G_Smith(NdotV, NdotL, k) * F)
                      / max(4.0 * NdotV * NdotL, 1e-3);
    return ((1.0 - F) * (1.0 - metallic) * albedo / kFacePI + spec) * NdotL;
}

static float3 hemiAmbient(float3 n, float3 sky, float3 ground) {
    return mix(ground, sky, n.y * 0.5 + 0.5);
}

// ---- the mask's material ---------------------------------------------------
//
// `P` is the shading position (world in the root scene; the transition passes
// one scaled into the root scene's terms so the light falloff and spot cone
// keep the size they were tuned at).
//
// Returns rgb = linear radiance, a = the fraction of it that is indirect (the
// fog pass uses that to decide how much of a fragment the atmosphere may take).
static float4 shadeFace(float3 P, float3 nIn, float3 albedo, float3 lightPos,
                        constant RootFaceU& U) {
    float3 n = normalize(nIn);
    const float3 v = normalize(U.eye.xyz - P);
    // See RootFaceU::albedoGamma: the photograph arrives encoded.
    if (U.albedoGamma > 0.0 && U.albedoGamma != 1.0)
        albedo = pow(max(albedo, float3(0.0)), U.albedoGamma);
    if (U.albedoSat != 1.0) {
        const float luma = dot(albedo, float3(0.2126, 0.7152, 0.0722));
        albedo = max(mix(float3(luma), albedo, U.albedoSat), float3(0.0));
    }

    // The albedo is the visitor's photograph, lit as skin: no pattern, no
    // relief -- the marble vein/turbulence path that used to sit here mixed
    // grey into it and bent its normals, which is what washed the masks out.
    const float3 baseColor = albedo;
    const float rough = clamp(U.roughness, 0.04, 1.0);

    const float3 sky = U.skyColor.xyz, ground = U.groundColor.xyz;
    float3 indirect = baseColor * hemiAmbient(n, sky, ground) * U.hemiStrength;
    if (U.envSpec > 0.0) {
        const float NdotV = max(dot(n, v), 0.0);
        const float3 R = normalize(mix(reflect(-v, n), n, rough * rough));
        indirect += hemiAmbient(R, sky, ground)
                  * F_Schlick(NdotV, mix(float3(0.04), baseColor, U.metallic))
                  * U.envSpec * (1.0 - rough * 0.8);
    }
    if (U.rimStrength > 0.0)
        indirect += sky * (pow(1.0 - max(dot(n, v), 0.0), 3.0) * U.rimStrength);

    // The directional key, kept from the original as a soft two-sided fill.
    const float3 l = normalize(U.lightDir.xyz);
    float3 col = indirect + U.keyColor.xyz * baseColor * (0.04 + 0.06 * abs(dot(n, l)));

    // The mask's own light, sitting just in front of its face -- a spotlight
    // rather than a bare point. A point light a few units off a face lights the
    // brow, the nose and the surrounding roots equally, which is why the masks
    // read as self-illuminated objects sitting in the tangle rather than as
    // objects someone has aimed a lamp at. A cone falls off towards the edges of
    // the face and leaves the roots around it to the key and the environment.
    //
    // The cone axis is the mask's own facing, recovered from the light's offset:
    // the mesh builder places the light at (face origin + normal * lightDist),
    // so the direction from the light back to the face is the axis, to within
    // the width of the face itself.
    const float3 toLight = lightPos - P;
    const float dist = length(toLight);
    const float3 ldir = toLight / max(dist, 0.001);
    float atten = 1.0 / (1.0 + U.lightFalloff * dist * dist);
    if (U.spotCosOuter > -1.0 && U.spotLightDist > 1e-4) {
        // The cone angle without needing the axis. The mesh builder puts the
        // light exactly spotLightDist along the mask's normal from the face
        // plane, so for a point r out from the axis the light is
        // sqrt(spotLightDist^2 + r^2) away -- which makes spotLightDist/dist the
        // cosine of the angle off-axis directly. The alternative was carrying the
        // mask's plane normal through as a fourth vertex attribute; the shading
        // normal cannot stand in for it, because that is the thing that varies
        // across a face and the axis is the thing that must not.
        const float axisCos = clamp(U.spotLightDist / max(dist, 1e-4), 0.0, 1.0);
        atten *= smoothstep(U.spotCosOuter, U.spotCosInner, axisCos);
    }
    float3 direct = ggx(n, v, ldir, baseColor, U.metallic, rough)
                  * (U.lightColor.xyz * U.lightIntensity * U.specStrength * atten);

    // Skin and stone both pass light a short way through the surface before it
    // comes back out; the wrap term is what stops the terminator from cutting a
    // hard line across a cheekbone.
    if (U.sssWrap > 0.0 || U.sssTrans > 0.0) {
        const float w = max(U.sssWrap, 0.0);
        const float wrapped = max((dot(n, ldir) + w) / ((1.0 + w) * (1.0 + w)), 0.0);
        const float lam = max(dot(n, ldir), 0.0);
        float3 sss = baseColor * max(wrapped - lam, 0.0) * U.sssTint.xyz;
        if (U.sssTrans > 0.0)
            sss += baseColor * U.sssTint.xyz
                 * (pow(saturate(dot(v, -ldir)), max(U.sssPower, 1.0)) * U.sssTrans);
        direct += sss * (U.lightColor.xyz * U.lightIntensity * atten / kFacePI);
    }
    col += direct;

    // The pluck flash (RootFaceU::flashPos): a point light behind one mask's
    // face. From the front the mask is back-lit -- what shows is the light
    // through the skin (the transmission lobe, tinted) and whatever the eye
    // and mouth holes let straight through; the back and the rim take it
    // directly.
    if (any(U.flashColor.xyz > 0.0)) {
        const float3 toF = U.flashPos.xyz - P;
        const float d2 = dot(toF, toF);
        const float3 fl = toF * rsqrt(max(d2, 1e-6));
        const float r2 = max(U.flashPos.w * U.flashPos.w, 1e-4);
        const float fat = 1.0 / (1.0 + d2 / r2);
        float3 f = baseColor * max(dot(n, fl), 0.0) / kFacePI;
        f += baseColor * U.sssTint.xyz
           * (pow(saturate(dot(v, -fl)), max(U.sssPower, 1.0)) * U.sssTrans);
        col += U.flashColor.xyz * f * fat;
    }

    const float lumT = dot(col,      float3(0.2126, 0.7152, 0.0722));
    const float lumI = dot(indirect, float3(0.2126, 0.7152, 0.0722));
    return float4(col, saturate(lumI / max(lumT, 1e-5)));
}

// ---- the display transform -------------------------------------------------

// ACES filmic, Stephen Hill's RRT+ODT fit. Chosen over a Reinhard curve because
// the shoulder desaturates towards white the way film does; Reinhard holds
// saturation into the clip and the bright wisps come out as flat colour blobs.
static constant float3x3 kACESIn = float3x3(
    float3(0.59719, 0.07600, 0.02840),
    float3(0.35458, 0.90834, 0.13383),
    float3(0.04823, 0.01566, 0.83777));
static constant float3x3 kACESOut = float3x3(
    float3( 1.60475, -0.10208, -0.00327),
    float3(-0.53108,  1.10813, -0.07276),
    float3(-0.07367, -0.00605,  1.07602));

static float3 acesFitted(float3 c) {
    c = kACESIn * c;
    float3 a = c * (c + 0.0245786) - 0.000090537;
    float3 b = c * (0.983729 * c + 0.4329510) + 0.238081;
    c = kACESOut * (a / b);
    return clamp(c, 0.0, 1.0);
}

// Piecewise sRGB, not pow(1/2.2). The two diverge most in the darkest stop, and
// the fog floor of this scene lives exactly there.
static float3 srgbEncode(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}
