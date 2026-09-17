// root_shared.h — layout-compatible uniform structs shared by the Metal root
// renderer (C++/ObjC++ host) and its MSL passes (root_geom.metal, root_fog.metal).
//
// The same file is #included from both sides: __METAL_VERSION__ selects MSL
// vector/matrix types, otherwise <simd/simd.h>. simd_* and MSL types have
// matching size/alignment (float3=16B, float4x4=64B, float3x3=48B), so a struct
// written here maps byte-for-byte onto a Metal argument buffer. Vec3 quantities
// are stored as float4 (w unused) so member alignment never diverges.
#ifndef ROOT_SHARED_H
#define ROOT_SHARED_H

#ifdef __METAL_VERSION__
    // This header is prepended to the MSL passes before their own includes, so it
    // must bring the metal types into scope itself.
    #include <metal_stdlib>
    using namespace metal;
    #define RS_F2   float2
    #define RS_F4   float4
    #define RS_F3X3 float3x3
    #define RS_F4X4 float4x4
    #define RS_INT  int
#else
    #include <simd/simd.h>
    #define RS_F2   simd_float2
    #define RS_F4   simd_float4
    #define RS_F3X3 simd_float3x3
    #define RS_F4X4 simd_float4x4
    #define RS_INT  int32_t
#endif

#define ROOT_MAX_GROUPS 8
// Pluck flash lights a frame can carry (every mask, when flash.all is on).
#define ROOT_MAX_FLASH 24

// Baked-noise tiling period; must match the CPU bake in metal_root_renderer.mm
// and the divisor in both MSL passes.
#define ROOT_NOISE_TILE_PERIOD 8.0f

// Geometry pass (root_geom.metal): capsule/blade sphere-tracer + shading.
struct RootGeomU {
    RS_F4X4 viewProj;
    RS_F3X3 cam;          // camera basis (right, up, fwd) as columns
    RS_F4   eye;          // xyz
    RS_F4   baseColor;
    RS_F4   baseColor2;
    RS_F4   specColor;
    RS_F4   lightDir;
    RS_F4   pulseColor;
    RS_F2   res;
    float   fov;
    float   radiusScale;
    float   radiusMin;
    float   radiusMax;
    float   ambient;
    float   diffuse;
    float   shininess;
    float   colorNoiseScale;
    float   colorNoiseStrength;
    float   metallic;
    float   roughness;
    float   pulseSpeed;
    float   pulseSpacing;
    float   pulseWidth;
    float   pulseIntensity;
    float   pulseTime;
    RS_INT  shaderMode;   // 0 Phong, 1 PBR, 2 Invert
    RS_INT  paletteCount;
    RS_INT  pulseEnabled;
    float   cullPx;       // drop capsules projecting smaller than this (0 = off)
    // Floor on a capsule's projected radius, in (internal, SSAA-scaled)
    // pixels; 0 = off. A capsule thinner than this is drawn this thick and
    // its radiance scaled by the ratio, so a hairline root at orbit distance
    // is a steady faint line rather than one that flashes as the samples
    // slide across it. See root_geom.metal's radius floor.
    float   minRadiusPx;
    // --- environment / organic shading --------------------------------------
    // A two-colour hemisphere standing in for an environment probe, plus the
    // terms that make a tube read as tissue rather than as painted plastic.
    RS_F4   skyColor;     // xyz, hemisphere upper
    RS_F4   groundColor;  // xyz, hemisphere lower (bounce)
    RS_F4   sssTint;      // xyz, colour light takes on its way through
    float   hemiStrength; // 0 = flat constant ambient (the old look)
    float   envSpec;      // roughness-blurred sky reflection
    float   rimStrength;  // Fresnel edge sheen
    float   sssWrap;      // diffuse wrap: (NdotL + w) / (1 + w)
    float   sssTrans;     // back-lit transmission amount
    float   sssPower;     // transmission lobe tightness
    // --- surface detail (capsules and blades) --------------------------------
    float   detailStrength;  // normal perturbation from the stretched noise
    float   detailScale;     // its frequency, in world units^-1
    float   detailStretch;   // how far features elongate along the root axis
    float   detailRough;     // specular/roughness break-up from the same field
    float   detailTint;      // per-segment albedo jitter
    float   detailFadePx;    // internal px one noise cell must span for full
                             // detail; strength and rough fade to 0 below half
                             // of it. 0 = never fade.
    float   _padD0;
    // Sub-pixel jitter of the projection, NDC units, for the temporal AA
    // (root_taa.metal). viewProj already carries it; the ray the fragment
    // builds from its pixel has to subtract it so pixel and matrix agree.
    RS_F2   jitter;
    RS_F4   keyColor;        // xyz, directional key colour x intensity
    // The pluck flash (MetalRootRenderer::Flash): bare point lights inside
    // masks, fired on a pluck marker during the Orbit -- one mask, or all of
    // them. xyz = position, w = the radius the inverse-square falloff is
    // normalised to; colour is colour x intensity; flashCount 0 = none.
    RS_F4   flashPos[ROOT_MAX_FLASH];
    RS_F4   flashColor;
    RS_INT  flashCount;
    RS_INT  _padFl0, _padFl1, _padFl2;
    RS_F4   palette[ROOT_MAX_GROUPS];
    RS_F4   paletteTip[ROOT_MAX_GROUPS];
};

// Per-draw companion to RootGeomU (buffer 9 of the geometry pass): the one
// thing that differs between the capsule sets a frame draws. RootGeomU is
// bound once per frame; this is bound once per set -- the live system and
// then each cached instance -- so an instance can stand in the scene dark.
struct RootDrawU {
    // 0 = dark: the set is drawn, occludes, and takes the fog, but keeps only
    // unlitLevel of its radiance -- no key, no fill, no pulse to speak of.
    // 1 = lit as normal. Anything between is a ramp between the two.
    float   lit;
    float   unlitLevel;
    // The pulse clock (RootGeomU::pulseTime) at which this set's pulses
    // started, or < 0 for always-on (the live system). Started, the set has
    // a travelling front at pulseSpeed x (pulseTime - pulseStart) along the
    // node distance: pulses run only behind it, and `lit` applies only behind
    // it too -- ahead of the front the set is still dark. So a structure
    // lights from its top mask down as its first pulses run, which is what
    // the Reveal (root_sequence.h) lights each structure's masks in step
    // with.
    float   pulseStart;
    float   _pad1;
};

// Face mid-geometry pass (root_face.metal): mask meshes rasterized into the
// shared colour+depth target between the capsule pass and fog.
struct RootFaceU {
    RS_F4X4 viewProj;
    RS_F4   eye;          // xyz
    RS_F4   lightDir;     // xyz
    float   lightIntensity;
    float   lightFalloff;
    float   specStrength;
    float   roughness;    // GGX roughness
    float   metallic;
    RS_F4   skyColor;
    RS_F4   groundColor;
    RS_F4   sssTint;
    float   hemiStrength;
    float   envSpec;
    float   rimStrength;
    float   sssWrap;
    float   sssTrans;
    float   sssPower;
    // The mask light as a spotlight rather than a bare point: cosines of the
    // half-angles at which it starts and finishes falling off, aimed along the
    // mask's own facing.
    float   spotCosOuter;
    float   spotCosInner;
    float   spotLightDist;   // the offset the mesh builder used, so the shader
                             // can recover the off-axis angle from the distance
    // What a mask drawn dark keeps of its radiance -- the face mesh carries
    // `lit` per vertex (FaceVertex in root_face.metal), since one mesh holds
    // every structure's masks; same meaning as RootDrawU::unlitLevel.
    float   unlitLevel;
    // Decode applied to the albedo before lighting: the mask wears the mirror's
    // output, which is display-referred (the pond is trained on camera pixels
    // and presented to a non-sRGB layer), so lighting it as if linear and then
    // encoding again washes it out. 2.2 undoes that; 1 is the old as-is.
    float   albedoGamma;
    // Saturation of the decoded albedo about its luma: 1 leaves the
    // photograph alone, >1 pushes back against what the lighting (a white
    // spot, the env sheen, the ACES shoulder) washes out of it.
    float   albedoSat;
    RS_F4   lightColor;   // xyz, the mask's own spotlight's colour (x lightIntensity)
    RS_F4   keyColor;     // xyz, the directional key's colour x intensity
    // The pluck flash (MetalRootRenderer::Flash): bare point lights inside
    // masks, fired on a pluck marker during the Orbit -- one mask, or all of
    // them. xyz = position, w = the radius the inverse-square falloff is
    // normalised to; colour is colour x intensity; flashCount 0 = none.
    RS_F4   flashPos[ROOT_MAX_FLASH];
    RS_F4   flashColor;
    RS_INT  flashCount;
    RS_INT  _padFl0, _padFl1, _padFl2;
};

// Cloth mid-geometry pass (root_cloth.metal): the pond -> face draped sheet,
// rasterized into the shared colour+depth target alongside the face mask and
// the leaves. Ported from TransitionScene's f_main (transition.metal), minus
// the fixed front-on camera assumption -- the cloth now sits in RootScene's
// own orbiting camera, sharing its viewProj/lightDir rather than owning a
// second fixed one.
struct RootClothU {
    RS_F4X4 viewProj;
    RS_F4   lightDir;     // xyz
    float   refract;      // uv shift from the surface normal, gated by displacement
    float   reliefShade;  // how far Lambert is allowed to swing from the flat sheet
    float   reliefSharp;  // curvature term strength
    float   sheen;        // raking specular on the sheet's own bends
    // How much of this pass's output is a display-referred *picture* rather
    // than scene radiance. The film the sheet carries is the mirror's own
    // output -- the exact image the piece cuts from -- so grading it (exposure,
    // ACES, split-tone, fog, AO, vignette, grain) makes the cut visible: on a
    // live fit it moves the frame by 0.27 mean absolute, which is not a seam,
    // it is a dissolve to a washed-out copy. The cloth pass writes -passThrough
    // into alpha; root_fog.metal and root_post.metal read that and hand the
    // pixel back unchanged. Ramps to 0 across the release, so the film that
    // falls away *is* graded with the scene it is falling into -- it stops
    // being a picture and becomes an object at the same moment it stops
    // covering the frame.
    float passThrough;
};

// Leaf mid-geometry pass (root_leaf.metal): meshed leaves rasterized into the
// same shared colour+depth target as the face masks, for the same reason -- but
// with leaf shading (matte lamina, back-lit translucency) rather than stone.
struct RootLeafU {
    RS_F4X4 viewProj;
    RS_F4   eye;          // xyz
    RS_F4   lightDir;     // xyz
    RS_F4   skyColor;
    RS_F4   groundColor;
    RS_F4   sssTint;
    float   diffuse;
    float   specStrength;
    float   roughness;
    float   hemiStrength;
    float   rimStrength;
    float   sssTrans;     // back-lit transmission amount
    float   sssPower;     // transmission lobe tightness
    float   _pad0;
};

// Fog post-process pass (root_fog.metal).
struct RootFogU {
    RS_F3X3 cam;
    RS_F4   eye;
    RS_F4   fogColor;
    RS_F2   res;
    float   fov;
    float   nearZ;
    float   farZ;
    float   fogDensity;      // extinction per world unit = 1 / visibility
    float   fogHeightRef;    // world Y the height falloff pivots about
    float   fogHeightScale;  // Y distance over which density drops by 1/e
    float   fogNoiseScale;
    float   fogNoiseStrength;
    float   fogNoiseContrast;
    float   fogStart;        // march begins here: the air near the lens is clear
    RS_F4   fogDrift0;       // xyz, first octave's advection (pre-multiplied by time)
    RS_F4   fogDrift1;       // xyz, second octave's, deliberately not parallel
    float   axisLength;
    float   gridSpacing;
    RS_INT  showAxes;
    RS_INT  showGrid;
    RS_INT  aoEnabled;    // multiply the geometry pass's ambient share by the AO
    RS_INT  fogSteps;     // march samples between fogStart and the hit
    float   fogDither;    // jitter the march start, in units of one step
    float   fogScatter;   // scattering albedo: how much of the extinguished
                          // energy comes back into the ray rather than being
                          // absorbed. 0 = smoke, 1 = cloud.
    float   fogAnisotropy;// Henyey-Greenstein g: >0 forward, <0 back scattering
    float   fogNoiseLod;  // mip level the march reads the noise volume at
    float   _padF0;
    float   _padF1;
    RS_F4   lightDir;     // xyz, the key's direction (surface -> light)
    RS_F4   keyColor;     // xyz, key colour x intensity
    // The pluck flash (MetalRootRenderer::Flash): bare point lights inside
    // masks, fired on a pluck marker during the Orbit -- one mask, or all of
    // them. xyz = position, w = the radius the inverse-square falloff is
    // normalised to; colour is colour x intensity; flashCount 0 = none.
    RS_F4   flashPos[ROOT_MAX_FLASH];
    RS_F4   flashColor;
    RS_INT  flashCount;
    RS_INT  _padFl0, _padFl1, _padFl2;
};

// Screen-space ambient occlusion (root_ao.metal), run on the geometry pass's
// depth buffer between the geometry and fog passes.
struct RootAOU {
    RS_F3X3 cam;
    RS_F4   eye;
    RS_F2   res;          // AO buffer resolution (typically half the scene's)
    float   fov;
    float   nearZ;
    float   farZ;
    float   radius;       // world-space sampling radius
    float   intensity;
    float   bias;         // normal-plane offset, suppresses self-occlusion acne
    RS_INT  samples;
    RS_INT  blurDir;      // blur pass: 0 = horizontal, 1 = vertical
    RS_INT  _pad0;
    RS_INT  _pad1;
};

// Bloom down/up-sample (root_bloom.metal). One struct for both directions.
struct RootBloomU {
    RS_F2   srcTexel;     // 1 / source resolution
    float   threshold;    // prefilter knee (down-sample level 0 only)
    float   radius;       // up-sample filter width, in source texels
    RS_INT  prefilter;    // 1 = apply the threshold (level 0 of the chain)
    RS_INT  _pad0;
    RS_INT  _pad1;
    RS_INT  _pad2;
};

// Final composite (root_post.metal): supersample resolve, bloom, depth of
// field, exposure + filmic tonemap, vignette, grain, dither, sRGB encode.
struct RootPostU {
    RS_F2   res;          // output resolution
    RS_F2   srcTexel;     // 1 / scene (supersampled) resolution
    RS_INT  ssaa;         // supersample factor being resolved (1 = none)
    RS_INT  tonemap;      // 0 = clamp only, 1 = filmic
    RS_INT  bloomOn;
    RS_INT  dofOn;
    RS_INT  ditherOn;
    float   exposure;
    float   bloomIntensity;
    float   dofFocus;     // focus distance, world units
    float   dofRange;     // distance over which the blur reaches full strength
    float   dofStrength;
    float   vignette;
    float   grain;
    float   time;         // animates the grain
    float   nearZ;
    float   farZ;
    // --- lens ---------------------------------------------------------------
    float   caStrength;    // radial chromatic aberration, in pixels at the corner
    float   streak;        // anamorphic bloom streak intensity
    float   streakLength;  // its reach, in bloom-mip texels
    RS_F4   streakTint;
    // --- film ---------------------------------------------------------------
    float   halation;      // warm bleed around highlights
    RS_F4   halationTint;
    float   contrast;      // about a mid-grey pivot, display-referred
    float   saturation;
    RS_F4   lift;          // xyz, shadows
    RS_F4   gainC;         // xyz, highlights ("gain" collides with nothing, but
                           //      keep the C suffix to match liftC/gammaC below)
    RS_F4   gammaC;        // xyz, midtones
    RS_F4   shadowTint;    // split toning
    RS_F4   highlightTint;
    float   toneBalance;   // where the split between them sits
    float   grainSize;     // grain cell size, in output pixels
    float   grainChroma;   // 0 = monochrome grain, 1 = independent per channel
    float   splitStrength; // scales both split-tone tints towards neutral
    float   distortK1;     // radial distortion: <0 barrel, >0 pincushion
    float   distortK2;     // fourth-order term, for the corners
    float   distortZoom;   // re-crop so the distorted corners stay in frame
};

// Temporal anti-aliasing (root_taa.metal). The scene's supersample grid is
// box-resolved to output resolution first (the same filter root_post.metal
// applies when this is off), then blended with last frame's result carried
// along the motion vectors below. The projection is jittered by a fraction of
// an output pixel each frame (RootGeomU::jitter), so what the blend
// accumulates is a supersample the SSAA grid alone cannot afford.
struct RootTaaU {
    RS_F2   res;          // output resolution
    RS_F2   srcTexel;     // 1 / scene (supersampled) resolution
    RS_INT  ssaa;         // supersample factor being resolved (1 = none)
    RS_INT  histValid;    // 0 = no usable history: pass the frame through
    float   blend;        // the new frame's share of the result
    float   clipGamma;    // history clamp, in neighbourhood standard deviations
};

// Camera-reprojection motion vectors (root_glitch.metal, first pass).
//
// Per-pixel screen motion, recovered from the depth buffer and the *previous*
// frame's view-projection rather than written out by the geometry pass. The
// capsules are drawn as analytic hits inside a bounding quad, so there is no
// vertex the rasterizer could difference across frames to give a real velocity
// -- and the scene's own motion is overwhelmingly the camera's, since the roots
// grow at a rate no smear would register. Reprojecting depth gets that motion
// for one fullscreen pass and no change at all to the geometry path.
struct RootMotionU {
    RS_F3X3 cam;          // camera basis (right, up, fwd) as columns
    RS_F4   eye;          // xyz
    RS_F2   res;          // motion buffer resolution
    float   fov;
    float   nearZ;
    float   farZ;
    // What distance a background pixel is treated as sitting at. The sky has no
    // depth, but it does move when the camera turns, and leaving it at the far
    // plane would give it a velocity of nearly zero while everything in front
    // of it swept sideways -- the smear would stop dead at every silhouette.
    float   bgDepth;
    float   _pad0;
    float   _pad1;
    RS_F4X4 prevViewProj; // last frame's world -> clip
};

// Pixel sort (root_glitch.metal, second pass).
//
// A real pixel sort orders whole spans of a scanline at once, which is a sort
// per span per frame and nothing a fragment shader should be asked to do. This
// is an odd-even transposition sort instead: every frame each pixel compares
// itself with one neighbour along the sort axis and the pair swaps if it is out
// of order. That is *two* samples per pixel per frame -- the cheapest pass in
// this whole file -- and repeated over successive frames it converges on the
// same fully sorted spans. The sort is therefore something the image visibly
// falls into over about a second rather than a state it snaps to, which is the
// better look anyway and is why the state lives in its own ping-pong pair.
//
// Only pixels whose luminance is inside [lo, hi] are allowed to move, which is
// what cuts the image into spans: a run of in-band pixels bounded by out-of-band
// ones sorts within itself and cannot leak past its ends.
struct RootSortU {
    RS_F2   res;
    float   lo;        // luminance band, below which a pixel is pinned
    float   hi;
    float   feed;      // share of the live frame mixed in each pass: 0 freezes
                       // the sorted picture, higher keeps it following the
                       // scene at the cost of never fully settling
    RS_INT  axis;      // 0 = sort down columns, 1 = along rows
    RS_INT  parity;    // which half of the odd-even pairing this pass runs
    RS_INT  descending;
    RS_INT  seed;      // 1 = ignore the state and start from the live frame
    RS_INT  _pad0;
    RS_INT  _pad1;
    RS_INT  _pad2;
};

// Datamosh + bitcrush (root_glitch.metal, second pass).
//
// Both are deliberately the *last* thing in the chain, after the sRGB encode:
// they are codec and display artefacts, not lens or film ones. A bitcrush
// applied in linear would put all its steps in the shadows, and a datamosh
// blends whole finished frames -- it is what a decoder does with a picture it
// already made, which is the entire look being asked for.
struct RootGlitchU {
    RS_F2   res;
    // Bitcrush. One dial: 0 is a bit-exact pass-through (block 1 px, 256
    // levels), 1 is the full block size and level count below. Making the dial
    // drive the parameters rather than cross-fade with the clean image is what
    // keeps the half-way setting looking like a lower-resolution picture
    // instead of a double exposure of two of them.
    float   crush;
    float   crushBlock;   // pixels per block at crush = 1
    float   crushLevels;  // colour steps per channel at crush = 1
    float   crushDither;  // ordered (Bayer) dither before the quantise
    // Datamosh. moshOn gates the whole thing; the frozen motion field lives in
    // its own texture, which the host simply stops re-rendering for as long as
    // the freeze lasts (see MetalRootRenderer::render).
    RS_INT  moshOn;
    float   moshAmount;   // 1 = the warped feedback replaces the frame entirely
    float   moshGain;     // multiplier on the motion vectors: >1 over-shoots
    float   moshBlock;    // macroblock the vectors are quantised to, in pixels
    // Pixel sort, mixed in ahead of both of the above: sortOn says the sorted
    // state texture is bound and worth reading, sortAmount cross-fades it
    // against the frame it was made from.
    RS_INT  sortOn;
    float   sortAmount;
};

#endif // ROOT_SHARED_H
