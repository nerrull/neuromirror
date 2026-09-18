# Build the Racine Shimmer authoring DLL (Windows)

One task, on the Windows machine. The Mac sound-engine side of this plug-in is
already built and linked into `mirror_app`; what is missing is the Wwise
Authoring DLL that makes "Racine Shimmer" appear in the Effects list. Until it
exists, WAAPI refuses the plug-in ("Could not find classId for the plug-in").

This is the same procedure that produced the other DLLs in `../dist/` (see
`../README.md`, "Authoring plug-in (Windows)"). OnsetTap was the last one built
this way; do it identically.

## Prerequisites (already on the box if OnsetTap built)

- Wwise SDK 2025.1.10 for Windows, vc170 toolset. The paths used last time:
  `Q:\Development\Audiokinetic\Wwise_2025.1.10.9233`.
- Visual Studio 2022 / Build Tools 2022 with **Desktop development with C++**
  and **C++ MFC for latest v143 build tools** (the GUI class derives from
  `PluginMFCWindows<>`; without MFC on the include path it will not compile).
- No `eurorack` checkout needed -- this plug-in has no Mutable Instruments code.

## Steps

From a Developer Command Prompt (or any shell where `cl.exe` resolves):

```bat
set WWISEROOT=Q:\Development\Audiokinetic\Wwise_2025.1.10.9233
set WWISESDK=%WWISEROOT%\SDK

cd <repo>\wwise_plugins\RacineShimmer
python %WWISEROOT%\Scripts\Build\Plugins\wp.py premake Authoring
python %WWISEROOT%\Scripts\Build\Plugins\wp.py build Authoring -t vc170 -c Release
```

`wp.py build` swallows the compiler output and can report success on a failed
build. Confirm the artifact actually exists before going on:

```
%WWISEROOT%\Authoring\x64\Release\bin\Plugins\RacineShimmer.dll
%WWISEROOT%\Authoring\x64\Release\bin\Plugins\RacineShimmer.xml
```

If the DLL is missing, open the generated
`WwisePlugin\RacineShimmer_Authoring_Windows_vc170.sln` in Visual Studio (or
run `msbuild` on it, Release/x64) to see the real error.

## Deliver

1. Copy both files into the repo at `wwise_plugins\dist\RacineShimmer.dll`
   and `wwise_plugins\dist\RacineShimmer.xml`.
2. Do **not** commit anything premake generated (`*.sln`, `*.vcxproj`,
   `Authoring_Windows_*`, `.vs/`) -- the plug-in's `.gitignore` already covers
   them, but check `git status` shows only the two `dist/` files.
3. Commit as `wwise: add RacineShimmer authoring DLL to dist`.

## Things that would be wrong to "fix"

- `WwisePlugin\RacineShimmerPlugin.cpp` `GetBankParameters()` writes six
  properties in a fixed order (Decay, Shimmer, Pitch, Damping, WetDryMix,
  OutputLevel). That order matches `SoundEnginePlugin\RacineShimmerFXParams.cpp`
  `SetParamsBlock()` and must stay so; do not reorder or "tidy" it.
- `CompanyID 64 / PluginID 23742` appear in `RacineShimmerConfig.h` and
  `WwisePlugin\RacineShimmer.xml` and must agree. Leave them.
- The `SoundEnginePlugin\` sources compile into the DLL too (the authoring
  build carries the sound-engine class). If they fail under MSVC, fix the
  portability issue minimally and say so in the commit; do not change the DSP.

## Then, back on the Mac

The Mac side installs the DLL into
`/Library/Application Support/Audiokinetic/Wwise 2025.1.10.9233/Authoring/x64/Release/bin/Plugins/`
and relaunches Wwise Authoring; the Wwise-project wiring (a `Strum_Shimmer`
ShareSet on `StrumBus`) happens there over WAAPI. Nothing for this task to do
in `WwiseProject/`.
