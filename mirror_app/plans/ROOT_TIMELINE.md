# Root scene timeline — the rewrite

Status: implemented; tuning. This doc is the shared brief for the refactor;
every stage below is done by a separate agent and each must leave the tree
building (`cmake --build build --target mirror_app` from the repo root) and
the tests passing (`ctest --test-dir build/mirror_app` or the individual test
targets).

## Why

The old `RootCameraSequence` (Face → Deal → Growth → Meander → Outro) was
built for the `--rootmovie` exporter and grafted onto the live show. The
mask deal-out, the marker-gated focus/grow toggle, the waypoint meander and
the four framing modes (`autoFrame`/`focusMask`/`focusGroup`/`anchorMask`/
`frameOnPlanned`) made the phase choppy, hard to read and hard to control.

## What stays

- `RootSim` (CPlantBox hop-by-hop growth), the phyllotaxis-on-cone mask
  layout (make the default preset a little more elongated: taller `Hh`
  relative to `R0`). **Layout note (anchor on the axis):** with
  `anchorOnAxis` (SimParams, default on; cone and cylinder hosts) mask 0
  is not the pattern's first surface sample but sits *on the cone's axis*
  at the start height, facing down the axis, so the chain grows straight
  out of the visitor's face. Masks 1..N-1 keep the phyllotaxis placement
  and their outward normals. The anchor-first transform then pitches the
  anchor's normal `anchorPitchDeg` (60) below the horizontal, toward +z:
  the Face camera stands down that normal (el = -60), the face is upright
  from there (bitangent -> (0, cos, sin)), and the whole structure hangs
  30 degrees off vertical leaning toward that camera -- "normal to +z" would
  have laid it level along z, with nothing left to hang in Turn/Reveal.
  There is no seed hop any more: `reset()` reveals mask 0 bare and the
  relay starts at hop 1, leaving from its mouth (`faceMouthU/V/N`, see
  root_sim.h) plus `anchorSpawn` cm further out along the normal (the
  source mask's own cavity and keep-clear tube are dropped for that one
  travel, since the root starts inside/against them -- every mask gets this,
  not just the anchor; see `rebuildTropism`'s `noCavity`). Every other mask
  leaves the same way, `spawnBehind` cm behind the surface at its own mouth
  rather than at a fixed point on its rim. The hop-1 path estimate is the
  chord (the anchor has no surface coordinate).
- `MetalRootRenderer`, the glitch stage (`triggerDatamosh`).
- The cloth press in Transition (`RootScene::restartCloth` etc.) and its
  pre-warm: the sequence's **Face** stage already runs during
  `Phase::Transition` (see `rootCamSeqActive` in main.mm), and the clock
  (`rootsClock`) is continuous across the Transition→Roots cut.
- `RootFaceSequence` (recorded head-movement playback on the masks).
- The camera *utilities* from the old sequence: exponential eye/look
  smoothing, the angular-speed clamp, smoothstep easing, the az/el/radius/
  target output into `RootScene`, and the "az/el straight down a normal"
  derivation.
- `addNeighbours`/`rr_->addInstance` as the mechanism for other structures.

## What goes

- `--rootmovie` and `--rootorbit` (dev_tools.mm, main.mm arg parsing,
  dev_tools.h, README mentions).
- `root_camera_sequence.h` → replaced by `root_sequence.h/.mm`.
- `RootBeatParams`/`g_root_beats` and the `show/roots/beat N` panel section
  → `RootSequenceParams`/`g_root_seq`, one `show/roots` section.
- `maskDeal`, `showPlannedMasks` deal-out semantics (a bool that draws
  unrevealed planned masks may survive for reveal option A, see below).
- `focusGroup`, `focusGroupSize`, `frameOnPlanned`, `frameOnMasks`,
  `faceOnFocus`, `autoOrbit`/`orbitRate` on RootScene. Keep `autoFrame` +
  `focusMask` only if the non-show (operator/devtools) path still needs a
  fallback framing; if it does, reduce it to one mode.
- Wwise-marker gating of growth (`growingInBeat3_`, waypoints).
  Markers (`rootMarkerHit` in main.mm, from the pluck track's cue stream)
  are used **only** in the Reveal stage now.

## The new timeline — `RootSequence`

```
enum class Stage { Face, Grow, Turn, Reveal, Orbit, Outro, Done };
```

One linear state machine, all advances timed from panel-editable seconds
except Reveal (marker-driven, with a timer fallback). `begin()` once per
entry into Transition/Roots (as today); `step(roots, clock, dt, params,
inputs)` every frame. It writes `roots.target/radius/azimuth/elevation`,
`roots.simPaused`, `roots.simStepsPerFrame`, and reads/writes nothing else
on the scene's framing.

### Face
Anchor mask (mask 0, at the origin, facing `anchorPitchDeg` below the
horizontal toward +z -- see the layout note above) alone, tight (radius ≈
2.6 × mask extent, down its normal, so el = -60). Sim paused. The mask is live-driven
by the viewer (existing `setFittedFace` path in main.mm — unchanged).
Duration: `face_seconds` as a floor, and it never ends before the cloth has
cleared + `face_hold_after_cloth_seconds` (panel: "face hold after cloth s",
default 10 -- same semantics as the old `beat1_clear_tail_seconds`/
`face_clear_tail_seconds`). This is the visitor's own controllable window
after the cloth falls, before the face freezes and the roots start growing.
Fog fades in over `fog_fade_seconds` (keep `applyFogFade`).

**The cut, the recording and the replay.** show_timeline's Transition → Roots
edge is `SceneDone`, and main.mm now calls `g_show.sceneDone()` at the exact
moment `RootSequence` leaves Face (`onLeaveFace`, keyed off the stage edge the
same way `squareAnchorMaskOnLeavingFace` already was) -- not off a
cloth-clear-plus-tail timer running independently of the sequence. The
Transition phase's fixed 30s `max` ceiling in `show_timeline.cpp`'s
`kTransitionEdges` is only the "cloth never clears" safety net now
(`Event::ClothCleared`/`Signals::cloth_cleared`, fed from `roots.clothCleared()`):
once seen, `PhaseGraph::clear_margin` (45s) replaces that ceiling with
"clearance clock + 45s", so a `face_hold_after_cloth_seconds` dialled up to
its full 30s panel range is never cut short by the pre-clearance number, and
there is still a genuine safety net if `SceneDone` somehow never arrives
(`show_timeline_test`'s "clear_margin" cases). The visitor's own head
movement is recorded the whole time (`FaceTrackRecorder`, started at
Transition entry) and `onLeaveFace` both `finish()`es it and hands the result
straight to `rootFaceSeq.begin()` on the same frame the sequence leaves Face
-- so mask 0 replays *this* visitor's own recorded pose/expression, looped,
from Grow onward, instead of freezing on a static mesh or (the old gap)
whichever visitor's track happened to finish most recently. The absence-based
`finish()` (main.mm's `g_track_absent_t` block) is now only the fallback for
a sitting that never reaches the cut. `RootFaceSequence` applies each
frame's rotation as a delta from the track's own mean rotation
(`computeMeanRot`/`MatMulTranspose`), not the frame's raw rotation, so the
replay oscillates around the squared neutral the mask's nest was grown
against (`squareAnchorMaskOnLeavingFace`/`autoCaptureAtCut`'s squaring rule)
rather than fighting it. Applies to mask 0 only -- `setFittedFace` always did.

### Grow (×5 target faces, i.e. planned masks 1..N-1)
- Sim runs. Rate = `growthStepEstimate()/ (N-1) / grow_face_seconds`
  (default 10 s/face, slider to 60; the show preset runs 3.3), clamped to
  `[grow_rate_min, grow_rate_max]` steps/s. The steps are dealt out through
  a fractional accumulator (`stepGrowth`), so a rate under one step per
  frame is honoured: the show's plant is ~180 steps over 5 hops, under 4
  steps/s at 10 s/face, and the old `lround(rate·dt)` rounded up to one
  step *every frame* (60/s). `grow_rate_min` is 1 for the same reason.
  Measured in `--seqshot` with `SEQSHOT_REALTIME=1` (dt = 1/60): Grow
  takes `(N-1)·grow_face_seconds` (16.5 s at 3.3 s/face, no hold).
- The viewer stops driving the mask the moment Grow starts (main.mm: stop
  the live `setFittedFace` upload; `RootFaceSequence` playback, if valid,
  may continue).
- Camera, **per hop**: for the hop in flight (`roots.currentMask()` → planned
  mask *i*) the camera direction is *that mask's outward normal* (az/el from
  `pm[i].normal`), the target is that mask's position -- leaning
  `grow_hop_lead` (0.3) of the way toward the growth tip while the root is
  still travelling, the mask itself once `arrivedAtMask()` -- and the radius
  is what fits the target mask, the tip and the previous mask (so the root's
  origin stays in frame) with `grow_margin` (0.35); it comes in as well as
  out, floored at the Face's tight radius. Target and radius ease with
  `cam_ease_seconds` (1.2), the angles with the same ease under the
  `cam_max_angular_speed` clamp, so each hop is one travel-out move that
  ends square on the face just reached, and the first hop's swing off the
  Face pose is the same ease (no separate swing/gate: at 3.3 s/face the
  travel is ~0.5 s of the hop and the camera settles during the dwell,
  8-10 degrees off the normal by the hop's end -- `--seqshot` prints the
  angle at each arrival and each hop end). The whole structure is **not**
  framed during Grow; the Turn is the first frame of it.
- Reveal of a target face — **both options, selectable**:
  `reveal_mode = OnArrival | WhenFramed`.
  - OnArrival: today's behaviour, the mask appears when the root reaches it.
  - WhenFramed: planned (unrevealed) masks are drawn as soon as they are
    inside the frustum. Implement as a per-mask visibility flag in
    `RootScene` set by the sequence (the mask index becomes "visible" the
    first frame its bound is inside the frustum; it stays visible).
- Grow ends when the sim is `done()` (all N-1 hops), or after
  `grow_face_seconds × (N-1) × grow_timeout_mult` (default 1.5) as a guard.

### Turn
The other structures -- baked variations of previous visitors' plants --
pop in here, all at once, at the moment Grow ends: `placeHood()` runs and
every structure is made visible and dark immediately, at the last Grow
framing, camera still close on the face just reached (`orbitBound()` also
runs at this point, over the just-placed hood, so its fit is ready for the
move below). Then over `turn_seconds` (default 6, smoothstep) the camera
rotates/zooms out from that pose straight to the **Orbit framing**:
elevation `orbit_elevation_deg`, azimuth unchanged, target and radius the
same fit Orbit itself uses (`orbitRadius`/`orbitTarget`, `orbit_zoom`,
`orbit_max_radius`). This is a single move with nothing left to ease when
Orbit begins -- there used to be a separate `turn_end_elevation_deg`
ending on the whole-structure's own frame, with Orbit easing again from
there; folding the two into one move made that knob meaningless, so it is
gone. The chain axis should end up reading vertical/downward on screen.
Sim continues running (it is usually done by now). No lighting yet --
`stepLighting` does not run until Orbit is entered.

### Reveal
Other structures — baked variations of previous visitors' plants — stand
around this one as a **tight ring forming an overall cone**
(`addNeighbours`): each structure's own seed mask (its variation's mask 0,
which the fixed anchor pose always carries at that variation's local
origin) lands `reveal_ring_radius` out from this structure's own seed mask
(`plannedMasks()[0]`), evenly spaced in angle around it in the plane
perpendicular to the live axis (`plannedMasks()[0].normal` -- the anchor
faces down the axis) -- starting angle seeded off the plant's own seed, so
the ring is stable across replacements of the same generation. Each
structure is then the live axis rotated `reveal_tilt_deg` outward, toward
its own position on the ring -- a rotation of the whole baked structure
about its own seed mask, so the seed mask stays on the ring and the
structure leans away from the centre -- so the hood reads as one cone with
the live structure down its middle. `reveal_ring_radius` defaults to ~1.2 ×
a seed mask's own max(rWidth, rHeight) (3.0 with the default face sizing),
i.e. the parent masks nearly touch; `reveal_tilt_deg` defaults to 60.
Placement (and every structure appearing at once, dark) now happens at
**Turn's entry**, not here -- see Turn above -- so by the time this stage
is read the hood is already standing and Turn has already moved the
camera onto the orbit framing. Then each marker (`markerHit`;
`reveal_fallback_seconds`, 2.5, without one) lights **one face mask**
somewhere in the hood -- `RootScene::setStructureMaskLit(k, j)`, the face
mesh's per-vertex `lit` -- in a shuffled order over every (structure, mask)
pair, fixed-seeded so reruns match. A structure's **roots** (the instance
`lit`, the emissive/pulse glow) come on only once every one of its masks
is lit (`setStructureLit`). Reveal ends when the last mask is lit. Each
lit step re-emits the shared face mesh (one rebuild per marker, the same
cost as the old per-structure step).
Number of structures: `reveal_structures` (default 0 = from the face bank,
see below; otherwise exactly that many, the bank's faces dealt round again
when it is short).

### Orbit
Azimuth advances at `orbit_rate` rad/s (default 0.08), elevation
`orbit_elevation_deg` (default 25). What is framed is decided once on entry:
the live structure plus every neighbour within `orbit_bound_frac` (default
0.7) of the furthest one's distance, never fewer than the nearest four; the
target is the mean of that set and the radius fits each of them as its own
bound (× `frame_margin`), capped at `orbit_max_radius` (150). Turn already
ends the camera on this framing (see Turn above), so on Orbit's first
frame the ease against it is a no-op; the ease (`cam_ease_seconds`) stays
live through the stage so a panel slider dragged mid-orbit still retimes
smoothly rather than snapping. The outermost of a full hood may leave the frame --
fitting all twelve puts the camera so far out the fog swallows the lot. Lasts `orbit_seconds` (default 40) or until the host
asks for the outro (`wantOutro`, the existing visitor-absence signal), whichever
first.

### Outro
`roots.renderer().triggerDatamosh(datamosh_seconds + fade_seconds + 0.5)`
once on entry (mosh default 3 s). After `datamosh_seconds` start the screen
fade (`g_screen_fade`, existing) over `fade_seconds` (default 2). When the
fade reaches 1 the stage is `Done` and main.mm moves the show to Idle
(`g_show.goTo(Phase::Idle)`) if the timeline hasn't already. The trigger
covers the fade because a trigger of `datamosh_seconds` alone expired on the
very frame the fade began, so the picture snapped clean as it went. The
renderer's `postTime` only advances while the scene renders, so whatever is
still owing at the cut to Idle would be running on the next visitor's first
Face frame — `begin()` calls `cancelDatamosh()`, which drops the trigger and
the feedback history (`moshHistValid_`, `moshWasOn_`, `prevViewProjValid_`).
`--seqshot` runs the outro and re-entry and prints an OK/FAIL for this.

### Head pan (Grow onward)
Tracked face centre (`setTrackedPosition`'s x/y, [0,1] top-left) maps to an
az/el offset of ±`head_pan_deg` (default 5) added on top of whatever the
stage computed; eased with `head_pan_tau` (default 0.6 s); when no face is
tracked the offset eases back to 0. `head_pan_enabled` toggle. Off during
Face (the viewer is driving the mask then, not the camera).

### Panel: `show/roots`
All of the above as `ui::SliderFloat`/`Checkbox`/`Combo` in one section,
saved in the `show` bank. Follow PANEL.md (declare-is-not-draw). Regenerate
SETTINGS.md (`--settings-doc`). Old `beat N` keys in `presets/show/*` may be
left to load as unknown keys (check `ui::LoadBank` tolerates that; if it does
not, migrate the preset files).

## The face bank

`captures/<id>/` (face_capture.h: `FaceCapture` = verts, tris, uv, colours)
is the bank. Ordered by id (timestamped) = chronological.

- **Auto-capture in the live show** (currently deferred, see the comment
  near `uploadFaceColorsIfFresh` in main.mm's Transition branch): at the
  Transition→Roots cut, if `g_capture_auto` and the live fit is valid and
  face colours are fresh, build a `FaceCapture` from `g_fitter` + the sampled
  colours and `SaveCapture` it. That is what grows the bank.
- **Chain faces**: mask 0 = the current visitor (live/`RootFaceSequence`, as
  today). Masks 1..N-1 = the most recent N-1 *other* captures, newest first.
  If the bank has fewer, repeat what there is; if it is empty, repeat the
  visitor's own face. `// TODO(face-bank): repeat is a placeholder`.
- **Other structures' faces**: older captures (those not used by the chain),
  dealt out N (=6) per structure, newest first: structure 0 wears older
  captures 0..5, structure 1 wears 6..11, and so on. Number of structures =
  `floor(olderCaptures / N)`, capped at `reveal_max_structures` (default
  12). When that is 0 (a young bank), show `reveal_min_structures` (default
  3) that repeat whatever faces exist — placeholder, same TODO.
- Per-mask **colours**: `RootScene` today has one `faceColors_` for every
  mask. It needs per-mask colours (parallel to `maskVerts_`), and
  `setTestIdentities` may be dropped or adapted.

## Baked structures

**Previous sittings' own plants, first.** A sitting's finished growth is
written to `captures/<id>/roots.bin` (`root_structure.h`: nodes/segs/radii
+ the planned masks, ~85 KB for the show's 6-mask plant) at the Grow ->
Turn edge (`saveSittingPlant` in main.mm, only when the sim actually
finished, keyed to the same capture id as the face and the track). The deal
(`dealBankFaces`) loads each bank capture's plant alongside its face and
track and hands `RootScene::setBankPlants` one per structure: structure k's
plant is the one saved with the capture on its mask 0
(`structureFaces()[k].captureIdx[0]`), so the hood really is earlier
visitors' structures wearing their own faces. Behind `show/roots/bank
plants`. A capture with no plant (pre-feature, or a Grow that timed out)
falls back to the seeded variation for its slot; `ensureVariations` prints
how many came from each. `--seqshot` exercises both with `SEQSHOT_BANK=1`
and `SEQSHOT_SAVE_PLANT=<id>`.

The bank's faces move too: `BankFacePlayback` (root_face_sequence.h) plays
each bank capture's `track.bin` on its face -- delta-from-mean rotation
over the squared capture, the same rule mask 0 gets -- for every face on a
drawn, lit mask, each refreshed every third frame, staggered. Behind
`show/roots/bank faces replay`. `FaceBasis::reconstructIdentity` /
`addExpression` split the identity out so a frame is one expression pass.

**The seeded fallback.** "Variations": `K = reveal_max_structures` (12)
throwaway `RootSim` runs with the current `simParams_` and seeds
`seed+1..seed+K`, grown to completion, with their geometry
(nodes/segs/radii) and planned masks cached in `RootScene`.
Cache keyed on `growGeneration()` (the existing pattern), so they are built
once per parameter change, not per visitor. Build them lazily on the first
Reveal, synchronously. The stall is a one-time cost per parameter change
and will not be hit in the installed show, so no threading. Instances get a
per-instance `lit` flag in the renderer (dark = drawn but unlit/near-black,
no key light contribution; check how `env.keyIntensity` reaches the
instance path and add a per-instance scalar). Masks for instances go through
the existing "neighbours emit into the shared face mesh" path.

## Stages of work

1. **Sequence + cleanup** (this is the bulk): drop exporters and the old
   sequence, add `RootSequence` with Face/Grow/Turn/Orbit/Outro, head pan,
   params + panel, main.mm wiring, both reveal modes. Reveal stage: stub that
   uses the existing `addNeighbours` copies (all lit), so the timeline runs
   end to end.
2. **Face bank**: auto-capture at the cut, per-mask colours, chain face
   assignment, structure face assignment.
3. **Baked structures + marker pop-in**: variations, per-instance lit flag,
   phyllotaxis placement, marker-driven Reveal.
4. **Review + tune**: build, tests, `/code-review`, default preset values.

## Known gaps / next

- Face bank repeat: `TODO(face-bank)` in `assignBankFaces` -- a bank smaller
  than the mask count deals the same capture more than once; the plan's
  "placeholder" masks for a young bank are just repeats.
- A twelve-structure hood cannot all read inside the fog's range (visibility
  45); the orbit trims to the inner ~70 % and the outer ring is a haze.
  Either fewer structures, a tighter `reveal_ring_radius`, or a fog that
  opens during Orbit.
- `--seqshot` renders with the constructor's fog (`fogFrac` 0.12), not the
  roots preset (0.552); tuning stills need
  `SEQSHOT_POST="fogFrac=0.552,fogAniso=-0.693,fogCon=3,fogScale=1.629,fogScat=0.03"`.
  The tool could load `presets/roots/default.roots` instead.
- The orbit passes over the outer ring by elevation (25°) rather than
  around it. Check on the show screen whether the lens ever brushes a near
  structure (seqshot prints the nearest surface distance at the orbit snap:
  ~35 with 12 structures, before the ring/cone rewrite).
- Grow: the travel is a small part of each hop (~0.5 s of 3.3 at the show's
  pacing -- Lupin covers the gap in a few sim days and the rest is dwell),
  so the arrival happens while the camera is still ~90 degrees off the new
  mask's normal and the per-hop move is mostly seen over the dwell. A
  shorter `cam_ease_seconds` or a longer `grow_face_seconds` brings the
  camera round sooner. The compressed `--seqshot` run uses an ease of 0.25.
- Lit masks on the hood are small at the Reveal's distance (60-150 out, in
  fog): on a 960x540 still a lit face is a bright dot. Judge on the show
  screen.
- The `cloth/*` section (the press timings hold/press/settle/release/fall
  and the film's look) had no `kBankRules` entry after its rename from
  `transition`, so its keys were drawn but never saved -- every launch came
  back with the defaults. It is in the `look` bank now; `presets/look/
  default.look` carries no `cloth/*` keys until the operator saves it once.
- `--roundtriptest` still reports `mirror/raindrops` (forced by phase every
  frame in main.mm) -- by design, not a lost key; the test could
  special-case it. (`sound/center (Hz)`, the other by-design miss, is gone:
  the pluck centre is a MIDI note now, `sound/pluck centre (MIDI note)`.)
- `root_sequence.h`'s `Stage` enum is `Face, Grow, Turn, Orbit, Outro, Done`
  -- Reveal was folded into Orbit (the header says so at the top of its own
  Reveal block) rather than kept as the separate stage this doc's timeline
  section still lists. Not a bug, but this doc's stage list is stale next
  to the code.
- `--growshot`'s `radius` positional argument (`roots.radius = rad` in
  dev_tools.mm) has no visible effect on the rendered frame -- shots taken
  at radius 5, 18, 42 and 100 (same az/el/faceScale) came back byte-identical.
  `faceScale` does change the render (confirmed at 0.3 vs 3.0, where the
  cavity oval visibly scales with it, and at the requested 0.6 vs 1.2, which
  differ byte-for-byte though the change reads as only a few pixels at
  growshot's fixed framing). Worth a look if growshot is meant to frame
  closer for tuning stills; `--seqshot`'s camera is unaffected (its stills
  above show normal per-hop framing).
