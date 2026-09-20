# The progression, tables only

Show preset numbers. N = pluck centre (79, G5) + offset (0..5), drawn per visitor.
Root = N - 36 (chord octave -3). See HARMONY.md for the rest.

## The pad (semitones above the root)

| stage | fit >= | chord (root C) | V1 | V2      | V3      | V4      | what moves               |
|-------|--------|----------------|----|---------|---------|---------|--------------------------|
| 0     | start  | Cm7(b13)       | 0  | 10 (b7) | 15 (b3) | 22 (b6) | dark, stacked            |
| 1     | 0.25   | Cm9            | 0  | 10      | 15      | 26 (9)  | the top opens to the 9th |
| 2     | 0.50   | Cm(add9)       | 0  | 7 (5)   | 15      | 26      | b7 -> 5th                |
| 3     | 0.75   | Cmaj9          | 0  | 7       | 16 (3)  | 26      | b3 -> 3, the turn        |
| 4     | 0.95   | Cmaj           | 0  | 7       | 16      | 28 (3)  | 9 -> 3, wide and open    |

Lives in: src/chord.cpp kOffsets  +  Wwise Mirror_Pad/Pad_V1..V4 ChordStage Pitch (cents).
Thresholds +/- hysteresis 0.03. resolve() = stage 4 regardless of fit.

## The pluck (climb 6, idle octave +1, fitting octave +1)

| stage        | linear target | nearest chord tone | pluck rings | over N    |
|--------------|---------------|--------------------|-------------|-----------|
| idle (fit 0) | --            | root (0)           | N + 12      | octave    |
| 0 (fit > 0)  | N + 0         | root (0)           | N + 12      | octave    |
| 1            | N + 1.5       | 9th (+2)           | N + 14      | 9th       |
| 2            | N + 3         | b3 (+3)            | N + 15      | minor 3rd |
| 3            | N + 4.5       | 3 (+4)             | N + 16      | major 3rd |
| 4            | N + 6         | 5th (+7)           | N + 19      | fifth     |

linear = N + stage/4 x climb, snapped to the nearest tone of that stage's chord (any octave), + 12 x octave slider.
