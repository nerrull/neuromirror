# mirror_app settings

Generated from the live registry -- do not edit by hand. Every row is a
control that declared itself in the frame this was written from, which is
all of them: declaring does not depend on what the panel has open.

Regenerate from the panel: **settings -> write SETTINGS.md**.

## Where a setting goes

| bank | file | what belongs here |
|---|---|---|
| `machine` | `presets/machine.machine` | the room, not the piece: sensor, screen, camera mask, MIDI map. Loaded at startup, never carried to another venue. |
| `fit` | `presets/fit/*.fit` | how the face fit is set up: crop shape, head mode, grid/steps/lr, and what happens outside the crop. Separate from `mirror` so a ripple preset cannot rewrite it. |
| `show` | `presets/show/*.show` | the running order -- what plays and when. |
| `look` | `presets/look/*.look` | composition that outlives one scene: text overlay, transition. |
| `mirror` | `presets/mirror/*.mirror` | the ripple scene. Many presets; this is the one dialled in per performance. |
| `roots` | `presets/roots/*.roots` | the root scene. |

The mapping from a top-level panel section to a bank is `kBankRules` in
`src/ui_params.cpp`. Add a section, add a rule -- otherwise its parameters
land in `unassigned` and are listed below until somebody decides.

## machine (27 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `camera mask/mask the camera` | bool | -- | 0 |
| `camera mask/soft edge` | float | 0 .. 0.2 | 0.03 |
| `face tracking/acquire` | int | 1 .. 10 | 2 |
| `face tracking/face finder first (Vision, full-size frame)` | bool | -- | 1 |
| `face tracking/finder crop (x face)` | float | 1.2 .. 4 | 2.2 |
| `face tracking/fitted mesh drives the root masks` | bool | -- | 1 |
| `face tracking/hold on loss` | float | 0 .. 3 | 0.6 |
| `face tracking/source` | int | 0 .. 1 | 0 |
| `face tracking/texture source` | int | 0 .. 1 | 0 |
| `face tracking/texture the mask from the neural fit` | bool | -- | 1 |
| `face tracking/track faces` | bool | -- | 1 |
| `face tracking/tracker px` | int | 240 .. 960 | 480 |
| `mirror/mirror image` | bool | -- | 1 |
| `roots/auto render-scale` | bool | -- | 1 |
| `roots/root downscale` | int | 1 .. 6 | 1 |
| `roots/target px` | int | 720 .. 3840 | 1920 |
| `screen/camera above centre (cm)` | float | -100 .. 150 | 40 |
| `screen/camera hfov (deg)` | float | 30 .. 120 | 84.1 |
| `screen/camera tilt (deg)` | float | -45 .. 45 | 15 |
| `screen/distance trim` | float | 0.5 .. 2 | 0.88 |
| `screen/feed x` | float | 0 .. 1 | 0.5 |
| `screen/feed y` | float | 0 .. 1 | 0.5 |
| `screen/feed zoom` | float | 0.25 .. 4 | 0.25 |
| `screen/orientation` | int | 0 .. 2 | 0 |
| `screen/panel aspect (w-h)` | float | 0.3 .. 1 | 0.5625 |
| `screen/screen height (cm)` | float | 20 .. 300 | 60 |
| `screen/video edge crop` | float | 0 .. 0.45 | 0.191 |

## fit (45 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `fit/animate z outside` | bool | -- | 1 |
| `fit/colour follows the fit` | bool | -- | 1 |
| `fit/colour secs` | float | 0 .. 20 | 6 |
| `fit/crop shape` | int | 0 .. 1 | 1 |
| `fit/crop the fit to the face` | bool | -- | 1 |
| `fit/crop/grid` | int | 1 .. 8 | 1 |
| `fit/crop/lr` | float | 0.0001 .. 0.02 | 0.0006 |
| `fit/crop/steps` | int | 1 .. 32 | 8 |
| `fit/dilate` | int | 0 .. 24 | 6 |
| `fit/effects follow (s)` | float | 0.02 .. 1.5 | 0.25 |
| `fit/face size x` | float | 0.5 .. 5 | 1.53 |
| `fit/fade starts` | float | 0 .. 0.8 | 0 |
| `fit/fade width` | float | 0.01 .. 1.5 | 0.515 |
| `fit/feed/grid` | int | 1 .. 8 | 3 |
| `fit/feed/lr` | float | 0.0001 .. 0.02 | 0.003 |
| `fit/feed/steps` | int | 1 .. 32 | 1 |
| `fit/fit w0` | float | 1 .. 80 | 80 |
| `fit/follow the outline` | bool | -- | 1 |
| `fit/full colour at fit` | float | 0.1 .. 1 | 0.62 |
| `fit/grey outside` | float | 0 .. 1 | 1 |
| `fit/head agility` | float | 0.1 .. 20 | 0.5 |
| `fit/head jitter` | float | 0.0005 .. 0.03 | 0.004 |
| `fit/head mode` | int | 0 .. 2 | 2 |
| `fit/identity/fit automatically` | bool | -- | 1 |
| `fit/identity/frames` | int | 1 .. 24 | 8 |
| `fit/identity/head pose from tracker` | bool | -- | 1 |
| `fit/identity/modes` | int | 10 .. 100 | 80 |
| `fit/identity/re-solve every` | float | 0 .. 10 | 2 |
| `fit/identity/ridge` | float | 0.01 .. 20 | 6 |
| `fit/identity/secs` | float | 1 .. 15 | 5 |
| `fit/kinect stall s` | float | 0.5 .. 15 | 3 |
| `fit/lr warm-up from` | float | 0 .. 1 | 0.2 |
| `fit/lr warm-up secs` | float | 0 .. 15 | 5 |
| `fit/max colour` | float | 0 .. 1 | 0.72 |
| `fit/pad` | float | 0 .. 0.6 | 0.3 |
| `fit/ramp secs` | float | 0 .. 8 | 4.3 |
| `fit/ramp w0 for the fit` | bool | -- | 1 |
| `fit/shift fade` | float | 0.05 .. 3 | 0.55 |
| `fit/shift far` | float | 0 .. 1 | 0.04 |
| `fit/shift gain (fit)` | float | 0 .. 2 | 1 |
| `fit/shift gain (idle)` | float | 0 .. 1 | 0.21 |
| `fit/shift reach` | float | 0 .. 3 | 0.29 |
| `fit/shrinks with distance` | float | 0 .. 1 | 0 |
| `fit/soft edge` | bool | -- | 1 |
| `fit/track live feed` | bool | -- | 1 |

## show (134 parameters, 2 retired)

| parameter | type | range | value |
|---|---|---|---|
| `show/cue CC` | int | 0 .. 127 | 100 |
| `show/fit score to convert` | float | 0 .. 1 | 0.89 |
| `show/fit_level half scale (loss)` | float | 0.0005 .. 0.05 | 0.005 |
| `show/fitting` | int | 0 .. 4 | 0 |
| `show/fitting/absent_hold` | float | 0 .. 30 | 9.9 |
| `show/fitting/fit_hold` | float | 0 .. 30 | 1.5 |
| `show/fitting/max (0 - no ceiling)` | float | 0 .. 120 | 36 |
| `show/fitting/min` | float | 0 .. 120 | 2 |
| `show/idle` | int | 0 .. 4 | 0 |
| `show/idle/face drop grace s` | float | 0 .. 3 | 0.5 |
| `show/idle/face hold s` | float | 0 .. 30 | 15 |
| `show/idle/intro fade-in (s)` | float | 0 .. 8 | 1.5 |
| `show/idle/max (0 - no ceiling)` | float | 0 .. 120 | 0 |
| `show/idle/min` | float | 0 .. 120 | 0 |
| `show/log phase changes` | bool | -- | 1 |
| `show/mesh fit residual, diagnostic (px)` | float | 1 .. 20 | 6 |
| `show/phase CC` | int | 0 .. 127 | 101 |
| `show/roots` | int | 0 .. 4 | 1 |
| `show/roots/absent_hold` | float | 0 .. 30 | 8 |
| `show/roots/bank faces replay` | bool | -- | 1 |
| `show/roots/bank plants` | bool | -- | 1 |
| `show/roots/cam ease seconds` | float | 0.05 .. 5 | 1.2 |
| `show/roots/cam max angular speed (rad-s)` | float | 0.05 .. 4 | 1.2 |
| `show/roots/datamosh seconds` | float | 0 .. 10 | 7 |
| `show/roots/debug spawn markers` | bool | -- | 0 |
| `show/roots/face hold after cloth s` | float | 0 .. 30 | 20.1 |
| `show/roots/face seconds` | float | 0.2 .. 20 | 2.3 |
| `show/roots/fade seconds` | float | 0.2 .. 10 | 2 |
| `show/roots/fog fade seconds` | float | 0 .. 20 | 2 |
| `show/roots/fog intensity (visibility, world u)` | float | 8 .. 600 | 25 |
| `show/roots/frame margin` | float | -0.9 .. 1.5 | 0.12 |
| `show/roots/grow face seconds` | float | 0.5 .. 60 | 6.9 |
| `show/roots/grow frame previous face` | bool | -- | 0 |
| `show/roots/grow hop lead` | float | 0 .. 1 | 0.3 |
| `show/roots/grow margin` | float | 0 .. 1.5 | 0.35 |
| `show/roots/grow rate max (steps-s)` | float | 1 .. 2000 | 1200 |
| `show/roots/grow rate min (steps-s)` | float | 1 .. 2000 | 1 |
| `show/roots/grow swing ease-in (s)` | float | 0 .. 10 | 4 |
| `show/roots/grow timeout mult` | float | 1 .. 4 | 1.97 |
| `show/roots/head pan` | bool | -- | 1 |
| `show/roots/head pan (deg)` | float | -30 .. 30 | 5 |
| `show/roots/head pan tau (s)` | float | 0.05 .. 3 | 0.6 |
| `show/roots/head pivot back (cm)` | float | 0 .. 20 | 8 |
| `show/roots/head pivot down (cm)` | float | 0 .. 20 | 5 |
| `show/roots/hold settle (s)` | float | 0 .. 3 | 0.75 |
| `show/roots/live smoothing (s)` | float | 0 .. 0.5 | 0.12 |
| `show/roots/max (0 - no ceiling)` | float | 0 .. 120 | 0 |
| `show/roots/min` | float | 0 .. 120 | 60 |
| `show/roots/mouth open amount` | float | 0 .. 1.5 | 0.8 |
| `show/roots/mouth open lead (s)` | float | 0 .. 5 | 3 |
| `show/roots/mouth open lips` | float | 0 .. 1.5 | 0.4 |
| `show/roots/mouth open seconds` | float | 0.1 .. 5 | 3 |
| `show/roots/mouth open width` | float | 0 .. 1.5 | 0.6 |
| `show/roots/movement boosts rate` | float | 0 .. 4 | 0 |
| `show/roots/new seed each sitting` | bool | -- | 1 |
| `show/roots/orbit bound frac` | float | 0.1 .. 1 | 0.53 |
| `show/roots/orbit elevation (deg)` | float | -60 .. 80 | -17 |
| `show/roots/orbit max radius` | float | 20 .. 400 | 73 |
| `show/roots/orbit rate (rad-s)` | float | -1 .. 1 | 0.054 |
| `show/roots/orbit seconds` | float | 1 .. 300 | 45 |
| `show/roots/orbit target lift` | float | -40 .. 40 | -6.2 |
| `show/roots/orbit tilt (deg)` | float | 0 .. 90 | 0 |
| `show/roots/orbit zoom` | float | 0.1 .. 1.5 | 0.55 |
| `show/roots/other structures` | bool | -- | 0 |
| `show/roots/reveal fallback seconds` | float | 0.2 .. 20 | 2.5 |
| `show/roots/reveal max structures` | int | 1 .. 32 | 6 |
| `show/roots/reveal min structures` | int | 0 .. 32 | 3 |
| `show/roots/reveal mode` _(retired)_ | int | 0 .. 1 | 0 |
| `show/roots/reveal pulse lag` | float | 0 .. 5 | 0 |
| `show/roots/reveal ring radius` | float | 0.1 .. 20 | 7.79 |
| `show/roots/reveal structures` | int | 0 .. 32 | 0 |
| `show/roots/reveal tilt (deg)` | float | 0 .. 89 | 60 |
| `show/roots/track smoothing (s)` | float | 0 .. 1 | 0.25 |
| `show/roots/turn seconds` | float | 0.5 .. 20 | 6 |
| `show/roots/zoom out seconds` | float | 1 .. 120 | 20 |
| `show/run the show` | bool | -- | 1 |
| `show/transition` | int | 0 .. 4 | 2 |
| `show/transition/done_hold` | float | 0 .. 30 | 0 |
| `show/transition/max (0 - no ceiling)` | float | 0 .. 120 | 30 |
| `show/transition/min` | float | 0 .. 120 | 0 |
| `sound/checkpoint hysteresis` | float | 0 .. 0.15 | 0.03 |
| `sound/chord octave` | int | -5 .. -1 | -3 |
| `sound/detune (cents)` | float | 0 .. 25 | 2.2 |
| `sound/fall (s)` | float | 0.05 .. 4 | 0.55 |
| `sound/far (face height)` | float | 0.02 .. 0.4 | 0.12 |
| `sound/flanger rate max (Hz)` | float | 0 .. 5 | 2.666 |
| `sound/flanger rate min (Hz)` | float | 0 .. 5 | 0.1 |
| `sound/level` | float | 0 .. 1 | 1 |
| `sound/movement full scale` | float | 0.2 .. 4 | 1.2 |
| `sound/near (face height)` | float | 0.1 .. 0.9 | 0.45 |
| `sound/offset range (semitones)` | int | 0 .. 7 | 5 |
| `sound/pad octave (semitones)` | float | -36 .. 12 | -36 |
| `sound/phases post their own events` | bool | -- | 1 |
| `sound/pluck centre (MIDI note)` | float | 60 .. 96 | 79 |
| `sound/pluck climb (semitones)` | float | 0 .. 36 | 6 |
| `sound/pluck fitting octave` | int | -3 .. 1 | 1 |
| `sound/pluck idle octave` | int | -3 .. 1 | 1 |
| `sound/resolved/flanger fade (s)` | float | 0.1 .. 30 | 3.342 |
| `sound/resolved/pluck glide (ms)` | float | 0 .. 2000 | 1493.33 |
| `sound/resolved/strum dead zone (deg)` | float | 0 .. 45 | 10 |
| `sound/resolved/strum drop glide (ms)` | float | 0 .. 2000 | 1500 |
| `sound/resolved/strum full velocity (deg-s)` | float | 10 .. 720 | 10 |
| `sound/resolved/strum hysteresis` | float | 0 .. 0.5 | 0.2 |
| `sound/resolved/strum mute fade (ms)` | float | 0 .. 5000 | 500 |
| `sound/resolved/strum mutes pluck` | bool | -- | 1 |
| `sound/resolved/strum octave` | int | -2 .. 4 | 1 |
| `sound/resolved/strum range (deg)` | float | 10 .. 90 | 40.578 |
| `sound/resolved/strum scale` | int | 0 .. 2 | 1 |
| `sound/resolved/strum shuffled` | bool | -- | 0 |
| `sound/resolved/strum velocity smooth (ms)` | float | 1 .. 1000 | 473.86 |
| `sound/resolved/strum wires` | bool | -- | 1 |
| `sound/resolved/wire arc (deg)` | float | 10 .. 360 | 102.556 |
| `sound/resolved/wire height (x mask)` | float | 0.5 .. 20 | 3.956 |
| `sound/resolved/wire pluck decay (s)` | float | 0.05 .. 5 | 1.2 |
| `sound/resolved/wire pluck vibration (px)` | float | 0 .. 60 | 14 |
| `sound/resolved/wire pluck width (x)` | float | 0 .. 4 | 1.289 |
| `sound/resolved/wire pulse divisor` | float | 1 .. 512 | 128 |
| `sound/resolved/wire radius (x nose)` | float | 0.5 .. 6 | 1.36 |
| `sound/resolved/wire spread` _(retired)_ | float | 0 .. 1 | 0.7 |
| `sound/resolved/wire wave modes` | float | 0.5 .. 8 | 2 |
| `sound/resolved/wire width (px)` | float | 0.25 .. 8 | 3.178 |
| `sound/rise (s)` | float | 0.01 .. 1 | 0.12 |
| `sound/shepherd rate max (st-s)` | float | 0 .. 3 | 0.6 |
| `sound/shepherd rate min (st-s)` | float | 0 .. 3 | 0.15 |
| `sound/shepherd rise` | bool | -- | 0 |
| `sound/sound on` | bool | -- | 1 |
| `sound/stage 1` | float | 0 .. 1 | 0.38 |
| `sound/stage 2` | float | 0 .. 1 | 0.63 |
| `sound/stage 3` | float | 0 .. 1 | 0.82 |
| `sound/stage 4` | float | 0 .. 1 | 0.86 |
| `sound/transpose (semitones)` | float | -24 .. 24 | 0 |
| `sound/wander` | bool | -- | 1 |
| `sound/wander cycle (s)` | float | 1 .. 300 | 126.1 |
| `sound/wander depth` | float | 0.001 .. 0.5 | 0.01 |

## look (46 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `cloth/align mask` | bool | -- | 0 |
| `cloth/clear distance (world units)` | float | 0.2 .. 5 | 1.5 |
| `cloth/damping` | float | 0.9 .. 1 | 0.985 |
| `cloth/fall` | float | 0.5 .. 6 | 1.8 |
| `cloth/film relief` | float | 0 .. 3 | 0.8 |
| `cloth/film sheen` | float | 0 .. 1.5 | 0.35 |
| `cloth/friction` | float | 0 .. 1 | 0.07 |
| `cloth/gravity back (-z)` | float | 0 .. 20 | 6 |
| `cloth/gravity down (-y)` | float | 0 .. 8 | 0 |
| `cloth/hold` | float | 0 .. 3 | 0.5 |
| `cloth/iterations` | int | 4 .. 64 | 24 |
| `cloth/lock when the press starts` | bool | -- | 1 |
| `cloth/mask offset x` | float | -0.2 .. 0.2 | 0 |
| `cloth/mask offset y` | float | -0.2 .. 0.2 | 0 |
| `cloth/mask relief` | float | 0.2 .. 4 | 2.2 |
| `cloth/mask scale x` | float | 0.6 .. 1.4 | 1 |
| `cloth/mask scale y` | float | 0.6 .. 1.4 | 1 |
| `cloth/refraction` | float | 0 .. 0.25 | 0.05 |
| `cloth/release` | float | 0.05 .. 3 | 0.7 |
| `cloth/relief shading` | float | 0 .. 1 | 0.55 |
| `cloth/save a capture on lock` | bool | -- | 1 |
| `cloth/set (plasticity)` | float | 0 .. 8 | 2 |
| `cloth/shading span` | float | 1 .. 10 | 4 |
| `cloth/sheet oversize` | float | 1 .. 1.3 | 1.08 |
| `cloth/sheet res` | int | 16 .. 128 | 72 |
| `cloth/show cloth` | bool | -- | 1 |
| `cloth/show mask` | bool | -- | 1 |
| `cloth/side force delay (s into release)` | float | 0 .. 30 | 17 |
| `cloth/side force magnitude` | float | 0 .. 15 | 4 |
| `cloth/stretch` | float | 0 .. 0.98 | 0.8 |
| `cloth/substeps` | int | 1 .. 8 | 2 |
| `cloth/wireframe` | bool | -- | 0 |
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

## mirror (60 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `mirror/colour/amp gain` | float | 0.2 .. 6 | 2.431 |
| `mirror/colour/color mix (0 grey -> 1 RGB)` | float | 0 .. 1 | 0 |
| `mirror/colour/color travel (palette follows orbit)` | bool | -- | 0 |
| `mirror/colour/gamma (>1 darkens)` | float | 0.3 .. 2 | 1 |
| `mirror/colour/grey ch` | int | 0 .. 2 | 0 |
| `mirror/colour/ripple amp -> color` | bool | -- | 0 |
| `mirror/colour/sRGB fix` | bool | -- | 0 |
| `mirror/colour/swap R-B` | bool | -- | 0 |
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
| `mirror/moving ripple` | bool | -- | 0 |
| `mirror/network/contrast (w out)` | float | 1 .. 12 | 4.717 |
| `mirror/network/detail (w hidden)` | float | 0.5 .. 10 | 6.449 |
| `mirror/network/gain tilt (front<->back)` | float | -3 .. 3 | 0.557 |
| `mirror/network/sine layers (0 - tanh only)` | int | 0 .. 5 | 1 |
| `mirror/network/sine w0 (composition)` | float | 1 .. 60 | 12.7 |
| `mirror/network/w shape (gauss<->uniform)` | float | 0 .. 1 | 0 |
| `mirror/pluck onsets (idle/fitting)/pluck onset gain` | float | 0.1 .. 4 | 1 |
| `mirror/pluck onsets (idle/fitting)/pluck onsets spawn drops` | bool | -- | 1 |
| `mirror/radius` | float | 0.02 .. 0.5 | 0.12 |
| `mirror/rain from audio/hit -> position` | float | 0 .. 1 | 0 |
| `mirror/rain from audio/hit -> size` | float | 0 .. 1 | 0.5 |
| `mirror/rain from audio/hit -> strength` | float | 0 .. 1 | 0.7 |
| `mirror/rain/area centre x` | float | -1.5 .. 1.5 | 0 |
| `mirror/rain/area centre y` | float | -1 .. 1 | 0 |
| `mirror/rain/area x` | float | 0 .. 1.2 | 1 |
| `mirror/rain/area y` | float | 0 .. 1.2 | 1 |
| `mirror/rain/max in flight` | int | 1 .. 24 | 12 |
| `mirror/rain/reject below (strength)` | float | 0 .. 2 | 0 |
| `mirror/rain/size` | float | 0.02 .. 0.6 | 0.14 |
| `mirror/rain/size jitter` | float | 0 .. 1 | 0.35 |
| `mirror/rain/spread jitter` | float | 0 .. 1 | 0.15 |
| `mirror/rain/strength` | float | 0 .. 2 | 0.769 |
| `mirror/rain/strength jitter` | float | 0 .. 1 | 0.3 |
| `mirror/rain/weak decay boost` | float | 0 .. 4 | 4 |
| `mirror/raindrops` | bool | -- | 1 |
| `mirror/refraction (warp)` | float | 0 .. 1 | 1 |
| `mirror/render/downscale` | int | 1 .. 10 | 2 |
| `mirror/render/pause` | bool | -- | 0 |
| `mirror/render/ripple time scale` | float | 0 .. 4 | 1 |
| `mirror/ring freq` | float | 0.3 .. 10 | 6.982 |
| `mirror/ripple decay` | float | 0 .. 5 | 2.28 |
| `mirror/ripple phase` | float | 0 .. 6.28319 | 0 |
| `mirror/ripple speed` | float | 0 .. 6 | 1.905 |
| `mirror/soft centers (anti-alias)` | bool | -- | 1 |
| `mirror/z/drop boost decay s` | float | 0.05 .. 5 | 0.25 |
| `mirror/z/drops add z speed -s` | float | 0 .. 0.5 | 0.1833 |
| `mirror/z/movement adds z speed -s` | float | 0 .. 0.2 | 0.0222 |
| `mirror/z/z amplitude` | float | 0 .. 3 | 1 |
| `mirror/z/z auto-rate -s` | float | 0 .. 0.2 | 0.0154 |
| `mirror/z/z step size` | float | 0.01 .. 1 | 0.06 |

## roots (235 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `roots/cached field: LOD & culling/LOD bias (>1 coarser)` | float | 0.1 .. 4 | 0.5 |
| `roots/cached field: LOD & culling/cull below px` | float | 0.5 .. 20 | 0.5 |
| `roots/cached field: LOD & culling/frustum cull` | bool | -- | 1 |
| `roots/cached field: LOD & culling/grid NxN` | int | 2 .. 20 | 6 |
| `roots/cached field: LOD & culling/min radius px` | float | 0 .. 3 | 0 |
| `roots/cached field: LOD & culling/sub-pixel cull` | bool | -- | 0 |
| `roots/camera/azimuth` | float | -3.14159 .. 3.14159 | 9.39194 |
| `roots/camera/elevation` | float | -1.5 .. 1.5 | -0.285692 |
| `roots/camera/fov` | float | 0.2 .. 1.2 | 0.6 |
| `roots/camera/frame automatically` | bool | -- | 0 |
| `roots/camera/margin` | float | 0 .. 1.5 | 0.35 |
| `roots/camera/radius` | float | 5 .. 120 | 58.0902 |
| `roots/camera/zoom` | float | 0.15 .. 5 | 1 |
| `roots/environment & material/AO downscale` | int | 1 .. 4 | 1 |
| `roots/environment & material/AO intensity` | float | 0 .. 4 | 2.338 |
| `roots/environment & material/AO radius` | float | 0.2 .. 6 | 2.187 |
| `roots/environment & material/AO samples` | int | 4 .. 24 | 10 |
| `roots/environment & material/ambient occlusion` | bool | -- | 1 |
| `roots/environment & material/angle follows the tracked visitor` | bool | -- | 1 |
| `roots/environment & material/background` | rgb | -- | 0.12 0.08 0.05 |
| `roots/environment & material/base intensity (silence)` | float | 0 .. 4 | 0.178 |
| `roots/environment & material/env specular` | float | 0 .. 2 | 0.6 |
| `roots/environment & material/fibre break-up` | float | 0 .. 1 | 0.45 |
| `roots/environment & material/fibre fade px` | float | 0 .. 6 | 1 |
| `roots/environment & material/fibre scale` | float | 2 .. 40 | 20 |
| `roots/environment & material/fibre strength` | float | 0 .. 1.5 | 0.55 |
| `roots/environment & material/fibre stretch` | float | 1 .. 20 | 7 |
| `roots/environment & material/ground color` | rgb | -- | 0.1 0.07 0.045 |
| `roots/environment & material/hemisphere` | float | 0 .. 3 | 1 |
| `roots/environment & material/intensity follows the mic` | bool | -- | 1 |
| `roots/environment & material/key color` | rgb | -- | 0.95098 0.860337 0.717897 |
| `roots/environment & material/key direction X` | float | -1 .. 1 | 0.4 |
| `roots/environment & material/key direction Y` | float | -1 .. 1 | 0.8 |
| `roots/environment & material/key direction Z` | float | -1 .. 1 | 0.35 |
| `roots/environment & material/key intensity` | float | 0 .. 4 | 0.178 |
| `roots/environment & material/lamp X` | float | -60 .. 60 | 6 |
| `roots/environment & material/lamp Y` | float | -60 .. 60 | 14 |
| `roots/environment & material/lamp Z` | float | -60 .. 60 | -10 |
| `roots/environment & material/mic gain` | float | 0 .. 4 | 4 |
| `roots/environment & material/offset azimuth (rad)` | float | -3.14 .. 3.14 | 1.05 |
| `roots/environment & material/offset elevation (rad)` | float | -1.5 .. 1.5 | 0.55 |
| `roots/environment & material/per-root tint` | float | 0 .. 0.5 | 0.14 |
| `roots/environment & material/rim` | float | 0 .. 1 | 0.1 |
| `roots/environment & material/sky color` | rgb | -- | 0.16 0.19 0.24 |
| `roots/environment & material/sss power` | float | 1 .. 16 | 6.1 |
| `roots/environment & material/sss tint` | rgb | -- | 0.583333 0.302852 0.254494 |
| `roots/environment & material/sss transmit` | float | 0 .. 2 | 0.363 |
| `roots/environment & material/sss wrap` | float | 0 .. 1.5 | 0.653 |
| `roots/environment & material/track angle range (rad)` | float | 0 .. 1.5 | 0.72 |
| `roots/environment & material/unlit level` | float | 0 .. 0.3 | 0.035 |
| `roots/face masks/albedo gamma` | float | 1 .. 3 | 2.347 |
| `roots/face masks/albedo level` | float | 0 .. 0.8 | 0.45 |
| `roots/face masks/albedo saturation` | float | 0 .. 3 | 1 |
| `roots/face masks/face falloff` | float | 0.001 .. 0.1 | 0.038 |
| `roots/face masks/face light` | float | 0 .. 8 | 3.857 |
| `roots/face masks/face light color` | rgb | -- | 1 0.82 0.62 |
| `roots/face masks/face recess` | float | -2 .. 1.5 | -0.273 |
| `roots/face masks/face scale` | float | 0.3 .. 1.5 | 1.01 |
| `roots/face masks/face spec` | float | 0 .. 3 | 0.967 |
| `roots/face masks/mask roughness` | float | 0.04 .. 1 | 0.571 |
| `roots/face masks/mask sss power` | float | 1 .. 16 | 2.8 |
| `roots/face masks/mask sss tint` | rgb | -- | 0.9 0.45 0.22 |
| `roots/face masks/mask sss transmit` | float | 0 .. 2 | 0.364 |
| `roots/face masks/mask sss wrap` | float | 0 .. 1.5 | 1.233 |
| `roots/face masks/show faces` | bool | -- | 1 |
| `roots/face masks/smooth normals` | bool | -- | 1 |
| `roots/face masks/spot inner angle` | float | 1 .. 89 | 1 |
| `roots/face masks/spot outer angle` | float | 5 .. 90 | 68.656 |
| `roots/fog & atmosphere/anisotropy (fwd <-> back)` | float | -0.9 .. 0.9 | 0.427 |
| `roots/fog & atmosphere/clear radius follows camera` | bool | -- | 1 |
| `roots/fog & atmosphere/clear radius x orbit` | float | 0 .. 1.5 | 0.865 |
| `roots/fog & atmosphere/drift speed` | float | 0 .. 6 | 0.827 |
| `roots/fog & atmosphere/fog color` | rgb | -- | 0.622012 0.656863 0.605344 |
| `roots/fog & atmosphere/fog noise` | float | 0 .. 1 | 1 |
| `roots/fog & atmosphere/fog on` | bool | -- | 1 |
| `roots/fog & atmosphere/height ref follows target` | bool | -- | 1 |
| `roots/fog & atmosphere/height scale` | float | 2 .. 120 | 120 |
| `roots/fog & atmosphere/march steps` | int | 4 .. 32 | 12 |
| `roots/fog & atmosphere/noise contrast` | float | 0 .. 3 | 3 |
| `roots/fog & atmosphere/noise mip level` | float | 0 .. 4 | 3.4 |
| `roots/fog & atmosphere/noise scale` | float | 0.02 .. 2.5 | 0.064 |
| `roots/fog & atmosphere/scatter (medium albedo)` | float | 0 .. 1.5 | 0.027 |
| `roots/fog & atmosphere/volume downscale` | int | 1 .. 4 | 1 |
| `roots/glitch/background depth` | float | 5 .. 400 | 64.689 |
| `roots/glitch/band high` | float | 0 .. 1 | 0.944 |
| `roots/glitch/band low` | float | 0 .. 1 | 0.016 |
| `roots/glitch/block size (px)` | float | 1 .. 64 | 5.76 |
| `roots/glitch/bright first` | bool | -- | 1 |
| `roots/glitch/colour levels` | float | 2 .. 32 | 6.666 |
| `roots/glitch/crush` | float | 0 .. 1 | 0 |
| `roots/glitch/crush dither` | float | 0 .. 2 | 1.235 |
| `roots/glitch/live feed` | float | 0 .. 0.5 | 0.049 |
| `roots/glitch/macroblock (px)` | float | 1 .. 64 | 32.36 |
| `roots/glitch/mosh (hold)` | bool | -- | 0 |
| `roots/glitch/mosh amount` | float | 0 .. 1 | 1 |
| `roots/glitch/passes-frame` | int | 1 .. 8 | 1 |
| `roots/glitch/sort` | bool | -- | 0 |
| `roots/glitch/sort amount` | float | 0 .. 1 | 1 |
| `roots/glitch/trigger length (s)` | float | 0.1 .. 10 | 4.522 |
| `roots/glitch/vector freeze (s)` | float | 0 .. 8 | 2.258 |
| `roots/glitch/vector gain` | float | 0 .. 6 | 4.399 |
| `roots/growth/anchor on axis` | bool | -- | 1 |
| `roots/growth/anchor pitch` | float | 0 .. 85 | 60 |
| `roots/growth/anchor spawn` | float | 0 .. 6 | 1.5 |
| `roots/growth/basal clear` | float | -1 .. 10 | 2 |
| `roots/growth/cone height` | float | 24 .. 96 | 65 |
| `roots/growth/cone radius` | float | 6 .. 24 | 13 |
| `roots/growth/crawl the cone surface` | bool | -- | 1 |
| `roots/growth/days - step` | float | 0.05 .. 3 | 0.2 |
| `roots/growth/dwell` | float | 0 .. 1 | 0.92 |
| `roots/growth/dwell days` | float | 2 .. 60 | 16.809 |
| `roots/growth/dwell lateral` | float | 0 .. 1 | 0.92 |
| `roots/growth/ease days` | float | 0 .. 60 | 5 |
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
| `roots/growth/masks` | int | 1 .. 24 | 6 |
| `roots/growth/motion cavity` | float | 0 .. 1.5 | 1 |
| `roots/growth/nest behind` | float | -5 .. 15 | 0 |
| `roots/growth/nest hit radius` | float | 0 .. 6 | 1.5 |
| `roots/growth/nest per ring` | int | 3 .. 16 | 8 |
| `roots/growth/nest rings` | int | 1 .. 6 | 3 |
| `roots/growth/old hops alive` | int | 0 .. 5 | 1 |
| `roots/growth/old hops rate` | float | 0 .. 1 | 0.11 |
| `roots/growth/pattern` | string | -- | phyllotaxis |
| `roots/growth/pull reach` | float | 0.4 .. 3 | 1.2 |
| `roots/growth/reach x` | float | 0.4 .. 4 | 1.6 |
| `roots/growth/root types` | int | 1 .. 3 | 1 |
| `roots/growth/seed` | int | 0 .. 1.07374e+09 | 2 |
| `roots/growth/shell` | float | 1 .. 20 | 3.6 |
| `roots/growth/spawn behind` | float | 0 .. 10 | 1.5 |
| `roots/growth/species` | string | -- | Brassica_oleracea_Vansteenkiste_2014.xml |
| `roots/growth/spiral drift` | float | -0.5 .. 0.5 | 0 |
| `roots/growth/spiral x golden` | float | 0.2 .. 2 | 1 |
| `roots/growth/steps-frame` | int | 1 .. 30 | 1 |
| `roots/growth/taper` | float | 0.4 .. 2.5 | 1 |
| `roots/growth/target lift` | float | -10 .. 10 | 0 |
| `roots/growth/travel pull` | float | 0 .. 1 | 0.681 |
| `roots/growth/travel slack` | float | 1 .. 4 | 2.5 |
| `roots/growth/travel trials` | float | 1 .. 60 | 14 |
| `roots/growth/tree relay` | bool | -- | 0 |
| `roots/growth/tube radius` | float | 2 .. 20 | 7 |
| `roots/growth/type 2 dwell` | float | 0 .. 1 | 0.92 |
| `roots/growth/type 2 dwell days` | float | 2 .. 60 | 18 |
| `roots/growth/type 2 dwell lateral` | float | 0 .. 1 | 0.92 |
| `roots/growth/type 3 dwell` | float | 0 .. 1 | 0.92 |
| `roots/growth/type 3 dwell days` | float | 2 .. 60 | 18 |
| `roots/growth/type 3 dwell lateral` | float | 0 .. 1 | 0.92 |
| `roots/growth/view cylinder` | float | 1 .. 30 | 8 |
| `roots/lens & film/anamorphic streak` | float | 0 .. 1 | 0 |
| `roots/lens & film/barrel <-> pincushion` | float | -0.4 .. 0.4 | -0.007 |
| `roots/lens & film/chromatic aberration` | float | 0 .. 8 | 1.53 |
| `roots/lens & film/contrast` | float | 0.5 .. 2 | 1 |
| `roots/lens & film/distortion (corners)` | float | -0.2 .. 0.2 | 0.001 |
| `roots/lens & film/distortion re-crop` | float | 0.6 .. 1.2 | 1.005 |
| `roots/lens & film/focal length (mm)` | float | 8 .. 135 | 21.734 |
| `roots/lens & film/fov (rad, half-angle)` | float | 0.15 .. 1.2 | 0.6 |
| `roots/lens & film/gain` | rgb | -- | 1 1 1 |
| `roots/lens & film/gamma` | rgb | -- | 1 1 1 |
| `roots/lens & film/grain` | float | 0 .. 0.12 | 0.03 |
| `roots/lens & film/grain chroma` | float | 0 .. 1 | 0.25 |
| `roots/lens & film/grain size (px)` | float | 1 .. 6 | 1.6 |
| `roots/lens & film/halation` | float | 0 .. 1 | 0.409 |
| `roots/lens & film/halation spread (mip)` | int | 0 .. 4 | 3 |
| `roots/lens & film/halation tint` | rgb | -- | 1 0.42 0.2 |
| `roots/lens & film/highlight tint` | rgb | -- | 1.08 1 0.9 |
| `roots/lens & film/lift` | rgb | -- | 0 0 0 |
| `roots/lens & film/saturation` | float | 0 .. 2 | 1 |
| `roots/lens & film/set FOV by focal length` | bool | -- | 1 |
| `roots/lens & film/shadow tint` | rgb | -- | 0.88 0.95 1.14 |
| `roots/lens & film/split balance (-1 off)` | float | -1 .. 1 | 0.45 |
| `roots/lens & film/split strength` | float | 0 .. 1 | 0.357 |
| `roots/lens & film/streak length` | float | 2 .. 60 | 16.436 |
| `roots/lens & film/streak tint` | rgb | -- | 0.55 0.72 1 |
| `roots/material/ambient` | float | 0 .. 0.5 | 0.06 |
| `roots/material/base color` | rgb | -- | 0.55 0.42 0.28 |
| `roots/material/base color 2` | rgb | -- | 0.28 0.18 0.12 |
| `roots/material/color noise` | float | 0 .. 1 | 0.6 |
| `roots/material/diffuse` | float | 0 .. 1.5 | 0.55 |
| `roots/material/metallic` | float | 0 .. 1 | 0.05 |
| `roots/material/radius scale` | float | 0.2 .. 4 | 1.5 |
| `roots/material/roughness` | float | 0.05 .. 1 | 0.8 |
| `roots/material/shininess` | float | 4 .. 300 | 150 |
| `roots/overlays/axes` | bool | -- | 0 |
| `roots/overlays/grid` | bool | -- | 0 |
| `roots/overlays/grid spacing` | float | 1 .. 20 | 5 |
| `roots/pluck flash/flash all masks` | bool | -- | 0 |
| `roots/pluck flash/flash color` | rgb | -- | 0.710784 0.354162 0.292676 |
| `roots/pluck flash/flash decay (s)` | float | 0.05 .. 4 | 0.27 |
| `roots/pluck flash/flash depth` | float | -1 .. 2 | -0.02 |
| `roots/pluck flash/flash intensity` | float | 0 .. 60 | 32.133 |
| `roots/pluck flash/flash mask 0` | bool | -- | 0 |
| `roots/pluck flash/flash nearest mask` | bool | -- | 1 |
| `roots/pluck flash/flash radius` | float | 0.2 .. 12 | 1.111 |
| `roots/pluck flash/glitch amount` | float | 0 .. 1 | 1 |
| `roots/pluck flash/glitch duration (s)` | float | 0.05 .. 4 | 1.375 |
| `roots/pluck flash/glitch mask` | bool | -- | 1 |
| `roots/pluck flash/glitch noise` | float | 0 .. 2 | 1.418 |
| `roots/pluck flash/glitch noise share` | float | 0 .. 1 | 0.018 |
| `roots/pluck flash/glitch swaps mask` | bool | -- | 1 |
| `roots/post/DoF focus (0-auto)` | float | 0 .. 120 | 0 |
| `roots/post/DoF focus ease (s)` | float | 0 .. 2 | 0.4 |
| `roots/post/DoF range` | float | 5 .. 150 | 90.389 |
| `roots/post/DoF strength` | float | 0 .. 1 | 0.627 |
| `roots/post/TAA blend` | float | 0.02 .. 1 | 0.225 |
| `roots/post/TAA clip` | float | 0 .. 3 | 1.2 |
| `roots/post/TAA jitter` | float | 0 .. 1 | 1 |
| `roots/post/TAA sharpen` | float | 0 .. 1 | 1 |
| `roots/post/bloom` | bool | -- | 0 |
| `roots/post/bloom intensity` | float | 0 .. 1 | 0.047 |
| `roots/post/bloom radius` | float | 0.5 .. 3 | 0.635 |
| `roots/post/bloom threshold` | float | 0.2 .. 4 | 1.214 |
| `roots/post/depth of field` | bool | -- | 0 |
| `roots/post/exposure` | float | 0.1 .. 4 | 1.001 |
| `roots/post/filmic tonemap` | bool | -- | 1 |
| `roots/post/fog dither` | float | 0 .. 1 | 1 |
| `roots/post/output dither` | bool | -- | 1 |
| `roots/post/post chain` | bool | -- | 1 |
| `roots/post/supersample` | int | 1 .. 3 | 3 |
| `roots/post/temporal AA` | bool | -- | 1 |
| `roots/post/vignette` | float | 0 .. 1 | 0.22 |
| `roots/travelling pulses/pulse color` | rgb | -- | 0.47549 0.0815792 0.0815792 |
| `roots/travelling pulses/pulse intensity` | float | 0 .. 4 | 1.253 |
| `roots/travelling pulses/pulse spacing` | float | 4 .. 60 | 60 |
| `roots/travelling pulses/pulse speed` | float | 0 .. 40 | 13.511 |
| `roots/travelling pulses/pulse width` | float | 0.5 .. 12 | 3.286 |
| `roots/travelling pulses/pulses on` | bool | -- | 1 |

## debug (8 parameters)

| parameter | type | range | value |
|---|---|---|---|
| `debug/camera overlay` | bool | -- | 1 |
| `debug/corner` | int | 0 .. 3 | 1 |
| `debug/input corner` | int | 0 .. 3 | 3 |
| `debug/input size` | int | 160 .. 640 | 260 |
| `debug/landmarks` | bool | -- | 1 |
| `debug/network input` | bool | -- | 1 |
| `debug/size` | int | 160 .. 640 | 298 |
| `debug/untrained dim` | float | 0 .. 1 | 0.22 |

## Retired

2 parameter(s) are marked retired: still loaded, still
saved, not drawn unless **show retired** is ticked. That is how a control
leaves the panel without breaking a preset that mentions it. To delete one
for good, remove the declaration and the key from every preset file.

