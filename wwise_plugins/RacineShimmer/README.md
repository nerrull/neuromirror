# Racine Shimmer

A Wwise effect plug-in: a reverb with a pitch shifter in its feedback loop.
Built for the strum on `StrumBus` -- each pluck blooms upward into octaves
behind itself.

## What it does

```
in --+--> diffusers --> FDN tank --+--> wet
     ^                             |
     +--- Shimmer * clip(LP(HP(pitch shift))) <---+
```

The tank is an 8-line feedback delay network (Householder mixing, per-line
decay gain and damping lowpass) behind four series allpasses. Its output goes
through a two-head granular pitch shifter (80 ms window, sine crossfade) and
back into the input, so every pass round the loop lands another **Pitch**
higher: +12 is the classic octave climb, +7 stacks fifths, negative sinks.

**Decay** is the tank's own T60. **Shimmer** is the gain of the pitched
return, and the two together set what the tail does: with a 2 s Decay the loop
gain crosses unity around Shimmer 60-70%, and 100% holds indefinitely. Nothing
runs away because the pitched path and the tank lines are soft-clipped -- the
bloom that comes from leaning on that clip is the sound.

## Parameters

| Property | Range | Default | Notes |
|---|---|---|---|
| Decay | 0.2 – 20 s | 4 | T60 of the tank alone. |
| Damping | 0 – 100 % | 30 | Lowpass in the tank and on the shimmer path, 20 kHz down to 1 kHz. Keeps the stacked octaves from turning to glass. |
| Shimmer | 0 – 100 % | 50 | Gain of the pitched feedback. |
| Pitch | −12 – 24 st | 12 | Interval per pass. Exclusive RTPC. |
| Wet/Dry Mix | 0 – 100 % | 40 | |
| Output Level | −24 – 24 dB | 0 | |

All six are RTPC-able. Decay and damping step at buffer boundaries (inaudible
inside a reverb); the gains ramp across the buffer.

## Design notes

**The tank is mono.** The channels are averaged into it and each channel takes
its own four lines back out (left the even ones, right the odd), so the sides
differ by their delays. Cheap, and a strum is mono to begin with.

**The pitched path needs gain.** The output tap sums four lines whose phases
do not agree, so the tank returns about half of what it is fed; the shimmer
return is scaled ×2 before its clip so that Shimmer maps onto something like
loop gain (`kShimmerGain` in the DSP).

**Tail.** `TailFrames` is a heuristic -- Decay stretched by Shimmer, capped at
30 s -- since the clip makes the true decay depend on level. On a bus that only
decides how long the bus stays alive after its last voice.

## Layout

Same shape as [Racine Comb](../RacineComb/README.md): `SoundEnginePlugin/RacineShimmerDSP.{h,cpp}`
is the DSP with no Wwise headers, `RacineShimmerFX.{h,cpp}` the Wwise wrapper,
`RacineShimmerFXParams.{h,cpp}` the parameter block, `WwisePlugin/` the
authoring side. Parameter order must agree between `RacineShimmerFXParams.h`,
`SetParamsBlock` and `RacineShimmerPlugin::GetBankParameters`.

## Tests

```sh
cd ..    # wwise_plugins/
c++ -std=c++17 -O2 -I. tests/shimmer_response_test.cpp \
    RacineShimmer/SoundEnginePlugin/RacineShimmerDSP.cpp -o shimmer_response_test
./shimmer_response_test
```

Checks that a 440 Hz burst comes back with an octave (or a fifth) in its tail
that the plain reverb did not have, that the tail decays with Shimmer off and
sustains at 100%, that the top of every range stays bounded, and that a
parameter jump does not click. Writes `shimmer_octave.wav` for ears.
