// app_state.mm — definitions for the globals declared in app_state.h.
//
// See app_state.h for why these are still plain globals rather than a struct.
// The comments below are unchanged from where these lines used to live in
// main.mm.
#import "app_state.h"

FitTune g_tune_crop{4, 2e-3f, 1};
FitTune g_tune_full{1, 3e-3f, 3};
bool  g_fit_live = false;       // retarget from the camera every frame
// The fitting phase asked for a fit and has not got one yet.
//
// A phase entry cannot simply call beginFit(): it fires from inside the show
// block, and whether there is a camera frame of the right size to fit is not a
// question that has an answer at that moment -- the sensor may still be
// opening, or the fit grid may have just changed shape. So the entry records
// the *request* and the render loop honours it on the first frame that can,
// which also means a phase entered before the sensor is up still fits as soon
// as the sensor is up rather than silently never fitting at all.
bool  g_fit_arm  = false;

// --- the fit's frequency ramp -----------------------------------------------
//
// sine_w0 is how many regions the field breaks into, and a fit wants far more
// of them than an idle mirror does: it is the frequency of the basis the
// network has to reconstruct a face out of, and at the idle value there simply
// are not enough of them to carry an eye.
//
// It cannot be turned up *during* a fit, which is the thing to know here. Once
// the trainer is ready the render draws the learned weights, and sine_w0 only
// ever shapes the *base* ones -- so its value matters at exactly one instant,
// the beginFit that seeds the optimiser from them. Hence a ramp that runs
// before the fit starts rather than alongside it: the arm waits for it.
//
// The ramp is also the visible part. Through it the idle field gains detail as
// the person is captured, which is the transition the piece wants anyway.
bool  g_w0_ramp_on   = true;
float g_w0_fit       = 60.f;    // where the fitting phase takes it
float g_w0_ramp_secs = 1.5f;
// Ramp state: where it started, when, and what to put back on the way out.
float g_w0_from      = 0.f;
float g_w0_idle      = -1.f;    // < 0 = nothing saved
double g_w0_t0       = -1.0;    // < 0 = not ramping

// --- colour follows the fit ----------------------------------------------
// The mirror idles in black and white and the fitting phase brings colour in,
// so the room sees the person arriving in the image rather than a cut. It is
// driven by `g_fit_level_now` -- the same number the harmony and the shepherd
// climb on -- so the three rise together off one measurement of how well she
// has been captured, instead of each running its own clock.
//
// Three shapings, all necessary. The level is mapped through `g_colour_fit_full`
// so full colour lands before the fit has finished converging (that last stretch
// is slow, and colour arriving only at the very end reads as a switch); the
// ceiling it climbs to is `g_colour_fit_max` rather than a hardcoded 1 -- a
// room that wants the mirror to only ever half-saturate, say, sets this
// instead of fighting the arrival point to get there; and the result is a
// one-way ratchet, slew-limited by `g_colour_fit_secs`, because the loss is
// noisy frame to frame and colour that drains back out on a bad step is the
// one thing that would give the mechanism away.
bool  g_colour_fit_on   = true;
float g_colour_fit_full = 0.7f;   // fit level that reaches g_colour_fit_max
float g_colour_fit_max  = 1.0f;   // the ratchet's ceiling (0 grey -> 1 full RGB)
float g_colour_fit_secs = 6.f;    // fastest the mix may cross 0 -> g_colour_fit_max
// Ramp state: where it started, where it is, and what to put back on the way
// out to idle.
float g_colour_from     = 0.f;
float g_colour_idle     = -1.f;   // < 0 = nothing saved
float g_colour_now      = 0.f;
#if MIRROR_HAVE_KINECT
mirror::KinectFitTarget g_kinect;
// The sensor is opened at startup (see main). --no-sensor leaves it closed,
// which is what you want when kinect_v2_demo needs the device: only one
// process can hold it, and whoever asks second gets LIBUSB_ERROR_NO_DEVICE.
bool g_open_sensor = true;
#endif
// --- face tracking ----------------------------------------------------------
//
// One tracker feeds two consumers, which is why it lives here rather than
// inside either scene:
//
//   the mirror  the landmark hull becomes the training mask, so the network
//               fits the person and leaves the background generative.
//   the roots   the landmarks + blendshapes drive a morphable-model fit, and
//               the fitted mesh replaces the static canonical face on the root
//               scene's masks.
//
// Tracking runs at its own resolution, well above the fit grid: the fit is a
// couple of hundred pixels wide, where a face is too few pixels for the
// landmarks to be worth anything. MediaPipe crops to the detected face ROI, so
// the cost is roughly resolution-independent (measured 4.5 ms/frame).
// MIDI stays open across the session; the registry holds the bindings.
midi::Input g_midi;
std::string g_midi_err;
// Onsets from the Wwise OnsetTap plug-in, and what they are allowed to do.
// Kept alive across scene changes: reconnecting on every switch would lose the
// stream's read position and replay nothing, but it would also make a live show
// depend on which scene happens to be up.
mirror::AudioPulses g_pulses;
bool  g_pulse_drops  = true;    // onsets spawn raindrops
float g_pulse_gain   = 1.0f;    // scales an onset's strength before it is used
bool  g_pluck_drops     = false;  // pluck-bed crackle onsets spawn raindrops
float g_pluck_drop_gain = 1.0f;   // scales a marker hit's strength before it is used

mirror::MicLevel g_mic;
std::string g_mic_err;
mirror::FaceTracker g_tracker;
mirror::FaceResult  g_face;
mirror::FaceFitter  g_fitter;
bool  g_track_on     = false;   // run the tracker at all
bool  g_mask_fit     = true;    // crop the live fit to the face when there is one
bool  g_drive_roots  = true;    // fitted mesh -> the root scene's face masks
// The tracker's input frame.
//
// Its *aspect must be the composition's*, and the size is derived per frame to
// keep it that way -- these are only the last computed values, not settings.
//
// Everything downstream trades in landmark coordinates normalised to whatever
// image the tracker was handed, and those coordinates are then applied straight
// to the fit grid, to the region and to the preview. That is only meaningful if
// all four are looking at the same rectangle of the sensor -- and
// ComputeFeedRect picks its rect from the *destination's aspect*. Fixed at
// 480x360 these were 4:3, while the fit grid and the preview follow the
// composition, which on the installation's portrait panel is 9:16. Out of a
// 1920x1080 sensor that is a 1440x1080 crop against a 608x1080 one: the tracker
// was looking at more than twice the width the fit was, so a landmark at 0.6
// across the tracker's frame landed at 0.74 across the fit's. Hence a mask
// visibly offset from the face in the overlay -- and, since the same numbers
// build the training mask, a fit supervised on the wrong pixels.
int   g_track_w      = 480;
int   g_track_h      = 270;
// Long edge of that frame. MediaPipe wants more resolution than the fit grid --
// a face a couple of hundred pixels wide is too few landmarks' worth of detail.
int   g_track_px     = 480;
int   g_mask_dilate  = 6;       // px, at fit-grid scale
int   g_mask_shape   = (int)MaskShape::Box;
float g_crop_pad     = 0.30f;   // box padding, as a fraction of the box's size
bool  g_collect_id   = false;   // gathering identity samples
// Start collecting on the frame a face is acquired with no identity fitted.
//
// The identity solve is what turns the mean face into *this* person's mask, and
// nothing was ever starting it outside a running show: the operator pressed
// "fit identity" or the mask stayed the basis's average, which is a real face
// and the wrong one. An installation has nobody to press it. So the arrival of
// a face with no identity behind it is the trigger, which also makes the
// re-arm free -- every path that forgets a sitter already calls clearIdentity(),
// and clearing it is now the same thing as asking for the next one.
bool  g_auto_fit_id  = true;
// Earliest the automatic start may fire again. A solve that produces nothing --
// no retained frames, a basis that failed to load -- leaves hasIdentity() false,
// and without this the trigger would refire on the very next frame and the app
// would spend its life in a collection that never completes.
double g_auto_fit_next = 0.0;
double g_last_id_sample = 0.0;
double g_id_started = 0.0;
float g_id_collect_secs = 5.0f;
float g_id_residual  = -1.f;
std::string g_track_err;
// --- the show ---------------------------------------------------------------
// The running order, when the piece is driving itself rather than being driven
// from the scene radio buttons. Off by default: development is one scene at a
// time, and a timeline that started reassigning the scene under you while you
// were tuning a shader would be an obstacle. The installation turns it on.
show::Timeline g_show;
bool  g_show_on = false;
// Which scene each phase renders. A phase is a moment in the piece, not a
// renderer, and the two are worth being able to repoint independently -- the
// fitting phase showing the diagnostic fit view instead of the mirror is a
// setting, not a rebuild. Indexed by show::Phase.
int g_show_scene[(int)show::Phase::Count] = {0, 0, 2, 1};  // mirror,mirror,trans,roots

// Per-phase timing, panel-declared under `show/<phase>` and pushed into
// g_show via setTiming/setHold every frame (see the "show" tab) -- these
// arrays are what a Bank::Show preset actually saves/loads, since Timeline
// itself holds no path names of its own. Seeded from show::Graph()'s
// defaults once at startup, below main()'s early setup.
float g_show_min[(int)show::Phase::Count] = {};
float g_show_max[(int)show::Phase::Count] = {};
float g_show_hold[(int)show::Phase::Count][show::kMaxEdges] = {};

// The Roots timeline's knobs (stage durations, growth-rate range, camera
// angles and easing, reveal, orbit, outro, head pan) -- panel-declared under
// `show/roots`, see the "show" tab. Passed fresh to RootSequence every
// frame, so a slider dragged mid-shot retimes what is running rather than
// requiring a restart.
RootSequenceParams g_root_seq;

// Per-phase fog visibility (world units -- lower is thicker), see
// MetalRootRenderer::Fog::visibility. Only the Roots renderer ever draws fog,
// but it is kept one-per-phase as asked rather than one global, so a look
// dialled in for Roots does not silently apply if fog is ever added to
// another scene. `fog_fade_seconds` on g_root_seq is not here: it is a Roots
// stage duration, so it lives with the rest of the timeline.
float g_phase_fog_intensity[(int)show::Phase::Count] = {45.f, 45.f, 45.f, 45.f};

// Screen-wide fade to black (0 = clear, 1 = black), applied in present.metal
// after everything else is composited. Two things drive it, never at once:
// RootSequence's outro stage ramps it up as the room empties, and Idle's
// own intro timer ramps it back down when the mirror resumes. See the
// entries()-diff block and the Roots render branch below.
float g_screen_fade = 0.f;
// How long Idle's fade-in from black takes, once it is entered. Runs on
// every Idle entry, not only the one after Roots -- harmless (a fade-in from
// black at boot too) and avoids threading "did we just come from Roots"
// through the entries()-diff block.
float g_idle_intro_seconds = 1.5f;
double g_idle_intro_t0 = -1.0;   // glfwGetTime() Idle was entered at, -1 = not fading

// How long the face has been continuously absent while in Phase::Roots, timed
// by the host rather than read from show::Timeline (which does not expose its
// own debounce accumulator). Kept in lockstep with Timeline's own FaceAbsent
// edge -- same signal, same dt -- so the outro, timed off it below, finishes
// exactly as Timeline's absent_hold fires and the phase change lands on a
// fully black screen. Reset whenever a face is present or the phase is not
// Roots.
double g_roots_absent_t = 0.0;

// The diagnostic views (fit view, camera mask) are not phases -- nothing in the
// piece ever cuts to them. They are a lens held over whatever the timeline is
// doing, so they override the scene without touching the phase: -1 to follow
// the phase, otherwise a Scene value.
int g_view_override = -1;

// The timeline held where it stands. Separate from g_show_on, which is a mode
// and restarts from the top when it is switched back on: pausing keeps the
// phase and its clock and resumes into them.
bool g_show_paused = false;
// Mean landmark error, in pixels, of the one-shot identity/mesh fit.
// Diagnostic only: nothing about the show is gated on the mesh fit any more
// (it still runs once, during Fitting, to personalize the Roots-phase mesh --
// it just no longer decides when Fitting ends). Kept as a display threshold
// for the "(N px)" readouts on the fit panel.
float g_show_fit_px = 6.f;
// Where AudioParams::fit_level's own curve is half scale, in loss. Tune
// against the live "loss %.5f" readout on the fit panel and the FitLevel
// readout together.
float g_show_fit_loss_half = 0.005f;
// AudioParams::fit_level score, 0..1, above which the live fit counts as
// having actually captured the face -- what ShowFitConverged() (the Fitting
// -> Transition gate, debounced by the script's `fit_hold`) waits on. Scored
// rather than gated on raw loss directly: fit_level is already the tuned,
// interpretable number (see g_show_fit_loss_half above), so this is one dial
// in the same units the FitLevel readout shows, not a second, separate loss
// threshold to keep in sync with it. ~0.85 by ear/eye.
float g_show_fit_score = 0.85f;
// ap.fit_level, mirrored into a global each frame (see the AudioParams block)
// so ShowFitConverged() -- a free function with no access to the live-loop's
// local `mirror` -- can read it.
float g_fit_level_now = 0.f;
// Operator overrides. Any CC on `cue_cc` past halfway takes the current phase's
// forward edge -- "go" means the same thing everywhere, so nobody has to know
// which event it is short-circuiting. Any on `phase_cc` jumps straight to the
// phase its value selects.
int g_show_cue_cc = 100;
int g_show_phase_cc = 101;
bool g_show_log = true;
std::vector<unsigned char> g_track_rgb;
std::vector<unsigned char> g_fit_mask;
int64_t g_track_ts = 0;         // must increase monotonically for video mode
// --- the sound --------------------------------------------------------------
//
// The Wwise engine, running in this process (see wwise_audio.h). It is fed from
// two places and only two: the phase-entry switch below posts the events, and
// the per-frame block after it pushes the continuous parameters. Nothing else
// in the app talks to it, which is what keeps "what does the piece sound like"
// a question with one answer in the Wwise project rather than a behaviour
// spread across the render code.
mirror::WwiseAudio g_audio;
mirror::Presence   g_presence;    // the room, as numbers the synth can use
// The mirror phase's harmony (see chord.h). Fed from the same block that feeds
// the RTPCs and reset from the same phase-entry switch that posts the events,
// so there is no second notion of "how far through the fit are we".
mirror::Chord      g_chord;
bool  g_audio_on   = true;        // send anything at all
bool  g_audio_auto = true;        // the phases post their own events
float g_audio_key  = 48.f;        // MIDI note: the piece's base pitch
float g_audio_intensity = 1.f;    // master, on the main bus
float g_audio_transpose = 0.f;    // semitones: offsets every emitter, Wwise-side
bool  g_shepherd_on = true;       // the Fitting-phase glissando, on or off
float g_shepherd_rate_min = 0.15f;  // semitones/s at fit_level 0
float g_shepherd_rate_max = 0.6f;   // semitones/s at fit_level 1
float g_shepherd_phase = 0.f;     // semitones, 0..12: Fitting-phase glissando position

float g_flanger_rate_min = 0.1f;   // Hz, at fit_level 0
float g_flanger_rate_max = 2.5f;   // Hz, at fit_level 1

std::string g_audio_err;

// The neural texture the mask wears: per-vertex RGB sampled from the mirror's
// own output at the fitted mesh's projected positions. Lives here rather than
// in either scene because it is produced by one and consumed by the other.
std::vector<float> g_face_colors;
// --- locked fits -----------------------------------------------------------
// The transition freezes the film and nails the mask's uv to it (see
// transition_scene.h). That pair is the sitter, and it is written out under an
// id so the root scene can wear it again later -- next scene, or next night.
bool  g_capture_auto = true;          // write one every time the transition locks
std::string g_capture_last;           // id of the most recent write, for the UI
std::string g_capture_msg;            // what happened, shown in the panel
std::vector<std::string> g_capture_ids;
int   g_capture_sel = -1;
// The capture currently worn by the root scene's masks, if any.
std::string g_capture_loaded;
bool  g_texture_mask = true;
bool  g_face_colors_fresh = false;
// --- the frame source -------------------------------------------------------
//
// Tracking and fitting want the same picture at different sizes and depths
// (RGB8 for MediaPipe, floats for the fit), so both go through here rather than
// reaching for the sensor themselves.
//
// A still photo can stand in for the camera. That is not only a convenience for
// working without a person in front of the Kinect: it makes the whole pipeline
// reproducible, which is what lets a known face be fitted and compared run to
// run. The photo is simply substituted into the stream -- nothing downstream
// knows the difference.
// --- screen orientation ------------------------------------------------------
//
// The installation's screen is portrait; development happens on a landscape
// monitor. See screen_layout.h -- scenes render at the *composition* size, which
// is the drawable in Auto and a centred tall box when Portrait is forced on a
// wide window. Everything shape-dependent follows from that one size: the
// mirror's coord aspect, the root frustum, where the text lands, and the rect
// taken out of the camera.
int   g_orientation = (int)mirror::Orientation::Auto;
float g_portrait_aspect = 9.f / 16.f;   // the panel's w/h stood on its end

// How the 16:9 sensor is framed into that shape. A portrait frame keeps about a
// third of the sensor's width, so this is not a fine adjustment -- it decides
// who is in the picture.
mirror::FeedCrop g_feed;

int g_source = (int)Source::Kinect;
std::vector<unsigned char> g_photo;      // full-res RGB8
int  g_photo_w = 0, g_photo_h = 0;
char g_photo_path[512] =
    "/Users/erichan/Documents/Development/neuromirror/emotion/_track_frames/f0016.png";
// A corner picture-in-picture of whatever the source is currently handing out.
// Worth having because every symptom of "the fit is not following me" looks the
// same on the mirror itself -- a closed sensor, a stale snapshot, the photo
// still selected, a mirrored image -- and they are all immediately obvious on
// the raw frame.
bool  g_show_source   = false;
int   g_source_pip_w  = 320;    // overlay width in points
int   g_source_corner = 1;      // 0 TL, 1 TR, 2 BL, 3 BR
bool  g_pip_landmarks = true;   // draw the tracker's landmarks over it

// --- what the network is actually being trained on --------------------------
//
// The camera overlay answers "is a frame arriving". This answers the question
// after it, which is the one a fit that converges onto the wrong thing actually
// poses: of that frame, *which pixels reach the optimiser, at what resolution,
// the right way round?* Everything between the sensor and the loss -- the feed
// crop, the mirroring, the fit grid, the head placement, the mask -- lands in
// this one buffer, and every one of them is a way for the input to be wrong
// while every individual stage looks fine.
//
// So it is drawn from `live_rgb` itself, the exact vector handed to setTarget,
// rather than rebuilt from the parts. A preview reconstructed from the same
// inputs would agree with a broken pipeline.
bool  g_show_netin    = false;
int   g_netin_pip_w   = 260;
int   g_netin_corner  = 3;
// Dim the pixels the mask excludes instead of hiding them, so the crop can be
// seen against what surrounds it. At 0 the untrained surround is black, which
// is what the optimiser effectively sees.
float g_netin_dim     = 0.22f;
// The running-order readout: phase, what it is waiting for, and how the fit is
// doing. Deliberately independent of the panel -- it is for watching the piece
// run with the UI hidden, which is when a phase that will not advance is both
// most likely and least visible.
bool  g_show_hud      = false;
// --- detached-panel viewports, rendered here rather than by the backend ------
//
// imgui_impl_metal's own Renderer_RenderWindow installs a CAMetalLayer on the
// viewport's content view once, at creation, and thereafter only touches its
// drawableSize when the backing scale factor changes. That holds right up until
// something else replaces the view's layer -- which the window server does on
// some window moves, particularly across screens -- and from then on the
// backend is drawing into a layer that is no longer the one being displayed.
// The window shows the empty layer that replaced it, i.e. black, and nothing
// ever puts it right because from the backend's point of view it is still
// rendering happily.
//
// So the layer is re-owned every frame instead of once: if the view is not
// carrying our CAMetalLayer any more, install one. The size is re-derived from
// the content view every frame too, off `bounds` rather than the window frame,
// which is the thing actually being drawn into.
//
// The occlusion guard is kept, and kept for the reason upstream states rather
// than as caution: -[CAMetalLayer nextDrawable] blocks for about a second on a
// fully occluded layer, and this runs on the render thread, so one occluded
// panel would take the whole piece to 1 fps. Skips are counted so a panel that
// has gone quiet can be told apart from one that is drawing black.
// How often the fit's target is actually being replaced.
//
// "The training buffer stopped updating" has three quite different causes --
// the sensor stopped delivering, the target stopped being swapped, or the
// optimiser stopped stepping -- and they are indistinguishable by looking at
// the picture. These are counters rather than flags because the interesting
// failure is a *rate* falling to zero, not a state.
unsigned g_target_swaps = 0;

unsigned g_vp_skips = 0;       // renders skipped as occluded
unsigned g_vp_relayers = 0;    // times the layer had to be re-installed
// The override is installed as a plain function pointer, so what it needs is
// here rather than captured.
id<MTLDevice> g_vp_device = nil;
id<MTLCommandQueue> g_vp_queue = nil;

// --- the control panel's own window ------------------------------------------
//
// The panel belongs to whoever is operating the piece, not to the frame the
// audience sees, so it has to be able to leave. Two separate things:
//
//   visible    F1 takes the whole UI away and brings it back, which is what
//              the projection wants during a run whichever window it is in.
//   detached   the panel becomes its own OS window (an ImGui "viewport"),
//              draggable to a second monitor -- or, on one monitor, simply
//              moved off the composition and hidden behind it.
//
// Detach is per-window rather than io.ConfigViewportsNoAutoMerge, which would
// also tear the cam-mask and source overlays off the frame they are drawn on.
bool  g_ui_visible  = true;
bool  g_ui_detached = false;

// --fullscreen: open on the primary monitor at its native mode instead of a
// 1280x720 window. The installation runs unattended on one screen, where a
// window with a title bar is a window a visitor can move; the operator's build
// keeps the default so the panel has somewhere to sit.
bool  g_fullscreen  = false;

// --reset-panel: put the panel back over the main window at a known size, for
// when imgui.ini has it parked on a monitor that is not here any more.
bool  g_panel_reset = false;
bool  g_panel_cli   = false;   // the flags above were given, so do not restore
// --settings-doc: build one panel frame, write SETTINGS.md, exit.
bool  g_write_settings_doc = false;
// --presettest: round-trip SimParams through the roots bank, then exit.
bool  g_roots_roundtrip = false;
// --roundtriptest: mutate every live parameter in every bank, save, corrupt,
// load, and check each one came back as the mutated value -- not the struct
// visitor --presettest does for one bank, but the registry mechanism itself,
// generalised to whichever ~350 controls the panel currently declares.
bool  g_full_roundtrip = false;
// --rootpreset <name> [field=value ...]: set growth fields from the command
// line, save the roots bank under that name, exit.
//
// A root look is dialled in headlessly -- tools/root_sweep.cpp grows the relay
// with no window and reports which hops actually arrived -- and the numbers that
// come out of that have to end up in a preset. Writing the file by hand would
// mean writing parameter *names* by hand, and a key that matches nothing loads
// as silence. This drives the real registry instead: the same save the panel's
// button calls, so the file is a real bank dump rather than a plausible one.
std::string g_root_preset_name;
std::vector<std::pair<std::string, std::string>> g_root_preset_kv;
// Height of the panel's content in the frame just built, for --paneltest.
float g_panel_content_h = 0.f;
// --paneltest: force-select each tab in turn, check only that tab drew and
// that it declared no live ImGui-ID or registry-path collision, then exit.
bool  g_panel_test = false;
int   g_panel_test_tab = 0;     // which tab index --paneltest is forcing open
int   g_panel_test_tab_count = 0;  // set once the first frame has counted them
// What main() returns when one of the in-app tests above asks it to stop. They
// have to run inside the real loop, so they cannot simply return from a branch.
int   g_exit_code = 0;
// --- the camera mask --------------------------------------------------------
//
// A rectangle of the sensor's view that is kept; everything outside it goes
// black. The mirror only sells if the frame contains the person and nothing
// that says "room" -- a doorway, a window, the edge of the rig.
//
// Applied in *camera* space, before any head-mode placement, because that is
// the space it is authored in: the rectangle covers a fixed part of the room,
// and a mask that moved with the subject would be a vignette rather than a
// piece of set dressing. It is applied to the tracker's frame as well as the
// fit's, so nothing outside it can be detected either.
bool  g_cam_mask_on = false;
float g_cam_x0 = 0.15f, g_cam_y0 = 0.05f, g_cam_x1 = 0.85f, g_cam_y1 = 0.95f;
float g_cam_feather = 0.03f;   // soft edge, as a fraction of the frame
int   g_head_mode = (int)HeadMode::Track;
float g_head_smooth = 0.25f;    // EMA per frame; 1 = no smoothing

// The tracked head, smoothed, in normalised frame coords. Smoothed because the
// landmark box jitters by a pixel or two on a perfectly still head, and every
// consumer here is something that must not jitter: an input offset that shakes
// makes the fit chase its own coordinate system, and a region edge that shakes
// is visible on screen directly.
bool  g_head_valid = false;
float g_head_cx = 0.5f, g_head_cy = 0.5f;
float g_head_hx = 0.15f, g_head_hy = 0.2f;   // half-extent, padding included

// Tracking is not all-or-nothing: MediaPipe drops a frame on a blink, a turn,
// a hand across the face. Treated as "no face" those gaps are expensive --
// the fit target flips from a crop to the whole frame and back, which resizes
// the trained pixel set, rebuilds the feature gather, and throws the region's
// soft edge on and off. So a detection has to be missing for a while before it
// counts as gone, and present for a moment before it counts as arrived.
float  g_face_hold_secs = 0.6f;   // keep the last box this long after the last hit
int    g_face_acquire   = 2;      // consecutive hits before a face is believed
double g_face_last_seen = -1e9;   // when the tracker last returned a face
int    g_face_streak    = 0;      // consecutive detections so far
bool   g_face_held      = false;  // showing a held box rather than a fresh one

// The soft edge around the fit, and what rides it.
bool  g_region_on   = true;
bool  g_region_hull = true;      // follow the mask's outline, not its bounding box
float g_fade_start  = 0.02f;     // where the fade begins, in coord units
float g_fade_width  = 0.35f;     // and how far it runs
bool  g_z_free      = false;     // animate the latent outside the crop
float g_grey_out    = 0.0f;      // drain colour outside the crop
std::vector<float> g_region_dist;   // scratch: distance field at fit-grid size
// The trained mask, the input shift and the soft region, all derived from the
// head box. Set once per frame, before anything reads them: the fit features
// and the render must agree on the offset, or the network is trained as one
// function and drawn as another.
bool g_have_mask = false;

// Where the mask sits in the fit grid, as a rect: what the training pass will
// actually read out of the target frame.
//
// The trainer gathers masked pixels into a compact batch, so with a face crop
// up it reads a few percent of the frame and the other 96% is resampled for
// nothing. Scanned off the finished mask rather than derived from the head box
// a second time -- the bound has to be *exactly* right or the fit trains on
// stale pixels, and re-deriving it is how the two get to disagree.
mirror::DstRect g_mask_bbox;
// How big the subject should be on screen: the half-height the head box is
// resampled to, as a fraction of the frame. Off by default, where the size is
// simply whatever distance the person is standing at.
bool  g_face_size_on = false;
float g_face_size    = 0.25f;
