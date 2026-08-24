# tools

Offline scripts, run by hand — not part of the CMake build.

- `export_face_basis.py` — face-tracking asset export (see the file header).
- `embed_pluck_markers.py` — detects loud crackle onsets in
  `../../WwiseProject/Originals/SFX/NHU05008080.wav` (the `FirePlucker` source)
  and embeds them as WAV cue markers, each labeled with the hit's 0..1
  strength. Wwise picks these up as Markers on refresh; `WwiseAudio` reads
  them back at runtime (`postFirePlucker()` / `pollFirePluckerMarkers()` in
  `../src/wwise_audio.{h,cpp}`) to drive pluck-triggered raindrops in
  `main.mm`. Re-run after retuning `MIN_STRENGTH`/`SENSITIVITY` etc., then in
  Wwise Authoring: refresh the audio file and regenerate SoundBanks — see
  `../../WwiseProject/README.md`.
