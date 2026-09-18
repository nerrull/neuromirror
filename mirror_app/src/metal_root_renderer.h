// MetalRootRenderer — Metal port of sdf_viewer/RootRenderer.
//
// Same two-pass structure as the GL original (geometry sphere-tracer + fog
// post-process) and the same public knobs (Material/PBRParams/Fog/Pulse/
// Overlay), but rendered through the app's shared MetalContext into offscreen
// MTLTextures. GL Texture-Buffer-Objects become plain MTLBuffers; the procedural
// noise is the same baked 128^3 tiling fBm. Segment upload takes flat arrays
// rather than CPlantBox types so this stays independent of the sim (the RootScene
// converts CPlantBox output to these arrays).
//
// Divergence from GL: Invert/XOR mode has no Metal fragment-logic-op equivalent,
// so it renders flat white silhouettes (nearest-depth) rather than XOR overlap.
//
// ObjC++ only.
#pragma once
#ifndef __OBJC__
#error "metal_root_renderer.h is ObjC++ only; include from a .mm file"
#endif

#import <Metal/Metal.h>
#include "root_shared.h"
#include <string>
#include <vector>
#include <array>

class MetalContext;

class MetalRootRenderer {
public:
    enum class ShaderMode { Phong = 0, PBR = 1, Invert = 2 };

    struct Material {
        float baseColor[3]  = {0.60f, 0.55f, 0.45f};
        float baseColor2[3] = {0.35f, 0.28f, 0.22f};
        float colorNoiseScale    = 0.4f;
        float colorNoiseStrength = 0.0f;
        float ambient      = 0.03f;
        float diffuse      = 0.30f;
        float specColor[3] = {1.00f, 0.95f, 0.85f};
        float shininess    = 150.0f;
    };
    struct PBRParams { float metallic = 0.05f; float roughness = 0.70f; };
    struct Fog {
        float color[3]      = {0.12f, 0.08f, 0.05f};
        // Visibility, not density. Extinction is 1/visibility, and transmittance
        // is exp(-extinction * distance) -- so a slider that is linear in density
        // is linear in the *exponent*, and the whole useful range of it lives in
        // the first sixth of its travel. Everything past that is opaque and
        // everything before it is nothing, which is exactly the "either far too
        // dense or invisible" behaviour this had. Visibility is the distance at
        // which the fog reaches about 63%, so it is linear in something the eye
        // actually measures, and it is in world units you can point at.
        float visibility    = 45.0f;
        bool  enabled       = true;
        // The height gradient pivots about heightRef rather than about the world
        // origin, and heightScale is the distance over which density falls by
        // 1/e (the reciprocal of the old `falloff`, which was hard to reason
        // about at either end of its range).
        float heightRef     = 8.0f;
        float heightScale   = 22.0f;
        bool  heightRefAuto = true;    // track the camera target's Y
        // The noise is sampled at pos * noiseScale and the baked texture tiles
        // with period ROOT_NOISE_TILE_PERIOD (8) in that space, so a feature is
        // 8/noiseScale world units across. At the old 0.05 that is 160 units --
        // and the whole piece is about 20 across, so the scene sat inside a
        // single lobe of the noise. The fog therefore had no visible structure
        // at all, only an overall level that drifted; which is the other half of
        // why it looked like a slab moving along a plane. 0.55 puts a feature at
        // about 15 units, a bit under the size of the piece.
        float noiseScale    = 0.55f;
        float noiseStrength = 0.55f;
        float noiseContrast = 1.20f;   // how far the noise swings about the mean
        float driftTime     = 0.0f;
        float driftSpeed    = 1.0f;
        // The march starts here: the air between the lens and the subject reads
        // as clear. Auto ties it to a fraction of the orbit radius so the subject
        // stays clear at any framing.
        float startDist     = 0.0f;
        float startFrac     = 0.12f;
        bool  startAuto     = true;
        int   steps         = 14;
        // Single-scatter terms. `scatter` is the medium's albedo -- the share of
        // the light it removes from the beam that comes back into it -- and
        // `anisotropy` is how forward-biased that scattering is. Together they
        // are what couples the fog to the key light, so the fog brightens
        // towards it and stays dark away from it.
        float scatter       = 0.04f;
        // The volumetric integral runs at output resolution / this. It is a
        // smooth, low-frequency quantity with no silhouettes of its own, so it
        // does not need the grid the geometry needs -- at 1080p, halving it is
        // indistinguishable from full rate (mean error under 0.5/255) and takes
        // the march from 17 ms to 4.5. The march is by far the most expensive
        // thing in the fog, so this is the knob that pays for all of it.
        int   downscale     = 2;
        // Mip level of the noise volume the march samples. A march step at
        // this scale spans many texels, so level 0 is not more detail, it
        // is more cache misses: the fetches are what the march costs, and
        // level 2 (32^3, 32 KB) reads the same field a quarter of the
        // texels at a time. The finest octave has a period of 16 texels at
        // level 0, so it survives to level 2 and is gone by 3.
        float noiseLod      = 2.0f;
        float anisotropy    = 0.55f;
        int   noiseType     = 0;
    };
    struct Pulse {
        bool  enabled   = false;
        float color[3]  = {1.0f, 0.85f, 0.45f};
        float speed     = 14.0f;
        float spacing   = 22.0f;
        float width     = 3.5f;
        float intensity = 1.6f;
        float time      = 0.0f;
        float hopOffset = 12.0f;
    };
    struct Overlay {
        bool  showAxes    = false;
        float axisLength  = 10.0f;
        bool  showGrid    = false;
        float gridSpacing = 5.0f;
    };
    // Material for the face mid-geometry pass (mirrors FaceGL's knobs).
    struct FaceParams {
        // Dimmer than it used to be (3.2): the mask's own point light sits a few
        // centimetres off its face, so at the old intensity it blew the forehead
        // and nose to clipped white and the mask read as a lamp rather than as a
        // lit object. With a tonemap in the chain there is also no longer any
        // need to overdrive it to get the highlights to register.
        float lightIntensity = 1.8f;
        // The spot's colour; a warm tungsten rather than white, so the skin
        // reads as lit by a lamp and not by the sky.
        float lightColor[3]  = {1.0f, 0.82f, 0.62f};
        float lightFalloff   = 0.012f;
        float specStrength   = 1.2f;
        // Skin, not polished stone (0.42): the highlight spreads instead of
        // sitting as one glazed dot on the nose and brow.
        float roughness      = 0.55f;
        // Decode of the vertex albedo before lighting (RootFaceU::albedoGamma).
        // The mirror's output is display-referred; lit as if linear it came
        // out pale and low-contrast on every mask.
        float albedoGamma    = 2.2f;
        // Saturation of the albedo about its luma (RootFaceU::albedoSat).
        float albedoSat      = 1.0f;
        float metallic       = 0.0f;
        // Area-weighted vertex normals rather than one face normal per triangle.
        // Lives here (rather than being unconditional) so the faceted original
        // is still reachable for comparison; RootScene reads it when it builds
        // the mask mesh, so changing it needs a rebuildFace().
        bool  smoothNormals  = true;
        // Spotlight cone for the mask's own light, in degrees off its axis. The
        // outer angle is where it reaches zero, the inner where it is still
        // full; the gap between them is the penumbra. 90 outer disables the cone
        // and gives the bare point light back.
        float spotOuterDeg   = 46.0f;
        float spotInnerDeg   = 20.0f;
        // Must match the lightDist RootScene passes to appendFaceVertexData.
        float spotLightDist  = 3.0f;
        // The mask's own subsurface terms, separate from the roots'
        // (EnvParams::sss*): skin over a face is not the same tissue as a
        // root, and the pluck flash reads through these (see face_shade.metal)
        // so they want to be tunable on their own.
        float sssWrap        = 0.55f;
        float sssTrans       = 0.35f;
        float sssPower       = 5.0f;
        float sssTint[3]     = {0.90f, 0.45f, 0.22f};
    };
    // The pluck flash: a bare point light the host places inside one mask
    // for a moment on a pluck marker (RootScene::triggerFlash, Orbit only).
    // The host sets pos/level every frame; the rest is the look.
    struct Flash {
        float pos[ROOT_MAX_FLASH][3] = {};
        int   count        = 0;      // lights in pos this frame
        float level        = 0.f;    // this frame's envelope, 0..1
        float intensity    = 12.f;   // colour x this x level reaches the shaders
        float color[3]     = {1.0f, 0.93f, 0.80f};
        float radius       = 3.f;    // inverse-square falloff's reference distance
        float decaySeconds = 0.7f;   // the envelope's e-fold time after the hit
        float depth        = 0.6f;   // where inside the head, x the mask's r_depth
        bool  nearest      = false;  // pick the mask nearest the camera, else random
        bool  all          = false;  // every mask at once, rather than one
        bool  mask0        = true;   // the visitor's own mask (the live chain's
                                     // mask 0) may flash
        // The glitch: on the flash, a share of the flashed mask's triangles
        // get their vertex indices randomised, redrawn every frame
        // (root_face.metal). Its envelope is a triangle wave, 0 -> 1 -> 0
        // over glitchSeconds, run by the host (RootScene::stepFlash)
        // alongside the light's own decay. glitchAmount is the share of
        // triangles torn at the peak; of their corners, glitchNoiseShare
        // (at the peak) are pushed off by up to glitchNoise world units,
        // on the same wave. glitchSwap: at the peak the mask is dealt a
        // different bank face (RootScene::swapFlashedFaces), so what the
        // tear closes on is someone else; mask 0 (the visitor's live face)
        // is never swapped.
        bool  glitch           = false;
        float glitchSeconds    = 0.6f;
        float glitchAmount     = 0.3f;
        float glitchNoise      = 0.f;
        float glitchNoiseShare = 0.5f;
        bool  glitchSwap       = false;
        // Host-set every frame with pos/level: the wave's level this frame,
        // the flashed masks' runs in the face mesh (first vertex, vertex
        // count) and this frame's seed.
        float glitchLevel  = 0.f;
        int   glitchRun[ROOT_MAX_FLASH][2] = {};
        int   glitchCount  = 0;
        int   glitchSeed   = 0;
    };
    Flash flash;
    // Shading for the meshed leaves. Separate from FaceParams because a leaf is
    // a matte, thin, translucent sheet and a mask is polished stone; they share
    // the pass slot and the environment, not the material.
    struct LeafParams {
        float diffuse      = 0.95f;
        float specStrength = 0.12f;   // broad and weak: leaves are matte
        float roughness    = 0.55f;
        // Back-lit transmission. A leaf with the light behind it glows, and this
        // is most of what stops a mesh leaf reading as painted cardboard.
        float sssTrans     = 0.55f;
        float sssPower     = 2.6f;
    };
    LeafParams leaf;

    // Draped-sheet material for the cloth mid-geometry pass -- ported from
    // TransitionScene's refract/reliefShade/reliefSharp/sheen knobs. See
    // root_cloth.metal.
    struct ClothParams {
        float refract     = 0.05f;
        float reliefShade = 0.55f;
        float reliefSharp = 0.8f;
        float sheen       = 0.35f;
        // 1 = the film reaches the display exactly as the mirror made it (see
        // RootClothU::passThrough in root_shared.h); 0 = it is graded with the
        // rest of the scene. RootScene drives this from the cloth's own
        // release, so the opening frame of the press is the pond and the sheet
        // that falls away belongs to the room it falls into.
        float passThrough = 1.0f;
    };
    ClothParams cloth;

    // The harp's wires (root_wire.metal, RootScene::setHarpWires): luminescent
    // lines drawn after the cloth, blended over it. `color` x a wire's glow
    // is the radiance it writes; past post.bloomThreshold it halos.
    struct WireParams {
        float color[3] = {0.35f, 0.75f, 1.00f};
    };
    WireParams wire;

    // Environment and organic-shading terms, shared by the capsule/blade pass
    // and the mask pass so both sit in the same light.
    struct EnvParams {
        // What the frame clears to behind the roots. Was hardcoded at the clear
        // colour, which made "shoot this against black" a recompile.
        float background[3]  = {0.12f, 0.08f, 0.05f};
        float skyColor[3]    = {0.16f, 0.19f, 0.24f};   // cool from above
        float groundColor[3] = {0.10f, 0.07f, 0.045f};  // warm bounce from below
        float hemiStrength   = 1.0f;
        float envSpec        = 0.6f;
        float rimStrength    = 0.10f;
        float sssWrap        = 0.55f;
        float sssTrans       = 0.35f;
        float sssPower       = 5.0f;
        float sssTint[3]     = {0.90f, 0.45f, 0.22f};   // light reddens on its way through
        // The directional key. It had no colour or intensity of its own before --
        // it was implicitly white at unity, with `Material::diffuse` doing double
        // duty as both the surface's albedo response and the light's brightness,
        // so warming the key meant warming every material.
        float keyColor[3]    = {1.00f, 0.93f, 0.82f};
        float keyIntensity   = 1.0f;
        // What a structure drawn *dark* keeps of its radiance (see
        // setInstanceLit and the face mesh's per-vertex lit): a fraction of
        // everything, key and environment alike, rather than a separate
        // material. Small but not zero -- a silhouette the fog can still
        // find is the point, and true black reads as a hole in the frame.
        float unlitLevel     = 0.035f;
    };
    // Fibre detail on the capsules and blades. Anisotropic on purpose -- see
    // root_geom.metal; isotropic noise here reads as grit on the surface rather
    // than as the lengthwise structure a root actually has.
    struct DetailParams {
        float strength = 0.55f;   // normal perturbation
        float scale    = 20.0f;   // frequency, world units^-1
        float stretch  = 7.0f;    // elongation along the root axis
        float rough    = 0.45f;   // specular / roughness break-up
        float tint     = 0.14f;   // per-segment albedo jitter
        // Distance fade, in *output* pixels (scaled by post.ssaa internally):
        // one noise cell (1/scale world units) projecting smaller than this
        // gets no detail, full detail from twice this up. Without it the
        // fibres of a far root are sampled finer than the pixel grid and
        // their normals crawl every frame the camera moves -- the largest
        // single source of orbit shimmer measured by --seqshot. 0 = off.
        float fadePx   = 1.0f;
    };
    // Screen-space ambient occlusion over the geometry pass's depth buffer.
    struct AOParams {
        bool  enabled   = true;
        // Radius and intensity are tuned together against the *indirect* term
        // only (see root_fog.metal): occlusion here darkens the environment
        // share of a pixel, which is a fifth of its radiance, so an intensity
        // of 1.0 -- correct for AO applied to a whole image -- barely registers.
        float radius    = 2.2f;    // world units
        float intensity = 2.0f;
        float bias      = 0.04f;
        int   samples   = 10;
        int   downscale = 2;       // AO buffer is this much smaller than the scene
    };
    // The final composite: everything between the fog image and the drawable.
    struct PostParams {
        bool  enabled        = true;   // off = fog output goes straight out, as before
        bool  tonemap        = true;
        // Under 1 on purpose. The bright root groups carry an albedo close to
        // white, and at unity exposure they sat on the tonemap's shoulder where
        // every value desaturates towards the same white -- the roots went flat
        // and none of the material work below was visible on them at all.
        float exposure       = 1.20f;
        bool  bloom          = true;
        // Measured against this scene, not assumed. Its linear luminance runs
        // 0.16 at the median, 0.48 at the 99th percentile and about 1.0 at the
        // brightest pixel -- so the 1.35 this was originally set to (chosen when
        // the travelling pulses were blowing highlights past white) meant the
        // bloom chain, and the halation and streak that read from it, produced
        // *exactly nothing*: bit-identical output to bloom disabled, for 0.9 ms
        // a frame. The knee is subtractive, so only the excess over the
        // threshold blooms, and the 13-tap downsample averages a thin bright
        // root with its dark surroundings before the test -- both push the
        // effective threshold well below the nominal one.
        float bloomThreshold = 0.28f;
        float bloomIntensity = 0.50f;
        float bloomRadius    = 1.0f;
        int   bloomLevels    = 5;
        bool  dof            = true;
        // 0 = automatic: the nearest mask in frame (setFocusPoints), eased
        // over dofFocusEase seconds so a mask entering the frame is a pull,
        // not a cut; the camera's orbit radius when no mask is in frame.
        float dofFocus       = 0.0f;
        float dofFocusEase   = 0.4f;
        // Wide and weak. The intent is to take the edge off the far end of the
        // tangle so the eye settles on the mask in focus, not to shoot the scene
        // at f/1.4 -- and a gather this size cannot support a heavy blur without
        // showing its own kernel.
        float dofRange       = 55.0f;
        float dofStrength    = 0.50f;
        float vignette       = 0.22f;
        float grain          = 0.030f;
        bool  dither         = true;
        float fogDither      = 1.0f;
        int   ssaa           = 2;      // supersample factor for the scene passes
        // Temporal AA on top of the supersample (root_taa.metal): the
        // projection is jittered a fraction of a pixel each frame and the
        // frames blended along the camera's motion vectors. What the box
        // resolve cannot settle at 2x -- the crawl along a long thick root's
        // edge, the highlight shimmer -- this does, over a dozen frames.
        bool  taa            = true;
        float taaBlend       = 0.10f;  // the new frame's share; 1 = off in effect
        float taaJitter      = 1.0f;   // jitter amplitude, output pixels (1 = the pixel)
        float taaClip        = 1.25f;  // history clamp, neighbourhood std devs
        float taaSharpen     = 0.3f;   // unsharp mask on the blend's output (RootPostU::sharpen)

        // --- lens ------------------------------------------------------------
        // Chromatic aberration, in pixels of channel separation at the image
        // corner. Zero at the optical axis by construction.
        float caStrength     = 0.0f;
        // Anamorphic highlight streak. Off by default: it is a strong stylistic
        // signature and reads as "someone put a filter on it" if it is not what
        // the piece is going for.
        float streak         = 0.0f;
        float streakLength   = 14.0f;
        float streakTint[3]  = {0.55f, 0.72f, 1.00f};   // the classic cool streak

        // --- film ------------------------------------------------------------
        // Halation: warm re-exposure around genuinely bright areas. A small
        // amount is on by default because it is the least "effect-like" of
        // these and does the most to stop the highlights looking synthetic.
        float halation       = 0.35f;
        float halationTint[3] = {1.00f, 0.42f, 0.20f};
        int   halationMip    = 3;      // which bloom level supplies the spread

        // Print grade, applied after the tonemap.
        float contrast       = 1.0f;
        float saturation     = 1.0f;
        float lift[3]        = {0.0f, 0.0f, 0.0f};
        float gammaC[3]      = {1.0f, 1.0f, 1.0f};
        float gain[3]        = {1.0f, 1.0f, 1.0f};
        // Split toning. Enabled by a non-negative balance; the defaults cool the
        // shadows very slightly against this scene's warm key, which is what
        // separates the tangle from the ground without reading as a colour cast.
        float toneBalance    = 0.45f;
        // Stored at full strength and scaled by splitStrength, so one dial takes
        // the effect from off to full rather than needing two swatches edited in
        // step. The default cools the shadows against this scene's warm key,
        // which is what separates the tangle from the ground.
        float splitStrength    = 0.35f;
        float shadowTint[3]    = {0.88f, 0.95f, 1.14f};
        float highlightTint[3] = {1.08f, 1.00f, 0.90f};

        float grainSize      = 1.6f;   // grain cell, in output pixels
        float grainChroma    = 0.25f;  // 0 = monochrome, 1 = independent channels

        // --- lens geometry ---------------------------------------------------
        // Radial distortion. Negative is barrel (what short lenses do), positive
        // is pincushion (what long ones do). distortZoom re-crops so the bowed
        // corners stay inside the rendered image; 1.0 leaves them empty.
        float distortK1      = 0.0f;
        float distortK2      = 0.0f;
        float distortZoom    = 1.0f;

        // --- signal degradation ----------------------------------------------
        // Two codec/display artefacts, run after everything above (see
        // root_glitch.metal). Both are off by default and cost nothing at all
        // when they are: the pass is not encoded and its targets are not even
        // allocated until the first frame that asks for them.

        // Bitcrush. One dial from a bit-exact pass-through to blockPx-sized
        // pixels quantised to `crushLevels` steps per channel.
        float crush          = 0.0f;
        float crushBlock     = 16.0f;   // pixels per block at crush = 1
        float crushLevels    = 5.0f;    // colour steps per channel at crush = 1
        float crushDither    = 1.0f;    // ordered dither before the quantise

        // Datamosh. `mosh` latches it on; triggerDatamosh() runs it for a fixed
        // time and releases it. moshFreeze is the heart of the effect: for that
        // many seconds after it starts, the motion field stops being
        // recomputed, so the picture keeps being dragged along a motion that
        // has already finished happening. After the freeze expires it tracks
        // the live motion again, still smearing -- which reads as the decoder
        // recovering without ever getting a keyframe. 0 or less freezes for the
        // whole run.
        bool  mosh           = false;
        float moshAmount     = 0.92f;   // 1 = the feedback replaces the frame
        float moshGain       = 1.0f;    // multiplier on the vectors
        float moshBlock      = 16.0f;   // macroblock size, output pixels
        float moshFreeze     = 1.2f;    // seconds the vectors stay fixed
        float moshTrigger    = 2.0f;    // default length of one triggered run
        // How far a background pixel is treated as being, for the vectors. The
        // sky has no depth but it does move when the camera turns; leaving it
        // at the far plane would stop the smear dead at every silhouette.
        float moshBgDepth    = 120.0f;

        // Pixel sort. Converges over frames rather than in one pass -- see
        // RootSortU in root_shared.h -- so `sortPasses` is the speed dial: one
        // pass per frame settles in about a second, four in a quarter of that,
        // and each pass is two texture reads per pixel.
        bool  sort           = false;
        float sortAmount     = 1.0f;    // cross-fade against the unsorted frame
        float sortLow        = 0.30f;   // luminance band allowed to move
        float sortHigh       = 1.0f;
        float sortFeed       = 0.06f;   // live frame mixed in per pass
        int   sortAxis       = 0;       // 0 = down columns, 1 = along rows
        int   sortPasses     = 1;
        bool  sortDescending = false;
    };

    static constexpr int MAX_GROUPS = ROOT_MAX_GROUPS;

    MetalRootRenderer(const MetalContext& ctx, const std::string& shaderDir,
                      const std::string& sharedHeaderPath, int w, int h);

    bool valid() const { return geomPipe_ != nil && fogPipe_ != nil; }

    void resize(int w, int h);

    // Flat-array segment upload. nodesXYZ: 3 floats/node; segs: 2 ints/seg;
    // radii: 1 float/seg. Optional per-segment: groups (1 int), prims (1 int),
    // frames (4 floats), aux (4 floats). Absent optionals default as in GL.
    void uploadSegments(const std::vector<float>& nodesXYZ,
                        const std::vector<int>&   segs,
                        const std::vector<float>& radii,
                        const std::vector<int>*   groups = nullptr,
                        const std::vector<int>*   prims  = nullptr,
                        const std::vector<float>* frames = nullptr,
                        const std::vector<float>* aux    = nullptr);

    // Face mid-geometry mesh: flat interleaved triangles, kFaceFloats (13)
    // floats/vertex (pos3, normal3, color3, lightPos3, lit) — FaceGL's VBO
    // layout plus the lit flag, 1 for a mask shaded as normal and 0 for one
    // standing dark (env.unlitLevel of its radiance). Drawn into the shared
    // colour+depth target between the capsules and the fog. Empty data clears
    // the face pass.
    static constexpr int kFaceFloats = 13;
    void uploadFaceMesh(const std::vector<float>& interleaved);
    // Overwrite one run of the face mesh (floats, offset into the last
    // uploadFaceMesh) -- a replayed bank face moving on its masks, without
    // rebuilding every other mask's triangles. Ignored if it does not fit.
    void patchFaceMesh(size_t offsetFloats, const std::vector<float>& interleaved);

    // Debug spawn-point markers (RootScene::debugSpawnMarkers): same
    // kFaceFloats layout and pipeline as the face mesh, uploaded to its own
    // buffer so it never competes with the actual faces. Empty clears it.
    void uploadDebugMarkers(const std::vector<float>& interleaved);

    // Leaf mid-geometry mesh: same 12-floats/vertex layout, but the last three
    // are (s, t, vein) rather than a light position, and it is drawn with leaf
    // shading instead of stone. Leaves are meshed rather than drawn on the
    // capsule/blade path because a blade SDF built from a union of capsules
    // cannot thin its margin to an edge — see sdf_viewer/LeafMesh.h.
    // Empty data clears the leaf pass.
    void uploadLeafMesh(const std::vector<float>& interleaved);

    // Cloth mid-geometry mesh: flat interleaved triangles, 10 floats/vertex
    // (pos3, normal3, uv2, aux2) -- matches ClothVertex in root_cloth.metal and
    // RootScene::packClothMesh's interleave. Drawn between the leaf pass and the
    // fog, sampling `setClothTexture`'s texture. Empty data clears the pass.
    void uploadClothMesh(const std::vector<float>& interleaved);
    // The pond/mirror texture the cloth samples -- set every frame by the
    // caller (RootScene::render()), the same texture TransitionScene's
    // setPondTexture used to receive. nil skips the cloth draw entirely rather
    // than sampling an unbound texture.
    void setClothTexture(id<MTLTexture> tex) { clothTex_ = tex; }
    // The harp's wires: 6 vertices per wire, kWireFloats each (foot3, head3,
    // side, t, glow, half-width in output pixels) -- matches WireVertex in
    // root_wire.metal; built by RootScene::packHarpWires. Drawn after the
    // cloth, before the fog. Empty data clears the pass.
    static constexpr int kWireFloats = 10;
    void uploadWires(const std::vector<float>& interleaved);
    // Candidates for the automatic focus distance (post.dofFocus == 0): the
    // world positions of the masks being drawn. Replaced each call.
    void setFocusPoints(const std::vector<std::array<float, 3>>& pts) { focusPoints_ = pts; }

    // --- cached instances (many static root systems, LOD + culling) ----------
    // Placement of a cached system in the world (applied once, baked into the
    // uploaded vertices — cached systems are static).
    struct InstancePlacement {
        float translate[3] = {0.f, 0.f, 0.f};
        float rotYaw       = 0.f;   // radians about world Y
        float scale        = 1.f;
    };
    // Add a cached capsule system, baked to world space, with LOD levels built by
    // radius (thin laterals drop first) and a world bounding sphere for culling.
    // Uploaded once; drawn each frame only if visible, at the LOD its projected
    // size warrants. Returns the instance index.
    // `nodeDistOut`, when given, receives the per-node distance the pulses
    // ride (computeNodeDist on the placed nodes: world units, hop-offset
    // seeded) -- exactly the numbers the instance's dist buffer holds, so a
    // caller timing something to the pulse front (setInstancePulseStart)
    // reads the same distances the shader does.
    int  addInstance(const std::vector<float>& nodesXYZ,
                     const std::vector<int>&   segs,
                     const std::vector<float>& radii,
                     const InstancePlacement&  place,
                     std::vector<float>* nodeDistOut = nullptr);
    void clearInstances();
    int  instanceCount() const { return (int)instances_.size(); }
    // Per-instance state for the Reveal: an instance can be held back from
    // the draw entirely, or drawn dark -- present and occluding but keeping
    // only env.unlitLevel of its radiance -- and then lit. `lit` is 0..1, so
    // a caller may ramp it; the two are independent (visible and unlit is
    // the "popped in dark" state). Both default to visible and lit, which is
    // what buildField's instances want. Out-of-range indices are ignored.
    void setInstanceVisible(int i, bool visible);
    void setInstanceLit(int i, float lit);
    // The pulse clock (pulse.time) at which the instance's pulses start,
    // or < 0 (the default) for always on. Started, the instance shows a
    // travelling front -- pulse.speed x (pulse.time - start) along the node
    // distance -- with pulses, and `lit`, only behind it; ahead of it the
    // instance is still dark. RootDrawU::pulseStart in root_shared.h.
    void setInstancePulseStart(int i, float start);

    // The camera's up -- the axis azimuth turns about and elevation is
    // measured from. World up unless a shot says otherwise: RootSequence's
    // pull-back stands the plant upright on screen by making this the
    // structure's own axis.
    float camUp[3] = {0.f, 1.f, 0.f};

    // Culling / LOD tuning.
    bool  cullInstances = true;    // frustum-cull whole systems
    float instanceCullPx = 2.0f;   // skip systems whose bound projects smaller than this
    bool  subpixelCull   = true;   // drop sub-pixel capsules in the vertex shader
    float lodBias        = 1.0f;   // >1 favours coarser LODs sooner (cheaper)
    // Anti-shimmer for thin roots: the smallest projected radius a capsule
    // is drawn at, in *output* pixels (scaled by post.ssaa internally), its
    // shading dimmed by true/floored radius so a sub-pixel root reads as a
    // steady faint line instead of flickering in and out between samples
    // as the camera orbits. 0 = off (the old behaviour). RootGeomU::
    // minRadiusPx.
    float minRadiusPx    = 0.0f;

    // Stats from the most recent render() (for UI / benchmarking).
    int  lastVisibleInstances = 0;
    int  lastCulledInstances  = 0;
    long lastDrawnSegments    = 0;
    // GPU time per render pass (dev tooling: --seqshot's frame-cost line).
    // On, each render() stamps a timestamp at every pass boundary; call
    // resolvePassTimes() once the command buffer has completed to read them.
    // Not free; leave off in the show.
    bool profilePasses = false;
    struct PassTime { std::string name; double ms; };
    std::vector<PassTime> resolvePassTimes();

    // Encode both passes into cb; returns the final fogged colour texture.
    id<MTLTexture> render(id<MTLCommandBuffer> cb,
                          float azimuth, float elevation, float radius,
                          const float target3[3], float fov, const float lightDir3[3]);

    id<MTLTexture> colorTex() const { return outTex_; }
    int width()  const { return w_; }
    int height() const { return h_; }

    // True when the composite pass ran, i.e. the returned texture holds
    // display-referred sRGB-encoded values rather than linear radiance. The
    // headless capture paths need this: they used to apply a 1/2.2 gamma on the
    // way to a PPM, and doing that on top of the tonemap would wash the image
    // out. Asked of the renderer rather than tracked at each call site, because
    // it is the renderer that decides.
    bool outputIsEncoded() const { return post.enabled; }

    // Quality tranches, for A/B comparison and as a coarse quality dial.
    //   0  baseline    — the original two-pass look, every addition off
    //   1  fundamentals— smooth masks, hemisphere ambient, exposure + tonemap
    //   2  + lighting  — supersampling, SSAO, subsurface, environment specular
    //   3  + post      — bloom, depth of field, vignette, grain, dither
    // Applies to the render settings only; it does not touch materials or fog.
    void setTranche(int level);
    int  tranche() const { return tranche_; }

    // Run the datamosh for `seconds` and then let go of it, without touching
    // post.mosh. This is the show-facing entry point -- a cue, a MIDI note, a
    // panel button -- while post.mosh is the latch for holding it open by hand.
    // Re-triggering while one is running restarts both the run and the freeze.
    void triggerDatamosh(float seconds);
    // Drop a running trigger and the feedback history behind it, so the next
    // frame is clean and the next trigger starts from scratch. The latch
    // (post.mosh) is the operator's and is left alone. postTime only moves
    // while the scene renders, so a trigger with time left when the scene
    // stopped would otherwise still be running when it came back.
    void cancelDatamosh();
    // True while either the latch or a trigger has the effect engaged.
    bool datamoshActive() const;

    // Public knobs (same defaults/meaning as RootRenderer).
    ShaderMode shaderMode = ShaderMode::Phong;
    Material   mat;
    PBRParams  pbr;
    Fog        fog;
    Pulse      pulse;
    Overlay    overlay;
    FaceParams face;
    EnvParams  env;
    DetailParams detail;
    AOParams   ao;
    PostParams post;
    float      postTime = 0.0f;   // drives the grain; advanced by the scene's clock
    float      radiusScale      = 1.0f;
    float      radiusMin        = 0.0f;
    float      radiusMax        = 0.0f;
    float      palette[MAX_GROUPS][3]    = {};
    int        paletteCount     = 0;
    float      paletteTip[MAX_GROUPS][3] = {};
    int        paletteTipCount  = 0;

private:
    void buildTargets();
    void buildNoiseTexture();
    id<MTLBuffer> makeBuffer(const void* data, size_t bytes);
    // Reuses `buf` (memcpy in place) when it is already >= bytes; otherwise
    // replaces it with a fresh, larger buffer. `buf` and `capBytes` are a pair
    // (capBytes tracks the buffer's real allocated size, not the live data
    // size) -- see uploadSegments, which calls this every frame while the sim
    // is growing and would otherwise reallocate all eight buffers per frame,
    // every frame, for as long as growth runs.
    void uploadBuffer(id<MTLBuffer>& buf, size_t& capBytes, const void* data, size_t bytes);

    id<MTLDevice> device_ = nil;
    int w_ = 0, h_ = 0;

    id<MTLRenderPipelineState> geomPipe_ = nil;
    id<MTLRenderPipelineState> facePipe_ = nil;
    id<MTLRenderPipelineState> leafPipe_ = nil;
    id<MTLRenderPipelineState> fogPipe_  = nil;
    id<MTLRenderPipelineState> fogVolPipe_ = nil;
    id<MTLRenderPipelineState> aoPipe_   = nil;
    id<MTLRenderPipelineState> aoBlurPipe_ = nil;
    id<MTLRenderPipelineState> bloomDownPipe_ = nil;
    id<MTLRenderPipelineState> bloomUpPipe_   = nil;   // additive blend
    id<MTLRenderPipelineState> postPipe_ = nil;
    id<MTLRenderPipelineState> motionPipe_ = nil;   // camera reprojection
    id<MTLRenderPipelineState> taaResolvePipe_ = nil;   // supersample box, to output res
    id<MTLRenderPipelineState> taaPipe_ = nil;          // the temporal blend
    id<MTLRenderPipelineState> sortPipe_   = nil;   // one odd-even sort step
    id<MTLRenderPipelineState> glitchPipe_ = nil;   // datamosh + bitcrush
    id<MTLDepthStencilState>   depthState_ = nil;

    id<MTLBuffer> faceBuf_ = nil;
    int faceVertCount_ = 0;

    id<MTLBuffer> debugMarkerBuf_ = nil;
    int debugMarkerVertCount_ = 0;
    size_t debugMarkerCap_ = 0;

    id<MTLBuffer> leafBuf_ = nil;
    int leafVertCount_ = 0;

    id<MTLBuffer> clothBuf_ = nil;
    int clothVertCount_ = 0;
    id<MTLRenderPipelineState> clothPipe_ = nil;
    id<MTLTexture> clothTex_ = nil;

    id<MTLBuffer> wireBuf_ = nil;
    int wireVertCount_ = 0;
    id<MTLRenderPipelineState> wirePipe_ = nil;

    // The scene passes (geometry, mask, fog) run at sw_ x sh_, which is the
    // output size times the supersample factor; everything from the composite
    // on runs at w_ x h_.
    id<MTLTexture> rootColorTex_ = nil;   // sw_ x sh_, HDR + ambient share in alpha
    id<MTLTexture> rootDepthTex_ = nil;   // sw_ x sh_
    id<MTLTexture> fogColorTex_  = nil;   // sw_ x sh_, HDR, fog applied
    id<MTLTexture> aoTex_        = nil;   // sw_/ao.downscale, R8
    id<MTLTexture> aoBlurTex_    = nil;   // ping-pong for the separable blur
    id<MTLTexture> fogVolTex_    = nil;   // sw_/fog.downscale, (scatter.rgb, transmittance)
    id<MTLTexture> postTex_      = nil;   // w_ x h_, display-referred, presented
    // The glitch stage's targets. Allocated on first use rather than in
    // buildTargets: they are three full-resolution surfaces that most runs of
    // this piece never touch, and the effects they serve are momentary.
    // Ping-pong rather than a target plus a copy: this stage's output IS the
    // datamosh's feedback buffer, and alternating which of the two it writes
    // saves a full-resolution blit every frame it runs.
    id<MTLTexture> glitchTex_[2] = {nil, nil};   // w_ x h_, output / feedback
    int   glitchIdx_ = 0;                        // the one written this frame
    id<MTLTexture> motionTex_    = nil;   // w_ x h_, RG16F screen velocity
    id<MTLTexture> sortTex_[2]   = {nil, nil};   // w_ x h_, sort state
    int   sortIdx_ = 0;
    bool  sortValid_ = false;       // sortTex_ holds a state worth continuing
    bool  moshHistValid_ = false;   // the unwritten glitchTex_ holds a frame
    bool  moshWasOn_     = false;   // the effect was engaged last frame
    float moshStart_     = 0.0f;    // postTime at the rising edge
    float moshUntil_     = 0.0f;    // postTime a trigger releases at
    bool  moshTriggered_ = false;   // a trigger is running (vs. the latch)
    // Last frame's view-projection, kept every frame whether or not the effect
    // is on: the field the freeze holds has to be the motion *into* the frame
    // the effect started on, which is only available if the previous frame's
    // camera was already recorded.
    simd_float4x4 prevViewProj_{};
    bool prevViewProjValid_ = false;
    void ensureGlitchTargets();
    void releaseGlitchTargets();
    // The motion field is shared by the datamosh and the TAA; either allocates it.
    void ensureMotionTarget();
    // The TAA's targets: the resolved frame and the history ping-pong, all
    // w_ x h_. Lazy like the glitch stage's, released with them on a resize.
    id<MTLTexture> taaResolveTex_ = nil;
    id<MTLTexture> taaTex_[2]     = {nil, nil};
    int   taaIdx_ = 0;              // the one written this frame
    bool  taaHistValid_ = false;    // the other one holds last frame
    unsigned taaFrame_ = 0;         // jitter sequence index
    std::vector<std::array<float, 3>> focusPoints_;
    float dofFocusCur_ = -1.f;      // the eased automatic focus; < 0 = unset
    float dofFocusTime_ = 0.f;      // postTime it was last eased at
    void ensureTaaTargets();
    float autoFocusDistance(const simd_float4x4& vp, float ex, float ey, float ez, float radius);
    void releaseTaaTargets();
    id<MTLTexture> outTex_       = nil;   // whichever of the two the caller gets
    std::vector<id<MTLTexture>> bloomMips_;   // w_/2, w_/4, ... (post.bloomLevels)
    id<MTLTexture> noiseTex_     = nil;
    int sw_ = 0, sh_ = 0;         // scene (supersampled) resolution
    int builtSsaa_ = 0;           // the ssaa the current targets were built for
    int builtAoDs_ = 0;           // ditto for the AO downscale
    int builtFogDs_ = 0;          // ditto for the volumetric fog downscale
    int builtBloomLevels_ = 0;
    int tranche_ = 3;
    // Rebuild only what the changed setting invalidates.
    void ensureTargets();

    id<MTLBuffer> nodeBuf_ = nil, segBuf_ = nil, radBuf_ = nil, distBuf_ = nil;
    id<MTLBuffer> grpBuf_ = nil, primBuf_ = nil, frameBuf_ = nil, auxBuf_ = nil;
    // Allocated size of each of the above, in bytes -- may be larger than the
    // buffer's live contents; see uploadBuffer().
    size_t nodeCap_ = 0, segCap_ = 0, radCap_ = 0, distCap_ = 0;
    size_t grpCap_ = 0, primCap_ = 0, frameCap_ = 0, auxCap_ = 0;
    // The mid-geometry meshes get the same treatment as the segment buffers
    // above, and for a much sharper reason: this file is not built with ARC
    // (only imgui_impl_metal.mm is), so newBufferWithLength: hands back a +1
    // object that assigning over simply drops on the floor. These three are
    // re-uploaded every frame -- the masks are rebuilt per frame even while the
    // growth is held, and the cloth is packed per frame for the whole press --
    // so leaving them on makeBuffer leaked a few megabytes per frame, which is
    // gigabytes per minute rather than the per-visitor trickle the segment
    // buffers were.
    size_t faceCap_ = 0, leafCap_ = 0, clothCap_ = 0, wireCap_ = 0;
    int segCount_ = 0;

    // A cached, static capsule system. node/dist are per-node (shared across LODs);
    // each LOD holds a per-segment {seg, rad} subset. Constant per-segment
    // attributes (prim/aux/grp/frame) for capsule instances come from shared
    // default buffers grown to the largest LOD segment count.
    struct InstanceLod { id<MTLBuffer> seg = nil, rad = nil; int segCount = 0; };
    struct Instance {
        id<MTLBuffer> node = nil, dist = nil;
        std::vector<InstanceLod> lods;    // lods[0] = full detail
        float center[3] = {0, 0, 0};
        float radius = 0.f;               // world-space bounding-sphere radius
        bool  visible = true;             // see setInstanceVisible
        float lit = 1.f;                  // see setInstanceLit
        float pulseStart = -1.f;          // see setInstancePulseStart
    };
    std::vector<Instance> instances_;
    id<MTLBuffer> defPrim_ = nil, defAux_ = nil, defGrp_ = nil, defFrame_ = nil;
    int defCap_ = 0;
    void ensureDefaults(int segCount);

    static constexpr MTLPixelFormat kColorFmt = MTLPixelFormatRGBA16Float;
    static constexpr MTLPixelFormat kDepthFmt = MTLPixelFormatDepth32Float;
    // AO is a single [0,1] visibility factor and 8 bits of it is plenty once
    // the bilateral blur has run over it.
    static constexpr MTLPixelFormat kAOFmt    = MTLPixelFormatR8Unorm;
    // Screen velocity in uv units: small, signed, and needing more precision
    // than 8 bits but nothing like a full float.
    static constexpr MTLPixelFormat kMotionFmt = MTLPixelFormatRG16Float;
};
