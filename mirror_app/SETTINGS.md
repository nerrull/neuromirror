# mirror_app settings

Generated from the live registry -- do not edit by hand. Every row is a
control that declared itself in the frame this was written from, which is
all of them: declaring does not depend on what the panel has open.

Regenerate from the panel: **settings -> write SETTINGS.md**.

## Where a setting goes

| bank | file | what belongs here |
|---|---|---|
| `machine` | `presets/machine.machine` | the room, not the piece: sensor, screen, camera mask, MIDI map. Loaded at startup, never carried to another venue. |
| `show` | `presets/show/*.show` | the running order -- what plays and when. |
| `look` | `presets/look/*.look` | composition that outlives one scene: text overlay, transition. |
| `mirror` | `presets/mirror/*.mirror` | the ripple scene. Many presets; this is the one dialled in per performance. |
| `roots` | `presets/roots/*.roots` | the root scene. |

The mapping from a top-level panel section to a bank is `kBankRules` in
`src/ui_params.cpp`. Add a section, add a rule -- otherwise its parameters
land in `unassigned` and are listed below until somebody decides.

## machine (25 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `camera mask/mask the camera` | bool | -- | 0 |
| `camera mask/soft edge` | float | 0 .. 0.2 | 0.03 |
| `face tracking/acquire` | int | 1 .. 10 | 2 |
| `face tracking/crop the fit to the face` | bool | -- | 1 |
| `face tracking/dilate` | int | 0 .. 24 | 6 |
| `face tracking/fitted mesh drives the root masks` | bool | -- | 1 |
| `face tracking/head smoothing` | float | 0.02 .. 1 | 0.25 |
| `face tracking/hold on loss` | float | 0 .. 3 | 0.6 |
| `face tracking/overlay/camera overlay` | bool | -- | 0 |
| `face tracking/overlay/corner` | int | 0 .. 3 | 1 |
| `face tracking/overlay/landmarks` | bool | -- | 1 |
| `face tracking/overlay/size` | int | 160 .. 640 | 320 |
| `face tracking/pad` | float | 0 .. 0.6 | 0.3 |
| `face tracking/set face size` | bool | -- | 0 |
| `face tracking/size` | float | 0.05 .. 0.5 | 0.25 |
| `face tracking/texture the mask from the neural fit` | bool | -- | 1 |
| `face tracking/track faces` | bool | -- | 0 |
| `roots/auto render-scale` | bool | -- | 1 |
| `roots/root downscale` | int | 1 .. 6 | 1 |
| `roots/target px` | int | 720 .. 3840 | 1920 |
| `screen/feed x` | float | 0 .. 1 | 0.5 |
| `screen/feed y` | float | 0 .. 1 | 0.5 |
| `screen/feed zoom` | float | 1 .. 4 | 1 |
| `screen/orientation` | int | 0 .. 2 | 0 |
| `screen/panel aspect (w-h)` | float | 0.3 .. 1 | 0.5625 |

## show (18 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `show/cue CC` | int | 0 .. 127 | 100 |
| `show/fit converged under (px)` | float | 1 .. 20 | 6 |
| `show/fitting` | int | 0 .. 4 | 0 |
| `show/idle` | int | 0 .. 4 | 0 |
| `show/log phase changes` | bool | -- | 1 |
| `show/phase CC` | int | 0 .. 127 | 101 |
| `show/roots` | int | 0 .. 4 | 1 |
| `show/run the show` | bool | -- | 0 |
| `show/transition` | int | 0 .. 4 | 2 |
| `sound/fall (s)` | float | 0.05 .. 4 | 0.55 |
| `sound/far (face height)` | float | 0.02 .. 0.4 | 0.12 |
| `sound/key (MIDI note)` | float | 24 .. 84 | 48 |
| `sound/level` | float | 0 .. 1 | 1 |
| `sound/movement full scale` | float | 0.2 .. 4 | 1.2 |
| `sound/near (face height)` | float | 0.1 .. 0.9 | 0.45 |
| `sound/phases post their own events` | bool | -- | 1 |
| `sound/rise (s)` | float | 0.01 .. 1 | 0.12 |
| `sound/sound on` | bool | -- | 1 |

## look (47 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `face tracking/identity/frames` | int | 1 .. 24 | 8 |
| `face tracking/identity/head pose from tracker` | bool | -- | 1 |
| `face tracking/identity/modes` | int | 10 .. 100 | 80 |
| `face tracking/identity/ridge` | float | 0.01 .. 20 | 6 |
| `face tracking/identity/secs` | float | 1 .. 15 | 5 |
| `text/edge softness` | float | 0.2 .. 3 | 1 |
| `text/inversion` | float | 0 .. 1 | 1 |
| `text/raster px` | int | 64 .. 1024 | 256 |
| `text/reveal` | float | 0 .. 1 | 1 |
| `text/show text` | bool | -- | 0 |
| `text/size` | float | 0.02 .. 0.6 | 0.16 |
| `text/stroke weight` | float | -0.02 .. 0.02 | 0 |
| `text/text refraction` | float | 0 .. 2 | 0.08 |
| `text/tracking` | float | -0.1 .. 0.5 | 0.02 |
| `text/turb drift` | float | 0 .. 2 | 0.15 |
| `text/turb scale` | float | 0.5 .. 30 | 12 |
| `text/turbulence` | float | 0 .. 1 | 0.8 |
| `text/x` | float | -2 .. 2 | 0 |
| `text/y` | float | -1 .. 1 | 0 |
| `transition/align mask` | bool | -- | 0 |
| `transition/damping` | float | 0.9 .. 1 | 0.985 |
| `transition/fall` | float | 0.5 .. 6 | 1.8 |
| `transition/friction` | float | 0 .. 1 | 0.07 |
| `transition/gravity back (-z)` | float | 0 .. 20 | 6 |
| `transition/gravity down (-y)` | float | 0 .. 8 | 0 |
| `transition/hold` | float | 0 .. 3 | 0.5 |
| `transition/iterations` | int | 4 .. 64 | 24 |
| `transition/mask offset x` | float | -0.2 .. 0.2 | 0 |
| `transition/mask offset y` | float | -0.2 .. 0.2 | 0 |
| `transition/mask relief` | float | 0.2 .. 4 | 2.2 |
| `transition/mask scale x` | float | 0.6 .. 1.4 | 1 |
| `transition/mask scale y` | float | 0.6 .. 1.4 | 1 |
| `transition/press` | float | 0.2 .. 6 | 1.6 |
| `transition/press depth` | float | 0 .. 0.4 | 0.16 |
| `transition/refraction` | float | 0 .. 0.25 | 0.05 |
| `transition/release` | float | 0.05 .. 3 | 0.7 |
| `transition/relief shading` | float | 0 .. 1 | 0.55 |
| `transition/set (plasticity)` | float | 0 .. 8 | 2 |
| `transition/settle` | float | 0 .. 2 | 0.3 |
| `transition/shading span` | float | 1 .. 10 | 4 |
| `transition/sheet oversize` | float | 1 .. 1.3 | 1.08 |
| `transition/sheet res` | int | 16 .. 128 | 72 |
| `transition/show cloth` | bool | -- | 1 |
| `transition/show mask` | bool | -- | 1 |
| `transition/stretch` | float | 0 .. 0.98 | 0.8 |
| `transition/substeps` | int | 1 .. 8 | 2 |
| `transition/wireframe` | bool | -- | 0 |

## mirror (72 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `mirror/animate z outside` | bool | -- | 0 |
| `mirror/colour/amp gain` | float | 0.2 .. 6 | 1.5 |
| `mirror/colour/color mix (0 grey -> 1 RGB)` | float | 0 .. 1 | 1 |
| `mirror/colour/color travel (palette follows orbit)` | bool | -- | 0 |
| `mirror/colour/gamma (>1 darkens)` | float | 0.3 .. 2 | 1 |
| `mirror/colour/ripple amp -> color` | bool | -- | 0 |
| `mirror/colour/sRGB fix` | bool | -- | 0 |
| `mirror/colour/swap R-B` | bool | -- | 0 |
| `mirror/crop/grid` | int | 1 .. 8 | 1 |
| `mirror/crop/lr` | float | 0.0001 .. 0.02 | 0.002 |
| `mirror/crop/steps` | int | 1 .. 32 | 4 |
| `mirror/fade starts` | float | 0 .. 0.8 | 0.02 |
| `mirror/fade width` | float | 0.01 .. 1.5 | 0.35 |
| `mirror/feed/grid` | int | 1 .. 8 | 3 |
| `mirror/feed/lr` | float | 0.0001 .. 0.02 | 0.003 |
| `mirror/feed/steps` | int | 1 .. 32 | 1 |
| `mirror/follow the outline` | bool | -- | 1 |
| `mirror/grey outside` | float | 0 .. 1 | 0 |
| `mirror/mask emergence (transition)/auto-play` | bool | -- | 0 |
| `mirror/mask emergence (transition)/background dim` | float | 0 .. 1 | 0.5 |
| `mirror/mask emergence (transition)/light azimuth` | float | -3.14159 .. 3.14159 | 0.7 |
| `mirror/mask emergence (transition)/light elevation` | float | 0.1 .. 1.5708 | 0.8 |
| `mirror/mask emergence (transition)/mask height` | float | 0.2 .. 1.2 | 0.72 |
| `mirror/mask emergence (transition)/mask width` | float | 0.2 .. 1 | 0.55 |
| `mirror/mask emergence (transition)/play rate -s` | float | 0.05 .. 1 | 0.25 |
| `mirror/mask emergence (transition)/relief height` | float | 0 .. 1.5 | 0.6 |
| `mirror/mask emergence (transition)/sheen tightness` | float | 4 .. 96 | 24 |
| `mirror/mask emergence (transition)/transition (0 pond -> 1 mask)` | float | 0 .. 1 | 0 |
| `mirror/mask emergence (transition)/wet sheen (spec)` | float | 0 .. 1.5 | 0.5 |
| `mirror/mirror image` | bool | -- | 1 |
| `mirror/moving ripple` | bool | -- | 0 |
| `mirror/network/contrast (w out)` | float | 1 .. 12 | 6 |
| `mirror/network/detail (w hidden)` | float | 0.5 .. 10 | 3 |
| `mirror/network/gain tilt (front<->back)` | float | -3 .. 3 | 0 |
| `mirror/network/sine layers (0 = tanh only)` | int | 0 .. 5 | 0 |
| `mirror/network/sine w0 (composition)` | float | 1 .. 60 | 6 |
| `mirror/network/w shape (gauss<->uniform)` | float | 0 .. 1 | 0 |
| `mirror/radius` | float | 0.02 .. 0.5 | 0.12 |
| `mirror/rain from audio/hit -> position` | float | 0 .. 1 | 0 |
| `mirror/rain from audio/hit -> size` | float | 0 .. 1 | 0.5 |
| `mirror/rain from audio/hit -> strength` | float | 0 .. 1 | 0.7 |
| `mirror/rain from audio/onset gain` | float | 0.1 .. 4 | 1 |
| `mirror/rain from audio/onsets spawn drops` | bool | -- | 1 |
| `mirror/rain/area centre x` | float | -1.5 .. 1.5 | 0 |
| `mirror/rain/area centre y` | float | -1 .. 1 | 0 |
| `mirror/rain/area x` | float | 0 .. 1.2 | 1 |
| `mirror/rain/area y` | float | 0 .. 1.2 | 1 |
| `mirror/rain/falling` | bool | -- | 1 |
| `mirror/rain/max in flight` | int | 1 .. 24 | 12 |
| `mirror/rain/rate (drops-s)` | float | 0.02 .. 12 | 0.8 |
| `mirror/rain/rate jitter` | float | 0 .. 1 | 0.7 |
| `mirror/rain/size` | float | 0.02 .. 0.6 | 0.14 |
| `mirror/rain/size jitter` | float | 0 .. 1 | 0.35 |
| `mirror/rain/spread jitter` | float | 0 .. 1 | 0.15 |
| `mirror/rain/strength` | float | 0 .. 2 | 1 |
| `mirror/rain/strength jitter` | float | 0 .. 1 | 0.3 |
| `mirror/raindrops` | bool | -- | 0 |
| `mirror/refraction (warp)` | float | 0 .. 1 | 0 |
| `mirror/render/downscale` | int | 1 .. 10 | 4 |
| `mirror/render/pause` | bool | -- | 0 |
| `mirror/render/ripple time scale` | float | 0 .. 4 | 1 |
| `mirror/ring freq` | float | 0.3 .. 10 | 3 |
| `mirror/ripple decay` | float | 0 .. 5 | 1.8 |
| `mirror/ripple phase` | float | 0 .. 6.28319 | 0 |
| `mirror/ripple speed` | float | 0 .. 6 | 1.2 |
| `mirror/soft centers (anti-alias)` | bool | -- | 1 |
| `mirror/soft edge` | bool | -- | 1 |
| `mirror/track live feed` | bool | -- | 0 |
| `mirror/z rate -s` | float | -2 .. 2 | 0 |
| `mirror/z/z amplitude` | float | 0 .. 3 | 1 |
| `mirror/z/z auto-rate -s` | float | -2 .. 2 | 0 |
| `mirror/z/z step size` | float | 0.01 .. 1 | 0.1 |

## roots (167 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `roots/cached field: LOD & culling/LOD bias (>1 coarser)` | float | 0.1 .. 4 | 1 |
| `roots/cached field: LOD & culling/cull below px` | float | 0.5 .. 20 | 2 |
| `roots/cached field: LOD & culling/frustum cull` | bool | -- | 1 |
| `roots/cached field: LOD & culling/grid NxN` | int | 2 .. 20 | 6 |
| `roots/cached field: LOD & culling/sub-pixel cull` | bool | -- | 1 |
| `roots/camera/auto-orbit` | bool | -- | 1 |
| `roots/camera/azimuth` | float | -3.14159 .. 3.14159 | 0.6 |
| `roots/camera/elevation` | float | -1.5 .. 1.5 | 0.35 |
| `roots/camera/focus group` | int | -1 .. 7 | -1 |
| `roots/camera/fov` | float | 0.2 .. 1.2 | 0.6 |
| `roots/camera/frame automatically` | bool | -- | 1 |
| `roots/camera/frame on masks` | bool | -- | 1 |
| `roots/camera/group of` | int | 1 .. 9 | 3 |
| `roots/camera/margin` | float | 0 .. 1.5 | 0.35 |
| `roots/camera/orbit rate` | float | -1 .. 1 | 0.15 |
| `roots/camera/radius` | float | 5 .. 120 | 42 |
| `roots/camera/zoom` | float | 0.15 .. 5 | 1 |
| `roots/environment & material/AO downscale` | int | 1 .. 4 | 2 |
| `roots/environment & material/AO intensity` | float | 0 .. 4 | 2 |
| `roots/environment & material/AO radius` | float | 0.2 .. 6 | 2.2 |
| `roots/environment & material/AO samples` | int | 4 .. 24 | 10 |
| `roots/environment & material/ambient occlusion` | bool | -- | 1 |
| `roots/environment & material/background` | rgb | -- | 0.12 0.08 0.05 |
| `roots/environment & material/env specular` | float | 0 .. 2 | 0.6 |
| `roots/environment & material/fibre break-up` | float | 0 .. 1 | 0.45 |
| `roots/environment & material/fibre scale` | float | 2 .. 40 | 20 |
| `roots/environment & material/fibre strength` | float | 0 .. 1.5 | 0.55 |
| `roots/environment & material/fibre stretch` | float | 1 .. 20 | 7 |
| `roots/environment & material/ground color` | rgb | -- | 0.1 0.07 0.045 |
| `roots/environment & material/hemisphere` | float | 0 .. 3 | 1 |
| `roots/environment & material/key color` | rgb | -- | 1 0.93 0.82 |
| `roots/environment & material/key direction X` | float | -1 .. 1 | 0.4 |
| `roots/environment & material/key direction Y` | float | -1 .. 1 | 0.8 |
| `roots/environment & material/key direction Z` | float | -1 .. 1 | 0.35 |
| `roots/environment & material/key intensity` | float | 0 .. 4 | 1 |
| `roots/environment & material/per-root tint` | float | 0 .. 0.5 | 0.14 |
| `roots/environment & material/rim` | float | 0 .. 1 | 0.1 |
| `roots/environment & material/sky color` | rgb | -- | 0.16 0.19 0.24 |
| `roots/environment & material/sss power` | float | 1 .. 16 | 5 |
| `roots/environment & material/sss tint` | rgb | -- | 0.9 0.45 0.22 |
| `roots/environment & material/sss transmit` | float | 0 .. 2 | 0.35 |
| `roots/environment & material/sss wrap` | float | 0 .. 1.5 | 0.55 |
| `roots/face masks/face falloff` | float | 0.001 .. 0.1 | 0.05 |
| `roots/face masks/face light` | float | 0 .. 8 | 1.8 |
| `roots/face masks/face recess` | float | -2 .. 1.5 | 0.5 |
| `roots/face masks/face scale` | float | 0.3 .. 1.5 | 0.85 |
| `roots/face masks/face spec` | float | 0 .. 3 | 1.2 |
| `roots/face masks/mask relief` | float | 0 .. 1.5 | 0 |
| `roots/face masks/mask roughness` | float | 0.04 .. 1 | 0.42 |
| `roots/face masks/relief scale` | float | 1 .. 30 | 9 |
| `roots/face masks/show faces` | bool | -- | 1 |
| `roots/face masks/smooth normals` | bool | -- | 1 |
| `roots/face masks/spot inner angle` | float | 1 .. 89 | 20 |
| `roots/face masks/spot outer angle` | float | 5 .. 90 | 46 |
| `roots/face masks/vein color` | rgb | -- | 0.55 0.53 0.5 |
| `roots/face masks/vein scale` | float | 0.1 .. 2 | 0.6 |
| `roots/face masks/vein strength` | float | 0 .. 1 | 0.5 |
| `roots/fog & atmosphere/anisotropy (fwd <-> back)` | float | -0.9 .. 0.9 | 0.55 |
| `roots/fog & atmosphere/clear radius follows camera` | bool | -- | 1 |
| `roots/fog & atmosphere/clear radius x orbit` | float | 0 .. 1.5 | 0.12 |
| `roots/fog & atmosphere/drift speed` | float | 0 .. 6 | 1 |
| `roots/fog & atmosphere/fog color` | rgb | -- | 0.12 0.08 0.05 |
| `roots/fog & atmosphere/fog noise` | float | 0 .. 1 | 0.55 |
| `roots/fog & atmosphere/fog on` | bool | -- | 1 |
| `roots/fog & atmosphere/height ref follows target` | bool | -- | 1 |
| `roots/fog & atmosphere/height scale` | float | 2 .. 120 | 22 |
| `roots/fog & atmosphere/march steps` | int | 4 .. 32 | 14 |
| `roots/fog & atmosphere/noise contrast` | float | 0 .. 3 | 1.2 |
| `roots/fog & atmosphere/noise scale` | float | 0.02 .. 2.5 | 0.55 |
| `roots/fog & atmosphere/scatter (medium albedo)` | float | 0 .. 1.5 | 0.04 |
| `roots/fog & atmosphere/wisp glow` | float | 0 .. 3 | 1 |
| `roots/fog & atmosphere/wisps` | int | 0 .. 8 | 0 |
| `roots/growth/cone height` | float | 24 .. 96 | 52 |
| `roots/growth/cone radius` | float | 6 .. 24 | 13 |
| `roots/growth/crawl the cone surface` | bool | -- | 0 |
| `roots/growth/days - step` | float | 0.05 .. 3 | 0.75 |
| `roots/growth/dwell` | float | 0 .. 1 | 0.92 |
| `roots/growth/dwell days` | float | 2 .. 60 | 18 |
| `roots/growth/dwell lateral` | float | 0 .. 1 | 0.92 |
| `roots/growth/even nests` | bool | -- | 1 |
| `roots/growth/feature clusters` | int | 1 .. 6 | 3 |
| `roots/growth/group size` | int | 1 .. 9 | 3 |
| `roots/growth/group spread` | float | 0.1 .. 1.2 | 0.55 |
| `roots/growth/helix turns` | float | 0.25 .. 6 | 2 |
| `roots/growth/hop days` | float | 10 .. 160 | 60 |
| `roots/growth/host` | string | -- | cone |
| `roots/growth/jitter` | float | 0 .. 1.2 | 0.35 |
| `roots/growth/lateral` | float | 0 .. 1 | 0.2 |
| `roots/growth/mask end` | float | 0 .. 1 | 0.94 |
| `roots/growth/mask start` | float | 0 .. 1 | 0.15 |
| `roots/growth/masks` | int | 1 .. 24 | 5 |
| `roots/growth/pattern` | string | -- | phyllotaxis |
| `roots/growth/pull reach` | float | 0.4 .. 3 | 1.2 |
| `roots/growth/reach x` | float | 0.4 .. 4 | 1.6 |
| `roots/growth/seed` | int | 0 .. 1.07374e+09 | 42 |
| `roots/growth/shell` | float | 1 .. 20 | 9 |
| `roots/growth/spawn behind` | float | -10 .. 10 | 0 |
| `roots/growth/species` | string | -- | Zea_mays_6_Leitner_2014.xml |
| `roots/growth/spiral drift` | float | -0.5 .. 0.5 | 0 |
| `roots/growth/spiral x golden` | float | 0.2 .. 2 | 1 |
| `roots/growth/steps-frame` | int | 1 .. 30 | 2 |
| `roots/growth/taper` | float | 0.4 .. 2.5 | 1 |
| `roots/growth/target lift` | float | -10 .. 10 | 0 |
| `roots/growth/travel pull` | float | 0 .. 1 | 0.9 |
| `roots/growth/travel slack` | float | 1 .. 4 | 2.5 |
| `roots/growth/travel trials` | float | 1 .. 60 | 14 |
| `roots/growth/tree relay` | bool | -- | 0 |
| `roots/growth/tube radius` | float | 2 .. 20 | 7 |
| `roots/growth/view cylinder` | float | 1 .. 30 | 8 |
| `roots/lens & film/anamorphic streak` | float | 0 .. 1 | 0 |
| `roots/lens & film/barrel <-> pincushion` | float | -0.4 .. 0.4 | 0 |
| `roots/lens & film/chromatic aberration` | float | 0 .. 8 | 0 |
| `roots/lens & film/contrast` | float | 0.5 .. 2 | 1 |
| `roots/lens & film/distortion (corners)` | float | -0.2 .. 0.2 | 0 |
| `roots/lens & film/distortion re-crop` | float | 0.6 .. 1.2 | 1 |
| `roots/lens & film/focal length (mm)` | float | 8 .. 135 | 17.5 |
| `roots/lens & film/fov (rad, half-angle)` | float | 0.15 .. 1.2 | 0.6 |
| `roots/lens & film/gain` | rgb | -- | 1 1 1 |
| `roots/lens & film/gamma` | rgb | -- | 1 1 1 |
| `roots/lens & film/grain` | float | 0 .. 0.12 | 0.03 |
| `roots/lens & film/grain chroma` | float | 0 .. 1 | 0.25 |
| `roots/lens & film/grain size (px)` | float | 1 .. 6 | 1.6 |
| `roots/lens & film/halation` | float | 0 .. 1 | 0.35 |
| `roots/lens & film/halation spread (mip)` | int | 0 .. 4 | 3 |
| `roots/lens & film/halation tint` | rgb | -- | 1 0.42 0.2 |
| `roots/lens & film/highlight tint` | rgb | -- | 1.08 1 0.9 |
| `roots/lens & film/lift` | rgb | -- | 0 0 0 |
| `roots/lens & film/saturation` | float | 0 .. 2 | 1 |
| `roots/lens & film/set FOV by focal length` | bool | -- | 1 |
| `roots/lens & film/shadow tint` | rgb | -- | 0.88 0.95 1.14 |
| `roots/lens & film/split balance (-1 off)` | float | -1 .. 1 | 0.45 |
| `roots/lens & film/split strength` | float | 0 .. 1 | 0.35 |
| `roots/lens & film/streak length` | float | 2 .. 60 | 14 |
| `roots/lens & film/streak tint` | rgb | -- | 0.55 0.72 1 |
| `roots/material/ambient` | float | 0 .. 0.5 | 0.06 |
| `roots/material/base color` | rgb | -- | 0.55 0.42 0.28 |
| `roots/material/base color 2` | rgb | -- | 0.28 0.18 0.12 |
| `roots/material/color noise` | float | 0 .. 1 | 0.6 |
| `roots/material/diffuse` | float | 0 .. 1.5 | 0.55 |
| `roots/material/metallic` | float | 0 .. 1 | 0.05 |
| `roots/material/radius scale` | float | 0.2 .. 4 | 1.4 |
| `roots/material/roughness` | float | 0.05 .. 1 | 0.7 |
| `roots/material/shininess` | float | 4 .. 300 | 150 |
| `roots/overlays/axes` | bool | -- | 0 |
| `roots/overlays/grid` | bool | -- | 0 |
| `roots/overlays/grid spacing` | float | 1 .. 20 | 5 |
| `roots/post/DoF focus (0=auto)` | float | 0 .. 120 | 0 |
| `roots/post/DoF range` | float | 5 .. 150 | 55 |
| `roots/post/DoF strength` | float | 0 .. 1 | 0.5 |
| `roots/post/bloom` | bool | -- | 1 |
| `roots/post/bloom intensity` | float | 0 .. 1 | 0.5 |
| `roots/post/bloom radius` | float | 0.5 .. 3 | 1 |
| `roots/post/bloom threshold` | float | 0.2 .. 4 | 0.28 |
| `roots/post/depth of field` | bool | -- | 1 |
| `roots/post/exposure` | float | 0.1 .. 4 | 1.2 |
| `roots/post/filmic tonemap` | bool | -- | 1 |
| `roots/post/fog dither` | float | 0 .. 1 | 1 |
| `roots/post/output dither` | bool | -- | 1 |
| `roots/post/post chain` | bool | -- | 1 |
| `roots/post/supersample` | int | 1 .. 3 | 2 |
| `roots/post/vignette` | float | 0 .. 1 | 0.22 |
| `roots/travelling pulses/pulse color` | rgb | -- | 1 0.85 0.45 |
| `roots/travelling pulses/pulse intensity` | float | 0 .. 4 | 1.6 |
| `roots/travelling pulses/pulse spacing` | float | 4 .. 60 | 22 |
| `roots/travelling pulses/pulse speed` | float | 0 .. 40 | 14 |
| `roots/travelling pulses/pulse width` | float | 0.5 .. 12 | 3.5 |
| `roots/travelling pulses/pulses on` | bool | -- | 1 |

