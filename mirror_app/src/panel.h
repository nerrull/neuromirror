// panel.h — the operator control panel: DrawControlPanel draws the main
// tabbed window (show/sound/screen/camera-mask/settings/face-tracking/text/
// network/growth/presets), DrawOverlayWindows draws the always-on-top
// diagnostic overlays (camera debug, cam-mask preview, source/netin PIP,
// show HUD). Both were, until this split, drawn inline in main.mm's per-
// frame loop -- see PANEL.md.
//
// PanelFrameArgs bundles exactly the main()-local state the panel body
// reads or writes that isn't already reachable through app_state.h globals
// or core_frame.h helpers: the scene objects, this frame's composition/fit
// geometry, a few tuning-knob locals the panel's sliders edit directly, and
// the PIP preview textures. main() builds one of these at the old panel
// call site and passes it to both functions.
#ifndef __OBJC__
#error "panel.h touches Metal types; include from an .mm file"
#endif
#import <Metal/Metal.h>

#include <vector>

class MirrorScene;
class RootScene;
class TransitionScene;
namespace mirror { class TextOverlay; struct TextParams; struct ScreenLayout; }

struct PanelFrameArgs {
    MirrorScene&      mirror;
    RootScene&        roots;
    TransitionScene&  trans;
    mirror::TextOverlay& text;
    mirror::TextParams&  textp;

    int scene = 0;                 // current Scene, read-only display
    int fbw = 0, fbh = 0;
    int compW = 0, compH = 0;
    const mirror::ScreenLayout& layout;
    double nowT = 0.0;
    int fit_w = 0, fit_h = 0;
    const std::vector<float>& live_rgb;
    double fpsShown = 0.0;

    int&  downscale;
    int&  rootDownscale;
    bool& rootAutoScale;
    int&  rootTargetDim;
    int&  rootSeed;
    int&  fieldGrid;

    id<MTLTexture> srcTex = nil;  int srcTexW = 0, srcTexH = 0;
    id<MTLTexture> netTex = nil;  int netTexW = 0, netTexH = 0;
    int pipW = 0, pipH = 0;
    bool srcFresh = false, netFresh = false;
};

// Whether the panel is its own OS window is remembered next to imgui.ini
// (see PanelFrameArgs' header comment) -- called once at bootstrap, before
// the loop, and again from inside the panel body when the setting changes.
void PanelStateSave(bool detached);
void PanelStateLoad(bool* detached);

void DrawControlPanel(PanelFrameArgs& a);
void DrawOverlayWindows(PanelFrameArgs& a);
// The roots tab alone (the "roots/..." registry section), for a headless
// caller that wants a roots preset applied to a RootScene without the rest
// of the app: see dev_tools.mm's applyRootsBank. Needs a live ImGui frame.
void DrawRootsTab(RootScene& roots, int& fieldGrid, int& rootSeed, int fbw, int fbh);
