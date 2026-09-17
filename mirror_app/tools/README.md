# tools

Offline scripts, run by hand — not part of the CMake build.

- `export_face_basis.py` — face-tracking asset export (see the file header).
- `embed_pluck_markers.py` — finds the pops (the clicks above 2 kHz, where
  the bed's rumble cannot fake one) in
  `../../WwiseProject/Originals/SFX/NHU05008080.wav` (the `FirePlucker` source)
  and embeds them as WAV cue markers, each labeled with the click's 0..1
  strength. `--dry-run --sheet hits.png` draws every hit before anything is
  written; `visualize_pluck_onsets.py` is the same detector with sliders. Wwise picks these up as Markers on refresh; `WwiseAudio` reads
  them back at runtime (`postFirePlucker()` / `pollFirePluckerMarkers()` in
  `../src/wwise_audio.{h,cpp}`) to drive pluck-triggered raindrops in
  `main.mm`. Re-run after moving `MIN_CLICK_DBFS` (the pops-per-second decision), then in
  Wwise Authoring: refresh the audio file and regenerate SoundBanks — see
  `../../WwiseProject/README.md`.
