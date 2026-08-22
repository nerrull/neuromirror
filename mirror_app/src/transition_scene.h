// TransitionScene — the pond -> face hydro-dip transition.
//
// A film of neural pond is stretched across the frame like a canvas. The mask
// presses into it from behind until the fabric is tented over the real face;
// the canvas then lets go, corners first, and slides off over the brow and the
// nose, leaving the face wearing the film. One locked front-on camera, one
// continuous 3D pass, four phases on one timeline:
//
//   1 hold      the flat sheet fills the frame -- pixel-identical to the pond
//   2 press     the mask advances through the sheet plane, tenting the fabric
//   3 release   the pins let go from the corners inward
//   4 fall      gravity plus contact: the sheet drapes off the face and away
//
// ## Why it is built this way
//
// The earlier version of this scene (and cloth_cpp before it) played the first
// half in screen space -- a fullscreen pass that refracted and embossed the
// pond by a face relief -- and then *swapped* to 3D at full emergence, hiding
// the seam under a crossfade. Everything delicate about it came from that
// swap: three separate quantities (brightness, face shading, texture content)
// had to be matched by hand across one frame, the sheet had to be held
// artificially flat for the length of the crossfade, and the moment the hold
// ended every pin released at once.
//
// There is no swap here. The sheet is 3D from the first frame, and at rest it
// is a flat quad sized to exactly fill the frustum cross-section, so it *is*
// the fullscreen pond -- nothing to match, because nothing changes hands. The
// look during the press is real geometry rather than a screen-space
// approximation of it, and "the face rising through the film" reads as the
// film being pushed, which is what a hydro dip actually is.
//
// ## The three things that make it register
//
//   * **The mask is the real mask.** Not an oval. The sheet is held at its
//     border, not around an elliptical ring cut near the face, so nothing in
//     the setup imposes a shape: what is uncovered is the fitted mesh's own
//     silhouette. Without a fit it is the basis's neutral face, which is a real
//     mask too.
//
//   * **It turns with the head.** The mesh arrives from FaceFitter already
//     carrying this frame's expression and head rotation, and it is re-sent
//     every frame rather than latched at the start. A turned head is also what
//     makes the drape interesting -- the fabric has an asymmetric solid to come
//     off.
//
//   * **The texture is exact, by construction.** `setFaceMesh` takes, per
//     vertex, the normalised frame position the *fit* projects that vertex to
//     (`FaceFitter::projectNormalised`) and places the vertex in world space so
//     that this camera projects it back to precisely that point. The mesh
//     therefore lands on the pond's own face, pixel for pixel, and its texture
//     coordinate is that same projection -- so the film the mask carries away
//     is the film that was covering it. Nothing is fitted twice and there is no
//     centring or scale guess left to drift.
//
// ## Collision
//
// cloth_cpp listed sheet<->face collision as expensive and skipped it, which is
// why its sheet could only fall away *behind* a face it never touched. The
// camera here is fixed front-on and never moves, so the mask is fully described
// for contact purposes by the z of its front surface at each (x, y) -- there is
// no view from which the sheet could reach its back. That makes the collider a
// depth map (`MaskField`, rasterised on the CPU each frame from the placed
// mesh) and the query one bilinear fetch per vertex. See cloth.h.
#pragma once
#ifndef __OBJC__
#error "transition_scene.h is ObjC++ only"
#endif

#import <Metal/Metal.h>

#include <memory>
#include <string>
#include <vector>

#include "cloth.h"
#include "metal_root_renderer.h"

class MetalContext;

class TransitionScene {
public:
    TransitionScene(const MetalContext& ctx, int w = 1280, int h = 720);
    ~TransitionScene();

    bool valid() const;
    void ensureSize(int w, int h);
    int  width() const;
    int  height() const;

    // Phase durations in seconds. Data-driven so the effect can be matched to a
    // cue rather than recompiled.
    struct Timing {
        float hold    = 0.5f;   // flat film, nothing happening
        float press   = 1.6f;   // the mask advancing through the sheet plane
        float settle  = 8.0f;   // fully through, the fabric taut over it
        float release = 0.7f;   // pins letting go, corners first
        float fall    = 1.8f;   // draping off and away
    };
    Timing timing;

    // Look.
    // The film refracts where the fabric bends -- driven by the cloth's own
    // normals, so it is exactly zero on the flat sheet (the rest state has to
    // stay the pond) and peaks where it is stretched over the brow and nose.
    float refract      = 0.05f;
    // How far proud of the sheet plane the mask ends up at full press, in world
    // units. Larger tents the fabric harder before it lets go.
    float pressProud   = 0.16f;
    // Depth exaggeration of the mask. 1 is the fit's own proportions; the fit
    // is solved from a single view, so a little more relief often reads better
    // on screen than the metrically correct amount.
    // 1 is the fit's own proportions, which measure about 0.18 of the mask's
    // width -- correct for a cropped front-facing mask and far too shallow to
    // read as a face pushing through a film. The exaggeration is a look
    // decision, not a correction to the fit.
    float depthScale   = 2.2f;
    // How far shading is allowed to swing either side of the flat sheet's
    // value. 0 is an unlit film; 1 is full Lambert, which blows the highlights
    // on a fold well past the film's own brightness.
    float reliefShade  = 0.55f;
    // The sheet, as a multiple of the frustum cross-section. A little over 1:
    // the moment the corners let go the canvas retracts, and a sheet cut
    // exactly to the frame shows black in the corners the instant it does.
    // The overhang samples the film clamped at its edge, which is the pond's
    // untrained margin anyway.
    float oversize     = 1.08f;
    bool  showCloth    = true;
    bool  showFace     = true;
    bool  wireframe    = false;

    // --- registration --------------------------------------------------------
    //
    // Where the mask sits, corrected by hand, in normalised frame units about
    // the fit's own projected centre.
    //
    // The mask is placed by the fit's projection, and that projection is a 2D
    // similarity: it carries rotation, uniform scale and translation, and it has
    // no perspective and no out-of-plane foreshortening. On a face looking at
    // the camera it lands on the features. On a head with real pitch it does
    // not -- the mask comes out too tall, with its eyes high and its mouth low
    // -- and nothing downstream can recover that, because the information was
    // never in the pose. So this is the operator's handle on it, and the scale
    // is per-axis because the error is: pitch stretches one of them.
    //
    // It moves the texture with the geometry, since they are the same
    // coordinate. That is deliberate: correcting where the mask sits keeps it
    // wearing the pixels it covers, which is the property the whole hydro-dip
    // rests on.
    float maskScale[2]  = {1.f, 1.f};
    float maskOffset[2] = {0.f, 0.f};

    // Hold the mask fully pressed through a flat film, so the two can be seen at
    // once and the registration above can actually be set. Without it the mask
    // spends the only part of the timeline that is easy to judge hidden behind
    // the sheet.
    bool  alignMask = false;

    // A yaw applied to the placed mask, about its own vertical axis, in radians.
    //
    // For exercising the drape against a turning head when the source is a
    // still. A live head's rotation already arrives inside the mesh -- the fit
    // rotates the vertices and the projection carries it -- so this stays at
    // zero in the running piece; it exists because a photo cannot turn and the
    // drape off an asymmetric solid is the interesting case to look at.
    //
    // Note that it deliberately breaks the exact-projection property: the mask
    // is being turned away from the film it was registered to, which is the
    // point of turning it.
    float maskYaw = 0.f;

    // --- the mask's material -------------------------------------------------
    //
    // Not a second set of knobs. `main.mm` copies the root scene's own
    // FaceParams/EnvParams straight in, so the mask this scene uncovers and the
    // mask the root scene grows around are the same object in the same light --
    // which is the only reason the cut between the two scenes does not land on a
    // face that changes finish. Tuning the roots' mask tunes this one.
    //
    // The film is deliberately *not* on this material. The two halves of the
    // scene sit in different colour worlds on purpose: the film is the mirror's
    // output, display-referred, and has to stay pixel-identical to the scene the
    // piece cuts from; the mask is lit radiance through the same exposure + ACES
    // + sRGB the root scene applies, matching the scene it cuts to.
    MetalRootRenderer::FaceParams faceMat;
    MetalRootRenderer::EnvParams  env;
    float keyDir[3] = {0.4f, 0.8f, 0.35f};   // RootScene::lightDir's default
    float exposure  = 1.20f;                 // PostParams::exposure's default
    bool  tonemap   = true;
    // The size the mask is shaded at, in the root scene's world units. The
    // marble, the light falloff and the spot cone are all world-space
    // quantities tuned against a mask about four units across; this scene places
    // the mask by projection instead, at whatever size the fit puts it, so the
    // shading space is scaled back to that reference rather than every
    // parameter being re-tuned against the others.
    float shadeSpan = 4.0f;

    // Cloth knobs (passed through to the solver).
    // Slower than a real 9.8: at this scale (the sheet half-height is ~1.24
    // world units) real gravity puts the sheet behind the camera in well under
    // a second and the drape never reads.
    // Gravity is straight back, away from the camera, and nothing else.
    //
    // What takes the film off is then the mask's own asymmetry. A sheet draped
    // on a *symmetric* form and pulled straight back is a shrink-wrap -- the
    // tension presses it on rather than off, and it will sit there. Turn the
    // mask and the surface normals stop cancelling: the tangential components
    // no longer balance, the fabric drifts toward the shallower side, and once
    // any of it passes the silhouette the weight hanging behind peels the rest.
    // That is why contact resolves along the surface normal and not along the
    // view axis (see cloth.h) -- along z there is no tangential component for
    // an asymmetry to be unequal *in*, and the film stays put whatever the mask
    // is doing.
    //
    // Measured, at these settings: a head turning through +/-20 degrees clears
    // by about 4.5s; a mask held at a static 20 degrees peels the same way but
    // is only half off by then. Motion does most of the work, asymmetry sets
    // the direction. A live head supplies both.
    //
    // A -y component is the obvious way to get the sheet off the face and the
    // wrong one: it drags the whole film downward, so the film leaves by
    // *falling out of frame* and the mask is uncovered by something that has
    // nothing to do with it. Pulling only along the view axis leaves the mask as
    // the sole reason anything moves sideways -- the fabric slides off the brow
    // and the nose because the mask is still coming through it, which is the
    // thing the gesture is about. Kept as a knob at zero rather than deleted,
    // because a little of it is a legitimate look.
    float gravityBack  = 6.0f;   // -z, behind the mask
    float gravityDown  = 0.0f;   // -y
    float friction     = 0.07f;  // tangential grip on contact, per step
    float skin         = 0.012f; // stand-off from the mask surface
    // How freely the film lengthens. This is the knob the gesture lives on: at
    // 0 the sheet is inextensible and bridges the face instead of wrapping it;
    // toward 1 it stretches over the form the way a dipped film does.
    float stretch      = 0.80f;
    float stretchMax   = 1.90f;  // hard ceiling, multiples of the built length
    // How fast a held stretch becomes the sheet's own shape, per second. This
    // is what stops the release from being a snap.
    float plastic      = 2.0f;
    float damping      = 0.985f; // velocity retention per step
    int   substeps     = 2;
    int   iterations   = 24;
    int   sheetRes     = 72;     // grid resolution per side

    // The face the transition uncovers.
    //
    // `verts` is 3 floats/vertex in the fitter's model units and `tris` its
    // topology; passing an empty `tris` keeps the previous one, so the mesh can
    // be re-sent every frame for the cost of one copy.
    //
    // `uv` is the payload that makes the texture exact: 2 floats/vertex, the
    // normalised frame position (0..1, y-down) the fit projects that vertex to,
    // i.e. FaceFitter::projectNormalised with the same pin transform the mirror
    // was drawn with. The vertex is then placed so this camera projects it back
    // there, and `uv` is also its texture coordinate into the film. Pass it
    // empty and the mesh falls back to being centred and normalised by its own
    // extent -- fine for a headless shot, but the film will not line up with a
    // live pond.
    void setFaceMesh(const std::vector<float>& verts, const std::vector<int>& tris,
                     const std::vector<float>& uv = std::vector<float>());
    bool hasFace() const;

    // The film. This is MirrorScene's own output texture -- the sheet is
    // skinned with whatever the network is currently rendering.
    void setPondTexture(id<MTLTexture> pond);

    // Timeline control.
    void restart();
    void advance(double dt);
    double clock() const;
    float  press() const;      // 0..1, how far the mask has come through
    float  release() const;    // 0..1, how far the release front has run
    bool   done() const;
    const char* phaseName() const;

    // Encode the whole effect into `cb` and return the colour texture.
    id<MTLTexture> render(id<MTLCommandBuffer> cb);

    const Cloth& cloth() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
