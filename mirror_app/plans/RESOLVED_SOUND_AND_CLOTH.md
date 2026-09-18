# Resolved chord through the cloth, and a cloth that just falls

Two independent tasks, run sequentially because both touch `src/main.mm`.
Build from the repo root: `cmake --build build --target mirror_app -j$(sysctl -n hw.logicalcpu)`.
Keep changes simple and to the point; match the surrounding comment style.

## Background

The show's phases are Idle -> Fitting -> Transition -> Roots. In Transition the
pond (neural mirror) is the film of a cloth pinned flat across the frame; the
cloth lets go and falls off the anchor mask (the visitor's face), then the
Roots sequence runs Face -> Grow -> Turn -> Orbit -> Outro
(`src/root_sequence.h`). RootScene renders continuously from Transition entry.
"Face" is the stage where the mask is captured/held; it ends when the mouth is
forced open (`RootSequence::mouthOpenRamp`, 0..1, 0 until the ramp starts) and
the root grows out of it.

Audio is Wwise (`src/wwise_audio.h/.cpp`, `src/chord.h`). `AudioParams` is
pushed once a frame from main.mm's audio block (~line 2900-2990); phase-edge
events are posted in the `switch (p)` at ~line 2726. The pad (chord) is
`Play_Pad`/`Stop_Pad`; its harmony is the `ChordStage` state (Stage0..Stage4,
Stage4 = the resolved major); `g_chord.resolve()` is already called at the
Transition entry so Stage4 is held from there. The pluck (FirePlucker) rings
throughout; its pitch is the `Comb_Tuning` RTPC (`AudioParams::comb_hz`, Hz,
20..2000) on the `Metallic_Ring` comb effect. Pluck marker hits are polled at
~line 3140 (`pluckHits`, after the audio block -- one frame of latency is fine).

Two RTPCs were just added in Wwise and are in the regenerated Mac bank:
- `Comb_Glide` (0..2000, ms) -> Metallic_Ring's Glide (the pluck's portamento). Authored default 265.
- `FlangerMix` (0..100) -> Mirror_Pad_Flanger's WetDryMix. Authored default 54.

---

## Task 1 (sound): the resolved chord rides through the cloth and the face capture

Files: `src/wwise_audio.h`, `src/wwise_audio.cpp`, `src/app_state.h`, `src/app_state.mm`, `src/main.mm`, `src/panel.mm`.

1. `AudioParams` gains `float comb_glide_ms = 265.f;  // 0..2000` and
   `float flanger_mix = 54.f;  // 0..100`; `WwiseAudio::update` pushes them as
   `SetRTPCValue("Comb_Glide", ...)` / `SetRTPCValue("FlangerMix", ...)` next to
   Comb_Tuning/FlangerRate. Add both to the header's RTPC list comment.

2. Define the **resolved window** in main.mm: from the Transition entry until
   the mouth starts to open. Concretely, each frame:
   `resolved = (phase == Transition || (phase == Roots && rootSeqActive && rootSeq.valid() && rootSeq.stage() == RootSequence::Stage::Face)) && mouthRamp <= 0`
   where `mouthRamp = rootSeq.valid() ? rootSeq.mouthOpenRamp(rootsClock, g_root_seq) : 0` (`rootSeq` is declared at ~line 1560, `rootsClock` ~1616, both before the audio block).
   Keep a `static bool wasResolved` to detect the edges.

3. While `resolved`:
   - The pad keeps playing: **remove** the `Stop_Pad` posts in the
     `Phase::Transition` and `Phase::Roots` cases of the entry switch (leave the
     one in `Phase::Idle`). Update those cases' comments.
   - The pluck does NOT drop to `kTransitionCombHz` (25 Hz); instead it
     arpeggiates the final chord: keep `static int arpStep`; on each pluck
     marker hit (the `pluckHits` loop at ~3140) advance `arpStep`. The note is
     `g_chord.effectiveRoot() + kArp[arpStep % 4]` with `kArp = {16, 19, 24, 28}`
     (3rd, 5th, octave, 3rd -- the last is exactly the resolved pluck note,
     so the arpeggio spans one octave ending where the pluck already sits at
     Stage4). `comb_hz = 440 * 2^((note - 69) / 12)`. Reset `arpStep = 0` on the
     window's entry edge. Gate the arpeggio on a panel bool `g_resolved_arp`
     (default true); with it off, comb_hz stays at the chord's Stage4 pluck
     note (`g_chord.voicing().comb_hz`, which is what `update()` gives while resolved).
   - `comb_glide_ms = g_resolved_glide_ms` (panel float, default 30, range 0..2000)
     so the steps land in tune. Outside the window `comb_glide_ms = 265`.
   - The flanger fades away: `flanger_mix = 54 * (1 - clamp(tResolved / g_resolved_flanger_fade_s))`
     where `tResolved` is seconds since the window's entry (accumulate `dt`;
     panel float, default 6 s, range 0.1..30). Outside the window `flanger_mix = 54`.
     Also hold `flanger_rate` at `g_flanger_rate_min` while resolved (fit_level
     is already 0 there, so this is likely already the case -- just make sure).

4. On the window's **exit edge** (mouth starts opening, or the phase leaves
   Transition/Roots-Face for any other reason): post `Stop_Pad` once, and from
   then on the existing behaviour applies -- `comb_hz = kTransitionCombHz` (25 Hz)
   through the rest of Roots, glide back to 265. Keep the existing 25 Hz
   override for Roots stages after Face. Idle entry still posts Stop_Pad (harmless double).

5. Panel (`src/panel.mm`): find the existing audio section with the flanger
   min/max sliders (`g_flanger_rate_min`) and add, right after them, under a
   `ui::PushSection("resolved")` / header "resolved (cloth + face)":
   `ui::Checkbox("pluck arpeggio", &g_resolved_arp)`,
   `ui::SliderFloat("pluck glide (ms)", &g_resolved_glide_ms, 0, 2000)`,
   `ui::SliderFloat("flanger fade (s)", &g_resolved_flanger_fade_s, 0.1, 30)`.
   Declare the globals in app_state.h/.mm like `g_flanger_rate_min`. Controls
   must be declared unconditionally (never inside an `if`), see PANEL.md.

6. Also handle the panel's "audio" section if it lists RTPC names anywhere (grep `FlangerRate` in panel.mm).

Verify: build clean; `grep -n "Stop_Pad" src/main.mm` shows the Idle post and
the new exit-edge post only. Run `./build/mirror_app/mirror_app --help` if it
exists, otherwise just the build. Report the line numbers of the window logic.

---

## Task 2 (cloth): keep the pond live until the release, and drop the press

Files: `src/main.mm` (Transition scene branch ~line 3590), `src/root_scene.h`,
`src/root_scene.mm` (`advanceCloth` ~1843, `clothPress`/`clothRelease`/
`clothDone`/`clothPhaseName` ~1411-1460, `ensureClothSheet` ~1504, and the
`relT0` use ~1935), `src/panel.mm` (cloth timing sliders ~3627),
`src/dev_tools.mm` (~2038 and ~2256), `presets/look/default.look`.

1. **Pond keeps training until the release.** In main.mm's
   `scene == Scene::Transition` branch the mirror is advanced and rendered
   without training (`mirror.advance(dt); roots.setPondTexture(mirror.render());`).
   Change it to: while `roots.clothPinned() && !rootHold` use
   `roots.setPondTexture(renderMirror())` (the lambda at ~3171 that trains and
   renders -- it also samples face colours, which the branch's
   `uploadFaceColorsIfFresh()` already expects); otherwise keep the current
   two lines. Update the branch comment ("Its training is left alone..." is no
   longer true: it trains until the pins let go, then the film freezes for the fall).

2. **No press.** The cloth timeline becomes hold -> release -> fall. Remove
   `press` and `settle` from `RootScene::ClothTiming`, remove `clothPressProud`,
   remove `clothPress()`. In `advanceCloth`: the anchor mask sits at `retract`
   (the existing computation -- its frontmost point just behind the sheet's
   rest plane) for the whole hold and release, and eases to its resting
   placement (offset 0) over the fall:
   `clothPressOffset_ = retract * (1 - smoothstep01(clamp((t - hold - release) / fall, 0, 1)))`.
   Keep the retract/restFront computation and its comments; rewrite the press
   comment block to say what now happens. `clothExtentFrozen_` freezes at the
   end of hold as it does now. Fix every `hold + press + settle` sum
   (`clothRelease`, `clothDone`, the ceiling, `clothPhaseName` -- phases are
   now "hold", "release", "fall", "done" -- and `relT0`).
   `clothPinned()` is unchanged (`clothRelease() <= 0`).

3. Panel: drop the "press", "settle" and "press depth" (clothPressProud)
   sliders and the press/settle lines of the tooltip. dev_tools: fix the two
   references (the timing array becomes 3 entries; the trace prints
   `clothRelease()` instead of `clothPress()`). Remove the `cloth/press`,
   `cloth/settle`, `cloth/press depth` lines from `presets/look/default.look`
   (and from any other `presets/look/*.look`). Leave `src/transition_scene.*`
   (the old standalone scene) untouched.

4. `clothTiming.hold` default stays 0.5 s; the release and fall defaults stay.

Verify: build clean, then
`cd mirror_app && ../build/mirror_app/mirror_app --clothshot /private/tmp/claude-501/-Users-erichan-Documents-Development-jardins-racine/f39022f6-61c6-4c16-8e3f-f53d290aa1b2/scratchpad/cloth.ppm`
(check `--clothshot`'s exact arguments in `src/main.mm`/`src/dev_tools.mm` first) renders without error.
Report what the trace line prints for the phases.
