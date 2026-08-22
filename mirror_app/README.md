# mirror_app

Unified **Metal** C++ app hosting neuromirror's shader-driven **neural mirror** and
jardins_racine's **3D lit root scene**, in one shading pipeline. See
[`plans/PLAN.md`](plans/PLAN.md) for the architecture and current scope.

Part of the JardinsRacine superbuild (`add_subdirectory(mirror_app)` in the repo-root
`CMakeLists.txt`), and it reaches sideways into the sibling `../../neuromirror`
checkout for MSL sources, `face_landmarker.task`, and the canonical face model.

## Build & run

```sh
# from the jardins_racine repo root
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target mirror_app -j$(sysctl -n hw.logicalcpu)
./build/mirror_app/mirror_app
```

VS Code: **Build: mirror_app** / **Run: mirror_app**.

### The control panel

The panel is an ImGui window with multi-viewport enabled, so it can leave the
composition:

- **own window** (checkbox, top of the panel) gives it its own OS window, to put
  on a second monitor — or, on a single monitor, anywhere off the frame. Untick
  it to bring the panel back inside the main window. The choice is remembered in
  `mirror_panel.ini` next to `imgui.ini`, so the next launch comes up the same
  way; `--panel-window` and `--reset-panel` set it from the command line, and
  `--reset-panel` also puts the panel back at a known position and size — the
  way out of a panel parked on a monitor that is not plugged in any more.
- **`--fullscreen`** opens the piece on the primary monitor at its size, with
  no title bar, instead of the default 1280x720 window. It is a borderless
  window rather than a video-mode switch, which is what keeps it from
  minimising when something steals focus — see
  [`install/README.md`](install/README.md) for the installation that wants it.
- **F1** or **`** hides and reveals the whole UI — panel, cam-mask handles and
  source PiP — and there is a **hide** button next to the checkbox. Two keys
  because macOS eats F1 for screen brightness unless F-keys are set to behave as
  function keys. `--no-panel` starts hidden. Hidden still means *declared*:
  every control registers itself every frame whether or not it is drawn, so MIDI
  and preset values reach it with the panel hidden, the tab unselected or the
  header folded.

The tabs are categories of parameter — they line up with the preset banks and
change nothing but what the panel shows. What is on screen comes from the phase
navigator above them. **[PANEL.md](PANEL.md) is how the panel is built**: the
declare-is-not-draw rule, the naming contract, the banks, and the tests that
catch a section drawing when it should not. Read it before adding a control.
[SETTINGS.md](SETTINGS.md) lists every parameter and its bank, and is generated
(`--settings-doc`) rather than maintained.

While attached, the panel is pinned inside the main window and capped to its
height (ImGui only merges a window that the main one contains whole, and this
panel is taller than a 720p window). While detached, neither applies.

Requires the imgui submodule on the **`docking`** branch (`git -C imgui checkout
docking`) — that is where viewports live.

## Installing it for a show

[`install/README.md`](install/README.md) is the unattended setup: a kiosk
account that auto-logs in, a LaunchAgent that brings the piece up fullscreen and
puts it back if it exits, a calendar of show days in `install/show-days.txt`, and
the power schedule around them. `install/racine` is the day-to-day control.

## Status

- [x] Metal window shell (GLFW + CAMetalLayer + ImGui-metal + MetalContext)
- [x] Neural mirror render: MLX C++ fused MLP (bit-exact vs Python) → ripple
      features → low-res RGBA16F → Metal texture, presented fullscreen (linear
      upsample).
- [x] **Full `demo_panel` feature parity**: weight shaping (detail / gain-tilt /
      gauss↔uniform / contrast / reseed), ripple/z/colour/time knobs, and the
      mask-emergence (hydro-dip) transition — the complete ImGui panel.
      Numerically matched vs the Python panel (`pond_parity_test`: max u8 |Δ|=1,
      0% pixels off by >1).
- [ ] Neural mirror: libmediapipe face tracking driving the field
- [x] **Metal root renderer** (GLSL→MSL port of sdf_viewer's `RootRenderer`):
      instanced capsule/blade sphere-tracer + Phong/PBR, wisp point lights,
      travelling pulses (`root_geom.metal`); FXAA-lite + volumetric fog +
      axes/grid + wisp glow (`root_fog.metal`); two-pass `MetalRootRenderer`
      into offscreen RGBA16F/Depth32 targets. Divergence: Invert/XOR has no Metal
      fragment-logic-op equivalent → flat-white silhouette.
- [x] **Face mid-geometry pass** (`root_face.metal`): mask meshes rasterized into
      the shared colour+depth target between the capsules and the fog, marble
      veining + per-face point light, depth-composited against the roots (GL clip-z
      remapped to Metal's [0,1] so it matches the capsules' custom depth).
- [x] **Live CPlantBox growth** (`RootSim`): a GL-free, incremental port of the
      GL app's "mask relay" driver — masks placed by phyllotaxis on a cone, a root
      system grown hop-by-hop (travel → dwell/wrap) confined by cavity geometry and
      steered by attraction tropism. Reuses sdf_viewer's `MaskCavities`/
      `RootAttractors` headers + CPlantBox directly (CPlantBox types hidden behind a
      pimpl, so it links into the ObjC++ app). `RootScene` steps it per frame,
      re-uploads geometry, and drives the face pass from the revealed masks. Falls
      back to the procedural stand-in if the parameter files aren't present.
- [ ] Transition (deferred — not yet defined)

Headless checks: `mirror_app --selftest` (MLX→texture path), `mirror_app
--roottest` (root MSL compile + render + readback), `mirror_app --rootshot
<out.ppm> [az el radius mode overlays]` (render the root scene to an image),
`mirror_app --growshot <out.ppm> [steps az el radius faceScale targetY faceRecess]`
(step the live CPlantBox growth then render), `mirror_app --taptest [tapId]
[seconds]` (list the Wwise onset taps that are publishing, watch one, and print
the hits it delivers -- the way to tell a missing plug-in from a wrong Tap ID
from a threshold nothing clears), `mirror_app --audiotest [seconds] [out.wav]`
(run the piece's whole arc through the embedded Wwise engine with no window --
see [Sound](#sound) below), and `mlp_parity_test mirror_app/tests/fixtures`
(MLP vs Python reference).
Regenerate the pond weights with `assets/gen_pond_weights.py` (needs neuromirror's venv).

### Dialling the growth in

`root_sweep [field=value ...]` grows the mask relay with no window and no
renderer — it links `mirror_sim` and CPlantBox only — and prints, per hop,
whether the root *arrived* at its mask or merely ran out of days and was
declared to have arrived. That distinction is invisible on screen (a hop out of
budget reveals its mask and starts dwelling exactly like one that got there),
which is why the growth is tuned through this rather than by watching the panel.
Fields are the `SimParams` names, plus `seeds=<n>` to grow the same look under
several seeds and `quiet=1` for one line per run:

```sh
./build/mirror_app/root_sweep species=Anagallis_femina_Leitner_2010.xml \
    N=12 coneSurfaceTravel=1 seeds=8 quiet=1
```

**A hop's travel budget is derived, not fixed.** How long the root is given to
cross to the next mask comes from how far it has to go — the geodesic over the
cone when it is crawling the surface, which is much longer than the chord — and
from how that species actually elongates: CPlantBox roots grow on a negative
exponential toward `lmax`, and past `lmax` the front is carried on by a lateral
at the lateral's own slower rate. So the same sixty days that are ample for
maize (tap root 238 cm) are nowhere near enough for pimpernel (33 cm), and a
flat budget is why late masks used to be revealed with the root still halfway
there. `hop days` is now only the ceiling; `travel slack` says how much longer
the real wandering path is than the straight line.

The other lever late masks need is **`shell`**: a thin cone shell plus the
cavities of the masks already revealed leaves a corridor narrow enough for the
random walk to get stuck in. 8–12 cm reaches every mask for every species; 6 cm
does not.

`mirror_app --rootpreset <name> [field=value ...]` writes the result out as a
roots-bank preset through the real registry — the same save the panel's button
calls — so a look dialled in with `root_sweep` becomes `presets/roots/<name>.roots`
without anybody hand-writing parameter names.

### The root presets

One per species, each dialled in so that **twelve masks on one cone are all
genuinely reached** (verified over twelve seeds each) while the system stays
legible. What varies between them is the dwell: how long the root is left
wrapping each face before it moves on, which is what sets how dense the whole
thing gets. The species differ by more than an order of magnitude in how fast
they thicken, so a dwell that gives maize a full nest buries wheat.

| preset | species | shell | dwell days | ≈ nodes at 12 masks |
|---|---|---|---|---|
| `maize` | Zea mays | 8 | 18 | 8.7k |
| `soybean` | Glycine max | 8 | 4 | 17.8k |
| `pea` | Pisum sativum | 9 | 14 | 13.5k |
| `sunflower` | Heliantus | 8 | 6 | 13.2k |
| `kale` | Brassica oleracea | 8 | 6 | 16.2k |
| `wheat` | Triticum aestivum | 8 | 2 | 36k |
| `lupin` | Lupinus albus | 10 | 18 | 14.2k |
| `pimpernel` | Anagallis femina | 12 | 6 | 15.7k |

All eight crawl the cone surface, and all hold up at fewer masks than twelve
(the hops get *longer*, not shorter, when masks are spread thinner). Wheat is
the outlier at four orders of lateral: two days of dwell is already its densest
legible setting.

## Sound

The piece's audio is the Wwise project at `../WwiseProject`, and **its engine
runs inside this app** — `src/wwise_audio.h` has the reasoning, but the short
version is that an installation should not depend on Wwise Authoring (a Windows
app under CrossOver here) staying up for the length of an exhibition. At showtime
this binary loads `GeneratedSoundBanks/Mac/{Init,Racine}.bnk` and needs no Wwise
at all.

What the project holds:

| | |
|---|---|
| **Busses** | `Mirror`, `Roots`, `Transition` under the main bus; `Mirror_Verb` / `Roots_Verb` aux busses, one Wwise RoomVerb each — long and open for the mirror, shorter and darker for the roots |
| **Beds** | `Amb_Mirror` and `Amb_Roots`, each a Blend Container layering a Macro Oscillator voice over a Random Container of recorded texture |
| **One-shots** | `Play_Pluck`, `Play_Bell`, `Play_Drop` (a random container of three modal drops, tuned to the key) |
| **The handoff** | `Play_Transition` / `Stop_Transition` |
| **Game Parameters** | `Proximity`, `Movement`, `Centering`, `HeadYaw`, `HeadTilt` (the room) · `FitLevel`, `SceneProgress` (the piece) · `Key`, `Intensity` (the operator) |
| **States** | `Phase` = `Idle` \| `Fitting` \| `Transition` \| `Roots`, set from the same edge that switches the scene |

The pads are Macro Oscillator sources with **Triggered off** — free-running
rather than plucked — and their amplitude comes from a Wwise envelope modulator
on voice volume (6 s in for the mirror pad, 10 s for the root drone, released by
the Stop event's fade). Pitch follows `Key` everywhere: the mirror pad at the
key, the root drone an octave below, plucks and drops in the octaves above, so
one slider retunes the whole piece.

### Where the numbers come from

`src/presence.h` turns the tracker's landmarks into the five room parameters:
proximity from how much of the frame the face fills, movement from landmark
travel *measured in face widths* (so leaning in does not read as movement), yaw
from the nose against the silhouette, tilt from the eye line. Everything is
asymmetrically smoothed — quick to rise, slow to fall — because a filter driven
by raw landmarks buzzes, and a movement signal that spikes on a dropped frame
reads as somebody lunging. The panel shows smoothed against raw side by side,
which is the only way to tune the time constants.

`FitLevel` is the identity fit's mean landmark error against the threshold the
fitting phase waits on, at half scale exactly on the threshold: converged is
where the sound gets interesting, not where it stops.

### When it is silent

`mirror_app --audiotest 30 /tmp/out.wav` walks the arc — mirror bed, drops,
pluck, bell, transition, roots, let go — sweeping every parameter, with no
window and no camera in the way. Silence there with no error printed means a
plug-in that is in the bank but not linked into this binary: check
`GeneratedSoundBanks/Mac/PluginInfo.json` against the factory headers included
by `src/wwise_audio.cpp`. An unregistered plug-in loads fine and plays nothing.

The app links the **Profile** Wwise configuration, so Wwise Authoring's profiler
connects to it and shows the live busses, voices and RTPC values — the
visibility that would otherwise be lost by moving the engine out of Authoring.
Build the plug-ins for whichever configuration you link (`../wwise_plugins/README.md`);
`Release` is the one for an unattended install.

## Raindrops, and driving them from audio

A drop is one impact, not a slot in a periodic table: it lands, its rings ride
outward on their own wavefront, and it is retired once they leave the frame
(`src/drop_spawner.h`, `src/mirror_render.h`). Two things spawn them, and the
split is the point of the design:

- **the schedule** — `rate` drops per second with `rate jitter` deciding how
  regular that is: 0 is a metronome, 1 is a Poisson process (gaps that cluster,
  the way rain actually arrives), in between blends the two. Size, strength and
  spread each have their own jitter, so no two drops read as the same event.
- **`Pond::triggerDrop(strength, pan)`** — one hit, now, because something
  outside said so. The **drop one** button in the panel is this, and so is every
  audio onset.

### Audio onsets

The **Onset Tap** Wwise effect (`../wwise_plugins/OnsetTap`) detects transients
on whatever bus it is inserted on and publishes them to shared memory; this app
reads that stream (`src/audio_pulse.h`) once per frame and spawns a drop per
hit. Nothing is polled from the audio itself — the detection happens on the
audio thread, where the transients are, and only the conclusion crosses over.
See the plug-in's section in `../wwise_plugins/README.md` for why the threshold
adapts and how to set it.

To use it: add **Onset Tap** to a bus in Wwise, give it a **Tap ID** and a
**Name**, then pick it in the panel under **mirror > rain from audio**. The
panel shows the tap's live level against the rise it currently has to clear,
which is how you tell "nothing is playing" from "the threshold is too high" —
they are otherwise the same silence.

Three sliders decide how much of a drop the hit gets to choose: **hit ->
strength**, **hit -> size**, **hit -> position** (from the hit's stereo
balance). At 0 across the board the audio only decides *when*, which is a real
setting — a steady shower on the beat. `audio_drops_test` covers the whole path
from a published event to a source on the water, playing the plug-in's part
through the same header the plug-in writes through, so it needs no Wwise
install.

## Root render performance

`mirror_app --rootbench [downscale] [frames] [baseW] [baseH]` grows the sim to
completion then times full `render()`s. Findings on the base M4:

- The roots pass is **overdraw-bound**: cost ≈ pixels × how many capsules stack
  per pixel, spent in the per-fragment ray-capsule intersection. **Lighting is
  nearly free** — Phong vs a no-shading pass differs by only ~0.5 ms even under
  heavy overdraw, so a depth pre-pass wouldn't help (it would still pay the
  intersection to compute depth).
- Framed view is cheap (~3 ms at 4K); a zoomed-in dense nest that fills a 4K frame
  is the worst case (~15 ms). The lever is **internal render resolution**: ½-res
  is ~3.6×, ⅓-res ~7×, since the fog pass's FXAA-lite + the bilinear present make a
  downscaled render upsample cleanly.
- The app therefore **auto-scales** the roots' internal resolution (cap the max
  internal dimension, default 1920) so a 4K/Retina window stays fast instead of
  collapsing; toggle/override in the roots panel.

### Many cached systems: LOD + culling

For the end goal of rendering **many cached root systems** (mostly small/distant),
`MetalRootRenderer` supports static instances (`addInstance`, baked to world space,
uploaded once) with three complementary levers, tuned live in the roots panel's
"cached field" section and measured by `--fieldbench [grid] [frames]`:

- **Frustum culling** — whole systems outside the view are skipped on the CPU
  (bounding sphere vs the six clip-space planes). The culled fraction grows with
  world size, so cost tracks what's *visible*, not the total count.
- **Distance LOD** — each system carries radius-percentile LODs (the thinnest
  laterals drop first); the level is chosen by the bound's projected pixel size.
- **Sub-pixel capsule cull** — the vertex shader degenerates any capsule whose
  projected radius is below ~1 px, so no fragments/intersections are launched.

On a 256-system field (immersive camera, 1080p, base M4): naive all-full **19.1 ms
→ 10.1 ms** with cull+LOD+sub-pixel (760k → 198k capsules drawn, 117/256 culled).
`--fieldshot <out.ppm> [grid az el]` renders a field for a visual check.

## Layout

- `src/main.mm` — window/app shell + main loop.
- `src/metal_context.{h,mm}` — the shared Metal device/queue (same one MLX uses) + MSL loader.
- `shaders/` — app MSL (compositor / transition / ported root passes).
- `plans/` — working plan, versioned with the code.
