// app_state.h — the app's shared, cross-TU global state.
//
// Extracted from main.mm so main.mm's dev-tool functions (dev_tools.mm) and
// its control panel (panel.mm) can be split into their own translation units
// without dragging the whole app shell along. This is a mechanical move: the
// globals below are still exactly what they were in main.mm, still touched
// directly by name (`g_foo`) from wherever they always were -- only their
// storage now lives in app_state.mm, declared `extern` here.
//
// Not a struct/class on purpose, for the same reason main.mm never made them
// one: every consumer already spells `g_foo`, and boxing them up would be a
// second, much larger rewrite this split doesn't need.
#ifndef __OBJC__
#error "app_state.h touches Metal/Cocoa types; include from an .mm file"
#endif
#import <Metal/Metal.h>

#include "audio_pulse.h"
#include "face_tracker.h"
#include "face_fit.h"
#if MIRROR_HAVE_KINECT
#include "kinect_target.h"
#endif
#include "midi_in.h"
#include "screen_layout.h"
#include "show_timeline.h"
#include "root_camera_sequence.h"
#include "presence.h"
#include "chord.h"
#include "wwise_audio.h"

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

// --- types that used to be declared inline among the globals ----------------

struct FitTune {
    int   steps     = 1;
    float lr        = 3e-3f;
    int   downscale = 2;        // fit grid = display size / this
};

// The box is the default because it is what "fit the face" usually means in
// practice -- the hull supervises skin only and never the boundary between a
// person and the room, so the network has no reason to draw an edge there.
enum class MaskShape { Box = 0, Hull = 1 };

enum class Source { Kinect = 0, Photo = 1 };

// centred    resample the subject to the middle of the frame every frame.
// track      fit the subject where the camera found it.
// stabilised fit it where it is, but shift the network's input coordinates
//            by the head's displacement instead of resampling.
enum class HeadMode { Centred = 0, Track = 1, Stabilised = 2 };

// What the panel/HUD render when nothing overrides it: mirrors show::Phase's
// scene choice. Lifted out of main() (where it used to be a local enum) since
// both the core loop and the panel need it.
enum class Scene { Mirror = 0, Roots = 1, Transition = 2, FitView = 3,
                    CamMask = 4, Camera = 5 };

// Fog visibility read as "no fog" while it fades in during Roots beat 1 --
// the top of the panel's visibility range (see the roots/fog panel section).
constexpr float kFogClearVisibility = 600.f;

// --- fit tuning ---------------------------------------------------------
extern FitTune g_tune_crop;
extern FitTune g_tune_full;
extern bool  g_fit_live;       // retarget from the camera every frame
extern bool  g_fit_arm;        // a fit was requested and not yet honoured

// --- the fit's frequency ramp --------------------------------------------
extern bool   g_w0_ramp_on;
extern float  g_w0_fit;
extern float  g_w0_ramp_secs;
extern float  g_w0_from;
extern float  g_w0_idle;
extern double g_w0_t0;

// --- colour follows the fit ----------------------------------------------
extern bool   g_colour_fit_on;
extern float  g_colour_fit_full;
extern float  g_colour_fit_max;
extern float  g_colour_fit_secs;
extern float  g_colour_from;
extern float  g_colour_idle;
extern float  g_colour_now;

#if MIRROR_HAVE_KINECT
extern mirror::KinectFitTarget g_kinect;
extern bool g_open_sensor;
#endif

// --- face tracking --------------------------------------------------------
extern midi::Input g_midi;
extern std::string g_midi_err;

extern mirror::AudioPulses g_pulses;
extern bool  g_pulse_drops;
extern float g_pulse_gain;

// The pluck bed's own crackle onsets (Wwise cue markers on Play_FirePlucker,
// see wwise_audio.h), Idle/Fitting only -- the phases where that bed plays.
extern bool  g_pluck_drops;
extern float g_pluck_drop_gain;

extern mirror::FaceTracker g_tracker;
extern mirror::FaceResult  g_face;
extern mirror::FaceFitter  g_fitter;
extern bool  g_track_on;
extern bool  g_mask_fit;
extern bool  g_drive_roots;
extern bool  g_root_authored_camera;
extern int   g_track_w;
extern int   g_track_h;
extern int   g_track_px;
extern int   g_mask_dilate;
extern int   g_mask_shape;
extern float g_crop_pad;
extern bool  g_collect_id;
extern bool  g_auto_fit_id;
extern double g_auto_fit_next;
extern double g_last_id_sample;
extern double g_id_started;
extern float g_id_collect_secs;
extern float g_id_residual;
extern std::string g_track_err;

// --- the show ---------------------------------------------------------------
extern show::Timeline g_show;
extern bool g_show_on;
extern int g_show_scene[(int)show::Phase::Count];
extern float g_show_min[(int)show::Phase::Count];
extern float g_show_max[(int)show::Phase::Count];
extern float g_show_hold[(int)show::Phase::Count][show::kMaxEdges];
extern RootBeatParams g_root_beats;
extern float g_phase_fog_intensity[(int)show::Phase::Count];
extern float g_screen_fade;
extern float g_idle_intro_seconds;
extern double g_idle_intro_t0;
extern double g_roots_absent_t;
extern int g_view_override;
extern bool g_show_paused;
extern float g_show_fit_px;
extern float g_show_fit_loss_half;
extern float g_show_fit_score;
extern float g_fit_level_now;
extern int g_show_cue_cc;
extern int g_show_phase_cc;
extern bool g_show_log;
extern std::vector<unsigned char> g_track_rgb;
extern std::vector<unsigned char> g_fit_mask;
extern int64_t g_track_ts;

// --- the sound ----------------------------------------------------------
extern mirror::WwiseAudio g_audio;
extern mirror::Presence   g_presence;
extern mirror::Chord      g_chord;
extern bool  g_audio_on;
extern bool  g_audio_auto;
extern float g_audio_key;
extern float g_audio_intensity;
extern float g_audio_transpose;
extern bool  g_shepherd_on;     // the Fitting-phase glissando, on or off
extern float g_shepherd_rate_min;  // semitones/s at fit_level 0
extern float g_shepherd_rate_max;  // semitones/s at fit_level 1
extern float g_shepherd_phase;  // semitones, 0..12 -- the Fitting-phase glissando's position

// The pad's flanger (Mirror_Pad_Flanger, ModFrequency bound 1:1 to the
// `FlangerRate` RTPC): a sweep that speeds up as the fit converges, the same
// "the room is responding" idea as the shepherd's rate above.
extern float g_flanger_rate_min;  // Hz, at fit_level 0
extern float g_flanger_rate_max;  // Hz, at fit_level 1
extern std::string g_audio_err;

extern std::vector<float> g_face_colors;

// --- locked fits -----------------------------------------------------------
extern bool  g_capture_auto;
extern std::string g_capture_last;
extern std::string g_capture_msg;
extern std::vector<std::string> g_capture_ids;
extern int   g_capture_sel;
extern std::string g_capture_loaded;
extern bool  g_texture_mask;
extern bool  g_face_colors_fresh;

// --- screen orientation ------------------------------------------------------
extern int   g_orientation;
extern float g_portrait_aspect;
extern mirror::FeedCrop g_feed;

// --- the frame source -------------------------------------------------------
extern int g_source;
extern std::vector<unsigned char> g_photo;
extern int  g_photo_w, g_photo_h;
extern char g_photo_path[512];

extern bool  g_show_source;
extern int   g_source_pip_w;
extern int   g_source_corner;
extern bool  g_pip_landmarks;

extern bool  g_show_netin;
extern int   g_netin_pip_w;
extern int   g_netin_corner;
extern float g_netin_dim;

extern bool  g_show_hud;

// --- detached-panel viewports ------------------------------------------------
extern unsigned g_target_swaps;
extern unsigned g_vp_skips;
extern unsigned g_vp_relayers;
extern id<MTLDevice> g_vp_device;
extern id<MTLCommandQueue> g_vp_queue;

// --- the control panel's own window ------------------------------------------
extern bool  g_ui_visible;
extern bool  g_ui_detached;
extern bool  g_fullscreen;
extern bool  g_panel_reset;
extern bool  g_panel_cli;
extern bool  g_write_settings_doc;
extern bool  g_roots_roundtrip;
extern bool  g_full_roundtrip;
extern std::string g_root_preset_name;
extern std::vector<std::pair<std::string, std::string>> g_root_preset_kv;
extern float g_panel_content_h;
extern bool  g_panel_test;
extern int   g_panel_test_tab;
extern int   g_panel_test_tab_count;
extern int   g_exit_code;

// --- the camera mask --------------------------------------------------------
extern bool  g_cam_mask_on;
extern float g_cam_x0, g_cam_y0, g_cam_x1, g_cam_y1;
extern float g_cam_feather;

// --- head movement ------------------------------------------------------
extern int   g_head_mode;
extern float g_head_smooth;
extern bool  g_head_valid;
extern float g_head_cx, g_head_cy;
extern float g_head_hx, g_head_hy;
extern float  g_face_hold_secs;
extern int    g_face_acquire;
extern double g_face_last_seen;
extern int    g_face_streak;
extern bool   g_face_held;

extern bool  g_region_on;
extern bool  g_region_hull;
extern float g_fade_start;
extern float g_fade_width;
extern bool  g_z_free;
extern float g_grey_out;
extern std::vector<float> g_region_dist;

extern bool g_have_mask;
extern mirror::DstRect g_mask_bbox;

extern bool  g_face_size_on;
extern float g_face_size;
