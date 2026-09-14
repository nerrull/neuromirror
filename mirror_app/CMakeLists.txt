# mirror_app — unified Metal app (neural mirror + 3D root scene).
#
# Added to the JardinsRacine superbuild via add_subdirectory in the parent
# CMakeLists. Built from the repo root, e.g.:
#   cmake -B build -DCMAKE_BUILD_TYPE=Release
#   cmake --build build --target mirror_app -j
#   ./build/mirror_app/mirror_app
#
# Scope right now: the Metal window shell only. MLX (neural mirror), libmediapipe
# (face tracking) and the Metal root renderer link in as their subsystems land —
# see the marked sections below.

project(mirror_app LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

list(APPEND CMAKE_PREFIX_PATH /opt/homebrew /usr/local)
find_package(glfw3 REQUIRED)

set(IMGUI_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../imgui)

# ImGui core + GLFW (C++) + Metal (ObjC++) backends. The Metal backend uses ARC.
add_library(mirror_imgui STATIC
    ${IMGUI_DIR}/imgui.cpp
    ${IMGUI_DIR}/imgui_draw.cpp
    ${IMGUI_DIR}/imgui_tables.cpp
    ${IMGUI_DIR}/imgui_widgets.cpp
    ${IMGUI_DIR}/backends/imgui_impl_glfw.cpp
    ${IMGUI_DIR}/backends/imgui_impl_metal.mm)
target_include_directories(mirror_imgui PUBLIC ${IMGUI_DIR} ${IMGUI_DIR}/backends)
set_source_files_properties(${IMGUI_DIR}/backends/imgui_impl_metal.mm
    PROPERTIES COMPILE_FLAGS "-fobjc-arc")
target_link_libraries(mirror_imgui PUBLIC glfw
    "-framework Metal" "-framework MetalKit" "-framework QuartzCore"
    "-framework Cocoa" "-framework Foundation" "-framework GameController")

# --- app ---------------------------------------------------------------------
add_executable(mirror_app
    src/main.mm
    src/app_state.mm
    src/dev_tools.mm
    src/panel.mm
    src/metal_context.mm
    src/mirror_scene.mm
    src/metal_root_renderer.mm
    src/root_scene.mm
    src/transition_scene.mm
    src/fit_view_scene.mm
    src/midi_in.mm
    src/ui_params.cpp
    src/text_sdf.cpp
    src/text_overlay.mm
    src/fullscreen_present.mm
    src/mic_level.mm)
# ../sdf_viewer for LeafMesh.h (the leaf triangulation is renderer-agnostic C++
# and lives with the rest of the flower code); ../wwise_plugins/mi_common for the
# OnsetTap shared-memory layout -- header-only, and deliberately the *same*
# header the plug-in writes through, so the two cannot drift apart on it.
target_include_directories(mirror_app PRIVATE src
    ${CMAKE_CURRENT_SOURCE_DIR}/../sdf_viewer
    ${CMAKE_CURRENT_SOURCE_DIR}/../wwise_plugins/mi_common)
target_link_libraries(mirror_app PRIVATE mirror_imgui glfw
    "-framework Metal" "-framework MetalKit" "-framework QuartzCore"
    "-framework CoreMIDI"
    # CoreText/CoreGraphics rasterise the text overlay's glyphs. Cocoa pulls
    # both in transitively, but the overlay uses them directly.
    "-framework CoreText" "-framework CoreGraphics"
    "-framework Cocoa" "-framework Foundation")

# Neuromirror sibling repo (MSL sources, face_landmarker.task, canonical model).
set(NEUROMIRROR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../neuromirror"
    CACHE PATH "Path to the neuromirror repo checkout")
target_compile_definitions(mirror_app PRIVATE
    NEUROMIRROR_DIR="${NEUROMIRROR_DIR}"
    SDF_VIEWER_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../sdf_viewer"
    MIRROR_APP_SHADER_DIR="${CMAKE_CURRENT_SOURCE_DIR}/shaders"
    MIRROR_APP_SRC_DIR="${CMAKE_CURRENT_SOURCE_DIR}/src"
    MIRROR_APP_ASSET_DIR="${CMAKE_CURRENT_SOURCE_DIR}/assets")

# --- MLX (neural mirror) -----------------------------------------------------
# The MLX C++ library + CMake package ships inside neuromirror's venv (pip mlx).
if(NOT MLX_DIR)
    file(GLOB _mlx_cfg_dirs
        "${NEUROMIRROR_DIR}/.venv/lib/python*/site-packages/mlx/share/cmake/MLX")
    if(_mlx_cfg_dirs)
        list(GET _mlx_cfg_dirs 0 MLX_DIR)
    endif()
endif()
find_package(MLX CONFIG REQUIRED)

# mirror_core: the neural-mirror compute (MLX C++ port of the fused MLP), shared
# by the app and the parity test. Pure C++ (no ObjC).
add_library(mirror_core STATIC
    src/mlp_forward.cpp
    src/mlp_backward.cpp
    src/mirror_train.cpp
    src/fit_target.cpp
    src/face_mask.cpp
    src/face_tracker.cpp
    src/face_basis.cpp
    src/face_fit.cpp
    src/face_capture.cpp
    src/face_track.cpp
    src/mirror_render.cpp
    src/screen_layout.cpp
    src/show_timeline.cpp
    src/drop_spawner.cpp
    src/presence.cpp
    src/chord.cpp
    src/pond_state.cpp)
target_include_directories(mirror_core PUBLIC src ${MLX_INCLUDE_DIRS})
# external/ is gitignored: face_basis.bin and the MediaPipe dylib are both
# generated, not committed. PUBLIC so the tests find the basis too.
target_compile_definitions(mirror_core PUBLIC
    MIRROR_APP_EXTERNAL_DIR="${CMAKE_CURRENT_SOURCE_DIR}/external"
    # RootScene resolves presets/ against this -- presets are edited in the
    # source tree during an install, not copied into a build directory.
    MIRROR_APP_SRC_DIR="${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(mirror_core PUBLIC mlx)

# --- MediaPipe face tracking -------------------------------------------------
# Uses MediaPipe's OFFICIAL C Tasks API (mediapipe/tasks/c/vision/face_landmarker)
# built as a shared library, not cpvrlab/libmediapipe: that wrapper pins
# MediaPipe v0.8.11, which predates the Tasks API entirely (legacy 468-point
# face_mesh, no blendshapes, no pose matrix) and is GPL-3.0. Upstream's C API
# gives 478 landmarks + 52 blendshapes + a 4x4 transform under Apache-2.0.
#
# Build it once with (from external/mediapipe, needs a JDK on PATH):
#   bazel build --config darwin_arm64 -c opt --strip always \
#     --define MEDIAPIPE_DISABLE_GPU=1 --repo_env=HERMETIC_PYTHON_VERSION=3.12 \
#     //mediapipe/tasks/c/vision/face_landmarker:libface_landmarker.dylib
set(_mp ${CMAKE_CURRENT_SOURCE_DIR}/external/mediapipe)
set(_mp_lib ${_mp}/bazel-bin/mediapipe/tasks/c/vision/face_landmarker/libface_landmarker.dylib)
if(EXISTS ${_mp_lib})
    # Bazel builds the dylib with install_name "libface_landmarker.dylib" -- a
    # bare filename, which dyld treats as a literal path and never resolves
    # against an rpath. Copy it out of bazel-bin (which is a symlink into a
    # cache anyway) and rewrite the id to @rpath so the usual mechanism works.
    set(_mp_stage ${CMAKE_CURRENT_BINARY_DIR}/mediapipe_lib)
    file(MAKE_DIRECTORY ${_mp_stage})
    execute_process(COMMAND ${CMAKE_COMMAND} -E copy_if_different
                            ${_mp_lib} ${_mp_stage}/libface_landmarker.dylib)
    execute_process(COMMAND install_name_tool -id @rpath/libface_landmarker.dylib
                            ${_mp_stage}/libface_landmarker.dylib
                    ERROR_QUIET)
    target_include_directories(mirror_core PUBLIC ${_mp})
    target_link_libraries(mirror_core PUBLIC ${_mp_stage}/libface_landmarker.dylib)
    # PUBLIC on a static lib propagates to whatever links mirror_core.
    target_link_options(mirror_core PUBLIC "-Wl,-rpath,${_mp_stage}")
    target_compile_definitions(mirror_core PUBLIC MIRROR_HAVE_MEDIAPIPE=1)
    message(STATUS "mirror_app: MediaPipe face tracking enabled")
else()
    target_compile_definitions(mirror_core PUBLIC MIRROR_HAVE_MEDIAPIPE=0)
    message(STATUS "mirror_app: MediaPipe face tracking disabled "
                   "(no libface_landmarker.dylib -- see the bazel command above)")
endif()

# --- Kinect v2 as a live fitting target --------------------------------------
# Reuses kinect_v2_validate's KinectSource rather than a second copy: it already
# carries the USB-reset policy and the independent latest-wins listeners that
# module exists to get right. Optional -- without freenect2 the app builds and
# runs, just without the camera target.
set(_kv2 ${CMAKE_CURRENT_SOURCE_DIR}/../kinect_v2_validate)
list(APPEND CMAKE_PREFIX_PATH ${_kv2}/external/libfreenect2/install)
find_package(freenect2 QUIET)
if(freenect2_FOUND AND EXISTS ${_kv2}/src/demo/kinect_source.cpp)
    target_sources(mirror_core PRIVATE
        src/kinect_target.cpp
        ${_kv2}/src/demo/kinect_source.cpp
        # mic_level.mm's Kinect-mic-array capture (see mic_level.h/.mm):
        # audio_capture.mm is pure CoreAudio/AudioToolbox, no freenect2 calls
        # of its own, but it lives with the rest of the Kinect subsystem and
        # follows the same MIRROR_HAVE_KINECT gate as the video side.
        ${_kv2}/src/demo/audio_capture.mm
        ${_kv2}/src/demo/dsp.cpp)
    target_include_directories(mirror_core PUBLIC
        ${_kv2}/src/demo ${freenect2_INCLUDE_DIRS})
    target_link_libraries(mirror_core PUBLIC ${freenect2_LIBRARIES}
        "-framework AudioToolbox" "-framework CoreAudio")
    target_compile_definitions(mirror_core PUBLIC MIRROR_HAVE_KINECT=1)
    message(STATUS "mirror_app: Kinect fit target enabled")
else()
    target_compile_definitions(mirror_core PUBLIC MIRROR_HAVE_KINECT=0)
    message(STATUS "mirror_app: Kinect fit target disabled (no freenect2)")
endif()

target_link_libraries(mirror_app PRIVATE mirror_core)

# --- Wwise sound engine ------------------------------------------------------
# The piece's audio is a Wwise project (../WwiseProject) whose engine runs
# *inside this app* rather than inside Wwise Authoring -- see src/wwise_audio.h
# for why. Optional, like MediaPipe and the Kinect: without the SDK the app
# builds and runs, silently.
#
# The Profile configuration, not Release, on purpose. It is the same optimised
# engine plus the communication module, which is what lets Wwise Authoring's
# profiler connect to this app and show the live busses, voices and RTPC values
# -- the visibility that would otherwise be lost by moving the engine out of
# Authoring. Switch to Release for an unattended install.
set(WWISE_SDK "/Applications/Audiokinetic/Wwise_2025.1.10.9233/SDK"
    CACHE PATH "Path to the Wwise SDK")
set(WWISE_CONFIG "Profile" CACHE STRING "Wwise SDK configuration (Debug/Profile/Release)")
set(_ak_lib ${WWISE_SDK}/Mac_Xcode2600/${WWISE_CONFIG}/lib)
set(_ak_samples ${WWISE_SDK}/samples/SoundEngine)
set(_mi_plugins ${CMAKE_CURRENT_SOURCE_DIR}/../wwise_plugins)

# The plug-in static libs are built separately (see ../wwise_plugins/README.md)
# and only for the configurations somebody has actually built -- a fresh
# checkout has none. Checking here rather than discovering the gap at link time
# makes the failure legible.
set(_ak_have_all TRUE)
foreach(_l ${_ak_lib}/libAkSoundEngine.a ${_ak_lib}/libMacroOscillatorSource.a)
    if(NOT EXISTS ${_l})
        set(_ak_have_all FALSE)
    endif()
endforeach()

target_sources(mirror_app PRIVATE src/wwise_audio.cpp)
if(_ak_have_all)
    # Catches the "plug-in lands in a bank but nobody adds the #include/link
    # line for it" bug at build time instead of at showtime: PluginInfo.json
    # is regenerated by Wwise on every bank build, so it's ground truth for
    # which plug-ins wwise_audio.cpp and this file need to carry. Runs every
    # build (no output file, so never considered up to date).
    add_custom_target(check_wwise_plugins ALL
        COMMAND ${CMAKE_COMMAND} -E env python3
            ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_wwise_plugins.py
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        COMMENT "Checking Wwise bank plug-ins are registered in the app"
        VERBATIM)
    add_dependencies(mirror_app check_wwise_plugins)
    target_sources(mirror_app PRIVATE
        ${_ak_samples}/POSIX/AkDefaultIOHookDeferred.cpp
        ${_ak_samples}/Common/AkMultipleFileLocation.cpp
        ${_ak_samples}/Common/AkFileLocationBase.cpp
        ${_ak_samples}/Common/AkGeneratedSoundBanksResolver.cpp)
    target_include_directories(mirror_app PRIVATE
        ${WWISE_SDK}/include
        ${_ak_samples}/POSIX
        ${_ak_samples}/Common
        # Each plug-in's *Factory.h is one AK_STATIC_LINK_PLUGIN, and they live
        # beside the plug-in sources rather than in the SDK.
        ${_mi_plugins}/MacroOscillator/SoundEnginePlugin
        ${_mi_plugins}/DrumSynth/SoundEnginePlugin
        ${_mi_plugins}/ModalVoice/SoundEnginePlugin
        ${_mi_plugins}/RacineComb/SoundEnginePlugin)
    # The plug-ins before the engine: they call into it, not the other way
    # round, and a static link resolves left to right.
    target_link_libraries(mirror_app PRIVATE
        ${_ak_lib}/libMacroOscillatorSource.a
        ${_ak_lib}/libDrumSynthSource.a
        ${_ak_lib}/libModalVoiceFX.a
        ${_ak_lib}/libRacineCombFX.a
        ${_ak_lib}/libAkRoomVerbFX.a
        # Factory effects the project authors and the engine therefore has to
        # carry: an unregistered plug-in loads without error and processes
        # nothing, so each of these was silently a no-op at showtime while
        # working perfectly in Authoring. Time Stretch and Convolution Reverb
        # are the pluck's chain; the Peak Limiter is the output ceiling.
        ${_ak_lib}/libAkTimeStretchFX.a
        ${_ak_lib}/libAkConvolutionReverbFX.a
        ${_ak_lib}/libAkPeakLimiterFX.a
        ${_ak_lib}/libAkParametricEQFX.a
        ${_ak_lib}/libAkFlangerFX.a
        ${_ak_lib}/libAkMemoryMgr.a
        ${_ak_lib}/libAkStreamMgr.a
        ${_ak_lib}/libAkSoundEngine.a
        "-framework AudioUnit" "-framework AudioToolbox"
        "-framework CoreAudio" "-framework AVFoundation")
    if(NOT WWISE_CONFIG STREQUAL "Release")
        # Profiling. Only Debug/Profile carry it; a Release engine defines
        # AK_OPTIMIZED and compiles those calls away.
        target_link_libraries(mirror_app PRIVATE ${_ak_lib}/libCommunicationCentral.a)
    endif()
    target_compile_definitions(mirror_app PRIVATE MIRROR_HAVE_WWISE=1)
    message(STATUS "mirror_app: Wwise sound engine enabled (${WWISE_CONFIG})")
else()
    message(STATUS "mirror_app: Wwise sound engine disabled (nothing in ${_ak_lib} "
                   "-- build the plug-ins for this configuration, see "
                   "../wwise_plugins/README.md)")
endif()

# --- mirror_sim (live CPlantBox root growth) ---------------------------------
# GL-free "mask relay" growth, reusing sdf_viewer's MaskCavities/RootAttractors
# headers and CPlantBox directly. Pure C++ (CPlantBox types hidden behind pimpl),
# so it links into the ObjC++ app cleanly.
add_library(mirror_sim STATIC src/root_sim.cpp)
target_include_directories(mirror_sim PRIVATE
    src ${CMAKE_CURRENT_SOURCE_DIR}/../sdf_viewer)
target_link_libraries(mirror_sim PUBLIC CPlantBox)

target_link_libraries(mirror_app PRIVATE mirror_sim)
set(ROOTSIM_PARAM_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../CPlantBox/modelparameter/structural/rootsystem/")
target_compile_definitions(mirror_app PRIVATE
    ROOTSIM_PARAM_DIR="${ROOTSIM_PARAM_DIR}")

# The growth, headless: grow the relay and print what each hop did. No Metal and
# no window, so dialling a species in is a shell loop over this rather than an
# afternoon of watching the panel — and it can see the one thing the panel
# cannot, a hop that ran out of days and revealed its mask anyway.
add_executable(root_sweep tools/root_sweep.cpp)
target_link_libraries(root_sweep PRIVATE mirror_sim)
target_include_directories(root_sweep PRIVATE src)
target_compile_definitions(root_sweep PRIVATE
    ROOTSIM_PARAM_DIR="${ROOTSIM_PARAM_DIR}")

# --- tests -------------------------------------------------------------------
add_executable(mlp_parity_test tests/mlp_parity_test.cpp)
target_link_libraries(mlp_parity_test PRIVATE mirror_core)

add_executable(pond_parity_test tests/pond_parity_test.cpp)
target_link_libraries(pond_parity_test PRIVATE mirror_core)

# Fused ripple kernel vs. the op-graph reference it replaced. Needs a Metal
# device but no fixtures, so unlike the two above it runs without a dump step.
add_executable(ripple_parity_test tests/ripple_parity_test.cpp)
target_link_libraries(ripple_parity_test PRIVATE mirror_core)

# Raindrops: one impact spreading outward, landing somewhere new each time.
add_executable(drop_test tests/drop_test.cpp)
target_link_libraries(drop_test PRIVATE mirror_core)

# The join between the Wwise onset tap and the drops: plays the plug-in's part
# through the same shared-memory header the plug-in writes through, so it needs
# no Wwise install and no running sound engine.
add_executable(audio_drops_test tests/audio_drops_test.cpp)
target_link_libraries(audio_drops_test PRIVATE mirror_core)
target_include_directories(audio_drops_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../wwise_plugins/mi_common)

# --- subsystems (wired in as they land) --------------------------------------
# TODO(tracking): prebuilt libmediapipe .dylib for face_tracker.
# TODO(roots): link sdfsim (GL-free CPlantBox sim) + MetalRootRenderer sources.

# The fused MLP at hidden widths other than the fixture's 64. hidden_dim is a
# kernel template parameter, so each width is a different kernel with a
# different simdgroup decomposition; the fixture test cannot see any of that.
add_executable(mlp_width_test tests/mlp_width_test.cpp)
target_link_libraries(mlp_width_test PRIVATE mirror_core)

# The fused backward against an fp32 MLX-op backprop, across widths, depths,
# hybrid splits, activations and ragged row counts. No fixtures needed.
add_executable(mlp_backward_test tests/mlp_backward_test.cpp)
target_link_libraries(mlp_backward_test PRIVATE mirror_core)

# End-to-end fit: loss falls AND the rendered image moves toward the target,
# including at a resolution the fit never saw.
add_executable(fit_test tests/fit_test.cpp)
target_link_libraries(fit_test PRIVATE mirror_core)

# Resampling + fitting a moving target (the camera case), with a synthetic feed
# so it needs no sensor.
add_executable(fit_target_test tests/fit_target_test.cpp)
target_link_libraries(fit_target_test PRIVATE mirror_core)

# The PBD cloth solver, headless. No Metal, no GPU -- which is why the solver was
# written GL-free in the first place.
add_executable(cloth_test tests/cloth_test.cpp)
target_include_directories(cloth_test PRIVATE src)

# Landmark outline -> training mask. Pure geometry; no MediaPipe needed.
add_executable(face_mask_test tests/face_mask_test.cpp)
target_link_libraries(face_mask_test PRIVATE mirror_core)

# Morphable-model fit against synthetic landmarks with a known ground-truth
# identity. Needs external/face_basis.bin; skips cleanly without it.
add_executable(face_fit_test tests/face_fit_test.cpp)
target_link_libraries(face_fit_test PRIVATE mirror_core)

# Composition size / letterbox arithmetic, and the camera crop that follows it.
# Pure arithmetic, no Metal: exactly the part that is wrong by a few pixels in a
# way a screenshot does not show.
add_executable(screen_layout_test tests/screen_layout_test.cpp)
target_link_libraries(screen_layout_test PRIVATE mirror_core)

# The show's running order: floors, ceilings, debounced events, text cues. Pure
# state machine, driven at a fixed step -- the alternative is discovering a bad
# debounce with somebody standing in front of the piece.
add_executable(show_timeline_test tests/show_timeline_test.cpp)
target_link_libraries(show_timeline_test PRIVATE mirror_core)

# Landmarks -> the room, as the five numbers Wwise is driven by. Synthetic
# faces, so the ground truth is known by construction and no camera (and no
# sound engine) is involved.
add_executable(presence_test tests/presence_test.cpp)
target_link_libraries(presence_test PRIVATE mirror_core)

# The mirror phase's harmony: the checkpoints, the glide, and the pluck staying
# in tune with the pad. Pure arithmetic over a synthetic fit, so a fit that
# stalls, runs backwards or is abandoned halfway can all be walked without a
# camera or a sound engine.
add_executable(chord_test tests/chord_test.cpp)
target_link_libraries(chord_test PRIVATE mirror_core)

# The text overlay's distance transform, against an analytically known shape.
# Pure geometry: no Metal, no fonts, no MLX.
add_executable(text_sdf_test tests/text_sdf_test.cpp src/text_sdf.cpp)
target_include_directories(text_sdf_test PRIVATE src)

# Is a face on a root mask square to its nest: the sim's grow->render frame
# map is one rigid transform (the cavity's axes are the face's axes), and the
# bank's captures come out square of their sitters' head pose. Needs the
# CPlantBox parameters and external/face_basis.bin; skips either half cleanly.
add_executable(mask_frame_test tests/mask_frame_test.cpp)
target_link_libraries(mask_frame_test PRIVATE mirror_sim mirror_core)
target_compile_definitions(mask_frame_test PRIVATE
    ROOTSIM_PARAM_DIR="${ROOTSIM_PARAM_DIR}")
