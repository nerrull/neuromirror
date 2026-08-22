# Neuromirror ⇄ Roots — unified Metal C++ app

> Working plan, versioned with the code. **Status as of 2026-07-25:** the
> scaffold, the C++ neural mirror, the full GLSL→Metal root/face port, live
> CPlantBox growth, MediaPipe face tracking, the morphable face fit and the
> **press/release/wrap transition** between the two scenes are all done and
> validated; a cached-system LOD/culling path is in.

## Status snapshot

Done (validated, on `jardins_racine` main):

- **Scaffold** — Metal window shell (GLFW + CAMetalLayer + ImGui-metal +
  `MetalContext`), superbuild wiring.
- **Neural mirror** — MLX C++ fused-MLP + features + upsample, bit-exact vs the
  Python reference; full `demo_panel` parity (weight shaping, ripples, z, colour,
  hydro-dip transition); performance-matched to Python; `MirrorScene` → texture.
- **Root render (Metal)** — `MetalRootRenderer`: capsule/blade sphere-tracer +
  Phong/PBR, wisps, pulses (`root_geom.metal`); FXAA-lite + volumetric fog +
  overlays + wisp glow (`root_fog.metal`); the face mask **mid-geometry pass**
  (`root_face.metal`, depth-composited). Invert/XOR falls back to flat white (no
  Metal fragment logic ops).
- **Live CPlantBox** — `RootSim`: GL-free, incremental port of the "mask relay"
  growth (per-frame state machine), reusing `MaskCavities`/`RootAttractors` +
  CPlantBox behind a pimpl. `RootScene` steps it and drives the face pass.
- **Scaling** — cached static instances (`addInstance`, baked, uploaded once) with
  **frustum culling + distance LOD + sub-pixel capsule cull**; auto render-scale of
  the roots' internal resolution. Profiled: the pass is overdraw-bound (lighting is
  ~free); 256-system field 19.1→10.1 ms with cull+LOD.
- **Mirror perf** — fused ripple-features kernel + cached coord grid:
  **26.2 → 16.2 ms at 960×540 (38 → 62 fps)**, 108.8 → 64.5 ms at 1080p. See
  [Neural mirror performance](#neural-mirror-performance).
- **Text overlay** — CoreText glyphs → exact Euclidean SDF (`text_sdf`) →
  composited in the present pass as an **inversion** of the scene under it, with
  the sample coordinate refracted by the *same* ripple gradient the feature
  kernel uses. Crisp at any scale, over any scene, and it never touches the
  network — see [Text](#text).
- **Show timeline** — `show_timeline`: the four phases (idle → fitting →
  transition → roots) as a **fixed graph in code**, advanced on **time or
  event**, with the durations and the text cues set by `shows/*.show` and
  reloadable without a rebuild — see [The show](#the-show).
- **Screen orientation** — the composition is its own size (`screen_layout`),
  separate from the drawable: scenes render at it, present blits it into a
  centred viewport, and the camera is cropped into its aspect. Forcing Portrait
  on a landscape monitor is a true preview of the installation — see
  [Orientation](#orientation).

Headless coverage: `--selftest`, `--roottest`, `--rootshot`,
`--growshot`, `--fieldshot`, `--rootbench`, `--fieldbench`, `--facetest`,
`--maskshot`, `--mirrorclip`, `--transhot`, `--textshot`, `--orientshot`,
`mlp_parity_test`, `pond_parity_test`, `ripple_parity_test`, `face_fit_test`,
`face_mask_test`, `cloth_test`, `text_sdf_test`, `screen_layout_test`,
`show_timeline_test`. (`mlp_parity_test` and `pond_parity_test` read fixtures by
relative path — run them from `mirror_app/tests/`.)

## Context

Two working codebases revolve around the **same face mask**
(`canonical_face_model.obj`):

- **neuromirror** — a shader-driven "neural mirror": a coordinate-MLP reconstructs
  the live face + face tracking/fitting. Today **Python only** (MLX fused-MLP with
  inline Metal, MediaPipe tracking, ICT-FaceKit fitting). Per-frame output is
  *an RGB grid → upsample → display* — i.e. a texture.
- **jardins_racine/sdf_viewer** — a 3D lit scene (`RootRenderer`, a **GLSL**
  sphere-tracer over CPlantBox root geometry). The flagship `mask_relay_gui` grows
  roots **around the same face mask**. Currently **OpenGL 4.1 + GLEW + ImGui**.

Goal: one native C++ app that runs the neural mirror and the 3D root scene and
(eventually) transitions between them, reusing each codebase as a module rather
than reimplementing in parallel.

## Confirmed decisions

- All-native C++; **unified Metal backend with a common shading pipeline** (port
  the GL root renderer to Metal — no GL/IOSurface interop).
- Face tracking via **MediaPipe's upstream C Tasks API** (one-time Bazel build →
  `.dylib`, then CMake-only; 478 landmarks + 52 blendshapes + 4×4 pose). Not
  cpvrlab/libmediapipe — see [MediaPipe face tracking](#mediapipe-face-tracking).
- Roots via **live CPlantBox** simulation.
- App lives at **`jardins_racine/mirror_app/`**; `sdf_viewer` refactored to expose
  reusable GL-free sim targets.
- **Only one simulation runs at a time** — running both sims tanks framerate, so any
  eventual transition is a well-defined handoff, not a blend of two live sims.

## Architecture — one Metal pipeline, two scenes

```
GLFW window → CAMetalLayer (Metal), ImGui (imgui_impl_metal)
 MetalContext (device/queue shared with MLX, MSL loader, RT/texture helpers)
 ├─ MirrorScene → MTLTexture   (MLX MLP zero-copy + libmediapipe tracking)
 ├─ RootScene   → MTLTexture   (Metal-ported RootRenderer, live CPlantBox)
 └─ TransitionPass → (deferred; effect over fromTex/toTex/t/mask)
```

MLX arrays are Metal-buffer-backed, so the mirror stays **zero-copy** (same
`MTLCreateSystemDefaultDevice()` as the compositor). Both scenes produce Metal
textures + depth in one pipeline, so an eventual transition can be a real shader
effect, not an alpha fade.

## Reuse map

| Piece | Source | Disposition |
|---|---|---|
| App shell (GLFW+CAMetalLayer+ImGui-metal + runtime MSL compile) | `neuromirror/reactor_cpp/src/main.mm` | **Reuse** as scaffold |
| Root growth sim + geometry (GL-free) | `sdf_viewer/FlowerLSystem.h`, `MaskCavities.h`, `RootAttractors.h` + **CPlantBox** | **Reuse as-is** |
| Root **rendering**: sphere-tracer + fog + capsule TBOs | `sdf_viewer/RootRenderer.{h,cpp}`, `shader/fog/face .vert/.frag` | **Port GLSL→MSL** (`MetalRootRenderer`) |
| Fused MLP kernel | `neuromirror/mlx_fused_mlp/forward.py` (MSL) + `features.py` (`ENRICHED_DIM=8`) + `upsample.py` | **Port to MLX C++** reusing verbatim MSL |
| Face tracking | MediaPipe `face_landmarker.task` | via **libmediapipe** `.dylib` |
| Morphable face fitting | `neuromirror/emotion/ict_fit.py` | **Ported** to `face_fit.{h,cpp}` (no OpenCV, no NumPy) |

## Work breakdown

1. ✅ **Scaffold** `mirror_app/`: CMake, `MetalContext`, GLFW+CAMetalLayer+
   ImGui-metal window shell.
2. ✅ **C++ neural mirror**: `mlp_forward` (MLX C++, verbatim MSL) + features +
   upsample + `MirrorScene`, parity-tested; `face_tracker` on MediaPipe's C
   Tasks API, feeding the landmark-hull training mask.
3. ✅ **Port root/mesh scene GLSL→Metal**: `MetalRootRenderer` (geometry + fog +
   face mid-pass), GL TBOs → Metal buffers, validated visually.
4. ✅ **Live CPlantBox**: shipped as the GL-free `RootSim` module reusing
   `MaskCavities`/`RootAttractors` + CPlantBox directly (rather than refactoring
   `sdf_viewer`'s CMake into a separate `sdfsim` target — same "no parallel
   reimplementation" goal, less churn to the GL apps).
5. ✅ **Cached-system scaling**: instances + LOD + frustum/sub-pixel culling +
   auto render-scale (`addInstance`, `RootScene::buildField`, `--fieldbench`).
6. ✅ **Show timeline**: `show_timeline` — the four phases as a fixed graph in
   code, advanced on **time or event**; `shows/*.show` sets only the durations
   and the text cues. See [The show](#the-show).

## Next

1. **Scene handoff, the sims.** The timeline now *directs* the four phases and
   the hydro-dip runs over the seam (below). What is still open underneath it is
   the sim handoff proper: stopping the mirror's training and starting the
   roots' growth on the phase change, rather than both scenes being live and one
   of them being the one that is drawn.

## Deferred

- Wwise audio layer.
- Per-instance model matrix (cached instances are baked-static today; add a
  per-draw transform if the transition needs to move/scale whole systems).

## Neural mirror performance

Measured on **Apple M4, 10-core, 32 GB**, `--bench`, 25 July 2026.

### Where the frame went (960×540, before)

| phase | ms | |
| --- | --- | --- |
| coord grid | 0.65 | rebuilt every frame, depends only on size |
| ripple features | 9.90 | **38% of the frame** |
| MLP + tone | 15.10 | |
| **total** | **25.65** | 38 fps |

### The fix

**Ripple features: 9.90 → 0.60 ms (16.6×).** The op-graph formulation expressed
~40 FLOPs/pixel as ~75 elementwise MLX ops, each round-tripping the whole
518k-element array through memory. One fused `metal_kernel` reads 2 floats and
writes 8 halves per pixel with everything in between in registers — now
memory-bound at ~12 MB/frame, so there is nothing further to win.

`mx::compile` was tried first as the smaller change and manages only 1.33×:
`concatenate`/`split` break its fusion groups.

**Coord grid: 0.65 → 0 ms.** Cached on `(lh, lw)`, evaluated eagerly so the
linspace/meshgrid graph is not spliced into a later frame.

### Result

| | before | after | |
| --- | --- | --- | --- |
| 960×540 (half) | 26.16 ms (38 fps) | **16.21 ms (62 fps)** | 1.61× |
| 1920×1080 | 108.76 ms (9 fps) | **64.48 ms (16 fps)** | 1.69× |

Verified by `pond_parity_test` (max deviation 1/255, 0% above), `mlp_parity_test`
(exact), and `ripple_parity_test` (fused vs op-graph, within 1 fp16 ulp across 11
parameter settings including every branch and 1/2/5/12 sources).

### What is left, and what it costs (960×540)

| | ms | |
| --- | --- | --- |
| ripple features | 0.82 | fused kernel; memory-bound |
| **MLP + clip/astype** | **15.43** | **95% of the frame** |
| shipping defaults, total | 16.22 | |

Tone mapping is **not** the problem — every optional stage is sub-millisecond:

| stage | added ms |
| --- | --- |
| gamma ≠ 1 | +0.08 |
| colour mix | +0.44 |
| swap_rb | +0.56 |
| amp_drives_color | +0.72 |
| srgb_fix | +0.79 |
| **transition (relief + lighting)** | **+3.60** |

Only the emergence transition is expensive, and it is transient by nature — but
it does push a 16.2 ms frame to 19.9 ms, i.e. it breaks 60 fps *during the
transition*. Worth folding into a kernel if the transition must hold 60.

**The MLP is now the whole budget.** It is already a fused kernel (8→64×6→3,
fp16, simdgroup matmul). Further headroom has to come from the network itself —
fewer layers, narrower hidden, or a smaller internal resolution — not from the
surrounding code, which is now ~5% of the frame.

### hidden_dim: what narrowing buys

`hidden_dim` was already configurable — it is a kernel *template* parameter
(`HIDDEN`), so each width compiles its own specialisation and there is **no
runtime cost to configurability itself**. Only the Pond constructor hardcodes 64.

Measured at 960×540, `--bench 2 200`, whole frame:

| hidden | ms | fps | vs 64 |
| --- | --- | --- | --- |
| 16 | 3.74 | 267 | 4.3× |
| **32** | **6.80** | **147** | **2.4×** |
| 48 | 10.85 | 92 | 1.5× |
| 64 (ships) | 16.24 | 61 | — |

Not the 4× that hidden² would predict, because ~0.8 ms of the frame is features
and tone, and the per-layer weight streaming and barriers do not shrink with
width.

**Retuning the tiling is not worth it.** `n_blks = (TILE_ROWS/16) · ceil(N/16)`
drops from 8 to 4 at hidden=32, so half the simdgroups idle — but fixing that
recovers only ~6%:

| hidden=32 tiling | ms |
| --- | --- |
| 32/8 (current) | 6.80 |
| 32/4 | 6.58 |
| 64/8 | 6.49 |
| 128/8 | 6.37 |

And 32/8 is genuinely optimal at hidden=64 (64/8 → 17.25 ms, 32/4 → 17.99 ms),
so the shipping constants stay.

**Ceiling: hidden_dim ≤ 80.** `wbuf` is `HIDDEN²` halves, so threadgroup memory
is quadratic; hidden=128 needs 57344 bytes against Apple's 32768 limit and Metal
refuses to load the pipeline. `fused_mlp_forward` now checks this up front and
throws something legible instead of aborting on the first frame.

`mlp_width_test` validates the kernel against a plain MLX matmul chain at widths
16/32/48/64/80 (48 and 80 deliberately not multiples of the 16-wide simdgroup
tile), depths 2/4/6/10, ragged row counts (1, 33, 1000), and all four
activations — plus that hidden=128 is rejected cleanly.

**Switching to 32 is a one-line change** in the `Pond` constructor
(`MLPConfig{ENRICHED_DIM, 64, ...}` → `32`). Left at 64 pending a look at what
the narrower network does to the image: it is a different network, so the
pattern changes and the fixtures would need regenerating.

### Training budget at hidden_dim=32

Measured with the **real fused training path** (fused forward + fused backward
vjp + Adam) from `neuromirror/mlx_fused_mlp/training.py`, at the mirror's config
(8 → N → 3, 6 layers, tanh/sigmoid), M4, 25 July 2026.

⚠️ **The fused backward kernel is not ported to C++ yet.** `mlp_forward.cpp` is
forward-only; `fused_mlp_backward` + the custom vjp exist only in the Python
reference. These numbers are what the C++ side will get *after* that port, and
they are the reason to do it: the explicit (non-fused) backward is much slower.

Budget at 60 fps, hidden=32: 16.67 ms frame − 6.80 ms display = **9.87 ms**.

| train res | points | ms/step | steps/frame |
| --- | --- | --- | --- |
| 960×540 (half) | 518 400 | 23.10 | **0.4** |
| 480×270 (quarter) | 129 600 | 5.83 | 1.7 |
| 320×180 | 57 600 | 2.63 | 3.8 |
| 240×135 (eighth) | 32 400 | 1.52 | 6.5 |
| 160×90 | 14 400 | 0.72 | 13.7 |
| 120×68 | 8 160 | 0.44 | 22.3 |
| 64×36 | 2 304 | 0.18 | 54.5 |

**Half resolution does not fit.** One step at 518 400 points costs 23.1 ms —
2.3 whole frames — against a 9.87 ms budget. A training step is ~3.4× a display
render over the same points (forward + backward + optimiser), so training at
display resolution can never fit while the display is also drawing.

Cost is linear in point count, so the tradeoff is a straight line: ~600×340 for
one step/frame, ~310×175 for four, ~220×125 for eight.

**At hidden_dim=64 training is impossible at 60 fps** — the display alone leaves
0.43 ms, which is under a single step at any resolution. If live training is
required, hidden=32 is not an optimisation, it is a precondition.

### Hybrid sine/tanh activations (SIREN split)

`MLPConfig` gained `split` + `act_first`: the first `split` hidden layers use
`act_first` (sine), the rest use `activation` (tanh). **`split = 0` is the
original network and is bit-identical to it** — verified by `pond_parity_test`
and `mlp_parity_test` still passing unchanged.

Why: raw coordinates through tanh cannot resolve fine detail (spectral bias),
and a Fourier input encoding fixes that but stamps an axis-aligned grid over the
whole image. A leading sine layer builds the high-frequency basis instead, with
no encoding and no grid, while the tanh layers behind it stay responsive to the
existing `detail`/`contrast` weight scales.

**One sine layer is enough.** Face-fit MSE at hidden=32, 6 layers, 1500 steps:

| split | pattern | fit loss |
| --- | --- | --- |
| 0 | TTTTT | 0.00562 |
| **1** | **STTTT** | **0.00250** |
| 2–4 | SS.. | 0.00249–0.00263 |
| 5 | SSSSS | 0.00273 |

### Two independent controls

| knob | what it does |
| --- | --- |
| `sine_w0` | how many regions the field breaks into (composition) |
| `detail` | how hard the boundaries are (articulation) |

They genuinely decouple at low `sine_w0`. Fraction of frame with near-zero
gradient, measured in C++ at a fixed z:

| sine_w0 | detail 0.8 | 1.5 | 2.5 | 4.0 |
| --- | --- | --- | --- | --- |
| 2 | 100% | 76% | 58% | 57% |
| 5 | 100% | 63% | 56% | 55% |
| 10 | 99% | 64% | 59% | 52% |
| 20 | 62% | 48% | 42% | 29% |
| 40 | 45% | 31% | 25% | 21% |

At `sine_w0` 2–10 roughly half the frame stays open while mean gradient rises
~10x across the `detail` sweep — large flat areas survive much sharper edges. By
40 that is gone and the field is uniform texture with no background. **The
open-composition regime is `sine_w0` 5–10 with `detail` 2.5–4.**

### Cost

| | 960×540, hidden=64 |
| --- | --- |
| `sine_layers = 0` | 16.31 ms (61 fps) |
| `sine_layers = 1` | 18.70 ms (53 fps) |
| `sine_layers = 2` | 18.16 ms (55 fps) |

The hybrid costs ~15%: it keeps the expensive `tanh` calls and adds a `sin`.
Pure sine would be *cheaper* than pure tanh (measured −17% on the forward), so
the cost here buys the tunable tanh stack, not the sine.

### Not yet ported: the backward

`mlp_forward.cpp` is forward-only, so this is the aesthetic/render path.
Training needs the sine-capable backward prototyped in Python: the shipping one
reconstructs `act'(z)` from post-activations (`tanh: 1-a²`), and `cos(z)` is not
recoverable from `sin(z)`. The fix is to store `act'(z)` for the sine layers
only during the re-forward pass — validated against explicit backprop at 0.0010
relative, and it costs one threadgroup buffer sized by `split` rather than by
depth:

| hidden | shipping | all-layer preact | split=1 preact |
| --- | --- | --- | --- |
| 32 | 13312 ✓ | 20480 ✓ | 14336 ✓ |
| 64 | 28672 ✓ | 43008 ✗ | 30720 ✓ |

i.e. the split is what keeps a trainable sine network within budget at
hidden=64 at all.

## MediaPipe face tracking

Built from **upstream MediaPipe's official C Tasks API**
(`mediapipe/tasks/c/vision/face_landmarker`) as a shared library — 478
landmarks, 52 blendshapes, 4x4 facial transformation matrix, Apache-2.0.

**Not cpvrlab/libmediapipe**, which this plan previously named: it pins
MediaPipe v0.8.11, which predates the Tasks API entirely (legacy 468-point
face_mesh, no blendshapes, no pose matrix) and is GPL-3.0.

```sh
./setup-mediapipe.sh      # installs deps, clones, patches, builds, verifies
cmake -S . -B build       # -> "MediaPipe face tracking enabled"
```

Measured: **4.5 ms/frame**, 50/50 detection, resolution-independent (the graph
crops to the detected face ROI). Face-oval mask rasterises to ~3.8% of frame at
640x480 — directly usable as the masked-training region.

### The build needs five fixes, three of them as patches

`external/` is gitignored, so the source edits live in `patches/` and
`setup-mediapipe.sh` re-applies them idempotently. None are cosmetic; each is a
distinct failure that does not name itself:

| # | problem | symptom |
| --- | --- | --- |
| — | system python 3.13+ | "Could not find requirements_lock.txt matching 3.14" — fixed by `--repo_env=HERMETIC_PYTHON_VERSION=3.12` |
| — | no JDK | `no such package '@@rules_java~//tools/jdk'` — fixed by `brew install openjdk` + `JAVA_HOME` |
| 0001 | OpenCV path/version | `fatal error: opencv2/core/version.hpp not found`. Upstream expects opencv@3 at `/usr/local`; arm64 Homebrew is `/opt/homebrew` and the plain `opencv` formula is now **5.x**, which MediaPipe does not build against. Needs `opencv@4` and deeper header paths. |
| 0002 | protobuf conflict | **Segfault before `main()`**, inside `DescriptorPool::InternalAddGeneratedFile`. `libopencv_video` pulls `libopencv_dnn` -> Homebrew `libprotobuf.35`, colliding with MediaPipe's static protobuf during dyld initialisers. MediaPipe's Image path does not use the video module, so it is dropped. |
| 0003 | no exported symbols | A 14 MB dylib exporting **zero** `MpFaceLandmarker*` symbols. The `.dylib` target depends on `face_landmarker_lib`, which lacks `alwayslink = 1`, so nothing inside the shared library references the C entry points and the linker discards them. Repointed at `face_landmarker_c_lib`; same fix for `:image`. |

`setup-mediapipe.sh` asserts the symbol count after building, because 0003's
failure mode is a build that reports success and produces a useless library.

CMake stages the dylib out of `bazel-bin` and rewrites its `install_name` to
`@rpath/...` — bazel emits a bare filename, which dyld treats as a literal path
and never resolves against an rpath.

### Face mesh fitting — done

`face_model2.nvf` has since been obtained and its layout validated (neuromirror
`emotion/TODO.md` now has the Maxine items checked), so the fitting is built and
wired to both consumers.

**One tracker, two consumers.** `main.mm` runs the tracker once per frame,
before either scene, so the mirror's mask and the roots' mesh come from the same
detection rather than from two frames a scene apart:

| consumer | what it takes | how |
| --- | --- | --- |
| **mirror** | landmarks only | face-oval hull → `RasteriseFaceMask` → `updateFitTarget(rgb, h, w, mask)`. The network fits the person; the background is left unconstrained and stays generative. |
| **roots** | landmarks + blendshapes + pose | morphable-model fit → `RootScene::setFittedFace` replaces `canonical_face_model.obj` on the placed masks. |

That split is deliberate: the training mask only ever needed the hull, which is
~40 lines and no model file. The [open question from the handoff
note](../../documentation/notes/face_mesh_fitting_resume.md) — whether the
fitted mesh beats the hull for the *mask* — is answered by not asking the mask
to use it. The mesh earns its place on the root scene, where the hull has
nothing to offer: a 3D surface that turns with the head.

#### The two-basis export

`tools/export_face_basis.py` (supersedes `export_ict_basis.py`) writes
`external/face_basis.bin` carrying **two bases that share one set of
coefficients**:

- **render mesh** — Maxine/NVF topology: 2056 verts, 4048 tris, already cropped
  to a face mask.
- **landmark basis** — 68 points in dlib order, used only by the fitter.

Because each source is good at a different thing. ICT-FaceKit has dlib-68
ordering right (from `vertex_indices.json`); NVF's `LMRK` chunk stores an
internal order that neuromirror had to *recover by nearest-neighbour matching*,
which is the less trustworthy half of an otherwise validated parser. So: **fit
against ICT's landmarks, draw with Maxine's triangles** — the bridge
`nvf_live.py` proved out live, baked in at export time by resampling ICT's modes
onto NVF's vertices (mean residual 0.196 model units). One `(alpha, expression)`
pair drives both bases and the C++ side needs no mapping table.

Falls out of that: **4.0 MB, down from 14.6**, and the 2056-vert mesh is light
enough to re-evaluate per frame.

#### The fit

`face_fit.{h,cpp}`, a port of `emotion/ict_fit.py`, split the way the cost does:

- **identity** — expensive, occasional. Alternates a 2D similarity (Umeyama) for
  pose given shape with a ridge-regularised solve for the identity coefficients
  given pose, over several collected frames sharing one identity. Expression is
  *known* per frame and subtracted first, so a smile in the collected frames
  does not get baked into the face.
- **per frame** — cheap. Expression from blendshapes by ARKit name, rotation
  from MediaPipe's 4×4, mesh as one weighted sum of modes.

Two dependencies the Python version needs and this does not:

- **OpenCV.** `solve_pose` ran `cv2.solvePnP`; the Tasks API already returns a
  facial transformation matrix, so the rotation is read off it directly.
- **NumPy.** The solves are small and dense — a 2×2 similarity over 68 points
  and an 80×80 SPD system — so they are written out (Cholesky; the ridge term is
  what guarantees positive-definiteness, so there is no pivoting path).

**Identity frames are ranked, not thresholded** (`frontality * neutrality`, best
`max_frames` retained, collected on a clock). A fixed threshold does not work:
MediaPipe reports substantial baseline activation on an ordinary face — a frame
of someone mid-sentence scores 0.04 neutrality, which is correct — so any
threshold either accepts everything or stalls forever depending on the person
and the lighting. See the note for the numbers.

#### Texturing the mask from the neural fit

The mask is coloured per vertex by projecting the fitted mesh into the mirror's
*own output* and sampling it — so it wears the network's reconstruction of the
face, not the camera's pixels. What crosses into the root scene is what the
mirror made of the person.

The colour is **captured, not looked up live.** Only one sim runs at a time, so
by the time the roots are drawing, the mirror has stopped and there is no neural
texture left to sample; capturing at the handoff is what lets the mask keep the
face. `RootScene::setFaceColors` stores it, and the face pass already carried a
per-vertex colour slot (12 floats/vertex: pos3, normal3, **color3**, lightPos3),
so nothing in the shader had to change.

#### A photo can stand in for the camera

`Source::Photo` substitutes a still into the stream; nothing downstream knows the
difference, so tracking → fit → mask → texture all run without a person in front
of the sensor, reproducibly, on a known face. `LoadImageRGB` letterboxes rather
than stretching — FHIBE's crops are square against a 4:3 canvas, and stretching
would have the fit dutifully recover a squashed identity.

#### Coverage

`--facetest [image]` runs the whole path headless on a still photo: MediaPipe →
landmarks → training mask, and → fit → mesh → `RootScene`. `face_fit_test`
covers the solver against synthetic ground truth, but everything upstream of it
— the tracker, the MP68 mapping, the blendshape name matching, the y-flip — only
runs when a real detector looks at a real face. On `f0016.png`: 478 landmarks,
52 named blendshapes, a 3.08% training mask, 25 of 53 expression modes active,
and the projected mesh landing **8 px from the tracker's own face centre (11% of
face width)** — which is the check that the flip, the mapping and the pose all
agree.

`face_fit_test` fits synthetic landmarks generated from a known identity.
Against neuromirror's `fit_identity_frames` on identical input it reproduces
**0.7609 / 0.8061 / 0.8443** correlation at ridge 6.0 / 1.0 / 0.1 to four
decimals — so a drift there is a regression against the original, not a tuning
question. The correlation is not near 1 *by design*: ridge shrinks toward the
mean face and the modes are far from orthogonal once projected to 2D, so many
coefficient vectors explain the same 68 points. Landmark residual is 0.27 px.


## The pond → face transition

A film of neural pond is stretched across the frame like a canvas. The mask
presses into it from behind until the fabric is tented over the real face; the
canvas then lets go, corners first, and slides off over the brow and the nose,
leaving the face wearing the film. One locked front-on camera, one continuous 3D
pass, five phases on one timeline:

1. **hold** — the flat sheet fills the frame, and *is* the pond
2. **press** — the mask advances through the sheet plane, tenting the fabric
3. **settle** — fully through, the film taut over it
4. **release** — the pins let go from the corners inward
5. **fall** — gravity plus contact: the sheet drapes off the face and away

`src/transition_scene.{h,mm}`, `shaders/transition.metal`, `src/cloth.h` (the PBD
solver).

### There is no swap

The previous version — and `cloth_cpp` before it — played the first half in
screen space (a fullscreen pass that refracted and embossed the pond by a face
relief) and then *swapped* to 3D at full emergence, hiding the seam under a
crossfade. Everything delicate about it came from that swap: three separate
quantities (brightness, face shading, texture content) had to be matched by hand
across one frame, the sheet had to be held artificially flat for the length of
the crossfade, and the moment the hold ended every pin released at once.

The sheet is 3D from the first frame now, and at rest it is a flat quad sized to
exactly fill the frustum cross-section — so it *is* the fullscreen pond. Nothing
to match, because nothing changes hands. `f_emerge` and `f_relief` are gone with
it; what is left is one vertex and one fragment function.

The one thing that still has to hold is that a flat surface shades to exactly the
film's own brightness. `f_main` gets that by construction rather than by tuning:
shading is expressed as a *deviation* from the flat response
(`1 + relief·(lambert − flat)/flat`), so a flat sheet reads 1 whatever the light
is doing. That is also what frees the light to be raking — and it has to be,
because a light down the view axis puts almost no gradient on a bulge facing the
camera and the whole press reads as nothing happening.

### The mask is the real mask

Not an oval. The sheet is held at its **border**, not around an elliptical ring
cut near the face, so nothing in the setup imposes a shape: what is uncovered is
the fitted mesh's own silhouette. Without a tracked face it is the basis's
neutral mesh, which is a real mask too — there is no faceless mode, because the
gesture is a film coming off a mask.

It also turns with the head. The mesh is re-sent every frame rather than latched
when the phase opens, so it carries this frame's expression and head rotation —
and a turned head is what makes the drape interesting, because the fabric has an
asymmetric solid to come off.

### The texture is exact, by construction

`setFaceMesh` takes, per vertex, the normalised frame position the *fit* projects
that vertex to (`FaceFitter::projectNormalised`, at the same pinned position the
root scene's texture uses). Each vertex is then placed in world space so that
this camera projects it back to precisely that point:

```
x = ndc.x · halfX · (CAM_D − z)/CAM_D        (and the same for y)
```

which cancels the perspective divide exactly, whatever depth the press has moved
the mask to. The mesh therefore lands on the pond's own face pixel for pixel, and
its texture coordinate is that same projection — so the film the mask carries
away is the film that was covering it. There is no centring or scale guess left
to drift, and no second fit.

### Registration, and the limit of the fit

The placement above is exact — the mesh lands wherever the fit projects it, to
the pixel. What it cannot do is be *more right than the fit*, and the fit's
projection is a 2D similarity (`FacePose`: rotation, uniform scale,
translation). It has no perspective and no out-of-plane foreshortening.

On a face looking at the camera that is fine: checked against `--maskshot` on
several subjects, the mesh sits on the eyes, nose and mouth. On a head with real
pitch it is not — the mask comes out too tall, with its eyes high and its mouth
low, because a similarity has no way to express a foreshortened forehead. The
information was never in the pose, so nothing downstream can recover it, and it
is not specific to this scene: the root scene textures its mask through the same
projection.

So the mask carries a hand registration — `maskScale` and `maskOffset`, applied
about the fit's own projected centre. Scale is per-axis because the error is:
pitch stretches one of them. The correction moves the texture with the geometry,
since they are the same coordinate — correcting where the mask sits keeps it
wearing the pixels it covers, which is the property the whole hydro-dip rests
on.

`alignMask` is what makes it settable. It holds the mask fully in front of a
flat film with the timeline stopped and draws it as a **wireframe**, so the face
underneath stays readable. Both of those are load-bearing: pressed through, the
film occludes everything not proud of it and what is left is a slice — brow,
nose, chin — that is not a shape anyone can align to a face; drawn solid, the
mask hides the very thing it is being aligned to. `--transalign <photo> <out.ppm>
[sx sy ox oy]` is the same view headless, for choosing the numbers against a
still.

### Collision, and why it is affordable

cloth_cpp listed sheet↔face collision as expensive and skipped it, which is why
its sheet could only fall away *behind* a face it never touched. The camera here
is fixed front-on and never moves, so the mask is fully described for contact
purposes by the z of its front surface at each (x, y) — there is no view from
which the sheet could reach its back. That makes the collider a depth map
(`MaskField`, rasterised on the CPU each frame from the placed mesh) and the
query one bilinear fetch per vertex.

Three things about it are worth keeping written down, because each was a visible
failure before it was a line of code:

- **Contact is inelastic.** Moving a position out of the mask and leaving `prev`
  behind turns the push into velocity, and the projection runs once per solver
  iteration — two dozen times a step. That velocity compounds until the sheet
  launches itself at the camera (measured: z reaching +3.5 on a sheet whose
  half-height is 1.24). `prev.z` is carried along with the push.
- **Friction is per step, not per iteration.** Bleeding the same fraction of
  tangential velocity inside the iteration loop compounds it the same way —
  0.35 becomes 1 − 0.65²⁴, which is total. The sheet welded itself to the mask
  on contact and gathered on the brow permanently. One friction pass per step.
- **Extension is compliant, compression is not.** A sheet that resists both
  equally cannot lie on anything: pressed onto a solid it bridges the high
  points, because reaching into a hollow costs it length it does not have.
  Letting it lengthen cheaply (`stretchGive`, with a hard `stretchMax` ceiling)
  is what turns bridging into wrapping — and a film being stretched over a face
  is what the gesture depicts, so the compliance *is* the effect. Compression
  stays stiff, which keeps the canvas taut and costs no folds: cloth folds by
  buckling out of plane, not by shortening along an edge.

- **The collider is conservative over a cloth cell.** Contact is resolved at
  vertices, but what is on screen is the flat triangles between them. Over a
  convex feature — a nose, a chin, both made sharper by the depth exaggeration —
  every vertex can sit exactly on the surface while the chord joining them still
  cuts through it, and the mask pokes out of the film in blobs a cell wide.
  Measured on the real mask mid-press: vertex penetration **0.0000**, chord
  penetration **0.0266**, against a skin of 0.012 — which is why looking at
  vertices alone reports this bug as no bug at all. `MaskField::dilate` runs a
  separable max-filter at the cell's radius, so a vertex is pushed clear of the
  highest point its own cell can span; coverage spreads with it, or the rim gets
  the same problem from the other side. Chord penetration after: **0.0000**. The
  sheet stands off by about a cell, which is what a cloth with thickness does.
  `cloth_test` runs the press twice, undilated and dilated, and checks the
  chords — it also fails if the test collider is ever smoothed to the point
  where the undilated sheet stops cutting it, since the check would then be
  passing on nothing.

And one that is about the release rather than the contact: a held stretch **takes
a set** (`plastic`). A film pulled over a form and held there does not spring
back when let go, and without it the release returns every bit of tension stored
during the press in a single frame — the sheet snaps off the face and the whole
picture jumps.

### The mask is on the roots' material

The mask is the one object the piece hands from scene to scene: this scene
uncovers it, and the root scene then grows around it. So it is shaded by the
root renderer's own face material — literally the same code and the same values.
`face_shade.metal` holds `shadeFace` (Cook-Torrance, hemisphere ambient,
environment specular, rim, wrapped subsurface, the marble vein field and its
relief) plus the display transform (ACES + sRGB), and it is prepended to the
face, post **and** transition libraries. `root_face.metal` is now just the pass
that feeds it; `root_post.metal` no longer carries its own copy of the curve.
Verified by rendering `--rootshot` either side of the extraction: byte-identical.

The parameters are not duplicated either. `TransitionScene` holds a
`MetalRootRenderer::FaceParams` and `EnvParams`, and `main.mm` copies the root
scene's own into it every frame, along with the exposure, the tonemap flag and
the key direction. Tuning the roots' mask tunes this one; there is no second set
of knobs that could drift, which is the same reason the show has one notion of
"which phase is up".

**The film is deliberately not on that material.** The two halves of this scene
sit in different colour worlds on purpose:

| | the film | the mask |
| --- | --- | --- |
| what it is | the mirror's output | lit radiance |
| referred to | display | scene |
| shading | deviation from flat (§ above) | `shadeFace` |
| display transform | none | exposure → ACES → sRGB |
| has to match | the scene the piece cuts **from** | the scene it cuts **to** |

The transition is where those two meet, and the mask being uncovered *is* the
handover. Putting the film through a tonemap would break the one invariant the
opening rests on — that a flat sheet is the pond, exactly.

One quantity does not come from the root scene, because it cannot: the mask's
marble, light falloff and spot cone are world-space, tuned against a mask about
four world units across, and this scene places the mask by projection at
whatever size the fit gives it. `shadeSpan` scales the shading space about the
mask's own centre back to that reference, so all three land where they were
tuned instead of each being re-tuned against the others.

### What actually takes the film off

Gravity is straight back, away from the camera, and nothing else. A -y component
is the obvious way to get the sheet clear and the wrong one: it drags the whole
film downward, so the mask ends up uncovered by the film *falling out of frame*,
which has nothing to do with the mask.

That leaves the mask's own asymmetry to do it, and the first attempt at it
failed outright — with gravity along the view axis the film simply sat on the
mask as a shroud for the whole clip. Two reasons, one real and one a mistake:

- **A sheet draped on a symmetric form and pulled straight back is a
  shrink-wrap.** The tension presses it *on*, not off. Turn the mask and the
  surface normals stop cancelling: the tangential components no longer balance,
  the fabric drifts toward the shallower side, and once any of it passes the
  silhouette the weight hanging behind peels the rest.

- **Contact was resolving along +z**, which made that impossible in principle.
  Pushing out along the view axis makes contact a constraint on z alone, so a
  backward pull is cancelled outright and the fabric is pinned wherever it
  landed — there is no tangential component for an asymmetry to be unequal *in*.
  It now resolves along the surface normal, taken from the height field's own
  gradient (flat at the silhouette, so a rim vertex is not flicked off the edge).
  The earlier comment claiming the normal would let vertices squirt out of
  creases was rationalising the bug.

Measured at the shipped settings, with the mask held out of the film once the
press is done: a head turning through ±20° clears by about 4.5s; a mask held at a
*static* 20° peels the same way but is only half off by then. Motion does most of
the work, asymmetry sets the direction, and a live head supplies both.

An intermediate version drove the mask further forward through the release to
push the film off. It is gone: it worked, but it moves the mask after the press
has landed, and the press landing is the moment the whole effect is built around.
It was also strictly worse — the film cleared *later* with the drive than
without it, because fabric cannot follow a mask that is moving while the border
pins still hold, so it ballooned instead of sliding.

The material changes across the release for the same reason. Under the press it
has to be compliant and take a set, or it bridges the face instead of wrapping it
and then snaps when the pins go; after the release that same material is what
keeps it stuck on, since a compliant sheet stretches instead of pulling and a
plastic one has already given up the length. `stretchGive`, `plastic` and
`friction` are all scaled down across the release front.

### Release order

`buildSheet` assigns each pin a `releaseAt` by elliptical radius, so it is 0 at
the corners and 1 at the middle of each edge; `setRelease(r)` runs a feathered
front across that. Corners are where a stretched canvas carries the most tension,
so they go first — which is both what the gesture wants and what the sheet would
actually do. The front is feathered rather than a threshold because an instant
unpin dumps a vertex's stored tension into one step and the sheet cracks like a
whip.

The sheet is also built a little larger than the frustum cross-section
(`oversize`): the moment the corners let go the canvas retracts, and a sheet cut
exactly to the frame shows black in the corners the instant it does.

### Headless

`--transhot <prefix> <frames> <photo> <fps>` renders the whole thing offscreen
against a real fit — the mirror is fitted to the photo and the mask to the same
face, so both assets are live. Without a face in the photo (or without a photo)
it falls back to the neutral mask and still plays. `cloth_test` covers the solver
on its own: that the press tents the sheet *forward*, that the release runs
corners first, and that after the fall nothing has passed through the collider.

## The show

The piece is not a demo with a scene radio button. It idles as a mirror until
someone walks up to it, fits their face, falls through the transition, grows
roots out of them, and lets go when they leave. `show_timeline` is that running
order.

### The shape is code; the timing is data

That sequence *is* the piece. It is not a thing to be configured, so the graph
is a fixed table in `show_timeline.cpp`:

| phase | edges, in priority order | `max` → |
|---|---|---|
| idle | `face_present` → fitting | — |
| fitting | `fit_converged` → transition, `face_absent` → idle | idle |
| transition | `scene_done` → roots | roots |
| roots | `face_absent` → idle | — |

A format that let you rewire that would be a format in which the piece could be
described wrongly, and every edge would need a runtime error for the case where
it was. What an install actually needs to change is *when* — how long the idle
floor is, how long a face must be gone before the piece lets go, when a caption
lands. Those are durations, and durations are all the script file sets.

Every one has a default in the graph, so `ShowScript()` **is** the designed
piece: a script names only what it moves, and a missing file is not a degraded
mode. That also removes the drift a separate built-in fallback script would have
had.

### Why both kinds of edge

A system that handles only one is wrong in a way that shows in the room.

| | what it is for |
|---|---|
| time | The idle phase needs a **floor**, or someone walking past retriggers the piece every few seconds. The roots need a minimum before the piece may reset. |
| events | The fitting phase is over when the fit has converged on *this* face, not after a duration chosen for the average one. The transition is over when `TransitionScene::done()` says so. |

So they compose: `min` is a floor the room's own events cannot fire below, `max`
is a ceiling whose target the graph fixes, and between them the edges decide.
One exception to the floor, deliberate — a scene reporting itself finished
advances regardless, because holding a completed transition on screen to satisfy
a minimum is a freeze, not a beat.

The level signals (`face_present`, `fit_converged`) are set by `main.mm` as
plain per-frame booleans; the debounce that makes them events lives in the
timeline, because "how long must a face be gone before the piece lets go" is a
decision about the room and belongs in the script next to the phase it governs.
A dropped tracker frame is not somebody leaving.

### The format

Line-oriented `key: value`, documented in `shows/default.show` itself. Three
properties it was designed for, each a fix for a way the first cut was worse:

- **No positional syntax.** Everything is a named field, so there is no order to
  get wrong and nothing to memorise about where a modifier goes.
- **Indentation is decorative.** A key attaches to the most recent item that
  accepts it, and the cue keys (`at`, `for`, `fade`, `when`) are disjoint from
  the keys that open one — so where a line belongs is unambiguous from the line
  itself, and re-indenting a file cannot change its meaning.
- **The colon is optional.** Punctuation that can be forgotten in the dark of an
  install will be.

Because the graph is fixed, the set of knobs a phase has is knowable, so an
unknown key is rejected *with the alternatives for that phase* rather than
merely refused. The error carries its line number and the running script is
kept, so a typo saved mid-show cannot leave the installation with no running
order. Reload keeps the phase that is running and restarts its clock rather than
cutting to the top of the piece.

### What it owns, and what it does not

It holds no Metal, no scenes and no textures: a state machine over durations and
booleans, which is what lets `show_timeline_test` drive the whole thing at a
fixed step — including asserting the *shape* of the graph, since the graph is
code. Its failure modes — a floor checked against the wrong clock, a debounce a
single dropped frame defeats, a caption whose fade-out never starts because its
duration is shorter than its fade — are all invisible until they happen in the
room and are then unreproducible.

The host reads `phase()` to pick a scene, watches `entries()` to know a phase
just started (where `TransitionScene::restart()` and the identity-collection
kickoff go), and copies `text()` into `TextParams`. The script owns *what* the
text says and *when*; placement, size, font and turbulence stay whatever the
panel set them to, so a scheduled caption is not a second, worse text editor.

Edge 0 of each phase is the forward path, which is what the operator's `go`
(space, a button, a MIDI CC) takes — so "go" means the same thing in every phase
without anyone having to know which event it is short-circuiting.

## Text

The show needs legible text over the work. The neural mirror cannot supply it and
was never going to: its input basis is eight features (`x, y, z, bias, sin_field,
cos_field, z_cos, spare`) through six tanh layers of width 32 — a few thousand
weights over one low-frequency radial field. That is why it reconstructs faces
well, and it is the same reason letterforms come out as smudges: text is sharp
edges and thin strokes everywhere. Fitting a glyph bitmap was considered and
dropped for a second reason as well — the network is tracking a live face, and a
text target would have to take the weights away from it.

So the text is not in the network. It is a **signed distance field composited in
the present pass**:

```
CoreText glyphs → 8-bit coverage → exact Euclidean SDF (text_sdf.cpp)
                → R8Unorm texture → present.metal, over whichever scene is up
```

Three decisions carry the effect:

- **A distance field, not a bitmap.** A bitmap is sharp at one scale and mush
  either side of it. The field's edge is wherever the interpolated distance
  crosses 0.5, so the fragment shader recovers a clean contour at any scale, with
  the antialiasing width taken from `fwidth` — and stroke weight becomes a free
  parameter (a bias on the distance) rather than a re-render.
- **Inversion, not a fill.** The palette underneath is generated and changes
  constantly, so no fixed colour stays legible across it. `1 - c` always does.
  (`root_face.metal`'s invert falls back to flat white because Metal has no
  framebuffer logic ops; here the scene colour is sampled in the fragment, so a
  real inversion is available.)
- **Refracted by the pond's own gradient.** The sample coordinate is warped by
  the same radial wave-slope accumulation `kRippleSrc` uses for its colour
  coords, from the sources the frame was *actually* rendered with
  (`Pond::lastSources`, cached rather than recomputed from the clock — a second
  evaluation would be a frame's phase out of step and would shear visibly once
  the ripples move). The text therefore bends with the water while staying
  exactly as sharp as it was before it moved. Sharpness comes from the field,
  motion from the sim.

Two things had to be got right in the shader, both recorded in the source: the
field is sampled clamped and masked afterwards rather than early-returning, so
`fwidth` stays in uniform control flow across the quad; and coverage is faded out
where the footprint grows past what the band can resolve, because a strong warp
folds the sample coordinate and a fold otherwise leaves a trail of half-lit
specks off the ends of the words.

Warp is low by default (0.08). Past ~0.15 the gradient displaces neighbouring
fragments far enough apart to tear the letterforms open — a usable effect, and
not the one anyone wants the first time they switch it on.

### Emerge / dissolve

`reveal` (0 → 1) is a timeline the word comes apart along. Implemented as a
**per-pixel threshold from an fBm field**, not as an erosion of the distance:
erosion is bounded by the encoded band, so thick stems would sit untouched
through the whole transition and then pop out at once. The noise is sampled at
the already-warped `p`, so with ripples running the dissolve flows with the water
for free — no second field to keep in step with the first.

Two calibrations, both found by rendering rather than by reasoning:

- **fBm needs its contrast stretched** before it can serve as a threshold field.
  Summed octaves cluster hard around the mean, so raw fBm makes every pixel cross
  at nearly the same moment — a plain fade with a little noise on it. Stretched
  2.6× about 0.5, the thresholds actually span the reveal and the word breaks
  into patches.
- **Scale 12, not 6.** At 6 the blobs are large enough to swallow whole letters;
  at 12 the dissolve eats into the strokes, which is what erosion looks like.

The interior is biased to survive slightly longer than the edges (a fixed term,
not a knob), which is the difference between strokes visibly thinning out and
uniform speckle.

### Softness

`edge softness` scales the sampled footprint to widen the antialiasing band. Two
bugs lived here and are worth not reintroducing:

- The fold-fade (above) originally multiplied by the *softened* width, so turning
  softness up faded the text away entirely. The raw footprint and the softened
  width are now separate quantities: the footprint says whether there is an edge
  here at all, softness is only a look.
- The band is clamped to 0.42 of the encoded range. Past that the ramp runs off
  the end of the field, where the distance saturates flat, and it stops dead at a
  fixed offset from the outline — which reads as a hard-edged halo tracing the
  text. `spread` was also widened (0.08 → 0.15 of the raster height, costing only
  padding) so there is more band to soften within.

It is an antialiasing control, not a glow. A real glow would want a second,
separately blurred tap.

Coverage: `--textshot <out.ppm> [text] [warp] [reveal] [softness]` renders a live pond plus the
overlay through the real present pipeline (the shader is compiled from disk at
run time, so a clean build says nothing about it); `text_sdf_test` checks the
distance transform against an analytic disc, which is the only way to catch the
error an approximate transform makes — still smooth, still monotone, wrong by a
fraction of a pixel in the places that make a straight stem wobble.


## Orientation

The installation runs on a portrait screen. Development does not. Almost
everything in the app is derived from the frame's shape — the mirror's coord
space spans (-aspect, aspect) x (-1, 1), `MetalRootRenderer` builds its frustum
from `w/h`, the text overlay places itself in coord units, and the camera has to
be resampled into it — so composing for the drawable directly makes the
installation's framing something you can only see by standing in front of it.

**The composition is its own size.** `ComputeLayout` returns the largest rect of
the target aspect that fits the drawable, centred; scenes render at that, and the
present pass sets a viewport for it. The letterbox needs no shader change at all:
the fullscreen triangle is in clip space, so restricting the viewport *is* the
letterbox, and the text overlay inside it keeps composing in composition coords.

One rule covers both cases, which is the point — the installation's drawable is
genuinely tall (macOS is set to portrait there), so its composition is the
drawable and nothing is letterboxed, while Portrait on a 16:9 dev monitor yields
a 608x1080 box in the middle. There is no fills-vs-letterboxes branch to get
wrong.

`portrait_aspect` is **stated** (0.5625 for a 1920x1080 panel on its end) rather
than derived by inverting the dev monitor's aspect. Inverting passes on a 16:9
monitor and is quietly wrong on 16:10, and a preview that matches the machine
previewing it rather than the panel it is previewing is worth nothing.

**No rotation is involved**, deliberately. macOS rotates the installation's
display, so the app only has to compose tall. A physically rotated panel fed a
landscape signal would need the blit to rotate too; that is not built.

### The camera does not turn around

The sensor is 16:9 and stays that way. Resampling it into a portrait fit grid
would stretch whoever is standing there — the kind of wrong that looks nearly
right in a thumbnail and unmistakable at 1080x1920. So `ComputeFeedRect` takes a
rect of the *output's* aspect out of the source: at 1080x1920, **32% of the
sensor's width survives**.

That makes framing a real decision rather than a nicety, hence `feed x/y/zoom`.
Two details worth keeping:

- The rect is **shifted** inside the source at the edge of travel, never shrunk.
  Widening it there would change how large a person is as they walk across the
  frame.
- The crop is applied to the fit target, the tracker's image **and** the source
  preview, from one `SrcRect`. The landmarks are normalised to whatever image
  they were found in, so cropping one and not another puts the training mask
  somewhere the face is not — the same invariant the shared box filter already
  existed to protect.

`screen_layout_test` covers the arithmetic: the installation's exact case, the
16:10 trap, viewport containment over a size sweep, panning that does not resize,
absurd and zero zoom staying inside the sensor, and the float and byte crops
agreeing. `--orientshot` renders the mirror-plus-text and the root scene at a
given drawable size (1080x1920 by default) — aspect bugs fail by looking
*plausible*, so that one is for looking at.

The root scene needed no change: its projection already came from `w/h`.
