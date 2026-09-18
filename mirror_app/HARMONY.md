# The pad progression, and the pluck that climbs it

What the mirror phase plays, stage by stage, with the show preset's numbers
(`presets/show/default.show`) filled in. For tweaking: every number here
says where it lives.

## One note per visitor

Everything is tuned from **N**, drawn once per visitor at the Roots -> Idle
edge and held for the whole sitting:

    N = pluck centre + offset,   offset uniform in 0 .. offset range

| knob | where | show preset |
|---|---|---|
| pluck centre (MIDI) | panel `sound`, `Chord::Config::pluck_center_note` | 79 (G5, 784 Hz) |
| offset range (semitones) | panel `sound`, `pluck_offset_max_semitones` | 5 |

So N is G5 .. C6. Only ever *up* from the centre -- the room sounds wrong flat.

The chord's root is N dropped by `chord octave` octaves:

| knob | where | show preset |
|---|---|---|
| chord octave | panel `sound`, `chord_octave` | -3 |

With -3 the root is **N - 36**: G2 (98 Hz) for a G5 visitor. That is
`effectiveRoot()`.

What Wwise is told: `Key` = N - 36 (`keyNote()`, the pad's pitch base, also
reaches the pluck) and `PadOctave` = 12 x chord octave + 36 (`padOctave()`,
0 with the preset). `Comb_Tuning` carries the pluck's Hz directly.

## The pad: five checkpoints

Four voices, each a Macro Oscillator, at these semitones above the root.
The table lives in two places that **must agree**: `src/chord.cpp`
`kOffsets` (what the pluck snaps to, and the panel's readout) and the
`ChordStage` state's per-voice Pitch on `Mirror_Pad/Pad_V1..V4` in Wwise
(what actually sounds; in cents, so 1000 = 10).

| stage | reached at fit | name (root C) | V1 | V2 | V3 | V4 | what moves |
|---|---|---|---|---|---|---|---|
| 0 | start | Cm7(b13) | 0 | 10 (b7) | 15 (b3) | 22 (b6) | dark, stacked |
| 1 | 0.25 | Cm9 | 0 | 10 | 15 | **26 (9)** | the top opens to the 9th |
| 2 | 0.50 | Cm(add9) | 0 | **7 (5)** | 15 | 26 | the b7 resolves to the 5th |
| 3 | 0.75 | Cmaj9 | 0 | 7 | **16 (3)** | 26 | b3 -> 3, the turn |
| 4 | 0.95 | Cmaj | 0 | 7 | 16 | **28 (3)** | 9 -> 3, wide and open |

Read down a column for a voice's path: V1 never moves, V2 makes one move,
V3 makes the one that matters, V4 opens out twice.

| knob | where | show preset |
|---|---|---|
| thresholds[1..4] | `Chord::Config::thresholds` (not on the panel) | 0.25 0.50 0.75 0.95 |
| checkpoint hysteresis | panel `sound`, `hysteresis` | 0.03 |

A stage advances when fit >= threshold + hysteresis and retreats when fit <
threshold - hysteresis (the fit is a live loss and can get worse). The
resolved window (Transition entry) calls `resolve()`: stage 4 whatever the
fit, held until the next visitor's `reset()`.

The glide between stages is Wwise's: the `ChordStage` State Group's
transition time.

## The pluck's target note

Pinned on N through the idle wait (fit at 0). Once the fit is moving it is
lifted by the checkpoint: stage s of 4 puts its *linear* target s/4 of the
way up `pluck climb`, and that is snapped to the nearest tone of the
current chord (any octave). Then the octave sliders shift the comb alone:

| knob | where | show preset |
|---|---|---|
| pluck climb (semitones) | panel `sound`, `pluck_climb` | 6 |
| pluck idle octave | panel `sound`, `pluck_idle_octave` | +1 |
| pluck fitting octave | panel `sound`, `pluck_fit_octave` | +1 |

With the preset, what the pluck actually rings:

| stage | linear target | nearest chord tone | pluck rings | interval over N |
|---|---|---|---|---|
| idle (fit 0) | -- | N | **N + 12** | octave |
| 0 (fit > 0) | N + 0 | root (0) | **N + 12** | octave |
| 1 | N + 1.5 | 9th (+2) | **N + 14** | 9th |
| 2 | N + 3 | b3 (+3) | **N + 15** | minor 3rd |
| 3 | N + 4.5 | 3 (+4) | **N + 16** | major 3rd |
| 4 | N + 6 | 5th (+7) | **N + 19** | fifth |

So the pluck walks root -> 9 -> b3 -> 3 -> 5, an octave above the visitor,
and the b3 -> 3 turn at stage 3 is heard in the pluck as well as the pad.

Notes for tweaking:

- The snap always wins over the climb: only the chord's own tones are
  reachable. To hear a different tone at a stage, move the linear target
  nearer to it (the climb) or change the tone (both tables).
- The original design had climb = 16: stage 4 then lands on +16, the
  resolved chord's top voice (V4 = 28, two octaves under it). At 6 it
  stops on the fifth.
- Idle -> fitting is by fit level, not phase: the first frames of Fitting
  before the pond trains are still "idle". With both octave sliders equal
  nothing steps at that edge.
- Ceiling: `Comb_Tuning` stops at 4000 Hz (MIDI ~111). N max 84, +12 +7 =
  103, fine; +2 octaves would clip the top stages.
- `pad octave (semitones)` on the panel (`Config::octave`, -36) only moves
  the panel's diagnostic `note[]` readout -- the pad's own register is
  Wwise's `Key -> Pitch` curve on `Pad_V1..V4\Osc`, and the b7 above.

## After the resolution: the harp

While the resolved window holds (Transition entry until the mouth opens)
the pluck is muted and a head turn strums `strum scale` over N + 12 x
`strum octave` (preset: lydian, +1) -- see `plans/STRUM.md` and the
`resolved (cloth + face)` panel section. The send-off plucks every string
and slides them to 20 Hz.

## Two things in the Wwise project (as of 2026-09-18)

1. `Play_Pad` plays **both** `Mirror_Pad` and `Mirror_Pad_01` (and the
   shepherd). `Mirror_Pad_01` carries a different `ChordStage` table --
   stage 0 = 0/19/22/27, stage 1 moves V1 to +6 (a tritone), stage 4 =
   0/31/35/16 -- so two chords sound at once, and the pluck snaps only to
   `Mirror_Pad`'s.
2. `Stop_Pad` stops `Mirror_Pad` and the shepherd but **not**
   `Mirror_Pad_01`, which keeps ringing after the window closes.

If `_01` is the progression being tried, retarget the two events to it and
copy its table into `kOffsets`; if it is a leftover, delete its action.
