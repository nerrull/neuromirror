# The resolved window's strum: its own source, its own timing, triggered by the head

One task. Build from the repo root:
`cmake --build build --target mirror_app -j$(sysctl -n hw.logicalcpu)`.
Keep changes simple and to the point; match the surrounding comment style.

## Background

Read `plans/RESOLVED_SOUND_AND_CLOTH.md` (Task 1) first -- it describes the
resolved window (`resolvedWindowActive` in `src/main.mm`, ~line 1569 for the
declarations, ~2996-3045 for the window logic) and how the arpeggio currently
works: `comb_hz` on the FirePlucker's comb steps through `kArp` on every pluck
marker hit (`resolvedArpStep`, advanced in the `pluckHits` loop ~3226). That
retunes the *one* ringing pluck, so it is monophonic and tied to the marker
rhythm. It goes away.

New Wwise objects, already in the regenerated Mac bank:
- Event `Play_Strum`: a one-shot -- a single click cut from the FirePlucker
  sample, through its own comb (`Strum_Ring`, an actor-mixer effect on the
  `Strum` sound, so **every voice has its own comb instance**) onto `StrumBus`
  (reverb + ceiling, no shared comb). Posting it does not touch the
  FirePlucker's `Comb_Tuning`.
- RTPC `Strum_Tuning` (20..4000 Hz, no glide) -> `Strum_Ring`'s frequency.
  Because the comb is per voice, the RTPC is read **per game object**: set it
  on a game object, post `Play_Strum` on that same object, and the note rings
  at that pitch while later posts on other objects ring at theirs.

## Changes

Files: `src/wwise_audio.h`, `src/wwise_audio.cpp`, `src/app_state.h`,
`src/app_state.mm`, `src/main.mm`, `src/panel.mm`.

1. `WwiseAudio::postStrum(float hz)`: a pool of strum game objects
   (`kStrumObjBase = 200`, `kStrumVoices = 8`, registered in `init` next to
   `kRacineObj`, unregistered in `term` if the others are). Round-robin: pick the
   next object, `SetRTPCValue("Strum_Tuning", hz, obj)` then
   `PostEvent("Play_Strum", obj)`; `++posted_`. No-op when `!ready_`. Add
   `Strum_Tuning` / `Play_Strum` to the header's RTPC/event list comments.
   Declare it in the header next to `postFirePlucker()` with a short comment
   saying why it has its own objects (per-voice pitch).

2. main.mm, the resolved window. Remove the marker-driven arpeggio entirely:
   `resolvedArpStep`, its declaration comment (~1562-1568, rewrite to describe
   what is still shared), the `pluckHits` advance (~3222-3227) and the `kArp`
   `comb_hz` branch. While the window holds, `ap.comb_hz` is simply
   `g_chord.voicing().comb_hz` (the Stage4 pluck note, what `update()` already
   gives) and `ap.comb_glide_ms = g_resolved_glide_ms` stays as is (it still
   tunes the FirePlucker's landing). Drop `g_resolved_arp` (app_state + panel).

3. The strum, in the same `if (resolvedWindowActive)` block (it has `dt`,
   `ap.movement` and `g_chord`). Model: a harp -- a head movement sweeps the
   strings.
   - Notes: `static const int kStrumTones[] = {0, 4, 7, 12, 16, 19, 24}` semitones
     above `g_chord.visitorNote()` (the pluck's own register -- see the comment
     that is there now about `chord octave`). Hz = `440 * 2^((note - 69) / 12)`.
   - State (declared next to `tResolvedWindow`): `int strumNote = -1` (index of
     the next note to fire, -1 = no strum running), `float strumNextAt = 0`
     (window time of the next note), `float strumLastAt = -1e9` (window time
     the last strum started), `bool strumDown = false`.
   - Trigger: `ap.movement > g_strum_threshold` while `strumNote < 0` and
     `tResolvedWindow - strumLastAt >= g_strum_gap_s` starts a strum:
     `strumNote = 0`, `strumNextAt = tResolvedWindow`, `strumLastAt = tResolvedWindow`,
     and if `g_strum_alternate` flip `strumDown` (a down-strum plays the tones
     in reverse order).
   - Playback: while `strumNote >= 0 && tResolvedWindow >= strumNextAt`, post
     the current tone (`g_audio.postStrum(hz)`, gated on `g_audio_on`), advance
     `strumNote`, `strumNextAt += g_strum_spacing_ms / 1000`; when `strumNote`
     reaches `g_strum_notes` set it to -1. A `while` so a long frame can't
     lose a note. Notes beyond the array's length clamp to its last entry.
   - Reset the state on the window's entry edge (where `tResolvedWindow = 0`).

4. Globals (app_state.h/.mm, declared like `g_resolved_glide_ms`):
   `g_strum_threshold = 0.25f` (0..1), `g_strum_gap_s = 1.5f` (0.1..10),
   `g_strum_spacing_ms = 70.f` (10..500), `g_strum_notes = 7` (1..7),
   `g_strum_alternate = true`.

5. Panel (`src/panel.mm`, the `resolved (cloth + face)` header ~2164): replace
   the `pluck arpeggio` checkbox with, in order:
   `ui::SliderFloat("strum threshold", &g_strum_threshold, 0.f, 1.f)`,
   `ui::SliderFloat("strum gap (s)", &g_strum_gap_s, 0.1f, 10.f)`,
   `ui::SliderFloat("strum spacing (ms)", &g_strum_spacing_ms, 10.f, 500.f)`,
   `ui::SliderInt("strum notes", &g_strum_notes, 1, 7)`,
   `ui::Checkbox("strum alternates", &g_strum_alternate)`.
   Keep the glide and flanger sliders. Update the tooltip that mentions the
   arpeggio (~2170) to describe the strum: the head sweeps the strings of the
   resolved chord, movement above the threshold starts a run, its own source
   so it never retunes the pluck. Controls must be declared unconditionally
   (never inside an `if`), see PANEL.md. If a `ui::SliderInt` does not exist,
   use whatever the panel uses for ints (grep `SliderInt` in panel.mm).

6. `grep -rn "resolved_arp\|resolvedArpStep\|kArp\b" src/` must come back empty.
   Check `presets/show/default.show` and `presets/*/*.{look,fit,roots,show}`
   for a `pluck arpeggio` line and remove it if present.

Verify: build clean. Report the line numbers of the strum block and the
`postStrum` implementation.
