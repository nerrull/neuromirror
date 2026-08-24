# WwiseProject

The audio project for `mirror_app`. See that app's
[`../mirror_app/README.md`](../mirror_app/README.md#sound) for the full picture
of what the project holds and how it's used at showtime (short version: this
project's engine is *embedded* in `mirror_app`, not run through Authoring — the
app loads `GeneratedSoundBanks/Mac/{Init,Racine}.bnk` directly and needs no
Wwise install to run).

## Editing this project

Wwise Authoring on this Mac is the Windows build running under CrossOver
(`WwiseProject.crossover.wsettings`) — that's also why paths in WAAPI results
look like `Y:\...`. It can be driven live over WAAPI (an MCP server is wired up
for this in Claude Code sessions: `mcp__wwise__execute_plan`); useful for
inspecting/editing the live project, but nothing here depends on Authoring
staying open — see the embedding rationale above.

After any change (new event, new marker, edited bus), **SoundBanks must be
regenerated** (Mac at minimum) for `mirror_app` to see it.

## Layout

Standard Wwise work-unit folders (`Busses/`, `Containers/`, `Events/`, `Game
Parameters/`, `States/`, ...) plus:

- `Originals/SFX/` — source audio, git-lfs tracked. `NHU05008080.wav` is the
  field recording behind `FirePlucker` (see below) — it carries WAV cue
  markers written by `../mirror_app/tools/embed_pluck_markers.py`, not
  authored by hand in Wwise.
- `GeneratedSoundBanks/{Mac,Windows}/` — build output `mirror_app` reads.
  `PluginInfo.json` here lists every plug-in a bank references; cross-check
  against the factory headers `mirror_app/src/wwise_audio.cpp` links, or a
  plug-in loads silently and plays nothing.

## Key objects (as of the last audit)

- **Busses**: `Mirror`, `Roots`, `Transition` under the main bus; `PluckBus`
  carries `FirePlucker` (see below) plus `Rain_A`/`Rain_B` (pitched textures,
  under `Racine > Mirror > Amb_Mirror > Mirror_Textures`). No dedicated "Rain"
  bus exists — rain content shares `PluckBus`.
- **`FirePlucker`** (`Containers/Default Work Unit.wwu`) — the looping sound
  behind `Play_FirePlucker`/`Stop_FirePlucker`, posted on entering both the
  Idle and Fitting phases (mirror_app's "pluck bed"). Source is
  `Originals/SFX/NHU05008080.wav`, pitch-shifted, Time-Stretched, with `Pitch`
  bound to the `FitLevel` RTPC. Its cue markers (loud-onset-only, see the
  Originals note above) drive `mirror_app`'s pluck-triggered raindrops.
- **`OnsetTap`** — a custom effect plug-in (`../wwise_plugins/OnsetTap`) for
  live transient detection on any bus, published to `mirror_app` over shared
  memory. Not currently inserted anywhere in this project; the
  marker-on-`FirePlucker` mechanism above was built instead for the
  pluck/raindrop use case. See `../wwise_plugins/README.md`'s Onset Tap
  section if a live/tunable-in-Authoring threshold is wanted for something
  else later.
