// panel.mm — the operator control panel and its always-on-top overlays.
// Moved out of main.mm's per-frame loop; see panel.h and PANEL.md.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Cocoa/Cocoa.h>

#include "imgui.h"
#include "imgui_internal.h"

#include "panel.h"
#include "app_state.h"
#include "core_frame.h"
#include "mirror_scene.h"
#include "fit_target.h"
#include "face_tracker.h"
#include "face_capture.h"
#include "face_fit.h"
#if MIRROR_HAVE_KINECT
#include "kinect_target.h"
#endif
#include "root_scene.h"
#include "transition_scene.h"
#include "ui_params.h"
#include "text_overlay.h"
#include "screen_layout.h"
#include "show_timeline.h"
#include "presence.h"
#include "chord.h"
#include "wwise_audio.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

// Whether the panel is its own window is a property of the machine it is being
// operated from, not of the show, so it is remembered next to imgui.ini rather
// than in a preset. One line, because that is all it is.
static const char* kPanelStatePath = "mirror_panel.ini";
void PanelStateSave(bool detached) {
    if (FILE* f = fopen(kPanelStatePath, "w")) {
        fprintf(f, "detached=%d\n", detached ? 1 : 0);
        fclose(f);
    }
}
void PanelStateLoad(bool* detached) {
    FILE* f = fopen(kPanelStatePath, "r");
    if (!f) return;
    int v = 0;
    if (fscanf(f, "detached=%d", &v) == 1) *detached = (v != 0);
    fclose(f);
}

static void DrawBankSaveUI(ui::Bank bank) {
    struct BankSaveUI { char name[128]; std::string msg;
                         std::vector<std::string> list; };
    static BankSaveUI bui[(int)ui::Bank::Count];
    static bool bui_init = false;
    if (!bui_init) {
        for (int b = 1; b < (int)ui::Bank::Count; ++b) {
            snprintf(bui[b].name, sizeof(bui[b].name), "default");
            bui[b].list = ui::ListBank((ui::Bank)b);
        }
        bui_init = true;
    }
    const int b = (int)bank;
    BankSaveUI& U = bui[b];
    int retired = 0;
    const int n = ui::BankCount(bank, &retired);
    ImGui::PushID(b);
    ImGui::Separator();
    ImGui::SeparatorText(ui::BankName(bank));
    ImGui::TextDisabled("%d parameter%s%s", n, n == 1 ? "" : "s",
                        retired ? " (some retired)" : "");

    if (bank == ui::Bank::Machine) {
        // One file, always the same one. Offering a choice of machine
        // configurations is offering to load the wrong one on the night.
        ImGui::SameLine();
        ImGui::TextDisabled("| this room only");
        if (ImGui::Button("save machine")) {
            std::string e;
            U.msg = ui::SaveBank(bank, ui::MachinePath(), e)
                        ? "saved machine settings" : e;
        }
        ImGui::SameLine();
        if (ImGui::Button("reload machine")) {
            std::string e;
            U.msg = ui::LoadBank(bank, ui::MachinePath(), e)
                        ? "reloaded machine settings" : e;
        }
    } else {
        ImGui::PushItemWidth(-110);
        if (ImGui::BeginCombo("load", "choose...")) {
            for (const std::string& nm : U.list) {
                if (!ImGui::Selectable(nm.c_str())) continue;
                std::string e;
                const std::string p = ui::BankDir(bank) + "/" + nm +
                                      ui::BankExt(bank);
                if (ui::LoadBank(bank, p, e)) {
                    snprintf(U.name, sizeof(U.name), "%s", nm.c_str());
                    U.msg = "loaded " + nm;
                } else {
                    U.msg = e;
                }
            }
            ImGui::EndCombo();
        }
        ImGui::InputText("name", U.name, sizeof(U.name));
        ImGui::PopItemWidth();
        if (ImGui::Button("save")) {
            std::string e;
            const std::string p = ui::BankDir(bank) + "/" + U.name +
                                  ui::BankExt(bank);
            U.msg = ui::SaveBank(bank, p, e)
                        ? ("saved " + std::string(U.name)) : e;
            U.list = ui::ListBank(bank);
        }
        ImGui::SameLine();
        if (ImGui::Button("rescan")) U.list = ui::ListBank(bank);

        // --- what this bank comes up in -------------------------------
        //
        // Written to presets/defaults as a name, not as a copy of the
        // values: "come up in mirror_bw" and "here are some numbers that
        // were mirror_bw last Tuesday" are different promises, and only
        // the first one survives editing the preset.
        const std::string dflt = ui::DefaultName(bank);
        ImGui::SameLine();
        if (ImGui::Button("make default")) {
            std::string e;
            ui::SetDefaultName(bank, U.name);
            U.msg = ui::SaveDefaults(e)
                        ? (std::string(U.name) + " loads at startup")
                        : e;
        }
        if (ImGui::IsItemHovered()) {
            ImGui::SetTooltip(
                "Come up in the preset named above, every\n"
                "launch. The installation starts with nobody in\n"
                "front of it -- without this the piece boots on\n"
                "the built-in defaults however it was left.");
        }
        if (!dflt.empty()) {
            ImGui::SameLine();
            const bool here = std::find(U.list.begin(), U.list.end(),
                                        dflt) != U.list.end();
            if (here) {
                ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f),
                                   "startup: %s", dflt.c_str());
            } else {
                // Named but not on disk. Silent until the next launch
                // otherwise, which is the wrong moment to find out.
                ImGui::TextColored(ImVec4(1.f, 0.5f, 0.5f, 1.f),
                                   "startup: %s (missing)",
                                   dflt.c_str());
            }
            ImGui::SameLine();
            if (ImGui::SmallButton("clear##dflt")) {
                std::string e;
                ui::SetDefaultName(bank, "");
                U.msg = ui::SaveDefaults(e) ? "no startup preset" : e;
            }
        }
    }
    if (!U.msg.empty()) ImGui::TextDisabled("%s", U.msg.c_str());
    ImGui::PopID();
}

// The roots tab's body, on its own so a headless caller (dev_tools.mm's
// applyRootsBank, for the --seqshot stills) can declare exactly the controls
// the panel does and have a loaded roots preset land on the scene the same
// way it lands in the app. Path level "roots" is pushed here; the tab itself
// adds none.
void DrawRootsTab(RootScene& roots, int& fieldGrid, int& rootSeed, int fbw, int fbh) {
    ui::PushSection("roots");
    MetalRootRenderer& R = roots.renderer();
        ImGui::Text("t=%5.1fs", roots.clock());   // fps is in the title
        ImGui::Text("render %d x %d -> %d x %d  (overdraw-bound)",
                    roots.width(), roots.height(), fbw, fbh);
        ImGui::Separator();

        // --- growth ------------------------------------------------
        ui::PushSection("growth");
        ui::BeginHeader("growth", /*default_open=*/true);
        {
            rootsim::SimParams& SP = roots.simParams();
            ImGui::Text("%s", roots.simActive()
                            ? (roots.simDone() ? "grown" : "growing")
                            : "stand-in (no CPlantBox parameters)");

            // The species is saved by name, not by its position in the
            // combo: the list is a hand-written table that will grow,
            // and an index would repoint every roots preset the day a
            // row is inserted above the one they meant.
            ui::DeclareString("species", &SP.speciesXml);

            const auto& sp = RootScene::species();
            int si = roots.speciesIndex();
            ImGui::PushItemWidth(-90);
            if (ImGui::BeginCombo("species",
                                  si >= 0 ? sp[size_t(si)].first.c_str()
                                          : SP.speciesXml.c_str())) {
                for (int i = 0; i < (int)sp.size(); ++i) {
                    const bool selected = (i == si);
                    if (ImGui::Selectable(sp[size_t(i)].first.c_str(), selected))
                        roots.setSpeciesIndex(i);
                    if (selected) ImGui::SetItemDefaultFocus();
                }
                ImGui::EndCombo();
            }
            ImGui::PopItemWidth();

            // --- host and pattern -----------------------------
            // Two axes, not one: the host is what the roots crawl on,
            // the pattern is where the masks sit in its coordinates.
            // Any pattern composes with any host -- a helix is a curve
            // on a cylinder, not a topology of its own.
            ui::DeclareString("host", &SP.host);
            ui::DeclareString("pattern", &SP.pattern);
            {
                static const char* kHosts[] = {"cone", "cylinder", "sphere",
                                               "torus", "lobes"};
                static const char* kPatterns[] = {"phyllotaxis", "helix",
                                                  "rosette", "feature"};
                ImGui::PushItemWidth(-90);
                if (ui::Visible() && ImGui::BeginCombo("host", SP.host.c_str())) {
                    for (const char* h : kHosts)
                        if (ImGui::Selectable(h, SP.host == h)) {
                            SP.host = h; roots.regrow();
                        }
                    ImGui::EndCombo();
                }
                // Lobes have no surface, so they have no (u, v) for a
                // pattern to place into -- the grouping is the layout.
                ui::BeginGate(SP.host != "lobes");
                if (ui::Visible() && ImGui::BeginCombo("pattern", SP.pattern.c_str())) {
                    for (const char* q : kPatterns)
                        if (ImGui::Selectable(q, SP.pattern == q)) {
                            SP.pattern = q; roots.regrow();
                        }
                    ImGui::EndCombo();
                }
                ui::EndGate();
                ImGui::PopItemWidth();
            }

            ImGui::PushItemWidth(110);
            ui::BeginGate(SP.pattern == "helix" && SP.host != "lobes");
            ui::SliderFloat("helix turns", &SP.helixTurns, 0.25f, 6.f, "%.2f");
            ui::EndGate();
            ui::BeginGate(SP.host == "lobes" || SP.pattern == "rosette");
            ui::SliderInt("group size", &SP.groupSize, 1, 9);
            ui::EndGate();
            ui::BeginGate(SP.pattern == "rosette" && SP.host != "lobes");
            ImGui::SameLine();
            ui::SliderFloat("group spread", &SP.groupSpread, 0.1f, 1.2f);
            ui::EndGate();
            ui::BeginGate(SP.pattern == "feature" && SP.host != "lobes");
            ui::SliderInt("feature clusters", &SP.featureClusters, 1, 6);
            ui::EndGate();
            ui::BeginGate(SP.host == "torus" || SP.host == "lobes");
            ui::SliderFloat("tube radius", &SP.tubeRadius, 2.f, 20.f, "%.1f cm");
            ui::EndGate();
            ImGui::PopItemWidth();

            ui::BeginGate(SP.host == "cone" || SP.host == "cylinder");
            ui::Checkbox("anchor on axis", &SP.anchorOnAxis);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "The first mask on the host's axis, facing down it,\n"
                    "instead of on the surface facing out: the root\n"
                    "leaves the visitor's face straight out of its front\n"
                    "and the chain grows toward the camera. Structural --\n"
                    "regrow to apply.");
            }
            ui::BeginGate(SP.anchorOnAxis);
            ImGui::PushItemWidth(110);
            ui::SliderFloat("anchor pitch", &SP.anchorPitchDeg, 0.f, 85.f, "%.0f deg");
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "How steeply the first face looks down, degrees below\n"
                    "the horizontal. The chain hangs off that face, so\n"
                    "this is how the structure hangs: 90 would be\n"
                    "straight down, 0 lays it level. Structural --\n"
                    "regrow to apply.");
            }
            ImGui::SameLine();
            ui::SliderFloat("anchor spawn", &SP.anchorSpawn, 0.f, 6.f, "%.2f cm");
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "How far behind the anchor mask's mouth the first\n"
                    "root starts; it grows out through the mouth hole\n"
                    "along the normal. Takes effect at the next regrow.");
            }
            ImGui::PopItemWidth();
            ui::EndGate();
            ui::EndGate();
            ui::Checkbox("tree relay", &SP.treeRelay);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Each hop leaves from the revealed mask NEAREST the\n"
                    "next one, rather than from the one just left: the\n"
                    "system branches instead of threading.\n\n"
                    "Changes nothing on a spiral, where the nearest mask\n"
                    "already is the previous one. It is for the clustered\n"
                    "layouts -- and it currently costs reach there, since\n"
                    "the hop starts inside a crowded neighbourhood it has\n"
                    "to escape.");
            }
            ImGui::Separator();

            ImGui::PushItemWidth(110);
            ui::SliderInt("masks", &SP.N, 1, 24);
            ImGui::SameLine();
            ui::SliderFloat("cone radius", &SP.R0, 6.f, 24.f, "%.1f cm");
            ui::SliderFloat("cone height", &SP.Hh, 24.f, 96.f, "%.1f cm");
            ImGui::SameLine();
            ui::SliderFloat("taper", &SP.taperPower, 0.4f, 2.5f);
            ui::SliderFloat("spiral x golden", &SP.angleStepGoldenMult,
                               0.2f, 2.0f);
            ImGui::SameLine();
            ui::SliderFloat("jitter", &SP.sigma, 0.f, 1.2f);
            ui::SliderFloat("travel pull", &SP.weight, 0.f, 1.f);
            ImGui::SameLine();
            ui::SliderFloat("pull reach", &SP.travelPullReach, 0.4f, 3.f);
            ui::SliderFloat("lateral", &SP.lateralWeight, 0.f, 1.f);
            ImGui::SameLine();
            ui::SliderFloat("dwell", &SP.dwellWeight, 0.f, 1.f);
            ui::SliderFloat("dwell days", &SP.dwellDays, 2.f, 60.f);
            ImGui::SameLine();
            ui::SliderFloat("hop days", &SP.maxHopDays, 10.f, 160.f);
            ui::SliderInt("root types", &SP.rootTypes, 1, 3);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Up to three dwell settings dealt to the hops in\n"
                    "turn (hop 1 type 1, hop 2 type 2, ... round again).\n"
                    "Type 1 is dwell / dwell days / dwell lateral above\n"
                    "and in advanced; types 2 and 3 are below. 1 = every\n"
                    "hop the same. Applies on regrow.");
            }
            // Gated, not if'd: declared every frame (PANEL.md).
            ui::BeginGate(SP.rootTypes >= 2);
            ui::SliderFloat("type 2 dwell days", &SP.dwell2Days, 2.f, 60.f);
            ImGui::SameLine();
            ui::SliderFloat("type 2 dwell", &SP.dwell2Weight, 0.f, 1.f);
            ImGui::SameLine();
            ui::SliderFloat("type 2 dwell lateral", &SP.dwell2Lateral, 0.f, 1.f);
            ui::EndGate();
            ui::BeginGate(SP.rootTypes >= 3);
            ui::SliderFloat("type 3 dwell days", &SP.dwell3Days, 2.f, 60.f);
            ImGui::SameLine();
            ui::SliderFloat("type 3 dwell", &SP.dwell3Weight, 0.f, 1.f);
            ImGui::SameLine();
            ui::SliderFloat("type 3 dwell lateral", &SP.dwell3Lateral, 0.f, 1.f);
            ui::EndGate();
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Ceiling, not the budget. How long a hop's travel\n"
                    "actually gets is worked out from how far it has to\n"
                    "go and how fast this species elongates -- this only\n"
                    "stops a hop that is never going to arrive from\n"
                    "growing the whole system into a ball.");
            }
            ui::SliderFloat("travel slack", &SP.travelSlack, 1.f, 4.f);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "How much longer the root's real path is than the\n"
                    "straight line to the mask. It wanders -- the tropism\n"
                    "is a random walk with a pull -- and it steers around\n"
                    "the masks already revealed, so a budget that assumes\n"
                    "a straight line runs out short of every target.\n\n"
                    "Too low and late masks get revealed with the root\n"
                    "still halfway there; too high only costs days on a\n"
                    "hop that was never going to make it.");
            }
            ImGui::PopItemWidth();

            ui::Checkbox("even nests", &SP.evenNests);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "The same amount of root at every mask.\n\n"
                    "The dwell is already the same everywhere, but the\n"
                    "nest is not: laterals grow during the travel too,\n"
                    "and travel gets longer as the cone widens -- so the\n"
                    "last mask ends up with about twice the root of the\n"
                    "first. This pads every hop out to one age, so the\n"
                    "early masks wait instead of the late ones being\n"
                    "fuller.\n\n"
                    "It costs days, and the days are what make the system\n"
                    "bushy: turning it on wants a shorter dwell to hold\n"
                    "the same density.");
            }
            ui::Checkbox("crawl the cone surface", &SP.coneSurfaceTravel);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Confine the travelling root to a thin shell around\n"
                    "the cone the masks sit on, so it crawls over the\n"
                    "surface between them instead of cutting through the\n"
                    "interior.\n\n"
                    "Travel only: the dwell wrapping stays free, or the\n"
                    "nests around each mask would be flattened onto the\n"
                    "surface instead of bulging into 3D.");
            }
            ui::BeginGate(SP.coneSurfaceTravel);
            if (ui::Visible()) {
                ImGui::SameLine();
                ImGui::SetNextItemWidth(90);
            }
            ui::SliderFloat("shell", &SP.coneShellThickness, 1.f, 20.f,
                               "%.1f cm");
            ui::EndGate();

            ImGui::SetNextItemWidth(110);
            ui::SliderFloat("days / step", &SP.growthDt, 0.05f, 3.f, "%.2f");
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "How far the plant moves per sim step. The show\n"
                    "paces steps to the same wall-clock speed whatever\n"
                    "this is, so smaller only makes the motion finer:\n"
                    "at 1 a hop is a few steps a second and reads as\n"
                    "stop motion; 0.2 is ~30 steps/s. Takes effect at\n"
                    "the next replant (the next visitor) or regrow --\n"
                    "the sim copies its parameters at reset.");
            }
            ImGui::SameLine();
            ImGui::SetNextItemWidth(90);
            ui::SliderInt("steps/frame", &roots.simStepsPerFrame, 1, 30);
            ImGui::SetNextItemWidth(110);
            ui::SliderInt("old hops alive", &SP.oldHopsAlive, 0, 5);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "How many finished hops keep growing behind the\n"
                    "hop in flight. A hop grows on while this many\n"
                    "later ones run, then freezes; everything freezes\n"
                    "when the relay is done. 0 = freeze on finishing.\n"
                    "Takes effect at the next replant or regrow.");
            }
            ImGui::SameLine();
            ImGui::SetNextItemWidth(90);
            ui::SliderFloat("old hops rate", &SP.oldHopsRate, 0.f, 1.f, "%.2f");
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip("Their share of each live step (1 = the same pace).");
            }
            ImGui::SameLine();
            ImGui::SetNextItemWidth(90);
            ui::SliderFloat("ease days", &SP.oldHopsEaseDays, 0.f, 60.f, "%.0f");
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "How gradually a hop changes pace, in sim days on\n"
                    "the relay's clock: the slew's time constant, both\n"
                    "down from the live pace when it finishes and down\n"
                    "to nothing when it leaves the window. A hop is\n"
                    "about 60 days.");
            }

            if (ImGui::Button("regrow")) roots.regrow();
            ImGui::SameLine();
            if (ImGui::Button("reseed")) roots.reseed((uint32_t)(++rootSeed));
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "A new random seed for the same parameters. Reseeds\n"
                    "the growth itself -- it used to drop a synthetic\n"
                    "stand-in structure over a running grow, which the\n"
                    "next frame then overwrote.");
            }
            ImGui::SameLine();
            if (roots.seedOffset())
                ImGui::TextDisabled("seed %u (+%u this sitting)", SP.seed, roots.seedOffset());
            else
                ImGui::TextDisabled("seed %u", SP.seed);

            // --- the rest of SimParams ----------------------------
            //
            // These had no control at all: they existed only in the
            // .root file, which is what made a second preset system
            // necessary in the first place. Declaring them here is what
            // lets that system go away -- a roots preset is now the
            // whole of SimParams, and there is one file per root look
            // instead of two that can disagree.
            //
            // Folded away by default because they are structure, not
            // performance: changing one means a regrow.
            ui::BeginHeader("structure (needs a regrow)");
            {
                ImGui::PushItemWidth(110);
                ui::SliderFloat("mask start", &SP.startFrac, 0.f, 1.f);
                ImGui::SameLine();
                ui::SliderFloat("mask end", &SP.endFrac, 0.f, 1.f);
                ui::SliderFloat("spiral drift", &SP.distStepFrac, -0.5f, 0.5f);
                ImGui::SameLine();
                ui::SliderFloat("travel trials", &SP.mainTravelTrials, 1.f, 60.f,
                                "%.0f");
                ui::SliderFloat("dwell lateral", &SP.dwellLateralWeight, 0.f, 1.f);
                ImGui::SameLine();
                ui::SliderFloat("reach x", &SP.reachMult, 0.4f, 4.f);
                ui::SliderFloat("view cylinder", &SP.viewCylLen, 1.f, 30.f,
                                "%.1f cm");
                ImGui::SameLine();
                ui::SliderFloat("target lift", &SP.targetLift, -10.f, 10.f,
                                "%.2f cm");
                ui::SliderFloat("spawn behind", &SP.spawnBehind, 0.f, 10.f,
                                "%.2f cm");
                ImGui::SameLine();
                ui::SliderFloat("nest behind", &SP.nestBehind, -5.f, 15.f,
                                "%.2f cm");
                ui::SliderFloat("basal clear", &SP.basalClear, -1.f, 10.f, "%.1f cm");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How far past the mouth the main root grows before\n"
                        "its first lateral. The species files start laterals\n"
                        "1 cm from the base -- inside the head -- and those\n"
                        "were the pile of root behind the first mask.\n"
                        "-1 = the species' own value.");
                }
                ui::SliderFloat("motion cavity", &SP.motionCavity, 0.f, 1.5f, "%.2f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How much of a replayed head's swing is added to\n"
                        "its mask's keep-out and nest ring, so the roots\n"
                        "grow around the motion instead of through it.\n"
                        "1 = the whole swing, 0 = ignore it. Next sitting.");
                }
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Where the dwell's ring of attractors sits: this far\n"
                        "behind the face along its normal. 0 rings the face in\n"
                        "its own plane (the wrap frames it); a few cm back and\n"
                        "the roots gather behind the head instead, a nest the\n"
                        "face sits in front of. Takes effect at the next regrow.");
                }
                ui::SliderInt("nest rings", &SP.nestRings, 1, 6);
                ImGui::SameLine();
                ui::SliderInt("nest per ring", &SP.nestPerRing, 3, 16);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The nest's attractors: a hemisphere behind the mask,\n"
                        "rings from the rim back to a point at the pole. More\n"
                        "of them, the more places the wrap has left to go once\n"
                        "the ones it reached are spent (nest hit radius).");
                }
                ui::SliderFloat("nest hit radius", &SP.nestHitRadius, 0.f, 6.f,
                                "%.2f cm");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "A nest attractor is dropped once a root node comes\n"
                        "within this of it, so the wrap moves on instead of\n"
                        "circling a spot it has reached. 0 keeps them all for\n"
                        "the whole dwell. Takes effect at the next regrow.");
                }
                ImGui::PopItemWidth();

                // The seed is part of the look -- a preset that came
                // back with a different one would not be the same root
                // system -- so it is saved, through an int because that
                // is the widest kind the registry has.
                int seed_i = (int)SP.seed;
                ui::DeclareInt("seed", &seed_i, 0, 1 << 30);
                SP.seed = (unsigned)seed_i;
            }
            ui::EndHeader();
        }
        ui::EndHeader();
        ui::PopSection();

        // --- presets -----------------------------------------------
        // The root scene's presets are the `roots` bank now, saved
        // from the settings section at the bottom of the panel with
        // everything else. There used to be a second preset system
        // here, writing .root files that held the SimParams fields the
        // panel did not expose -- so "the root preset" and "the root
        // settings" were two different things that could disagree, and
        // only one of them was ever in the file you loaded.

        // --- camera ------------------------------------------------
        ui::PushSection("camera");
        ui::BeginHeader("camera", /*default_open=*/true);
        {
            // In the show the timeline (show tab, show/roots) owns the
            // camera and these are inert. They drive the fallback
            // framing outside Transition/Roots -- looking at the scene
            // rather than playing it.
            ImGui::TextDisabled("in Transition/Roots the show's timeline drives the camera");
            ui::Checkbox("frame automatically", &roots.autoFrame);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Derive the target and distance from the layout's\n"
                    "own bounds -- the whole planned layout, or one\n"
                    "mask square to its normal. The constants this\n"
                    "replaced were tuned to one cone size and pointed\n"
                    "at the wrong part of any other.");
            }
            ui::BeginGate(roots.autoFrame);
            {
                const int nm = (int)roots.plannedMasks().size();
                std::string label = roots.focusMask >= 0 && roots.focusMask < nm
                                        ? ("mask " + std::to_string(roots.focusMask))
                                        : std::string("whole scene");
                ImGui::PushItemWidth(-90);
                if (ImGui::BeginCombo("focus", label.c_str())) {
                    if (ImGui::Selectable("whole scene", roots.focusMask < 0))
                        roots.focusMask = -1;
                    for (int i = 0; i < nm; ++i) {
                        const std::string it = "mask " + std::to_string(i);
                        if (ImGui::Selectable(it.c_str(), roots.focusMask == i))
                            roots.focusMask = i;
                    }
                    ImGui::EndCombo();
                }
                ImGui::PopItemWidth();
                ImGui::SetNextItemWidth(110);
                ui::SliderFloat("zoom", &roots.zoom, 0.15f, 5.f, "%.2fx");
                ImGui::SameLine();
                if (ImGui::SmallButton("reset zoom")) roots.zoom = 1.f;
                ImGui::SetNextItemWidth(90);
                ui::SliderFloat("margin", &roots.frameMargin, 0.f, 1.5f, "%.2f");
            }
            ui::EndGate();
            ImGui::BeginDisabled(roots.autoFrame);
            ui::SliderFloat("radius", &roots.radius, 5.0f, 120.0f);
            ImGui::EndDisabled();
            ui::SliderFloat("azimuth", &roots.azimuth, -(float)M_PI, (float)M_PI);
            ui::SliderFloat("elevation", &roots.elevation, -1.5f, 1.5f);
            ui::SliderFloat("fov", &roots.fov, 0.2f, 1.2f);
        }
        ui::EndHeader();
        ui::PopSection();
        ImGui::Separator();
        ImGui::Separator();
        // shading
        ui::PushSection("material");
        const char* modes[] = {"Phong", "PBR", "Invert (approx)"};
        int sm = (int)R.shaderMode;
        if (ImGui::Combo("shader", &sm, modes, 3)) R.shaderMode = (MetalRootRenderer::ShaderMode)sm;
        ui::ColorEdit3("base color", R.mat.baseColor);
        ui::ColorEdit3("base color 2", R.mat.baseColor2);
        ui::SliderFloat("color noise", &R.mat.colorNoiseStrength, 0.0f, 1.0f);
        ui::SliderFloat("ambient", &R.mat.ambient, 0.0f, 0.5f);
        ui::SliderFloat("diffuse", &R.mat.diffuse, 0.0f, 1.5f);
        ui::SliderFloat("shininess", &R.mat.shininess, 4.0f, 300.0f);
        ui::BeginGate(sm == 1);
        {
            ui::SliderFloat("metallic", &R.pbr.metallic, 0.0f, 1.0f);
            ui::SliderFloat("roughness", &R.pbr.roughness, 0.05f, 1.0f);
        }
        ui::EndGate();
        ui::SliderFloat("radius scale", &R.radiusScale, 0.2f, 4.0f);
        ui::PopSection();           // "material"
        ImGui::Separator();
        // fog
        ui::PushSection("fog & atmosphere");
        ui::BeginHeader("fog & atmosphere", /*default_open=*/false);
        {
            ui::Checkbox("fog on", &R.fog.enabled);
            ui::ColorEdit3("fog color", R.fog.color);
            // Visibility itself is per-phase now (show/<phase>/fog
            // intensity, with beat 1's fade-in on top) -- see the
            // Roots render branch, which writes R.fog.visibility
            // every frame. Everything else about the look stays one
            // global Roots-preset value.
            ImGui::TextDisabled("visibility: set per phase, in the show tab");
            ui::SliderFloat("height scale", &R.fog.heightScale, 2.0f, 120.0f);
            ui::Checkbox("height ref follows target", &R.fog.heightRefAuto);
            if (!R.fog.heightRefAuto)
                ui::SliderFloat("height ref (Y)", &R.fog.heightRef, -20.0f, 60.0f);
            ImGui::Separator();
            ui::Checkbox("clear radius follows camera", &R.fog.startAuto);
            if (R.fog.startAuto)
                ui::SliderFloat("clear radius x orbit", &R.fog.startFrac, 0.0f, 1.5f);
            else
                ui::SliderFloat("clear radius", &R.fog.startDist, 0.0f, 200.0f);
            ImGui::TextDisabled("marching from %.1f u", R.fog.startDist);
            ImGui::Separator();
            ui::SliderFloat("fog noise", &R.fog.noiseStrength, 0.0f, 1.0f);
            ui::SliderFloat("noise contrast", &R.fog.noiseContrast, 0.0f, 3.0f);
            ui::SliderFloat("noise scale", &R.fog.noiseScale, 0.02f, 2.5f);
            ImGui::TextDisabled("feature size ~%.1f world u",
                                8.0f / std::max(R.fog.noiseScale, 1e-3f));
            ui::SliderFloat("drift speed", &R.fog.driftSpeed, 0.0f, 6.0f);
            ui::SliderInt("march steps", &R.fog.steps, 4, 32);
            ui::SliderFloat("noise mip level", &R.fog.noiseLod, 0.0f, 4.0f, "%.1f");
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Which mip of the noise volume the march reads.\n"
                    "Coarser is cheaper (the march is bound by these\n"
                    "fetches) and loses nothing until about 3, where\n"
                    "the finest octave goes.");
            }
            ui::SliderInt("volume downscale", &R.fog.downscale, 1, 4);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "The volumetric integral runs at 1/this of the\n"
                    "output. Depth-aware upsampling keeps it tight to\n"
                    "silhouettes at 3 and 4.");
            }
            ImGui::Separator();
            ui::SliderFloat("scatter (medium albedo)", &R.fog.scatter, 0.0f, 1.5f);
            ui::SliderFloat("anisotropy (fwd <-> back)", &R.fog.anisotropy, -0.9f, 0.9f);
        }
        ui::EndHeader();
        ui::PopSection();
        // pulses
        ui::PushSection("travelling pulses");
        ui::BeginHeader("travelling pulses", /*default_open=*/false);
        {
            ui::Checkbox("pulses on", &R.pulse.enabled);
            ui::SliderFloat("pulse speed", &R.pulse.speed, 0.0f, 40.0f);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "The live structure's train runs continuously, node\n"
                    "distance 0..N under the free-running pulse clock.\n"
                    "A hood structure shows no pulses at all until its\n"
                    "own Reveal marker fires (see roots/reveal); at that\n"
                    "moment its train starts from its seed (top) mask,\n"
                    "node distance 0, and travels outward from there.");
            }
            ui::SliderFloat("pulse spacing", &R.pulse.spacing, 4.0f, 60.0f);
            ui::SliderFloat("pulse width", &R.pulse.width, 0.5f, 12.0f);
            ui::SliderFloat("pulse intensity", &R.pulse.intensity, 0.0f, 4.0f);
            ui::ColorEdit3("pulse color", R.pulse.color);
        }
        ui::EndHeader();
        ui::PopSection();
        ui::PushSection("environment & material");
        ui::BeginHeader("environment & material", /*default_open=*/false);
        {
            // The tranche buttons are a coarse quality dial and the A/B
            // control: each one is a whole group of the settings below,
            // so a look can be compared against the previous stage
            // without hunting for which sliders belonged to it.
            ImGui::TextUnformatted("quality tranche");
            for (int t = 0; t <= 3; ++t) {
                if (t) ImGui::SameLine();
                char lbl[8]; snprintf(lbl, sizeof lbl, "%d", t);
                if (ImGui::RadioButton(lbl, R.tranche() == t)) {
                    R.setTranche(t);
                    roots.rebuildFace();   // smoothNormals is baked into the mesh
                }
            }
            ImGui::SameLine();
            ImGui::TextDisabled("(0 baseline, 3 full)");
            ImGui::TextUnformatted("key light");
            ui::ColorEdit3("key color", R.env.keyColor);
            ui::SliderFloat("key intensity", &R.env.keyIntensity, 0.0f, 4.0f);
            if (roots.micLightResponsive) {
                ImGui::SameLine();
                ImGui::TextDisabled("(live -- set by the mic below)");
            }
            // What a structure the Reveal has popped in but not yet lit
            // keeps of its radiance (see MetalRootRenderer::EnvParams).
            ui::SliderFloat("unlit level", &R.env.unlitLevel, 0.0f, 0.3f);
            ui::SliderFloat("key direction X", &roots.lightDir[0], -1.0f, 1.0f);
            ui::SliderFloat("key direction Y", &roots.lightDir[1], -1.0f, 1.0f);
            ui::SliderFloat("key direction Z", &roots.lightDir[2], -1.0f, 1.0f);
            if (roots.trackLightAngle) {
                ImGui::SameLine();
                ImGui::TextDisabled("(home dir. -- swung by tracking below)");
            }
            ImGui::Separator();
            ImGui::TextUnformatted("key light -- room responsivity");
            ui::Checkbox("intensity follows the mic", &roots.micLightResponsive);
            ui::SliderFloat("base intensity (silence)", &roots.micBaseKeyIntensity,
                            0.0f, 4.0f);
            ui::SliderFloat("mic gain", &roots.micIntensityGain, 0.0f, 4.0f);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Key intensity = base * (1 + gain * mic level).\n"
                    "The mic level is the room's own ambient level\n"
                    "(a real microphone tap -- see mic_level.h), not\n"
                    "anything Wwise is playing.");
            }
            ui::Checkbox("angle follows the tracked visitor",
                        &roots.trackLightAngle);
            ui::SliderFloat("track angle range (rad)", &roots.trackAngleRange,
                            0.0f, 1.5f);

            ImGui::Separator();
            ImGui::TextUnformatted("key light -- placement");
            {
                int lm = (int)roots.lightMode;
                if (ImGui::Combo("aim", &lm,
                        "direction (authored)\0position (place a lamp)\0"
                        "camera-relative\0"))
                    roots.lightMode = (RootScene::LightMode)lm;
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The key stays a single directional light in every\n"
                        "mode -- this is how its direction is decided.\n"
                        "  direction       the X/Y/Z above, dialled by hand\n"
                        "  position        aim from a world point at the\n"
                        "                  focus below; easier to place by eye\n"
                        "  camera-relative offset from the view axis, so the\n"
                        "                  rake stays put as the camera moves");
                }
                // Both arms declare (PANEL.md): the inactive mode's
                // numbers still have to load and save.
                ui::BeginGate(roots.lightMode == RootScene::LightMode::Position);
                {
                    ui::SliderFloat("lamp X", &roots.lightPos[0], -60.f, 60.f);
                    ui::SliderFloat("lamp Y", &roots.lightPos[1], -60.f, 60.f);
                    ui::SliderFloat("lamp Z", &roots.lightPos[2], -60.f, 60.f);
                }
                ui::EndGate();
                ui::BeginGate(roots.lightMode == RootScene::LightMode::CameraRelative);
                {
                    ui::SliderFloat("offset azimuth (rad)",
                                    &roots.lightOffsetAz, -3.14f, 3.14f);
                    ui::SliderFloat("offset elevation (rad)",
                                    &roots.lightOffsetEl, -1.5f, 1.5f);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "A key on the view axis (offset 0) is flat frontal\n"
                            "light with nothing to model the form -- the rake\n"
                            "lives in the off-axis angle.");
                    }
                }
                ui::EndGate();
                int lf = (int)roots.lightFocus;
                if (ImGui::Combo("focus", &lf,
                        "scene centre\0anchor mask\0camera target\0"))
                    roots.lightFocus = (RootScene::LightFocus)lf;
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip("What the lamp aims at.");
                }
                const float* rl = roots.resolvedLightDir();
                const float* rf = roots.resolvedLightFocus();
                ImGui::TextDisabled("live dir (%.2f, %.2f, %.2f)  focus (%.1f, %.1f, %.1f)",
                                    rl[0], rl[1], rl[2], rf[0], rf[1], rf[2]);
            }

            ImGui::Separator();
            ImGui::TextUnformatted("ambient (hemisphere)");
            ui::ColorEdit3("background", R.env.background);
            ui::ColorEdit3("sky color", R.env.skyColor);
            ui::ColorEdit3("ground color", R.env.groundColor);
            ui::SliderFloat("hemisphere", &R.env.hemiStrength, 0.0f, 3.0f);
            ui::SliderFloat("env specular", &R.env.envSpec, 0.0f, 2.0f);
            ui::SliderFloat("rim", &R.env.rimStrength, 0.0f, 1.0f);
            ImGui::Separator();
            ui::SliderFloat("sss wrap", &R.env.sssWrap, 0.0f, 1.5f);
            ui::SliderFloat("sss transmit", &R.env.sssTrans, 0.0f, 2.0f);
            ui::SliderFloat("sss power", &R.env.sssPower, 1.0f, 16.0f);
            ui::ColorEdit3("sss tint", R.env.sssTint);
            ImGui::Separator();
            ImGui::Separator();
            ImGui::TextUnformatted("root surface (fibre detail)");
            ui::SliderFloat("fibre strength", &R.detail.strength, 0.0f, 1.5f);
            ui::SliderFloat("fibre scale", &R.detail.scale, 2.0f, 40.0f);
            ui::SliderFloat("fibre stretch", &R.detail.stretch, 1.0f, 20.0f);
            ui::SliderFloat("fibre break-up", &R.detail.rough, 0.0f, 1.0f);
            ui::SliderFloat("per-root tint", &R.detail.tint, 0.0f, 0.5f);
            ui::SliderFloat("fibre fade px", &R.detail.fadePx, 0.0f, 6.0f, "%.1f");
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Anti-shimmer. Fibre detail is faded out on roots\n"
                    "far enough that one fibre cell projects smaller\n"
                    "than this many screen pixels (full detail from\n"
                    "twice this up). Far roots go smooth instead of\n"
                    "crawling as the camera orbits. 0 = never fade.");
            }
            ImGui::Separator();
            ui::Checkbox("ambient occlusion", &R.ao.enabled);
            ui::SliderFloat("AO radius", &R.ao.radius, 0.2f, 6.0f);
            ui::SliderFloat("AO intensity", &R.ao.intensity, 0.0f, 4.0f);
            ui::SliderInt("AO samples", &R.ao.samples, 4, 24);
            ui::SliderInt("AO downscale", &R.ao.downscale, 1, 4);
        }
        ui::EndHeader();
        ui::PopSection();
        ui::PushSection("post");
        ui::BeginHeader("post", /*default_open=*/false);
        {
            ui::Checkbox("post chain", &R.post.enabled);
            ui::SliderInt("supersample", &R.post.ssaa, 1, 3);
            ImGui::TextDisabled("scene renders at %dx%d", R.width() * R.post.ssaa,
                                R.height() * R.post.ssaa);
            ui::Checkbox("temporal AA", &R.post.taa);
            ui::SliderFloat("TAA blend", &R.post.taaBlend, 0.02f, 1.0f);
            ui::SliderFloat("TAA jitter", &R.post.taaJitter, 0.0f, 1.0f);
            ui::SliderFloat("TAA clip", &R.post.taaClip, 0.0f, 3.0f);
            ui::SliderFloat("TAA sharpen", &R.post.taaSharpen, 0.0f, 1.0f);
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Unsharp mask on the TAA's output, giving back the\n"
                    "edge the temporal blend takes. Clamped to the\n"
                    "neighbours so it does not ring. Only with TAA on.");
            }
            ui::Checkbox("filmic tonemap", &R.post.tonemap);
            ui::SliderFloat("exposure", &R.post.exposure, 0.1f, 4.0f);
            ImGui::Separator();
            ui::Checkbox("bloom", &R.post.bloom);
            ui::SliderFloat("bloom threshold", &R.post.bloomThreshold, 0.2f, 4.0f);
            ui::SliderFloat("bloom intensity", &R.post.bloomIntensity, 0.0f, 1.0f);
            ui::SliderFloat("bloom radius", &R.post.bloomRadius, 0.5f, 3.0f);
            ImGui::Separator();
            ui::Checkbox("depth of field", &R.post.dof);
            ui::SliderFloat("DoF focus (0=auto)", &R.post.dofFocus, 0.0f, 120.0f);
            ui::SliderFloat("DoF focus ease (s)", &R.post.dofFocusEase, 0.0f, 2.0f);
            ui::SliderFloat("DoF range", &R.post.dofRange, 5.0f, 150.0f);
            ui::SliderFloat("DoF strength", &R.post.dofStrength, 0.0f, 1.0f);
            ImGui::Separator();
            ui::SliderFloat("vignette", &R.post.vignette, 0.0f, 1.0f);
            ui::SliderFloat("fog dither", &R.post.fogDither, 0.0f, 1.0f);
            ui::Checkbox("output dither", &R.post.dither);
        }
        ui::EndHeader();
        ui::PopSection();
        ui::PushSection("lens & film");
        ui::BeginHeader("lens & film", /*default_open=*/false);
        {
            ImGui::TextUnformatted("lens");
            if (ImGui::Button("wide angle")) roots.setWideAngle(true);
            ImGui::SameLine();
            if (ImGui::Button("normal")) roots.setWideAngle(false);
            ui::Checkbox("set FOV by focal length", &roots.useFocal);
            ui::BeginGate(roots.useFocal);
            {
                ui::SliderFloat("focal length (mm)", &roots.focalMM, 8.0f, 135.0f);
                ImGui::TextDisabled("35mm equiv · %.0f deg vertical FOV",
                                    roots.effectiveFov() * 2.0f * 57.2957795f);
            }
            ui::EndGate();
            ui::BeginGate(!(roots.useFocal));
            {
                ui::SliderFloat("fov (rad, half-angle)", &roots.fov, 0.15f, 1.2f);
            }
            ui::EndGate();
            ui::SliderFloat("barrel <-> pincushion", &R.post.distortK1, -0.4f, 0.4f);
            ui::SliderFloat("distortion (corners)", &R.post.distortK2, -0.2f, 0.2f);
            ui::SliderFloat("distortion re-crop", &R.post.distortZoom, 0.6f, 1.2f);
            ImGui::Separator();
            ui::SliderFloat("chromatic aberration", &R.post.caStrength, 0.0f, 8.0f);
            ImGui::TextDisabled("px of channel separation at the corner");
            ui::SliderFloat("anamorphic streak", &R.post.streak, 0.0f, 1.0f);
            ui::SliderFloat("streak length", &R.post.streakLength, 2.0f, 60.0f);
            ui::ColorEdit3("streak tint", R.post.streakTint);
            ImGui::Separator();
            ImGui::TextUnformatted("film");
            ui::SliderFloat("halation", &R.post.halation, 0.0f, 1.0f);
            ui::ColorEdit3("halation tint", R.post.halationTint);
            ui::SliderInt("halation spread (mip)", &R.post.halationMip, 0, 4);
            ImGui::Separator();
            ui::SliderFloat("grain", &R.post.grain, 0.0f, 0.12f);
            ui::SliderFloat("grain size (px)", &R.post.grainSize, 1.0f, 6.0f);
            ui::SliderFloat("grain chroma", &R.post.grainChroma, 0.0f, 1.0f);
            ImGui::Separator();
            ImGui::TextUnformatted("print grade");
            ui::SliderFloat("contrast", &R.post.contrast, 0.5f, 2.0f);
            ui::SliderFloat("saturation", &R.post.saturation, 0.0f, 2.0f);
            ui::SliderFloat("split strength", &R.post.splitStrength, 0.0f, 1.0f);
            ui::SliderFloat("split balance (-1 off)", &R.post.toneBalance, -1.0f, 1.0f);
            ui::ColorEdit3("shadow tint", R.post.shadowTint);
            ui::ColorEdit3("highlight tint", R.post.highlightTint);
            ui::ColorEdit3("lift", R.post.lift);
            ui::ColorEdit3("gamma", R.post.gammaC);
            ui::ColorEdit3("gain", R.post.gain);
            if (ImGui::Button("reset grade")) {
                R.post.contrast = 1.f; R.post.saturation = 1.f;
                for (int i = 0; i < 3; ++i) {
                    R.post.lift[i] = 0.f; R.post.gammaC[i] = 1.f; R.post.gain[i] = 1.f;
                }
            }
        }
        ui::EndHeader();
        ui::PopSection();
        ui::PushSection("glitch");
        ui::BeginHeader("glitch", /*default_open=*/false);
        {
            ImGui::TextUnformatted("bitcrush");
            ui::SliderFloat("crush", &R.post.crush, 0.0f, 1.0f);
            ImGui::TextDisabled("0 is bit-exact; the dial drives block "
                                "size and level count together");
            ui::BeginGate(R.post.crush > 0.0f);
            {
                ui::SliderFloat("block size (px)", &R.post.crushBlock, 1.0f, 64.0f);
                ImGui::TextDisabled("output is %.0fx%.0f blocks at full crush",
                                    (float)R.width() / std::max(R.post.crushBlock, 1.0f),
                                    (float)R.height() / std::max(R.post.crushBlock, 1.0f));
                ui::SliderFloat("colour levels", &R.post.crushLevels, 2.0f, 32.0f);
                ui::SliderFloat("crush dither", &R.post.crushDither, 0.0f, 2.0f);
            }
            ui::EndGate();
            ImGui::Separator();
            ImGui::TextUnformatted("datamosh");
            ui::Checkbox("mosh (hold)", &R.post.mosh);
            ImGui::SameLine();
            if (ImGui::Button("trigger")) R.triggerDatamosh(R.post.moshTrigger);
            ui::SliderFloat("trigger length (s)", &R.post.moshTrigger, 0.1f, 10.0f);
            ui::SliderFloat("vector freeze (s)", &R.post.moshFreeze, 0.0f, 8.0f);
            ImGui::TextDisabled("how long the motion field stays fixed after "
                                "it starts; 0 = for the whole run");
            ui::SliderFloat("mosh amount", &R.post.moshAmount, 0.0f, 1.0f);
            ui::SliderFloat("vector gain", &R.post.moshGain, 0.0f, 6.0f);
            ui::SliderFloat("macroblock (px)", &R.post.moshBlock, 1.0f, 64.0f);
            ui::SliderFloat("background depth", &R.post.moshBgDepth, 5.0f, 400.0f);
            ImGui::TextDisabled(R.datamoshActive() ? "moshing" : "idle");
            ImGui::Separator();
            ImGui::TextUnformatted("pixel sort");
            ui::Checkbox("sort", &R.post.sort);
            ui::BeginGate(R.post.sort);
            {
                ui::SliderFloat("sort amount", &R.post.sortAmount, 0.0f, 1.0f);
                ui::SliderFloat("band low", &R.post.sortLow, 0.0f, 1.0f);
                ui::SliderFloat("band high", &R.post.sortHigh, 0.0f, 1.0f);
                ImGui::TextDisabled("only pixels inside the band move, so the "
                                    "band's edges are where the spans break");
                ui::SliderInt("passes/frame", &R.post.sortPasses, 1, 8);
                ImGui::TextDisabled("the sort converges over frames; this is "
                                    "how fast");
                ui::SliderFloat("live feed", &R.post.sortFeed, 0.0f, 0.5f);
                int axis = R.post.sortAxis;
                if (ImGui::RadioButton("columns", axis == 0)) R.post.sortAxis = 0;
                ImGui::SameLine();
                if (ImGui::RadioButton("rows", axis == 1)) R.post.sortAxis = 1;
                ui::Checkbox("bright first", &R.post.sortDescending);
            }
            ui::EndGate();
        }
        ui::EndHeader();
        ui::PopSection();
        ui::PushSection("face masks");
        ui::BeginHeader("face masks", /*default_open=*/false);
        {
            if (ui::Checkbox("show faces", &roots.showFace)) roots.rebuildFace();
            if (ui::SliderFloat("face scale", &roots.faceScale, 0.3f, 1.5f))
                roots.rebuildFace();
            if (ui::SliderFloat("face recess", &roots.faceRecess, -2.0f, 1.5f))
                roots.rebuildFace();
            ImGui::TextDisabled("cavity half-depths back along the normal;\n"
                                "negative stands the face proud of the nest");
            ui::SliderFloat("face light", &R.face.lightIntensity, 0.0f, 8.0f);
            ui::ColorEdit3("face light color", R.face.lightColor);
            ui::SliderFloat("face falloff", &R.face.lightFalloff, 0.001f, 0.1f);
            ui::SliderFloat("spot outer angle", &R.face.spotOuterDeg, 5.0f, 90.0f);
            ui::SliderFloat("spot inner angle", &R.face.spotInnerDeg, 1.0f, 89.0f);
            ImGui::TextDisabled("90 outer = no cone (bare point light)");
            ui::SliderFloat("face spec", &R.face.specStrength, 0.0f, 3.0f);
            ui::SliderFloat("mask roughness", &R.face.roughness, 0.04f, 1.0f);
            if (ui::SliderFloat("albedo level", &R.face.albedoLevel, 0.0f, 0.8f))
                roots.rebuildFace();
            ui::SliderFloat("albedo gamma", &R.face.albedoGamma, 1.0f, 3.0f);
            ui::SliderFloat("albedo saturation", &R.face.albedoSat, 0.0f, 3.0f);
            ImGui::TextDisabled("level: mean brightness every face is brought\n"
                                "to before the decode (0 = the camera's own);\n"
                                "gamma 1 = as-is (pale), 2.2 = sRGB; sat 1 = as-is");
            if (ui::Checkbox("smooth normals", &R.face.smoothNormals))
                roots.rebuildFace();
            ui::SliderFloat("mask sss wrap", &R.face.sssWrap, 0.0f, 1.5f);
            ui::SliderFloat("mask sss transmit", &R.face.sssTrans, 0.0f, 2.0f);
            ui::SliderFloat("mask sss power", &R.face.sssPower, 1.0f, 16.0f);
            ui::ColorEdit3("mask sss tint", R.face.sssTint);
            ImGui::TextDisabled("the mask's own subsurface terms (the roots'\n"
                                "are under environment); transmit is also\n"
                                "how much of the pluck flash shows through");
        }
        ui::EndHeader();
        ui::PopSection();
        ui::PushSection("pluck flash");
        ui::BeginHeader("pluck flash", /*default_open=*/false);
        {
            ImGui::TextDisabled("a point light inside one mask on each pluck\n"
                                "marker, orbit only; 0 intensity = off");
            ui::SliderFloat("flash intensity", &R.flash.intensity, 0.0f, 60.0f);
            ui::ColorEdit3("flash color", R.flash.color);
            ui::SliderFloat("flash radius", &R.flash.radius, 0.2f, 12.0f);
            ui::SliderFloat("flash decay (s)", &R.flash.decaySeconds, 0.05f, 4.0f);
            ui::SliderFloat("flash depth", &R.flash.depth, -1.0f, 2.0f);
            ImGui::TextDisabled("x the mask's cavity half-depth, back along\n"
                                "its facing; negative is in front of the face");
            ui::Checkbox("flash all masks", &R.flash.all);
            ui::Checkbox("flash nearest mask", &R.flash.nearest);
            ui::Checkbox("flash mask 0", &R.flash.mask0);
            ImGui::TextDisabled("mask 0 = the visitor's own face");
            ui::Checkbox("glitch mask", &R.flash.glitch);
            ui::SliderFloat("glitch duration (s)", &R.flash.glitchSeconds, 0.05f, 4.0f);
            ui::SliderFloat("glitch amount", &R.flash.glitchAmount, 0.0f, 1.0f);
            ui::SliderFloat("glitch noise", &R.flash.glitchNoise, 0.0f, 2.0f);
            ui::SliderFloat("glitch noise share", &R.flash.glitchNoiseShare, 0.0f, 1.0f);
            ui::Checkbox("glitch swaps mask", &R.flash.glitchSwap);
            ImGui::TextDisabled("the flashed mask's triangles get random vertex\n"
                                "indices, redrawn every frame, on a 0-1-0 wave\n"
                                "over the duration; amount = the share torn at\n"
                                "the peak. noise = how far (world units) a\n"
                                "share of the torn corners are pushed, both on\n"
                                "the wave. swap: at the peak it is dealt another\n"
                                "bank face (never mask 0)");
            if (ImGui::Button("fire flash")) roots.triggerFlash();
        }
        ui::EndHeader();
        ui::PopSection();
        ui::PushSection("cached field: LOD & culling");
        ui::BeginHeader("cached field: LOD & culling", /*default_open=*/false);
        {
            ui::SliderInt("grid NxN", &fieldGrid, 2, 20);
            if (ImGui::Button("tile field")) roots.buildField(fieldGrid, 30.0f);
            ImGui::SameLine();
            if (ImGui::Button("clear field")) { R.clearInstances(); roots.regrow(); }
            ui::Checkbox("frustum cull", &R.cullInstances); ImGui::SameLine();
            ui::Checkbox("sub-pixel cull", &R.subpixelCull);
            ui::SliderFloat("cull below px", &R.instanceCullPx, 0.5f, 20.0f);
            ui::SliderFloat("LOD bias (>1 coarser)", &R.lodBias, 0.1f, 4.0f);
            ui::SliderFloat("min radius px", &R.minRadiusPx, 0.f, 3.f, "%.2f");
            if (ImGui::IsItemHovered()) {
                ImGui::SetTooltip(
                    "Anti-shimmer for thin roots. A capsule projecting\n"
                    "thinner than this many screen pixels is drawn this\n"
                    "thick and dimmed by the ratio, so a hairline root\n"
                    "at orbit distance is a steady faint line rather\n"
                    "than one flashing in and out as the camera moves.\n"
                    "0 = off. Also relaxes the sub-pixel cull below it.");
            }
            ImGui::Text("instances %d   visible %d   culled %d",
                        R.instanceCount(), R.lastVisibleInstances, R.lastCulledInstances);
            ImGui::Text("capsules drawn: %ld", R.lastDrawnSegments);
        }
        ui::EndHeader();
        ui::PopSection();
        ui::PushSection("overlays");
        ui::BeginHeader("overlays", /*default_open=*/false);
        {
            ui::Checkbox("axes", &R.overlay.showAxes); ImGui::SameLine();
            ui::Checkbox("grid", &R.overlay.showGrid);
            ui::SliderFloat("grid spacing", &R.overlay.gridSpacing, 1.0f, 20.0f);
        }
        ui::EndHeader();
        ui::PopSection();
    ui::PopSection();          // "roots"
}

void DrawControlPanel(PanelFrameArgs& pf) {
            // --- the panel, drawn (or not) --------------------------------
            //
            // Hidden means invisible and click-through, *not* unsubmitted: a
            // control takes its pending MIDI or preset value at the moment it
            // is declared, and it is declared as it is drawn (see ui_params.h).
            // A panel that stopped drawing would quietly stop the knobs
            // working, which is the opposite of what hiding it is for.
            //
            // While hidden it is also pulled back into the main window, so a
            // detached panel does not leave an empty transparent OS window
            // behind; its position is remembered and restored on the way back
            // out, since the trip through the main viewport can clamp it.
            static ImVec2 panel_pos(20, 20);
            static bool panel_was_hidden = false;
            static bool panel_was_detached = g_ui_detached;
            static int  panel_frames = 0;
            const ImGuiViewport* mainvp = ImGui::GetMainViewport();
            const bool panel_hidden = !g_ui_visible;
            ImVec2 want_pos, want_size;
            bool want_pos_set = false, want_size_set = false;
            if (panel_hidden) {
                ImGui::SetNextWindowViewport(mainvp->ID);
                ImGui::PushStyleVar(ImGuiStyleVar_Alpha, 0.f);
            } else {
                // Every launch, not just a first-ever run: imgui.ini persists
                // window position across runs, so ImGuiCond_FirstUseEver below
                // does nothing once the panel has been drawn once, ever -- the
                // panel would otherwise come back exactly where it was left,
                // including off-screen or on a monitor that got unplugged.
                // panel_frames is still 0 the first time this function runs
                // this process, so it is what "first frame of this launch"
                // means here; forcing the position (not the size) only on
                // that frame leaves the operator free to drag it anywhere
                // afterwards, same as before.
                if (panel_frames == 0) {
                    want_pos = ImVec2(mainvp->WorkPos.x + 8, mainvp->WorkPos.y + 8);
                    want_pos_set = true;
                }
                // One SetNextWindowPos call, decided here. ImGui keeps a single
                // pending position per frame, so a later default with
                // ImGuiCond_FirstUseEver does not "fall through" -- it replaces
                // whatever was asked for above it, which is a silent way to
                // make every reposition below do nothing at all.
                if (panel_was_hidden) { want_pos = panel_pos; want_pos_set = true; }
                // Coming back in -- the box unticked, or --reset-panel for a
                // panel that imgui.ini has parked on a monitor that is not
                // plugged in any more. Over the main window is the only place a
                // panel that is not its own window can be.
                const bool attaching = (panel_was_detached && !g_ui_detached);
                if (attaching || g_panel_reset) {
                    want_pos = ImVec2(mainvp->WorkPos.x + 20,
                                      mainvp->WorkPos.y + 20);
                    want_pos_set = true;
                    if (g_panel_reset) {
                        want_size = ImVec2(340, 0);
                        want_size_set = true;
                        ImGui::SetNextWindowCollapsed(false, ImGuiCond_Always);
                        g_panel_reset = false;
                    }
                }
                if (!g_ui_detached) {
                    // Attached is pinned, every frame, not just on the edge:
                    // ImGui re-picks a window's viewport each frame, and a
                    // window that has owned one takes it straight back the
                    // frame after it is handed to the main viewport. Pinning is
                    // what makes the checkbox mean something in both
                    // directions -- and while it is ticked off, the panel
                    // behaves the way it did before viewports existed: inside
                    // the window, clipped by it.
                    ImGui::SetNextWindowViewport(mainvp->ID);
                    // Pinned, a window still keeps whatever desktop position it
                    // had -- including one from when it was its own OS window
                    // on another monitor, which draws the panel off the corner
                    // of the frame with most of it clipped away. So attached
                    // also means inside: anything outside is pulled back in.
                    const ImVec2 lo = mainvp->WorkPos;
                    const ImVec2 hi(mainvp->WorkPos.x + mainvp->WorkSize.x - 120.f,
                                    mainvp->WorkPos.y + mainvp->WorkSize.y - 80.f);
                    if (panel_pos.x < lo.x || panel_pos.y < lo.y ||
                        panel_pos.x > hi.x || panel_pos.y > hi.y) {
                        want_pos = ImVec2(std::min(std::max(panel_pos.x, lo.x + 20.f),
                                                   std::max(lo.x + 20.f, hi.x)),
                                          std::min(std::max(panel_pos.y, lo.y + 20.f),
                                                   std::max(lo.y + 20.f, hi.y)));
                        want_pos_set = true;
                    }
                    // And it has to *fit*: ImGui only merges a window into the
                    // main one when the main one contains it whole, and this
                    // panel is taller than a 720p window with two sections
                    // open. Without the cap, unticking the box pops the panel
                    // straight back out and the checkbox looks broken.
                    // Detached, the height is the operator's business.
                    ImGui::SetNextWindowSizeConstraints(
                        ImVec2(0, 0),
                        ImVec2(FLT_MAX, std::max(200.f, mainvp->WorkSize.y - 40.f)));
                } else if (panel_frames > 0) {
                    // The one window allowed to leave the frame on its own.
                    // Done per-window rather than with ConfigViewportsNoAutoMerge
                    // so the cam-mask and source overlays stay welded to the
                    // composition they annotate.
                    //
                    // Never on the panel's first frame: the window has no size
                    // until it has been drawn once, and a zero-size viewport
                    // gets no platform window -- which the GLFW backend then
                    // dereferences as it polls focus, and the app is gone
                    // before it has drawn anything.
                    //
                    // TopMost as well as NoAutoMerge. The composition runs in a
                    // borderless-fullscreen window, which is an ordinary window
                    // as far as the window server is concerned -- so a panel at
                    // the same level can end up *behind* it, and a panel behind
                    // a fullscreen window is one macOS reports as occluded.
                    // imgui_impl_metal skips rendering an occluded viewport
                    // (nextDrawable hangs for about a second on one, so it has
                    // to), and a panel that is never redrawn is a black
                    // rectangle you cannot get back. Floating keeps it above
                    // the piece, which is where an operator's panel belongs
                    // anyway.
                    ImGuiWindowClass wc;
                    wc.ViewportFlagsOverrideSet = ImGuiViewportFlags_NoAutoMerge |
                                                  ImGuiViewportFlags_TopMost;
                    ImGui::SetNextWindowClass(&wc);
                }
            }
            panel_was_hidden = panel_hidden;

            if (want_pos_set) ImGui::SetNextWindowPos(want_pos, ImGuiCond_Always);
            else ImGui::SetNextWindowPos(ImVec2(20, 20), ImGuiCond_FirstUseEver);
            if (want_size_set) ImGui::SetNextWindowSize(want_size, ImGuiCond_Always);
            else ImGui::SetNextWindowSize(ImVec2(340, 0), ImGuiCond_FirstUseEver);
            // The frame rate lives in the title, where it is readable with the
            // panel scrolled anywhere and with the window collapsed. Everything
            // before "###" is the visible title and everything after is the id,
            // so the rate can change every frame without imgui.ini losing track
            // of where this window was put -- a title that is also an id would
            // make the panel a new window sixty times a second.
            char panel_title[128];
            snprintf(panel_title, sizeof(panel_title),
                     "neuromirror — %.0f fps###controls", pf.fpsShown);
            ImGui::Begin(panel_title, nullptr,
                         panel_hidden ? (ImGuiWindowFlags_NoInputs |
                                         ImGuiWindowFlags_NoNav |
                                         ImGuiWindowFlags_NoFocusOnAppearing |
                                         ImGuiWindowFlags_NoSavedSettings)
                                      : 0);
            ++panel_frames;
            if (!panel_hidden) {
                panel_pos = ImGui::GetWindowPos();
                // Where the panel lives is remembered by this app rather than
                // read back out of imgui.ini: the .ini says where a window is,
                // not why, and a panel that came up in its own viewport merely
                // because its saved position missed the main window would
                // otherwise be recorded as a choice the operator made.
                if (g_ui_detached != panel_was_detached || panel_frames == 2) {
                    if (panel_frames != 2) PanelStateSave(g_ui_detached);
                    printf("panel: %s\n", g_ui_detached ? "in its own window"
                                                        : "in the main window");
                    fflush(stdout);
                }
                panel_was_detached = g_ui_detached;
            }
            ImGui::Text("t=%5.1fs", pf.mirror.clock());     // fps is in the title
            ImGui::SameLine();
            ImGui::Checkbox("own window", &g_ui_detached);
            if (ImGui::IsItemHovered())
                ImGui::SetTooltip(
                    "Give the panel its own OS window, to move to a second\n"
                    "monitor (or off the composition on a single one).\n"
                    "Untick to bring it back over the main window.");
            ImGui::SameLine();
            if (ImGui::Button("hide")) g_ui_visible = false;
            if (ImGui::IsItemHovered())
                ImGui::SetTooltip("Hide the whole UI. F1 or ` brings it back\n"
                                  "(on macOS F1 may need fn).");
            // --- phase navigator ------------------------------------------
            //
            // Above the tabs and outside them, because it is not a setting: it
            // is where the piece currently is. The tabs below are categories of
            // parameter and nothing else -- opening the roots tab to adjust a
            // fog value must not cut the projection to the root scene, which is
            // what a tab that doubled as a scene picker did.
            //
            // Everything here goes through the timeline. "go" takes the phase's
            // forward edge, which is the operator's cue; the named buttons force
            // a phase outright. Both count as entries, so the scene restarts and
            // the per-phase setup runs identically either way.
            {
                const show::Phase cur = g_show.phase();
                ImGui::TextUnformatted("phase:");
                for (int p = 0; p < (int)show::Phase::Count; ++p) {
                    ImGui::SameLine();
                    const bool on = (p == (int)cur) && g_view_override < 0;
                    if (on) ImGui::PushStyleColor(ImGuiCol_Button,
                                                  ImVec4(0.26f, 0.45f, 0.30f, 1.f));
                    if (ImGui::Button(show::PhaseName((show::Phase)p))) {
                        g_view_override = -1;
                        g_show.goTo((show::Phase)p);
                    }
                    if (on) ImGui::PopStyleColor();
                }
                ImGui::SameLine();
                if (ImGui::Button("go >")) {
                    // A cue is still a cue while paused: freezing the clock
                    // should stop the piece running away on its own, not take
                    // the operator's hands off it.
                    g_view_override = -1;
                    g_show_paused = false;
                    g_show.go();
                }
                if (ImGui::IsItemHovered())
                    ImGui::SetTooltip(
                        "Take this phase's forward edge now, whatever it was\n"
                        "waiting for. The same cue as the MIDI CC and the key.");

                // Pause freezes the timeline where it stands. Distinct from
                // unticking "run the show", which is a mode and re-arms from
                // the top: this holds the current phase, at its current time,
                // and resumes into it. In the root scene it holds the scene
                // itself too (main.mm's rootHold), which is why it is also
                // offered with the show off while that scene is up: the
                // sequence runs off the phase, not the show mode.
                ImGui::SameLine();
                const bool can_pause = g_show_on || g_root_stage >= 0;
                ImGui::BeginDisabled(!can_pause);
                if (g_show_paused) ImGui::PushStyleColor(ImGuiCol_Button,
                                                         ImVec4(0.55f, 0.42f, 0.16f, 1.f));
                if (ImGui::Button(g_show_paused ? "paused" : "pause"))
                    g_show_paused = !g_show_paused;
                if (g_show_paused) ImGui::PopStyleColor();
                ImGui::EndDisabled();
                if (ImGui::IsItemHovered())
                    ImGui::SetTooltip(
                        can_pause ? "Hold the timeline where it is. The phase and\n"
                                    "its clock keep their values and resume from\n"
                                    "them. In Transition/Roots the scene holds too:\n"
                                    "sequence, growth, cloth, face playback and\n"
                                    "fog fade all stand still, still rendering, so\n"
                                    "lighting and material changes show on the\n"
                                    "held frame. Idle and Fitting keep animating."
                                  : "Nothing to pause: the show is not running and\n"
                                    "the root scene is not up. The phase buttons\n"
                                    "drive it by hand.");

                ImGui::SameLine();
                ImGui::TextDisabled("| %.1fs", g_show.phaseTime());
                if (g_show.maxTime(cur) > 0.f) {
                    ImGui::SameLine();
                    ImGui::ProgressBar(g_show.phaseProgress(), ImVec2(70, 0));
                }

                // The diagnostic views sit apart, and say so: they are not part
                // of the running order and leaving one on is a mistake worth
                // making visible rather than one more button in the same row.
                ImGui::TextUnformatted("view:");
                struct ViewBtn { const char* name; int scene; };
                const ViewBtn views[] = {{"camera",    (int)Scene::Camera},
                                         {"fit view",  (int)Scene::FitView},
                                         {"cam mask",  (int)Scene::CamMask}};
                for (const ViewBtn& v : views) {
                    ImGui::SameLine();
                    const bool on = (g_view_override == v.scene);
                    if (on) ImGui::PushStyleColor(ImGuiCol_Button,
                                                  ImVec4(0.55f, 0.42f, 0.16f, 1.f));
                    if (ImGui::Button(v.name))
                        g_view_override = on ? -1 : v.scene;
                    if (on) ImGui::PopStyleColor();
                }
                if (g_view_override >= 0) {
                    ImGui::SameLine();
                    ImGui::TextColored(ImVec4(1.f, 0.85f, 0.4f, 1.f),
                                       "overriding %s", show::PhaseName(cur));
                }
            }
            ImGui::Separator();

            // --- show -----------------------------------------------------
            // Above everything else, because when it is on it is what is
            // choosing the scene: a panel that showed the radio buttons as the
            // authority while a timeline was reassigning them would be lying.
            ui::BeginTabBar("panel");
            int panel_test_tab_i = 0;
            g_panel_test_tab_count = 9;
            ui::BeginTab("show", g_panel_test && g_panel_test_tab == panel_test_tab_i++);
            ui::PushSection("show");
            {
                if (ui::Checkbox("run the show", &g_show_on) && g_show_on)
                    g_show.restart();
                ImGui::SameLine();
                ImGui::BeginDisabled(!g_show_on);
                if (ImGui::Button("restart")) g_show.restart();
                ImGui::EndDisabled();
                ImGui::SameLine();
                // Plain ImGui, not a ui:: control: the readout is UI state,
                // like the panel itself, not a parameter -- a show preset
                // that carried it on put the diagnostics over the piece at
                // every launch. Off at start, F2 (or this) turns it on.
                ImGui::Checkbox("readout (F2)", &g_show_hud);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Phase, what it is waiting for, and how the fit is\n"
                        "doing, in a corner -- with or without this panel.");
                }

                if (g_show_on) {
                    const show::Phase p = g_show.phase();
                    ImGui::Text("%s  %.1fs", show::PhaseName(p), g_show.phaseTime());
                    if (g_show.maxTime(p) > 0.f) {
                        ImGui::SameLine();
                        ImGui::ProgressBar(g_show.phaseProgress(), ImVec2(90, 0));
                    }
                    ImGui::TextDisabled("%s", g_show.lastReason().c_str());

                    // The two signals, live. Nearly every "why did it not
                    // advance" question is answered by looking at these while
                    // standing in front of the camera.
                    const bool face = ShowFacePresent();
                    const bool fit = ShowFitConverged();
                    ImGui::TextColored(face ? ImVec4(0.4f, 0.9f, 0.4f, 1)
                                            : ImVec4(0.5f, 0.5f, 0.5f, 1),
                                       "face");
                    ImGui::SameLine();
                    ImGui::TextColored(fit ? ImVec4(0.4f, 0.9f, 0.4f, 1)
                                           : ImVec4(0.5f, 0.5f, 0.5f, 1),
                                       "fit");
                    ImGui::SameLine();
                    if (g_id_residual >= 0.f)
                        ImGui::TextDisabled("(%.1f px)", g_id_residual);
                    else
                        ImGui::TextDisabled(g_collect_id ? "(collecting)" : "(none)");

                    if (!g_track_on) {
                        ImGui::TextColored(ImVec4(1, 0.5f, 0.3f, 1),
                                           "face tracking is off: the show");
                        ImGui::TextColored(ImVec4(1, 0.5f, 0.3f, 1),
                                           "can only advance on time");
                    }

                    ImGui::SeparatorText("force");
                    for (int i = 0; i < (int)show::Phase::Count; ++i) {
                        if (i) ImGui::SameLine();
                        if (ImGui::SmallButton(show::PhaseName((show::Phase)i)))
                            g_show.goTo((show::Phase)i);
                    }
                    if (ImGui::SmallButton("go")) g_show.go();
                    ImGui::SameLine();
                    ImGui::TextDisabled("(keys 1-4, space)");
                }

                ui::BeginHeader("phase -> scene", /*default_open=*/false);
                {
                    const char* kScenes[] = {"mirror", "roots", "transition",
                                             "fit view", "cam mask"};
                    for (int i = 0; i < (int)show::Phase::Count; ++i) {
                        ImGui::SetNextItemWidth(120);
                        ImGui::Combo(show::PhaseName((show::Phase)i),
                                     &g_show_scene[i], kScenes, IM_ARRAYSIZE(kScenes));
                        ui::DeclareInt(show::PhaseName((show::Phase)i),
                                       &g_show_scene[i], 0, IM_ARRAYSIZE(kScenes) - 1);
                    }
                }
                ui::EndHeader();

                // --- per-phase timing, grouped by phase --------------------
                //
                // One header per phase: its floor/ceiling, its edges'
                // debounce (labelled by the graph's own key names, so the
                // panel and Graph() can never name a knob differently), and
                // its fog intensity. Roots additionally carries its beat
                // schedule; Idle carries the fade-in that follows Roots'
                // outro. Declared every frame regardless of which header is
                // open, per PANEL.md -- setTiming/setHold are cheap and do
                // not touch the running clock, so calling them from a value a
                // preset just wrote is exactly as safe as calling them from a
                // dragged slider.
                for (int pi = 0; pi < (int)show::Phase::Count; ++pi) {
                    const show::Phase p = (show::Phase)pi;
                    const show::PhaseGraph& g = show::Graph(p);
                    ui::Section sec(show::PhaseName(p));
                    // The phases are named "roots" and "transition", which are
                    // also bank rules -- and a section matching a rule takes
                    // that bank at any depth (see kBankRules). These are the
                    // running order, not the root scene's look, so say so:
                    // everything under show/<phase> is saved with the show.
                    ui::SetBank(ui::Bank::Show);
                    ui::BeginHeader(show::PhaseName(p), /*default_open=*/false);
                    {
                        ui::SliderFloat("min", &g_show_min[pi], 0.f, 120.f, "%.1fs");
                        ui::SliderFloat("max (0 = no ceiling)", &g_show_max[pi],
                                        0.f, 120.f, "%.1fs");
                        for (int e = 0; e < g.edge_count; ++e) {
                            // Idle's face_hold is the main Idle timing control
                            // (min is 0 by default -- see show_timeline.cpp),
                            // so it gets a plainer label and a tooltip saying
                            // so, rather than the graph's own edge key.
                            const bool is_idle_face_hold =
                                p == show::Phase::Idle &&
                                std::string(g.edges[e].key) == "face_hold";
                            ui::SliderFloat(is_idle_face_hold ? "face hold s"
                                                              : g.edges[e].key,
                                            &g_show_hold[pi][e], 0.f, 30.f, "%.1fs");
                            if (is_idle_face_hold && ImGui::IsItemHovered()) {
                                ImGui::SetTooltip(
                                    "How long a face must be seen in Idle before\n"
                                    "Fitting starts -- the main Idle timing\n"
                                    "control.");
                            }
                            if (is_idle_face_hold) {
                                ui::SliderFloat("face drop grace s",
                                                &g_show_grace[pi][e], 0.f, 3.f, "%.1fs");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "How long a dropped face frame is\n"
                                        "forgiven before the face-hold clock\n"
                                        "resets -- so one missed detection does\n"
                                        "not throw away an almost-there hold.");
                                }
                            }
                        }
                        if (p == show::Phase::Roots)
                            ui::SliderFloat("fog intensity (visibility, world u)",
                                            &g_roots_fog_intensity, 8.f, 600.f, "%.0f",
                                            ImGuiSliderFlags_Logarithmic);
                        g_show.setTiming(p, g_show_min[pi], g_show_max[pi]);
                        for (int e = 0; e < g.edge_count; ++e) {
                            g_show.setHold(p, e, g_show_hold[pi][e]);
                            g_show.setGrace(p, e, g_show_grace[pi][e]);
                        }

                        if (p == show::Phase::Idle) {
                            ui::SliderFloat("intro fade-in (s)", &g_idle_intro_seconds,
                                            0.f, 8.f, "%.1f");
                            if (ImGui::IsItemHovered()) {
                                ImGui::SetTooltip(
                                    "How long Idle takes to fade in from black on\n"
                                    "entry -- every entry, not only the one after\n"
                                    "Roots' outro, so a fresh boot fades in too.");
                            }
                        }

                        if (p == show::Phase::Roots) {
                            // The Roots timeline (RootSequence, root_sequence.h):
                            // one stage after another, every duration and angle
                            // authored here. Sub-headers are presentation only
                            // (BeginHeader adds no path level), so every key is
                            // a flat `show/roots/<label>`.
                            RootSequenceParams& S = g_root_seq;
                            // Jump to a stage: actions, not parameters, so raw
                            // ImGui buttons (nothing registers, nothing is
                            // saved -- the same way the sound tab's cue
                            // buttons are done). The request goes through
                            // g_root_jump to main.mm, which owns the sequence
                            // and honours it before the next step; g_root_stage
                            // is its readout of where the sequence is.
                            {
                                const bool live = g_root_stage >= 0;
                                ImGui::TextUnformatted("jump to:");
                                ImGui::BeginDisabled(!live);
                                struct JumpBtn { const char* name; RootSequence::Stage s; };
                                const JumpBtn jumps[] = {
                                    {"face",   RootSequence::Stage::Face},
                                    {"grow",   RootSequence::Stage::Grow},
                                    {"turn",   RootSequence::Stage::Turn},
                                    {"orbit",  RootSequence::Stage::Orbit},
                                    {"outro",  RootSequence::Stage::Outro},
                                };
                                bool hovered = false;
                                for (const JumpBtn& j : jumps) {
                                    ImGui::SameLine();
                                    const bool on = live && g_root_stage == (int)j.s;
                                    if (on) ImGui::PushStyleColor(ImGuiCol_Button,
                                                                  ImVec4(0.26f, 0.45f, 0.30f, 1.f));
                                    // "##jump": the stage headers below carry the
                                    // same labels, and ImGui IDs by label.
                                    if (ImGui::Button((std::string(j.name) + "##jump").c_str()))
                                        g_root_jump = (int)j.s;
                                    if (on) ImGui::PopStyleColor();
                                    hovered = hovered ||
                                              ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled);
                                }
                                ImGui::EndDisabled();
                                if (hovered) {
                                    ImGui::SetTooltip(
                                        live ? "Cut to the start of this stage, snapped: the\n"
                                               "chain grown or reseeded, the hood placed or\n"
                                               "dropped, the camera on the stage's opening\n"
                                               "pose. The stage then runs on from there --\n"
                                               "pause to hold the frame. Orbit still lights\n"
                                               "one structure per marker after a jump."
                                             : "The root sequence is not running: it only\n"
                                               "runs while the phase is Transition or Roots\n"
                                               "(and the plant has a layout). Jump there\n"
                                               "from the phase row first.");
                                }
                            }
                            ui::BeginHeader("face", false);
                            {
                                ui::SliderFloat("face seconds", &S.face_seconds, 0.2f, 20.f, "%.1f");
                                ui::SliderFloat("face hold after cloth s", &S.face_hold_after_cloth_seconds,
                                                0.f, 30.f, "%.1f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "How long the live face stays on mask 0 after\n"
                                        "the cloth has fallen, before it freezes and the\n"
                                        "roots grow; the visitor's face is recorded\n"
                                        "through this window.");
                                }
                                ui::SliderFloat("fog fade seconds", &S.fog_fade_seconds, 0.f, 20.f, "%.1f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Fog only exists in the Roots renderer, so it\n"
                                        "would otherwise pop on the instant the cloth\n"
                                        "falls away. This ramps visibility from clear\n"
                                        "down to the phase's fog intensity over the\n"
                                        "start of Face instead.");
                                }
                            }
                            ui::EndHeader();
                            ui::BeginHeader("grow", false);
                            {
                                ui::SliderFloat("grow face seconds", &S.grow_face_seconds, 0.5f, 60.f, "%.1f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Seconds per target face. The growth rate is\n"
                                        "derived from the plant's own step count so it\n"
                                        "lands on time whatever the layout, then clamped\n"
                                        "into the rate range below. The whole chain takes\n"
                                        "(masks - 1) x this, after the swing.");
                                }
                                ui::SliderFloat("grow rate min (steps-s)", &S.grow_rate_min, 1.f, 2000.f,
                                                "%.0f", ImGuiSliderFlags_Logarithmic);
                                ui::SliderFloat("grow rate max (steps-s)", &S.grow_rate_max, 1.f, 2000.f,
                                                "%.0f", ImGuiSliderFlags_Logarithmic);
                                ui::SliderFloat("movement boosts rate", &S.grow_move_boost, 0.f, 4.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "The growth rate x (1 + this x the visitor's\n"
                                        "movement, 0..1). At 1 someone in full motion\n"
                                        "grows the plant twice as fast; sitting still\n"
                                        "is the authored pace.");
                                }
                                ui::SliderFloat("grow hop lead", &S.grow_hop_lead, 0.f, 1.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Each hop the camera looks down the normal of the\n"
                                        "face the root is heading for, at that face. While\n"
                                        "the root travels the target sits this far from\n"
                                        "the face toward the tip (0 pins the face, 1\n"
                                        "follows the tip); on arrival it is the face.");
                                }
                                ui::SliderFloat("grow swing ease-in (s)", &S.grow_swing_ease_seconds, 0.f, 10.f, "%.1f");
                                if (ImGui::IsItemHovered())
                                    ImGui::SetTooltip(
                                        "Every hop's departure -- the first off the Face\n"
                                        "pose, each later one off the face just settled on:\n"
                                        "the camera ease's rate is faded in from zero over\n"
                                        "this long, so it leaves from rest instead of at\n"
                                        "full speed. 0 = the plain ease.");
                                ui::Checkbox("new seed each sitting", &S.vary_seed);
                                if (ImGui::IsItemHovered())
                                    ImGui::SetTooltip(
                                        "Every visitor's plant grows from a fresh random\n"
                                        "seed on top of the roots preset's own. Off, each\n"
                                        "sitting grows the preset's seed exactly -- the\n"
                                        "same root system every time.");
                                ui::Checkbox("grow frame previous face", &S.grow_frame_previous);
                                if (ImGui::IsItemHovered())
                                    ImGui::SetTooltip(
                                        "Each hop also keeps the face the root left and the\n"
                                        "growth tip in frame: a pull-out on every hop and a\n"
                                        "push back in on arrival. Off, the camera stays close\n"
                                        "and travels from face to face.");
                                ui::SliderFloat("grow margin", &S.grow_margin, 0.f, 1.5f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Margin around the target face / growth tip /\n"
                                        "face the root left, as a fraction of their\n"
                                        "extent, when fitting the hop's camera distance.");
                                }
                                ui::SliderFloat("grow timeout mult", &S.grow_timeout_mult, 1.f, 4.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Guard: Grow ends at face seconds x (N-1) x this\n"
                                        "even if the sim has not reported done.");
                                }
                                // Retired: a planned mask now stands from the
                                // moment the root heads for it, which leaves
                                // "when framed" nothing to add.
                                ui::BeginRetired("reveal mode");
                                {
                                    const char* kReveal[] = {"on arrival", "when framed"};
                                    ImGui::SetNextItemWidth(140);
                                    if (ui::Visible())
                                        ImGui::Combo("reveal mode", &S.reveal_mode, kReveal, IM_ARRAYSIZE(kReveal));
                                    ui::DeclareInt("reveal mode", &S.reveal_mode, 0, IM_ARRAYSIZE(kReveal) - 1);
                                }
                                ui::EndRetired();
                            }
                            ui::EndHeader();
                            ui::BeginHeader("mouth", false);
                            {
                                ui::SliderFloat("mouth open amount", &S.mouth_open_amount, 0.f, 1.5f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "The root leaves mask 0 through its mouth, so\n"
                                        "the jaw is forced open before it emerges -- the\n"
                                        "jawOpen coefficient at full open. Only ever\n"
                                        "raises the jaw (max against the live/replayed\n"
                                        "value), so a visitor already talking is not\n"
                                        "clamped shut. The spawn point itself tracks this\n"
                                        "opened mouth, not the neutral one.");
                                }
                                ui::SliderFloat("mouth open width", &S.mouth_open_width, 0.f, 1.5f, "%.2f");
                                if (ImGui::IsItemHovered())
                                    ImGui::SetTooltip(
                                        "mouthStretch_L/R at full open: the corners pulled\n"
                                        "wide, on top of the jaw.");
                                ui::SliderFloat("mouth open lips", &S.mouth_open_lips, 0.f, 1.5f, "%.2f");
                                if (ImGui::IsItemHovered())
                                    ImGui::SetTooltip(
                                        "mouthUpperUp/LowerDown_L/R at full open: the lips\n"
                                        "parted off the teeth. Whatever the fit or the\n"
                                        "recording has closing the mouth (mouthClose,\n"
                                        "pucker, funnel, press, roll, shrug) fades out\n"
                                        "with the ramp -- a jaw dropped under pressed lips\n"
                                        "read as a mouth half shut.");
                                ui::SliderFloat("mouth open seconds", &S.mouth_open_seconds, 0.1f, 5.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "The ease-in. Held open through Grow/Turn/Orbit\n"
                                        "once reached -- the root is coming out of the\n"
                                        "mouth the whole time.");
                                }
                                ui::SliderFloat("track smoothing (s)", &S.track_smooth_seconds, 0.f, 1.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Temporal filter over a recorded head track\n"
                                        "before replay (mask 0 and the hood alike):\n"
                                        "takes the fit's frame-to-frame jitter out.\n"
                                        "0 = raw. Applies to the next sitting.");
                                }
                                ui::SliderFloat("live smoothing (s)", &S.live_smooth_seconds, 0.f, 0.5f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Exponential smoothing of the live fit's mesh on\n"
                                        "mask 0 while the visitor drives it (Face). Takes\n"
                                        "the frame-to-frame jitter out; too high and the\n"
                                        "head lags. 0 = raw.");
                                }
                                ui::SliderFloat("head pivot back (cm)", &S.head_pivot_back_cm, 0.f, 20.f, "%.1f");
                                ui::SliderFloat("head pivot down (cm)", &S.head_pivot_down_cm, 0.f, 20.f, "%.1f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Where a replayed head turns about: behind and\n"
                                        "below the middle of the face, at the neck, so a\n"
                                        "turn swings the nose and a nod the chin. 0/0 is\n"
                                        "the old pin through the face. Next sitting.");
                                }
                                ui::SliderFloat("mouth open lead (s)", &S.mouth_open_lead, 0.f, 5.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "How long before Grow begins the mouth starts\n"
                                        "opening -- during the last part of Face. Floored\n"
                                        "at \"mouth open seconds\" so the ease actually\n"
                                        "finishes by the time Grow starts rather than\n"
                                        "still being mid-open when the root needs it.");
                                }
                                ui::SliderFloat("hold settle (s)", &S.hold_settle_seconds, 0.f, 3.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "How long mask 0 eases from the last frame the\n"
                                        "visitor drove (posed, live) onto the frame it\n"
                                        "holds from Grow on (squared, jaw open). Runs\n"
                                        "over the last seconds of Face, so the mask is\n"
                                        "still before the root leaves it. 0 cuts.");
                                }
                            }
                            ui::EndHeader();
                            ui::BeginHeader("camera easing", false);
                            {
                                ui::SliderFloat("cam ease seconds", &S.cam_ease_seconds, 0.05f, 5.f, "%.2f");
                                ui::SliderFloat("cam max angular speed (rad-s)",
                                                &S.cam_max_angular_speed, 0.05f, 4.f, "%.2f");
                                ui::Checkbox("head pan", &S.head_pan_enabled);
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "The tracked face's place in frame nudges the\n"
                                        "camera's angles, Grow onward. Off during Face,\n"
                                        "where the viewer drives the mask instead.");
                                }
                                ui::BeginGate(S.head_pan_enabled);
                                ui::SliderFloat("head pan (deg)", &S.head_pan_deg, -30.f, 30.f, "%.1f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Positive: the camera's azimuth follows the\n"
                                        "visitor across the tracker frame, the same sign\n"
                                        "the key light swings with. Negative flips it, for\n"
                                        "a sensor that is not mirrored the way the screen is.");
                                }
                                ui::SliderFloat("head pan tau (s)", &S.head_pan_tau, 0.05f, 3.f, "%.2f");
                                ui::EndGate();
                            }
                            ui::EndHeader();
                            ui::BeginHeader("finale", false);
                            {
                                ui::Checkbox("other structures", &S.hood_enabled);
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "On: the hood -- previous visitors' plants --\n"
                                        "pops in at Turn and lights through the Orbit\n"
                                        "(the turn / reveal / orbit sections below).\n"
                                        "Off: nothing else is ever placed. Grow ends\n"
                                        "straight into a slow pull-back from the last\n"
                                        "face to the centre of this structure, zooming\n"
                                        "out until the whole plant fills the frame\n"
                                        "(frame margin) while the orbit turns; then the\n"
                                        "rest of the orbit seconds, and the outro.");
                                }
                                ui::BeginGate(!S.hood_enabled);
                                ui::SliderFloat("zoom out seconds", &S.zoom_out_seconds, 1.f, 120.f, "%.0f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "How long the pull-back from the last face to\n"
                                        "the whole plant takes, from the start of the\n"
                                        "Orbit.");
                                }
                                ui::SliderFloat("orbit tilt (deg)", &S.orbit_tilt_deg, 0.f, 90.f, "%.0f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "0: the orbit turns about the plant's own axis,\n"
                                        "so it stands upright on screen (mask 0 at the\n"
                                        "top). More tilts that axis toward world up by\n"
                                        "this many degrees -- past the angle between the\n"
                                        "two it is simply the world orbit.");
                                }
                                ui::EndGate();
                                ui::SliderFloat("frame margin", &S.frame_margin, -0.9f, 1.5f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Alone: margin around every mask of the plant,\n"
                                        "as a fraction of each one's extent, for the\n"
                                        "pull-back's end framing -- negative lets the\n"
                                        "outer masks run off the frame's edge. With the\n"
                                        "hood: the same around every structure, for\n"
                                        "Turn's end framing and the Orbit's.");
                                }
                            }
                            ui::EndHeader();
                            ui::BeginHeader("turn", false, S.hood_enabled);
                            {
                                ui::SliderFloat("turn seconds", &S.turn_seconds, 0.5f, 20.f, "%.1f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Turn pops the hood in dark at the last Grow\n"
                                        "framing, then rotates/zooms out in one move to\n"
                                        "the Orbit's own framing (orbit elevation below)\n"
                                        "-- there is nothing left to ease once Orbit\n"
                                        "begins.");
                                }
                            }
                            ui::EndHeader();
                            ui::BeginHeader("reveal", false, S.hood_enabled);
                            {
                                ui::SliderFloat("reveal ring radius", &S.reveal_ring_radius, 0.1f, 20.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Radius of the ring the other structures' seed\n"
                                        "masks sit on, around this one's seed mask.\n"
                                        "Tight (nearly touching) is about 1.2x a seed\n"
                                        "mask's own max(width,height).");
                                }
                                ui::SliderFloat("reveal tilt (deg)", &S.reveal_tilt_deg, 0.f, 89.f, "%.0f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Each structure's axis, tilted this many degrees\n"
                                        "outward (away from the ring's centre, in its own\n"
                                        "radial direction) from the live structure's own\n"
                                        "axis -- together the hood forms a cone with the\n"
                                        "live structure down its middle.");
                                }
                                ui::SliderFloat("reveal fallback seconds", &S.reveal_fallback_seconds,
                                                0.2f, 20.f, "%.1f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Every structure stands dark from the Orbit's\n"
                                        "first frame; each FirePlucker marker lights the\n"
                                        "next one's top mask and starts its pulse front.\n"
                                        "This is the fallback used when no marker\n"
                                        "arrives (audio off, or no SDK).");
                                }
                                ui::SliderFloat("reveal pulse lag", &S.reveal_pulse_lag, 0.f, 5.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "A structure's other masks light as its pulse\n"
                                        "front (pulse speed x seconds since the marker)\n"
                                        "reaches the point on the root where each sits.\n"
                                        "Seconds of extra delay on each, for a front that\n"
                                        "reads as arriving a little after it has.");
                                }
                                ui::SliderInt("reveal structures", &S.reveal_structures, 0, 32);
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "How many other structures stand around this\n"
                                        "one. 0 leaves it to the face bank -- one per\n"
                                        "(masks) older captures, between min and max\n"
                                        "below; anything else is exactly that many, the\n"
                                        "bank's faces dealt round again when it is short.");
                                }
                                ui::SliderInt("reveal min structures", &S.reveal_min_structures, 0, 32);
                                ui::SliderInt("reveal max structures", &S.reveal_max_structures, 1, 32);
                                ui::Checkbox("bank plants", &S.bank_plants);
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Each other structure is the plant its own\n"
                                        "mask-0 sitter grew (captures/<id>/roots.bin),\n"
                                        "saved when their Grow finished. Off, or for a\n"
                                        "capture with no saved plant: a seeded throwaway\n"
                                        "growth of the current parameters. Read at the\n"
                                        "deal (Transition entry).");
                                }
                                ui::Checkbox("bank faces replay", &S.bank_replay);
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Every bank face on a drawn, lit mask plays back\n"
                                        "its own sitter's recorded head movement\n"
                                        "(captures/<id>/track.bin), looped, instead of\n"
                                        "holding the capture's one instant. Off: still\n"
                                        "faces. Read at the deal (Transition entry).");
                                }
                            }
                            ui::EndHeader();
                            ui::BeginHeader("orbit", false);
                            {
                                ui::SliderFloat("orbit rate (rad-s)", &S.orbit_rate, -1.f, 1.f, "%.3f");
                                ui::SliderFloat("orbit elevation (deg)", &S.orbit_elevation_deg,
                                                -60.f, 80.f, "%.0f");
                                ui::SliderFloat("orbit seconds", &S.orbit_seconds, 1.f, 300.f, "%.0f");
                                // The hood's framing: how many structures to
                                // fit and how far out to stand. Alone, the
                                // pull-back's own fit (finale) decides that.
                                ui::BeginGate(S.hood_enabled);
                                ui::SliderFloat("orbit bound frac", &S.orbit_bound_frac, 0.1f, 1.f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "The orbit frames the bound of every structure\n"
                                        "shrunk to this fraction of its radius: the\n"
                                        "outermost are allowed to leave the frame.");
                                }
                                ui::SliderFloat("orbit max radius", &S.orbit_max_radius, 20.f, 400.f, "%.0f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "The camera never stands further than this from\n"
                                        "the hood's centre, whatever the bound asks. World\n"
                                        "units, because the fog is: past about three\n"
                                        "visibilities nothing reads at all.");
                                }
                                ui::SliderFloat("orbit zoom", &S.orbit_zoom, 0.1f, 1.5f, "%.2f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "The fitted radius (every kept structure inside\n"
                                        "the frame with the margin) x this. Under 1 lets\n"
                                        "the outer ones run off the edge so the near ones\n"
                                        "fill the frame. One framing from the moment the\n"
                                        "structures appear: the reveal and the orbit share it.");
                                }
                                ui::EndGate();
                                ui::SliderFloat("orbit target lift", &S.orbit_target_lift, -40.f, 40.f, "%.1f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Raises (or lowers) the point the orbit looks at,\n"
                                        "in world units, off the framed structures' mean.\n"
                                        "Alone: along the orbit axis (screen vertical),\n"
                                        "after the fit -- positive moves the plant down\n"
                                        "the frame, and nothing else changes.");
                                }
                            }
                            ui::EndHeader();
                            ui::BeginHeader("outro", false);
                            {
                                ui::SliderFloat("datamosh seconds", &S.datamosh_seconds, 0.f, 10.f, "%.1f");
                                ui::SliderFloat("fade seconds", &S.fade_seconds, 0.2f, 10.f, "%.1f");
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "The datamosh fires on the outro's entry; after\n"
                                        "its time the screen fades to black over this,\n"
                                        "and the show moves to Idle when it lands.");
                                }
                            }
                            ui::EndHeader();
                            ui::BeginHeader("debug", false);
                            {
                                ui::Checkbox("debug spawn markers", &S.debug_spawn_markers);
                                if (ImGui::IsItemHovered()) {
                                    ImGui::SetTooltip(
                                        "Small coloured spheres in the root scene: each\n"
                                        "mask's spawn point (red for mask 0's hop,\n"
                                        "orange for the rest), mouth point (green), the\n"
                                        "first CPlantBox node actually placed for that\n"
                                        "hop (blue) and the mask centre (white). Also\n"
                                        "prints one line per hop to stdout. --seqshot\n"
                                        "always turns this on (SEQSHOT_DEBUG_MARKERS).");
                                }
                            }
                            ui::EndHeader();
                        }
                    }
                    ui::EndHeader();
                }

                ui::BeginHeader("signals", /*default_open=*/false);
                {
                    ui::SliderFloat("mesh fit residual, diagnostic (px)", &g_show_fit_px,
                                    1.f, 20.f, "%.1f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Mean landmark error of the one-shot identity fit.\n"
                            "Display only: the mesh fit no longer gates the\n"
                            "transition, it only shapes the Roots-phase mesh --\n"
                            "this just colours the \"(N px)\" readouts.");
                    }
                    ui::SliderFloat("fit score to convert", &g_show_fit_score,
                                    0.f, 1.f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "AudioParams::fit_level, 0..1. Above this, the\n"
                            "texture counts as having actually captured the\n"
                            "face -- it's the Fitting -> Transition gate,\n"
                            "debounced by the fit_hold above. Tune against\n"
                            "the live FitLevel readout on the fit panel.");
                    }
                    ui::SliderFloat("fit_level half scale (loss)", &g_show_fit_loss_half,
                                    0.0005f, 0.05f, "%.4f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Where AudioParams::fit_level reads 0.5. Deliberately\n"
                            "looser than the converged-under threshold above --\n"
                            "a fit already good enough to convert should sound\n"
                            "close to resolved, not half there. Tune against the\n"
                            "live \"loss\" and FitLevel readouts together.");
                    }
                    ui::SliderInt("cue CC", &g_show_cue_cc, 0, 127);
                    ui::SliderInt("phase CC", &g_show_phase_cc, 0, 127);
                    ui::Checkbox("log phase changes", &g_show_log);
                }
                ui::EndHeader();
            }
            ui::PopSection();               // "show"
            ImGui::Separator();

            // --- sound ----------------------------------------------------
            // In the show tab because that is what it is: the piece's audio,
            // not the machine's. The Wwise project holds every mapping from
            // these numbers to a filter or an oscillator -- what is here is the
            // handful of things an operator sets on the night (key, level) and
            // the readout that answers "is it hearing the room".
            ui::PushSection("sound");
            ui::BeginHeader("sound (Wwise)", /*default_open=*/false);
            {
                if (ui::Visible()) {
                    if (g_audio.ready()) {
                        ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f),
                                           "engine up");
                        ImGui::SameLine();
                        ImGui::TextDisabled("| %lu events", g_audio.eventsPosted());
                    } else {
                        ImGui::TextColored(ImVec4(1.f, 0.7f, 0.5f, 1.f), "silent");
                        ImGui::SameLine();
                        ImGui::TextDisabled("| %s", g_audio_err.c_str());
                        if (ImGui::Button("retry")) {
                            // The usual reason to be here is that the banks had
                            // not been generated yet when the app started.
                            if (g_audio.init(mirror::WwiseAudio::DefaultBankDir(),
                                             g_audio_err))
                                g_audio_err.clear();
                        }
                    }
                }

                // The room's own mic (Kinect v2 array), independent of the
                // Wwise engine above -- this is what drives the root scene's
                // light responsivity (see mic_level.h), not the piece's mix.
                if (g_mic.running()) {
                    ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "mic up");
                    ImGui::SameLine();
                    ImGui::ProgressBar(g_mic.level(), ImVec2(80, 0));
                } else {
                    ImGui::TextColored(ImVec4(1.f, 0.5f, 0.5f, 1.f), "mic off");
                    ImGui::SameLine();
                    ImGui::TextDisabled("| %s", g_mic_err.c_str());
                }

                ui::Checkbox("sound on", &g_audio_on);
                ui::Checkbox("phases post their own events", &g_audio_auto);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Off leaves the beds to the buttons below -- for\n"
                        "auditioning a scene's sound without moving the piece\n"
                        "through its phases.");
                }
                ui::SliderFloat("level", &g_audio_intensity, 0.f, 1.f);
                ui::SliderFloat("transpose (semitones)", &g_audio_transpose, -24.f, 24.f, "%.0f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Offsets every pad voice, the pluck and the drone\n"
                        "together, on the Wwise side (bound to `Transpose` on\n"
                        "each emitter's own Pitch) -- moving this does not touch\n"
                        "the chord's voicing or the key, only where it all sits.");
                }
                ui::Checkbox("shepherd rise", &g_shepherd_on);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "A looping glissando layered under the pad in Wwise\n"
                        "(Mirror_Pad_Shepherd), riding this same `Transpose`\n"
                        "RTPC -- speed follows FitLevel. Fitting phase only;\n"
                        "off leaves transpose at the slider above.");
                }
                ui::SliderFloat("shepherd rate min (st/s)", &g_shepherd_rate_min, 0.f, 3.f);
                if (ImGui::IsItemHovered())
                    ImGui::SetTooltip("Rise speed at fit_level 0 -- semitones/sec.");
                ui::SliderFloat("shepherd rate max (st/s)", &g_shepherd_rate_max, 0.f, 3.f);
                if (ImGui::IsItemHovered())
                    ImGui::SetTooltip("Rise speed at fit_level 1 -- semitones/sec.");

                ui::SliderFloat("flanger rate min (Hz)", &g_flanger_rate_min, 0.f, 5.f);
                if (ImGui::IsItemHovered())
                    ImGui::SetTooltip("Flanger LFO speed at fit_level 0.");
                ui::SliderFloat("flanger rate max (Hz)", &g_flanger_rate_max, 0.f, 5.f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Flanger LFO speed at fit_level 1 -- Mirror_Pad_Flanger's\n"
                        "ModFrequency, bound 1:1 to `FlangerRate`. Accelerates\n"
                        "between the two as the fit converges, same shape as the\n"
                        "shepherd's rate above.");
                }

                ui::PushSection("resolved");
                ui::BeginHeader("resolved (cloth + face)", /*default_open=*/false);
                {
                    ui::SliderFloat("strum dead zone (deg)", &g_strum_dead_deg, 0.f, 45.f);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "While the resolved window holds (Transition entry\n"
                            "through the Face stage, until the mouth starts to\n"
                            "open), the strings of the resolved chord lie across\n"
                            "the head's yaw, lowest at full-left, highest at\n"
                            "full-right, this dead zone cut out of the middle;\n"
                            "turning across a string plucks it. Its own source\n"
                            "(postStrum), so it never retunes the pluck.");
                    }
                    ui::SliderFloat("strum range (deg)", &g_strum_range_deg, 10.f, 90.f);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("Yaw at which the outermost strings sit, each side.");
                    ui::SliderInt("strum octave", &g_strum_octave, -2, 4);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("The chord's tones in the pluck's register, this many octaves up.");
                    {
                        const char* kScales[] = {"pentatonic", "lydian", "lydian colour"};
                        ImGui::SetNextItemWidth(140);
                        if (ui::Visible())
                            ImGui::Combo("strum scale", &g_strum_scale, kScales, IM_ARRAYSIZE(kScales));
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "The strings' tones over the resolved root:\n"
                                "pentatonic 0 2 4 7 9 (5 strings), lydian 0 2 4 6 7 9 11 12\n"
                                "(8), lydian colour 9 14 18 23 (4) -- the 6th, 9th, #11th\n"
                                "and 7th, the octave above.");
                        }
                        ui::DeclareInt("strum scale", &g_strum_scale, 0, IM_ARRAYSIZE(kScales) - 1);
                    }
                    ui::Checkbox("strum shuffled", &g_strum_shuffle);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("Deal the tones across the yaw in a random order, drawn fresh\nat each window's opening, instead of low-left to high-right.");
                    ui::SliderFloat("strum hysteresis", &g_strum_hysteresis, 0.f, 0.5f);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("How far past a string (in string widths) the nose must go\nbefore it counts as crossed, so jitter on a string doesn't re-pluck it.");
                    ui::SliderFloat("strum full velocity (deg/s)", &g_strum_full_vel, 10.f, 720.f);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("Head turn speed for a full-loudness pluck; slower turns\nare quieter (Strum_Velocity -> the Strum sound's volume).");
                    ui::SliderFloat("strum velocity smooth (ms)", &g_strum_vel_smooth_ms, 1.f, 1000.f);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("Smoothing on the head's turn rate before it sets the loudness;\nthe tracker's frame-to-frame jitter alone reads as a fast turn.");
                    ui::Checkbox("strum mutes pluck", &g_strum_mute_pluck);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("Fades the FirePlucker out while the harp plays (PluckMute)\nand back in as the roots start.");
                    ui::SliderFloat("strum mute fade (ms)", &g_strum_mute_fade_ms, 0.f, 5000.f);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("The mute's fade, out and back in, run by Wwise.");
                    ui::SliderFloat("strum drop glide (ms)", &g_strum_drop_glide_ms, 0.f, 2000.f);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("When the mouth opens and the roots start, every string is\nplucked once and slides down to 20 Hz at this glide.");
                    ui::Checkbox("strum wires", &g_strum_wires);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("Draw the strings: a hair-thin line each, pinned to the top and\nbottom of the screen beside the mask at the yaw that plucks it,\ninverting what is behind it. A pluck widens it and sets it vibrating.");
                    ui::SliderFloat("wire spread", &g_strum_wire_spread, 0.f, 1.f);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("Where the outermost strings sit, in screen half-widths from\nthe mask; the rest lie between by their yaw.");
                    ui::SliderFloat("wire width (px)", &g_strum_wire_px, 0.25f, 8.f);
                    ui::SliderFloat("wire pluck width (x)", &g_strum_wire_pluck_width, 0.f, 4.f);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("How much wider a plucked string is, as a multiple of its width.");
                    ui::SliderFloat("wire pluck vibration (px)", &g_strum_wire_vib_px, 0.f, 60.f);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("How far a plucked string swings either way at its belly --\na standing wave, a node at each end of the screen.");
                    ui::SliderFloat("wire pluck decay (s)", &g_strum_wire_decay_s, 0.05f, 5.f);
                    ui::SliderFloat("wire pulse divisor", &g_strum_wire_pulse_div, 1.f, 512.f, "%.0f");
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("A plucked string vibrates at its note's frequency over this:\n440 Hz / 64 is about 7 swings a second.");
                    ui::SliderFloat("pluck glide (ms)", &g_resolved_glide_ms, 0.f, 2000.f);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Comb_Glide while the window holds, short so the\n"
                            "pluck lands on the resolved note rather than\n"
                            "sliding into it. 265ms (Metallic_Ring's authored\n"
                            "default) the rest of the time.");
                    }
                    ui::SliderFloat("flanger fade (s)", &g_resolved_flanger_fade_s, 0.1f, 30.f);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "How long, from the window's entry, FlangerMix takes\n"
                            "to fade from 54 to 0 -- the pad clearing as the\n"
                            "chord settles.");
                    }
                }
                ui::EndHeader();
                ui::PopSection();

                if (ui::Visible()) {
                    ImGui::SeparatorText("post");
                    if (ImGui::Button("pluck bed")) g_audio.postFirePlucker();
                    ImGui::SameLine();
                    if (ImGui::Button("pad")) g_audio.post("Play_Pad");
                    ImGui::SameLine();
                    if (ImGui::Button("stop pad")) g_audio.post("Stop_Pad");
                    if (ImGui::Button("roots bed")) g_audio.post("Play_Amb_Roots");
                    ImGui::SameLine();
                    if (ImGui::Button("transition")) g_audio.post("Play_Transition");
                    if (ImGui::Button("pluck")) g_audio.post("Play_Pluck");
                    ImGui::SameLine();
                    if (ImGui::Button("bell")) g_audio.post("Play_Bell");
                    ImGui::SameLine();
                    if (ImGui::Button("drop")) g_audio.post("Play_Drop");
                    ImGui::SameLine();
                    if (ImGui::Button("stop all")) g_audio.stopAll();

                    ImGui::SeparatorText("the room, as Wwise sees it");
                    const mirror::AudioParams& a = g_audio.lastSent();
                    const mirror::PresenceSignals& raw = g_presence.raw();
                    // Smoothed against raw, side by side: the time constants
                    // below are unturnable without seeing both.
                    ImGui::Text("Proximity  %.2f", a.proximity);
                    ImGui::SameLine(); ImGui::TextDisabled("(raw %.2f)", raw.proximity);
                    ImGui::Text("Movement   %.2f", a.movement);
                    ImGui::SameLine(); ImGui::TextDisabled("(raw %.2f)", raw.movement);
                    ImGui::Text("Centering  %+.2f", a.centering);
                    ImGui::Text("HeadYaw    %+.0f deg", a.head_yaw);
                    ImGui::SameLine();
                    ImGui::Text("HeadTilt %+.0f deg", a.head_tilt);
                    ImGui::Text("FitLevel   %.2f", a.fit_level);
                    ImGui::SameLine();
                    ImGui::Text("SceneProgress %.2f", a.scene_progress);

                    ImGui::SeparatorText("the chord");
                    const mirror::ChordVoicing& cv = g_chord.voicing();
                    // Note against target, per voice: a glide in flight is the
                    // two columns disagreeing, and "did the checkpoint fire"
                    // is the stage number. Neither is answerable by ear alone
                    // while the fit is also moving.
                    ImGui::Text("stage %d/%d  (next at fit %.2f)",
                                cv.stage + 1, mirror::Chord::kStages,
                                cv.stage + 1 < mirror::Chord::kStages
                                    ? g_chord.StageThreshold(cv.stage + 1)
                                    : 1.f);
                    for (int i = 0; i < mirror::kChordVoices; ++i) {
                        ImGui::Text("  V%d  %6.2f", i + 1, cv.note[i]);
                        ImGui::SameLine();
                        ImGui::TextDisabled("-> %.0f", cv.target[i]);
                    }
                    ImGui::Text("pluck %6.2f", cv.pluck_note);
                    ImGui::SameLine();
                    ImGui::TextDisabled("(comb %.1f Hz)", cv.comb_hz);
                    ImGui::Text("root  %6.2f", g_chord.effectiveRoot());
                    ImGui::SameLine();
                    ImGui::TextDisabled("(visitor note %.0f)", g_chord.visitorNote());
                }

                mirror::Chord::Config& cc = g_chord.config();
                ui::BeginHeader("chord tuning", /*default_open=*/false);
                {
                    ui::SliderFloat("pad octave (semitones)", &cc.octave, -36.f, 12.f, "%.0f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Where the pad sits relative to the key. The key is\n"
                            "the piece's pitch, not the pad's register -- and the\n"
                            "pluck reads the key directly, so this moves the\n"
                            "chord without moving the pluck.");
                    }
                    ui::SliderFloat("detune (cents)", &cc.detune_cents, 0.f, 25.f, "%.1f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "How far movement pulls the voices apart, alternating\n"
                            "up the stack. A few cents does not sound out of tune,\n"
                            "it makes the coinciding harmonics beat.");
                    }
                    ui::SliderFloat("checkpoint hysteresis", &cc.hysteresis, 0.f, 0.15f, "%.2f");
                    ImGui::TextDisabled("checkpoints -- fit_level each stage becomes current at");
                    for (int s = 1; s < mirror::Chord::kStages; ++s) {
                        char label[32];
                        std::snprintf(label, sizeof(label), "stage %d", s);
                        ui::SliderFloat(label, &cc.thresholds[s], 0.f, 1.f, "%.2f");
                    }
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Where each chord change lands against fit_level.\n"
                            "Keep these increasing, or the checkpoint gate\n"
                            "above (a Schmitt trigger per boundary) reads a\n"
                            "later stage's threshold as already cleared. The\n"
                            "last one deliberately stops short of 1.0 -- see\n"
                            "chord.h's comment on `thresholds` for why.");
                    }
                    ui::SliderFloat("pluck centre (MIDI note)", &cc.pluck_center_note,
                                     60.f, 96.f, "%.0f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "The note everything is tuned from. The pinned pluck\n"
                            "rings it (plus this visitor's offset) through the\n"
                            "idle wait, and the chord's root is it, `chord\n"
                            "octave` octaves down. 79 is G5, 784 Hz. Currently\n"
                            "%.1f Hz.",
                            440.f * std::pow(2.f, (g_chord.visitorNote() - 69.f) / 12.f));
                    }
                    ui::SliderInt("chord octave", &cc.chord_octave, -5, -1);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Where the chord's root sits relative to the pluck's\n"
                            "note, in octaves. Moves the pad only, via Wwise's\n"
                            "`PadOctave` (+/-24 st, hence the range); `Key` stays\n"
                            "on the pluck's note, so the pluck, drone and drops\n"
                            "don't follow. -1: the resolved chord's top voice is\n"
                            "a major third over the pluck's base note.");
                    }
                    ui::SliderInt("offset range (semitones)", &cc.pluck_offset_max_semitones,
                                   0, 7);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Drawn once per visitor, uniform over 0..+N\n"
                            "semitones above the centre (never below), so 3\n"
                            "lands anywhere up to a minor third up.");
                    }
                    ui::SliderFloat("pluck climb (semitones)", &cc.pluck_climb,
                                     0.f, 36.f, "%.0f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "How far above the visitor's note the last checkpoint\n"
                            "lifts the pluck; each checkpoint is a quarter of the\n"
                            "way, snapped to a tone of the current chord. 16 with\n"
                            "chord octave -1 ends on the chord's top voice.");
                    }
                    ui::SliderInt("pluck idle octave", &cc.pluck_idle_octave, -3, 1);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("The pluck's register through the idle wait (fit at 0),\noctaves from the visitor's note. The comb alone -- the\nchord's root and Key stay put.");
                    ui::SliderInt("pluck fitting octave", &cc.pluck_fit_octave, -3, 1);
                    if (ImGui::IsItemHovered())
                        ImGui::SetTooltip("The pluck's register while the fit climbs, octaves,\napplied after the snap to a chord tone. Comb_Tuning\nstops at 4000 Hz, so +1 is as high as the climb clears.");

                    ImGui::Separator();
                    ui::Checkbox("wander", &cc.pluck_wander_enabled);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "While the pluck is pinned (fit at 0 -- the idle\n"
                            "wait, and Roots), let its comb frequency drift a few\n"
                            "percent instead of sitting dead still. Stops the\n"
                            "instant fitting moves it. Never moves the root.");
                    }
                    ui::SliderFloat("wander depth", &cc.pluck_wander_depth, 0.001f, 0.5f,
                                     "%.3f", ImGuiSliderFlags_Logarithmic);
                    ui::SliderFloat("wander cycle (s)", &cc.pluck_wander_period_s,
                                     1.f, 300.f, "%.1f", ImGuiSliderFlags_Logarithmic);
                }
                ui::EndHeader();

                mirror::Presence::Config& pc = g_presence.config();
                ui::BeginHeader("presence tuning", /*default_open=*/false);
                {
                    ui::SliderFloat("far (face height)", &pc.far_span, 0.02f, 0.4f);
                    ui::SliderFloat("near (face height)", &pc.near_span, 0.1f, 0.9f);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "The two numbers worth retuning per room: how much\n"
                            "of the frame a face fills standing back, and\n"
                            "standing at the mirror. Everything Proximity\n"
                            "drives is stretched between them.");
                    }
                    ui::SliderFloat("movement full scale", &pc.move_full, 0.2f, 4.f);
                    ui::SliderFloat("rise (s)", &pc.rise_tau, 0.01f, 1.f, "%.2f");
                    ui::SliderFloat("fall (s)", &pc.fall_tau, 0.05f, 4.f, "%.2f");
                }
                ui::EndHeader();
            }
            ui::EndHeader();
            ui::PopSection();               // "sound"
            DrawBankSaveUI(ui::Bank::Show);

            // --- screen ---------------------------------------------------
            // Always visible: the composition's shape is upstream of every
            // scene, the text's placement and the camera's crop.
            ui::EndTab();
            ui::BeginTab("machine", g_panel_test && g_panel_test_tab == panel_test_tab_i++);
            ui::PushSection("screen");
            ui::BeginHeader("screen orientation", /*default_open=*/false);
            {
                ImGui::TextUnformatted("compose for:"); ImGui::SameLine();
                ImGui::RadioButton("auto", &g_orientation,
                                   (int)mirror::Orientation::Auto);
                ImGui::SameLine();
                ImGui::RadioButton("landscape", &g_orientation,
                                   (int)mirror::Orientation::Landscape);
                ImGui::SameLine();
                ImGui::RadioButton("portrait", &g_orientation,
                                   (int)mirror::Orientation::Portrait);
                // Declared rather than drawn by ui:: -- a radio group is three
                // widgets over one value, and the registry stores the value.
                ui::DeclareInt("orientation", &g_orientation, 0, 2);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The installation's screen is portrait, so macOS is set\n"
                        "to portrait there and the drawable is already tall --\n"
                        "'auto' composes for it and nothing is letterboxed.\n\n"
                        "'portrait' on this landscape monitor is the preview:\n"
                        "the same aspect, the same camera crop, the same place\n"
                        "the text lands, in a tall box in the middle.");
                }

                ui::SliderFloat("panel aspect (w/h)", &g_portrait_aspect,
                                0.3f, 1.0f, "%.4f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The installation panel's width/height stood on its\n"
                        "end. 0.5625 is a 1920x1080 panel turned 90 degrees.\n\n"
                        "Stated rather than taken from this monitor: the\n"
                        "preview is only worth anything if it matches the\n"
                        "screen the piece will run on.");
                }

                ImGui::TextDisabled("compose %d x %d  ->  window %d x %d%s",
                                    pf.compW, pf.compH, pf.fbw, pf.fbh,
                                    pf.layout.letterboxed ? "  (letterboxed)" : "");

                ImGui::Separator();
                ImGui::TextUnformatted("camera framing");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The sensor is 16:9 and does not turn around when the\n"
                        "screen does, so a portrait frame keeps a tall rect out\n"
                        "of it and throws the sides away -- about a third of\n"
                        "the width survives. This is where that rect sits.\n\n"
                        "The tracker and the fit are given the same crop, so\n"
                        "moving this cannot put the mask off the face.");
                }
                ui::SliderFloat("feed x", &g_feed.cx, 0.f, 1.f);
                ui::SliderFloat("feed y", &g_feed.cy, 0.f, 1.f);
                ui::SliderFloat("feed zoom", &g_feed.zoom, 1.f, 4.f);
                if (ImGui::Button("centre feed")) {
                    g_feed = mirror::FeedCrop{};
                }
            }
            ui::EndHeader();
            ui::PopSection();               // "screen"

            // --- camera mask ---------------------------------------------
            ui::PushSection("camera mask");
            ui::BeginHeader("camera mask", /*default_open=*/true);
            {
                ui::Checkbox("mask the camera", &g_cam_mask_on);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Keep a rectangle of the sensor's view and black out\n"
                        "the rest. The mirror only sells if the frame holds the\n"
                        "person and nothing that says 'room' -- a doorway, a\n"
                        "window, the edge of the rig.\n\n"
                        "Applied in camera space, ahead of everything: the fit\n"
                        "never sees the masked pixels and the tracker cannot\n"
                        "find a face in them.");
                }
                ImGui::SameLine();
                if (ImGui::SmallButton("reset")) {
                    g_cam_x0 = 0.15f; g_cam_y0 = 0.05f;
                    g_cam_x1 = 0.85f; g_cam_y1 = 0.95f;
                }
                ImGui::BeginDisabled(!g_cam_mask_on);
                ImGui::PushItemWidth(-90);
                ImGui::DragFloatRange2("x", &g_cam_x0, &g_cam_x1, 0.002f, 0.f, 1.f,
                                       "%.3f", "%.3f", ImGuiSliderFlags_AlwaysClamp);
                ImGui::DragFloatRange2("y", &g_cam_y0, &g_cam_y1, 0.002f, 0.f, 1.f,
                                       "%.3f", "%.3f", ImGuiSliderFlags_AlwaysClamp);
                ui::SliderFloat("soft edge", &g_cam_feather, 0.f, 0.2f, "%.3f");
                ImGui::PopItemWidth();
                ImGui::EndDisabled();
                if (pf.scene != (int)Scene::CamMask) {
                    ImGui::TextDisabled("(the 'cam mask' scene has drag handles)");
                }
            }
            ui::EndHeader();
            ui::PopSection();

            // --- settings edited on other pages ------------------------
            // Declared under the same section those pages use, so the
            // preset key is unchanged -- only where this draws moves.
#if MIRROR_HAVE_KINECT
            ui::PushSection("mirror");
            ui::SetBank(ui::Bank::Machine);   // which way round the sensor
            ui::BeginGate(g_kinect.isOpen());  // is mounted
            {
                bool mir = g_kinect.mirrored();
                if (ui::Checkbox("mirror image", &mir)) g_kinect.setMirrored(mir);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "On: behave like a mirror -- move left, see\n"
                        "yourself move left. The sensor's raw frame\n"
                        "already reads this way (confirmed with\n"
                        "--feedshot), so this leaves it alone. Off\n"
                        "flips it into a plain camera view instead.");
                }
            }
            ui::EndGate();
            ui::PopSection();
#endif
            ui::PushSection("roots");
            ui::SetBank(ui::Bank::Machine);
            ui::Checkbox("auto render-scale", &pf.rootAutoScale);
            // Both arms declare; only the live one draws. Otherwise
            // whichever mode was off at save time got written from a stale
            // cache, and the two would drift apart across a round trip.
            ui::BeginGate(pf.rootAutoScale);
            if (ui::Visible()) { ImGui::SameLine(); ImGui::SetNextItemWidth(120); }
            ui::SliderInt("target px", &pf.rootTargetDim, 720, 3840);
            ui::EndGate();
            ui::BeginGate(!pf.rootAutoScale);
            ui::SliderInt("root downscale", &pf.rootDownscale, 1, 6);
            ui::EndGate();
            ui::PopSection();

            // --- face tracking (feeds both scenes) ------------------------
            ui::PushSection("face tracking");
            ui::BeginHeader("face tracking", /*default_open=*/false);
            {
                ui::BeginGate(!mirror::FaceTracker::available());
                {
                    ImGui::TextDisabled("MediaPipe not compiled in");
                    ImGui::TextDisabled("run ./setup-mediapipe.sh, then re-cmake");
                }
                ui::EndGate();
                ui::BeginGate(!(!mirror::FaceTracker::available()));
                {
                    if (ui::Checkbox("track faces", &g_track_on) && g_track_on) {
                        if (!g_tracker.isOpen()) {
                            const std::string model =
                                std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_landmarker.task";
                            if (!g_tracker.open(model, g_track_err)) g_track_on = false;
                        }
                        if (g_track_on && !g_fitter.valid()) {
                            const std::string basis =
                                std::string(MIRROR_APP_EXTERNAL_DIR) + "/face_basis.bin";
                            std::string ferr;
                            if (!g_fitter.load(basis, ferr)) g_track_err = ferr;
                        }
                    }
                    ImGui::SameLine();
                    if (g_face_held) {
                        ImGui::TextColored(ImVec4(1.f, 0.85f, 0.4f, 1.f), "held %.2fs",
                                           pf.nowT - g_face_last_seen);
                    } else if (g_face.valid) {
                        ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "face");
                    } else {
                        ImGui::TextDisabled("no face");
                    }
                    ImGui::PushItemWidth(90);
                    ui::SliderFloat("hold on loss", &g_face_hold_secs, 0.f, 3.f,
                                       "%.2fs");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "How long a detection survives after the tracker\n"
                            "stops returning one. A blink or a turn drops\n"
                            "frames, and without this the fit target flips from\n"
                            "a crop to the whole frame and back -- resizing the\n"
                            "trained pixel set and rebuilding the feature\n"
                            "gather to report something already over.");
                    }
                    ImGui::SameLine();
                    ui::SliderInt("acquire", &g_face_acquire, 1, 10);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Consecutive detections before a face is believed.\n"
                            "The other half of the same idea: keeps a single\n"
                            "spurious hit from starting everything up.");
                    }
                    ui::SliderInt("tracker px", &g_track_px, 240, 960);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Long edge of the frame handed to MediaPipe. The\n"
                            "short edge follows the composition's aspect and is\n"
                            "not a choice: the tracker has to be looking at the\n"
                            "same crop of the sensor as the fit grid, or the\n"
                            "landmarks it returns describe a different\n"
                            "rectangle from the one they get applied to.");
                    }
                    ImGui::SameLine();
                    ImGui::TextDisabled("%d x %d", g_track_w, g_track_h);
                    ImGui::PopItemWidth();
#if !MIRROR_HAVE_KINECT
                    ImGui::TextDisabled("(no camera: tracking needs the Kinect target)");
#endif
                    if (!g_track_err.empty())
                        ImGui::TextColored(ImVec4(1.f, 0.5f, 0.5f, 1.f), "%s",
                                           g_track_err.c_str());

                    ui::Checkbox("fitted mesh drives the root masks", &g_drive_roots);
                    ui::Checkbox("texture the mask from the neural fit",
                                    &g_texture_mask);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Colour the mask's vertices by projecting them into\n"
                            "the mirror's own output and sampling it -- so the\n"
                            "mask wears the network's reconstruction of the\n"
                            "face, not the camera's pixels.\n\n"
                            "The colour is captured, not looked up live: the\n"
                            "mirror and the roots never run at the same time,\n"
                            "so by the time the roots draw there is no neural\n"
                            "texture left to sample. Capturing at the handoff\n"
                            "is what lets the mask keep the face.");
                    }
                    if (!g_face_colors.empty()) {
                        ImGui::SameLine();
                        ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "captured");
                    }
                    ImGui::TextUnformatted("texture from:"); ImGui::SameLine();
                    ImGui::RadioButton("neural render", &g_texture_source,
                                       (int)TextureSource::Mirror);
                    ImGui::SameLine();
                    ImGui::RadioButton("camera frame", &g_texture_source,
                                       (int)TextureSource::Camera);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "The camera's own pixels at the fitted mesh, in\n"
                            "the frame the fit was solved in -- the photograph\n"
                            "rather than what the mirror made of it.");
                    }
                    ui::DeclareInt("texture source", &g_texture_source, 0, 1);
                    if (g_face_colors_best_score >= 0.f)
                        ImGui::TextDisabled("best frame of the sitting: score %.2f "
                                            "(frontality x fit), the capture takes it",
                                            g_face_colors_best_score);

                    // --- frame source --------------------------------------
                    ImGui::Separator();
                    ImGui::TextUnformatted("source:"); ImGui::SameLine();
                    ImGui::RadioButton("sensor", &g_source, (int)Source::Kinect);
                    ImGui::SameLine();
                    ImGui::RadioButton("photo", &g_source, (int)Source::Photo);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Substitute a still photo for the camera. Nothing\n"
                            "downstream knows the difference, so the whole\n"
                            "path -- tracking, fit, mask, texture -- runs\n"
                            "without a person in front of the sensor, and runs\n"
                            "reproducibly on a known face.");
                    }
                    ui::DeclareInt("source", &g_source, 0, 1);
                    if (g_source == (int)Source::Photo) {
                        ImGui::PushItemWidth(-70);
                        ImGui::InputText("##photo", g_photo_path, sizeof(g_photo_path));
                        ImGui::PopItemWidth();
                        ImGui::SameLine();
                        if (ImGui::Button("load")) {
                            std::string perr;
                            if (!LoadPhotoSource(g_photo_path, perr)) g_track_err = perr;
                            else g_track_err.clear();
                        }
                        if (g_photo.empty()) ImGui::TextDisabled("no photo loaded");
                        else ImGui::TextDisabled("photo %dx%d", g_photo_w, g_photo_h);
                    }
                }
                ui::EndGate();
            }
            ui::EndHeader();
            ui::PopSection();               // "face tracking"
            DrawBankSaveUI(ui::Bank::Machine);

            ui::EndTab();
            ui::BeginTab("fit", g_panel_test && g_panel_test_tab == panel_test_tab_i++);
            ui::PushSection("fit");
            ui::BeginGate(!mirror::FaceTracker::available());
            {
                ImGui::TextDisabled("MediaPipe not compiled in");
                ImGui::TextDisabled("run ./setup-mediapipe.sh, then re-cmake");
            }
            ui::EndGate();
            ui::BeginGate(mirror::FaceTracker::available());
            {
                // --- crop & head ---------------------------------------
                ui::Checkbox("crop the fit to the face", &g_mask_fit);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "With a face tracked, train only on its crop; with\n"
                        "none, fit the whole video feed. The network stays\n"
                        "global -- nothing constrains it outside the crop --\n"
                        "so the person is fitted and the rest of the frame\n"
                        "stays generative. A face is a few percent of the\n"
                        "frame, and a cropped step costs about that fraction\n"
                        "of a full one.");
                }
                ImGui::BeginDisabled(!g_mask_fit);
                ImGui::Indent();
                ImGui::TextUnformatted("crop:"); ImGui::SameLine();
                ImGui::RadioButton("landmark box", &g_mask_shape,
                                   (int)MaskShape::Box);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The landmarks' bounding box: the whole face crop,\n"
                        "hair and jawline and the background just around\n"
                        "them included.");
                }
                ImGui::SameLine();
                ImGui::RadioButton("hull", &g_mask_shape, (int)MaskShape::Hull);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The silhouette the landmarks trace. Tighter, but it\n"
                        "supervises skin only -- the network never sees the\n"
                        "boundary between a person and the room, so it has\n"
                        "no reason to draw one.");
                }
                // A radio group draws itself, so it has to declare itself by
                // hand -- and this one never did. The crop shape was saved
                // by nothing and reset to "box" on every launch, however it
                // had been left.
                ui::DeclareInt("crop shape", &g_mask_shape, 0, 1);
                ImGui::PushItemWidth(90);
                ui::BeginGate(g_mask_shape == (int)MaskShape::Box);
                {
                    ui::SliderFloat("pad", &g_crop_pad, 0.f, 0.6f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Grow the box by a fraction of its own size, so\n"
                            "the margin scales with how close the person is.");
                    }
                    ImGui::SameLine();
                }
                ui::EndGate();
                ui::SliderInt("dilate", &g_mask_dilate, 0, 24);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "A fixed margin in fit-grid pixels, on top of the\n"
                        "crop. A region tight to the outline gives the\n"
                        "network no background pixels near the edge, and\n"
                        "with only positive supervision it has no reason to\n"
                        "form a boundary there -- it converges to a soft\n"
                        "blob instead of an edge.");
                }
                ImGui::PopItemWidth();

                // --- head movement ---------------------------------
                ImGui::TextUnformatted("head moves:");
                ImGui::RadioButton("centre it", &g_head_mode,
                                   (int)HeadMode::Centred);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Shift the frame so the head sits in the middle and\n"
                        "fit it there. The network is shown the same problem\n"
                        "every frame, which is the most stable thing to ask\n"
                        "of it -- but the mirror stops showing where in the\n"
                        "room the person is.");
                }
                ImGui::SameLine();
                ImGui::RadioButton("follow it", &g_head_mode,
                                   (int)HeadMode::Track);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Fit the head where the camera found it. Honest, and\n"
                        "the least stable: a face crossing the frame is a\n"
                        "different function at every step, so the weights\n"
                        "spend themselves re-learning one face at a hundred\n"
                        "addresses.");
                }
                ImGui::SameLine();
                ImGui::RadioButton("shift the inputs", &g_head_mode,
                                   (int)HeadMode::Stabilised);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Fit the head where it is, but offset the network's\n"
                        "input coordinates by its displacement -- so the\n"
                        "subject holds still in the network's own frame\n"
                        "while still moving on screen. The picture of\n"
                        "'follow', the weights of 'centre'.\n\n"
                        "The whole field shifts with the head, background\n"
                        "included: the offset is on the coordinates, not on\n"
                        "the subject -- unless 'shift reach' confines it to\n"
                        "around the head.");
                }
                // Size is only meaningful where the app owns the placement.
                // In the other two modes the subject is where the camera
                // found it, and rescaling would be fighting that.
                ui::DeclareInt("head mode", &g_head_mode, 0, 2);
                // The input-shift mode's own dials. Declared always (see
                // the declare-is-not-draw rule); shown only in that mode.
                {
                    const bool stab = g_head_mode == (int)HeadMode::Stabilised;
                    if (!stab) ImGui::BeginDisabled();
                    ImGui::PushItemWidth(110);
                    ui::SliderFloat("shift gain (fit)", &g_shift_gain_fit, 0.f, 2.f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "How far the field follows the head while\n"
                            "fitting. 1 is exact: a point on the face lands\n"
                            "at the same network input wherever the person\n"
                            "stands, which is the whole idea of this mode.");
                    }
                    ui::SliderFloat("shift gain (idle)", &g_shift_gain_idle, 0.f, 1.f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "The same in Idle, where nothing is being fitted\n"
                            "and the shift is only a nudge of interactivity.\n"
                            "The shift is a latch: it holds where it is when\n"
                            "the face is lost, and the next one picks up\n"
                            "from there.");
                    }
                    ui::SliderFloat("shift reach", &g_shift_radius, 0.f, 3.f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "How far from the head the whole shift applies, in\n"
                            "coord units (the frame is 2 tall). 0: the whole\n"
                            "field moves with the head, background included.\n"
                            "Above 0 the field moves whole within this radius\n"
                            "and falls off to 'shift far' past the fade -- a\n"
                            "parallax, the near moving more than the far. The\n"
                            "face is still fitted at one network input.");
                    }
                    ui::SliderFloat("shift fade", &g_shift_fade, 0.05f, 3.f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Over how many coord units the shift falls from\n"
                            "whole to 'shift far'. A shift larger than this\n"
                            "band folds the field over itself.");
                    }
                    ui::SliderFloat("shift far", &g_shift_far, 0.f, 1.f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "The fraction of the shift left past the fade.\n"
                            "0 pins the far field to the room.");
                    }
                    ui::SliderFloat("face size x", &g_stab_size_mul, 0.5f, 2.f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "The on-screen face as a multiple of its size in\n"
                            "the camera. The size still follows the person's\n"
                            "distance, as a mirror's would; this makes the\n"
                            "mirror a little larger or smaller than life.\n"
                            "Anything but 1 costs a bilinear resample of the\n"
                            "frame every frame.");
                    }
                    ImGui::PopItemWidth();
                    if (!stab) ImGui::EndDisabled();
                }
                // The distance-driven size is for the other two modes: the
                // input-shift one takes the multiplier above instead, so its
                // size keeps following the person's distance.
                ImGui::BeginDisabled(g_head_mode == (int)HeadMode::Stabilised);
                ui::Checkbox("set face size", &g_face_size_on);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Resample the crop so the head is a chosen size on\n"
                        "screen, instead of whatever distance the person\n"
                        "happens to be standing at.\n\n"
                        "Costs a bilinear resample every frame: at size 1:1\n"
                        "the centred mode only shifts by whole pixels, which\n"
                        "is deliberate -- refiltering the face every frame is\n"
                        "the noise that mode exists to remove.");
                }
                ImGui::BeginDisabled(!g_face_size_on);
                ui::SliderFloat("size when near", &g_face_size_near, 0.05f, 0.5f, "%.2f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Half the head's height on screen as a fraction of\n"
                        "the frame (0.25 fills half of it top to bottom) when\n"
                        "the person is at 'near' or closer. The size follows\n"
                        "their distance from here to 'size when far'.");
                }
                ui::SliderFloat("size when far", &g_face_size_far, 0.05f, 0.5f, "%.2f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip("The same, at 'far' or beyond.");
                }
                ui::SliderFloat("near (head height)", &g_face_near_hy, 0.05f, 0.5f, "%.2f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How big the head looks to the camera (half-height,\n"
                        "fraction of the frame) when the person counts as\n"
                        "near. The readout below shows the live value; stand\n"
                        "where 'near' should be and copy it in.");
                }
                ui::SliderFloat("far (head height)", &g_face_far_hy, 0.02f, 0.4f, "%.2f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip("The same, where the person counts as far.");
                }
                ImGui::EndDisabled();
                if (g_face_size_on && HaveCrop()) {
                    ImGui::TextDisabled("head %.2f -> size %.2f  x%.2f", g_head_hy,
                                        FaceSizeTarget(), PlaceScale());
                    if (g_head_mode != (int)HeadMode::Centred) {
                        ImGui::SameLine();
                        ImGui::TextDisabled("(in place)");
                    }
                }
                ImGui::EndDisabled();

                ImGui::SetNextItemWidth(110);
                ui::SliderFloat("head smoothing", &g_head_smooth, 0.02f, 1.f,
                                   "%.2f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How fast the tracked box follows the landmarks.\n"
                        "1 is raw. The box jitters a pixel or two on a still\n"
                        "head, and both the input shift and the soft edge\n"
                        "show that jitter directly.");
                }
                ImGui::Unindent();
                ImGui::EndDisabled();

                // --- identity ------------------------------------------
                ImGui::Separator();
                ui::PushSection("identity");
                ImGui::Text("IDENTITY");
                ImGui::SameLine();
                if (g_fitter.hasIdentity()) {
                    ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f),
                                       "fitted (%.2f px residual, %d solve%s, %d worse)%s",
                                       g_id_residual, g_id_solves, g_id_solves == 1 ? "" : "s",
                                       g_id_rejected, g_collect_id ? "  re-solving" : "");
                } else if (g_collect_id) {
                    float best = 0, worst = 0;
                    g_fitter.identityScores(best, worst);
                    ImGui::TextDisabled("collecting %.1fs  best %.2f",
                                        g_id_collect_secs - (pf.nowT - g_id_started),
                                        best);
                } else {
                    ImGui::TextDisabled("mean face");
                }
                ImGui::BeginDisabled(!g_fitter.valid());
                if (ImGui::Button(g_collect_id ? "cancel" : "fit identity")) {
                    if (g_collect_id) {
                        g_collect_id = false;
                    } else {
                        ResetIdentityFit();
                        g_collect_id = true;
                        g_id_started = pf.nowT;
                    }
                }
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Look at the camera with a still face for a few\n"
                        "seconds, then the 100 identity coefficients are\n"
                        "solved over the best frames at once.\n\n"
                        "Frames are ranked by frontality x neutrality and\n"
                        "the best few kept -- not thresholded. MediaPipe\n"
                        "reports substantial baseline activation on an\n"
                        "ordinary face, so any fixed threshold either\n"
                        "accepts everything or nothing depending on the\n"
                        "person and the lighting.\n\n"
                        "Expression is known per frame (from the\n"
                        "blendshapes) and subtracted first, so a smile does\n"
                        "not get baked into the face.");
                }
                ImGui::SameLine();
                ImGui::SetNextItemWidth(90);
                ui::SliderFloat("secs", &g_id_collect_secs, 1.f, 15.f, "%.0fs");
                ImGui::EndDisabled();
                ui::SliderFloat("re-solve every", &g_id_resolve_secs, 0.f, 10.f, "%.1fs");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "After the first solve, keep offering frames and\n"
                        "solve again this often, keeping the best (by\n"
                        "residual over the eye distance, so stepping\n"
                        "closer does not count against it). A solve worse\n"
                        "by more than a quarter is dropped and the best\n"
                        "put back. 0 = solve once, as before.");
                }
                ui::Checkbox("fit automatically", &g_auto_fit_id);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Start collecting the moment a face is acquired\n"
                        "with no identity behind it.\n\n"
                        "Nothing else starts one outside a running show:\n"
                        "the button above was the only trigger, and an\n"
                        "installation has nobody to press it, so the mask\n"
                        "stayed the basis's average -- a real face, and\n"
                        "the wrong one. Every path that forgets a sitter\n"
                        "already clears the identity, so clearing it is\n"
                        "the same thing as asking for the next one.");
                }

                ui::BeginGate(g_fitter.valid());
                {
                    ImGui::PushItemWidth(90);
                    ui::SliderInt("modes", &g_fitter.config().n_identity, 10, 100);
                    ImGui::SameLine();
                    ui::SliderFloat("ridge", &g_fitter.config().ridge, 0.01f, 20.f,
                                       "%.2f", ImGuiSliderFlags_Logarithmic);
                    ImGui::SameLine();
                    ui::SliderInt("frames", &g_fitter.config().max_frames, 1, 24);
                    ImGui::PopItemWidth();
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "modes: of the basis's 100. The tail modes are\n"
                            "detail 68 landmarks cannot resolve, and fitting\n"
                            "them is how the fit starts chasing noise.\n"
                            "ridge: pulls the solve toward the mean face.\n"
                            "frames: more samples average out landmark jitter.");
                    }

                    bool tp = g_fitter.trackerPose();
                    if (ui::Checkbox("head pose from tracker", &tp))
                        g_fitter.useTrackerPose(tp);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Rotate the mesh by MediaPipe's 4x4 facial\n"
                            "transformation matrix. The Python original ran\n"
                            "solvePnP for this; the Tasks API hands back the\n"
                            "pose directly, so there is no PnP and no OpenCV.\n"
                            "Off falls back to the flat 2D similarity, which\n"
                            "is enough for placement but does not turn.");
                    }
                    if (g_face.valid && tp) {
                        float yaw, pitch, roll;
                        g_fitter.headAngles(yaw, pitch, roll);
                        ImGui::TextDisabled("yaw %+.0f°  pitch %+.0f°  roll %+.0f°",
                                            yaw * 57.2958f, pitch * 57.2958f,
                                            roll * 57.2958f);
                    }
                    ImGui::TextDisabled("basis: %d verts, %d tris (%s)",
                                        g_fitter.basis().vertexCount(),
                                        g_fitter.basis().triangleCount(),
                                        g_fitter.basis().nvfTopology() ? "Maxine/NVF"
                                                                       : "ICT");
                }
                ui::EndGate();
                ui::BeginGate(!(g_fitter.valid()));
                {
                    ImGui::TextDisabled("no face_basis.bin -- run");
                    ImGui::TextDisabled("tools/export_face_basis.py");
                }
                ui::EndGate();
                ui::PopSection();       // "identity"
            }
            ui::EndGate();

            ImGui::Separator();
            {
                    mirror::PondParams& P = pf.mirror.params();
                    // Empty, not a path. This used to be hard-coded to a
                    // frame from an unrelated project on one developer's disk,
                    // and since "fit" falls back to the still whenever the live
                    // feed is not armed, the usual way to meet it was pressing
                    // fit and watching the mirror converge onto a stranger's
                    // photograph -- which reads as the camera fit being broken
                    // rather than as a different target being used.
                    static char fit_path[512] = "";
                    static std::string fit_err;

                    ImGui::Text("FIT  %s", pf.mirror.pond().fitted()
                                    ? (pf.mirror.pond().fitting() ? "training" : "held")
                                    : "not fitted");
                    ImGui::SameLine();
                    ImGui::TextDisabled("| %d steps | loss %.5f",
                                        pf.mirror.pond().fitSteps(), pf.mirror.lastLoss());

                    ImGui::PushItemWidth(-1);
                    ImGui::InputText("##fitpath", fit_path, sizeof(fit_path));
                    ImGui::PopItemWidth();

#if MIRROR_HAVE_KINECT
                    {
                        ImGui::Separator();
                        const bool open = g_kinect.isOpen();
                        const mirror::KinectFitTarget::SensorState kstate = g_kinect.state();
                        ImGui::Text("LIVE");
                        ImGui::SameLine();
                        if (open) {
                            ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "%s",
                                               g_kinect.deviceInfo().c_str());
                        } else if (kstate == mirror::KinectFitTarget::SensorState::kLost) {
                            ImGui::TextColored(ImVec4(1.f, 0.6f, 0.3f, 1.f),
                                               "sensor lost -- retrying in %.0fs",
                                               g_kinect.retryInSeconds());
                        } else {
                            ImGui::TextDisabled("sensor closed");
                        }
                        ImGui::SameLine();
                        ImGui::TextDisabled("| %llu frames",
                                            (unsigned long long)g_kinect.frames());

                        // Always declared, never gated behind `open` -- see
                        // PANEL.md: this is a plain preset value, not
                        // something whose meaning depends on sensor state.
                        ImGui::PushItemWidth(90);
                        ui::SliderFloat("kinect stall s", &g_kinect_stall_s,
                                        0.5f, 15.f, "%.1f");
                        ImGui::PopItemWidth();
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "How long the colour stream may go quiet\n"
                                "before the sensor is declared lost and the\n"
                                "watchdog starts closing/reopening it on a\n"
                                "backoff (1s, 2s, 4s ... capped at 15s).\n\n"
                                "Nobody is at the panel during the show to\n"
                                "notice a dead feed and press \"open sensor\"\n"
                                "again -- this is what does it instead.");
                        }

                        if (ImGui::Button(open ? "close sensor" : "open sensor")) {
                            if (open) {
                                g_fit_live = false;
                                g_kinect.close();
                            } else {
                                std::string kerr;
                                if (!g_kinect.open(kerr)) fit_err = kerr;
                                else fit_err.clear();
                            }
                        }
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "Only one process can hold the sensor -- close\n"
                                "kinect_v2_demo first, or opening fails with\n"
                                "LIBUSB_ERROR_NO_DEVICE.");
                        }
                        ImGui::SameLine();
                        ImGui::BeginDisabled(!open);
                        // Arming the feed does not start training: the frame
                        // pull, the tracker and the preview all come alive, and
                        // "fit" below is what begins (or restarts) the fit on
                        // whatever the camera is showing at that moment.
                        ui::Checkbox("track live feed", &g_fit_live);
                        ImGui::EndDisabled();
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "Retarget from the camera every frame. The fit\n"
                                "never finishes -- it tracks, running a few\n"
                                "hundred ms behind whoever is in front of the\n"
                                "sensor. That lag is the effect.\n\n"
                                "This only arms the feed. Press fit to start\n"
                                "training on it.");
                        }
                        // --- outside the crop ---------------------------
                        //
                        // Inside, the network is reproducing a person and
                        // every input must hold still. Outside, nothing is
                        // constrained. These are what that difference is
                        // allowed to look like.
                        ui::Checkbox("soft edge", &g_region_on);
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "Fade the effects below in across a band around\n"
                                "the crop instead of switching at its border.");
                        }
                        ImGui::BeginDisabled(!g_region_on);
                        ImGui::SameLine();
                        ui::Checkbox("follow the outline", &g_region_hull);
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "Fade outward from the mask's actual shape --\n"
                                "the face outline when the crop is a hull --\n"
                                "rather than from its bounding box.\n\n"
                                "Also what makes the band an even width all the\n"
                                "way round: the box form measures distance as a\n"
                                "fraction of each half-extent, so a tall crop\n"
                                "fades over a longer distance vertically than\n"
                                "horizontally and flares at the corners, which\n"
                                "is the gradient pooling along the edges.");
                        }
                        ImGui::PushItemWidth(90);
                        ui::SliderFloat("fade starts", &g_fade_start, 0.f, 0.8f,
                                           "%.3f");
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "How far out from the crop the fade begins, in\n"
                                "coord units (the frame is 2 tall). Push it out\n"
                                "to keep a clean margin of untouched pixels\n"
                                "around the subject before anything happens.");
                        }
                        ImGui::SameLine();
                        ui::SliderFloat("fade width", &g_fade_width, 0.01f, 1.5f,
                                           "%.3f");
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "And how far it runs. Start and width are\n"
                                "separate because 'where the gradient sits' and\n"
                                "'how long it takes' are separate complaints --\n"
                                "a fade pinned to the edge pools against it\n"
                                "however wide you make it.");
                        }
                        ImGui::PopItemWidth();

                        ui::Checkbox("animate z outside", &g_z_free);
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "Let the latent move everywhere except on the\n"
                                "subject, which stays pinned to the z the fit\n"
                                "was begun at.\n\n"
                                "z is an MLP input, not a colour knob: moving it\n"
                                "under a fitted network asks the same weights a\n"
                                "different question, and the face comes apart.\n"
                                "Pinning it inside the crop is what lets the\n"
                                "rest of the frame keep breathing.");
                        }
                        ImGui::BeginDisabled(!g_z_free);
                        ImGui::SameLine();
                        ImGui::SetNextItemWidth(90);
                        // Raw, not ui::. This is the *same* P.z_rate the z latent
                        // section declares as "mirror/z/z auto-rate /s"; wrapping
                        // it here too registered one variable under two names, in
                        // two different banks once this block moved to Fit -- so a
                        // load would apply both and whichever declared last won.
                        // A second handle on a control is a convenience; a second
                        // *name* for it is a bug.
                        ImGui::SliderFloat("z rate /s", &P.z_rate, 0.f, 0.2f,
                                          "%.4f");
                        ImGui::EndDisabled();

                        ImGui::SetNextItemWidth(110);
                        ui::SliderFloat("grey outside", &g_grey_out, 0.f, 1.f,
                                           "%.2f");
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "Drain colour outside the crop: 1 leaves the\n"
                                "subject in colour on a greyscale field. Rides\n"
                                "the same falloff as the latent, so there is one\n"
                                "edge in the picture rather than two that nearly\n"
                                "agree.");
                        }
                        ImGui::EndDisabled();
                        if (!pf.mirror.pond().fitted()) {
                            ImGui::TextDisabled("(these need a fit: there is no "
                                                "inside without one)");
                        } else if (!HaveCrop()) {
                            ImGui::TextDisabled("(these need a tracked face)");
                        }
                    }
#endif
                    // Two tunings, switched by whether a crop is active. The
                    // live one is marked, because otherwise sliders that do
                    // nothing right now look broken rather than inactive.
                    const bool crop_live = g_have_mask;
                    for (int which = 0; which < 2; ++which) {
                        FitTune& T = which == 0 ? g_tune_crop : g_tune_full;
                        const bool active = (which == 0) == crop_live;
                        ImGui::PushID(which);
                        // Own section per row: the two rows carry the same
                        // labels, and without this they would be one parameter
                        // in the registry rather than two.
                        ui::PushSection(which == 0 ? "crop" : "feed");
                        if (active) {
                            ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "%s",
                                               which == 0 ? "face crop  >" : "whole feed >");
                        } else {
                            ImGui::TextDisabled("%s",
                                which == 0 ? "face crop   " : "whole feed  ");
                        }
                        ImGui::SameLine();
                        ImGui::PushItemWidth(70);
                        ui::SliderInt("grid", &T.downscale, 1, 8);
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(
                                "Fit resolution as a divisor of the display\n"
                                "size, so 1 is the full render grid and 4 is a\n"
                                "sixteenth of the area.\n\n"
                                "A step costs roughly 3x a render over the same\n"
                                "points -- but a crop is only a few percent of\n"
                                "those points, so it can afford a far finer grid\n"
                                "than the whole feed ever could, and a face is\n"
                                "where the detail has to go. The network is\n"
                                "continuous either way: whatever grid the\n"
                                "gradient came from, the result renders at full\n"
                                "size.");
                        }
                        ImGui::SameLine();
                        ui::SliderInt("steps", &T.steps, 1, 32);
                        ImGui::SameLine();
                        ui::SliderFloat("lr", &T.lr, 1e-4f, 2e-2f, "%.4f",
                                           ImGuiSliderFlags_Logarithmic);
                        ImGui::PopItemWidth();
                        ui::PopSection();
                        ImGui::PopID();
                    }
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "A crop is a few percent of the pixels, so a step\n"
                            "costs a few percent as much and many more fit in a\n"
                            "frame -- but each gradient sees far less data, so a\n"
                            "smaller step keeps it from chasing the crop box's\n"
                            "own jitter. The whole feed is the opposite. One\n"
                            "shared set of numbers meant every crop/no-crop\n"
                            "transition quietly changed what they meant.");
                    }
                    if (pf.fit_w > 0) {
                        ImGui::TextDisabled("fit grid %d x %d  (%d px%s)", pf.fit_w, pf.fit_h,
                                            pf.mirror.pond().fitPixels(),
                                            crop_live ? ", cropped" : "");
                    }

                    if (ImGui::Button(pf.mirror.pond().fitting() ? "stop" : "fit")) {
                        if (pf.mirror.pond().fitting()) {
                            pf.mirror.pond().stopFit();
                        } else if (g_fit_live &&
                                   pf.live_rgb.size() != size_t(pf.fit_w) * pf.fit_h * 3) {
                            // Armed but nothing has arrived yet. Falling back to
                            // the still here would silently fit the photo and
                            // then look like the camera fit had failed.
                            fit_err = "no camera frame yet";
                        } else if (g_fit_live) {
                            // Start on the frame the camera is showing right
                            // now, cropped the same way the per-frame retarget
                            // will crop it -- beginFit sizes the optimiser to
                            // the pixel set, so starting unmasked and narrowing
                            // a frame later would rebuild it immediately.
                            fit_err.clear();
                            if (g_have_mask) {
                                pf.mirror.pond().beginFit(pf.live_rgb, pf.fit_h, pf.fit_w, P,
                                                       g_fit_mask);
                            } else {
                                pf.mirror.pond().beginFit(pf.live_rgb, pf.fit_h, pf.fit_w, P);
                            }
                        } else {
                            // The still-image path has no crop, so it is the
                            // whole-feed grid that applies.
                            const int ds = std::max(1, g_tune_full.downscale);
                            const int fw = std::max(8, pf.mirror.lowW() / ds);
                            const int fh = std::max(8, pf.mirror.lowH() / ds);
                            std::vector<float> rgb;
                            fit_err.clear();
                            if (fit_path[0] == '\0') {
                                fit_err = "no image named -- tick 'track live "
                                          "feed' to fit the camera";
                            } else if (LoadImageRGB(fit_path, fw, fh, rgb, fit_err)) {
                                pf.mirror.pond().beginFit(rgb, fh, fw, P);
                            }
                        }
                    }
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            g_fit_live
                                ? "Fit the live feed -- the face crop when one\n"
                                  "is tracked, the whole frame otherwise."
                                : "Fit the still image above. Arm 'track live\n"
                                  "feed' to fit the camera instead.");
                    }
                    ImGui::SameLine();
                    ImGui::BeginDisabled(!pf.mirror.pond().fitted());
                    if (ImGui::Button("clear fit")) pf.mirror.pond().clearFit();
                    ImGui::EndDisabled();
                    ImGui::SameLine();
                    ImGui::TextDisabled("(clear returns to the generated field)");

                    if (!fit_err.empty()) {
                        ImGui::PushStyleColor(ImGuiCol_Text, IM_COL32(255, 140, 120, 255));
                        ImGui::TextWrapped("%s", fit_err.c_str());
                        ImGui::PopStyleColor();
                    }
                    if (pf.mirror.pond().fitted()) {
                        ImGui::TextDisabled(
                            "weights are learned: detail / contrast / tilt no "
                            "longer apply");
                    }
                }

                ui::Checkbox("ramp w0 for the fit", &g_w0_ramp_on);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Entering the fitting phase, take sine w0 up to the\n"
                        "value below before starting the fit, and put it back\n"
                        "on the way out to idle.\n\n"
                        "It has to happen *before* beginFit. w0 shapes the base\n"
                        "weights, and the optimiser is seeded from those once --\n"
                        "after that the network is learned and w0 no longer\n"
                        "reaches it, so turning it up mid-fit does nothing.");
                }
                ui::BeginGate(g_w0_ramp_on);
                {
                    ImGui::PushItemWidth(110);
                    ui::SliderFloat("fit w0", &g_w0_fit, 1.0f, 80.0f, "%.1f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "The frequency of the basis the face is\n"
                            "reconstructed out of. A fit wants far more regions\n"
                            "than an idle field does -- at the idle value there\n"
                            "are not enough of them to carry an eye.");
                    }
                    ImGui::SameLine();
                    ui::SliderFloat("ramp secs", &g_w0_ramp_secs, 0.f, 8.f, "%.1fs");
                    ImGui::PopItemWidth();
                    if (ui::Visible() && g_w0_t0 >= 0.0) {
                        ImGui::SameLine();
                        ImGui::TextColored(ImVec4(1.f, 0.85f, 0.4f, 1.f),
                                           "ramping %.0f%%",
                                           100.f * W0RampT(pf.nowT));
                    }
                }
                ui::EndGate();

                ImGui::PushItemWidth(110);
                ui::SliderFloat("lr warm-up secs", &g_lr_warm_secs, 0.f, 15.f, "%.1fs");
                ImGui::SameLine();
                ui::SliderFloat("lr warm-up from", &g_lr_warm_from, 0.f, 1.f, "%.2fx");
                ImGui::PopItemWidth();
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The learning rate starts at this fraction of the\n"
                        "crop/full lr when a fit begins and eases up to the\n"
                        "full value over the warm-up seconds (0 = off), so the\n"
                        "face resolves over the first seconds instead of\n"
                        "snapping in on the first.");
                }

                ui::Checkbox("colour follows the fit", &g_colour_fit_on);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Drive the mirror's 'color mix' from the fit level --\n"
                        "the same number the harmony climbs on -- so the room\n"
                        "idles in black and white and gains colour as she is\n"
                        "captured. Put back on the way out to idle.\n\n"
                        "It writes the mirror's own colour slider, so that\n"
                        "slider is what it starts from and what it returns to:\n"
                        "the preset decides the idle colour, this decides how\n"
                        "the fit takes it to full.");
                }
                ui::BeginGate(g_colour_fit_on);
                {
                    ImGui::PushItemWidth(110);
                    ui::SliderFloat("full colour at fit", &g_colour_fit_full,
                                    0.1f, 1.0f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "The fit level that reaches the ceiling below. Below\n"
                            "1 on purpose: the last stretch of convergence is\n"
                            "slow, and colour that only completes at the very\n"
                            "end reads as a switch being thrown rather than as\n"
                            "the image filling in.");
                    }
                    ImGui::SameLine();
                    ui::SliderFloat("max colour", &g_colour_fit_max, 0.0f, 1.0f,
                                    "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "The ratchet's ceiling -- 1 is full RGB, lower caps\n"
                            "the mirror at a partial mix even once the fit\n"
                            "reaches 'full colour at fit'. Separate from that\n"
                            "dial on purpose: one controls when colour arrives,\n"
                            "this controls how far it ever gets.");
                    }
                    ImGui::SameLine();
                    ui::SliderFloat("colour secs", &g_colour_fit_secs, 0.f, 20.f,
                                    "%.1fs");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "How long the colour takes to ease in (smoothstep,\n"
                            "like the w0 ramp) once the fit level calls for it.\n"
                            "The loss is noisy frame to frame; this and the\n"
                            "one-way ratchet are what keep the colour from\n"
                            "flickering back out on a bad step.");
                    }
                    ImGui::PopItemWidth();
                    if (ui::Visible() && g_colour_idle >= 0.f) {
                        ImGui::SameLine();
                        ImGui::TextColored(ImVec4(1.f, 0.85f, 0.4f, 1.f),
                                           "colour %.0f%%", 100.f * g_colour_now);
                    }
                }
                ui::EndGate();
            ui::PopSection();               // "fit"
            DrawBankSaveUI(ui::Bank::Fit);
            ui::EndTab();
            ui::BeginTab("debug", g_panel_test && g_panel_test_tab == panel_test_tab_i++);
            ui::PushSection("debug");
            ui::BeginGate(!mirror::FaceTracker::available());
            {
                ImGui::TextDisabled("MediaPipe not compiled in");
                ImGui::TextDisabled("run ./setup-mediapipe.sh, then re-cmake");
            }
            ui::EndGate();
            ui::BeginGate(mirror::FaceTracker::available());
            {
                // --- camera preview -------------------------------------
                ui::Checkbox("camera overlay", &g_show_source);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Show the raw source frame in a corner -- the same\n"
                        "image the tracker sees, mirroring included. The\n"
                        "mirror's own output cannot tell a closed sensor\n"
                        "from a stale frame from the photo still being\n"
                        "selected; this can.");
                }
                ui::BeginGate(g_show_source);
                {
                    ImGui::SameLine();
                    ui::Checkbox("landmarks", &g_pip_landmarks);
                    ImGui::PushItemWidth(110);
                    ui::SliderInt("size", &g_source_pip_w, 160, 640);
                    ImGui::SameLine();
                    const char* corners[] = {"top-left", "top-right",
                                             "bottom-left", "bottom-right"};
                    ImGui::Combo("corner", &g_source_corner, corners, 4);
                    ui::DeclareInt("corner", &g_source_corner, 0, 3);
                    ImGui::PopItemWidth();
                }
                ui::EndGate();

                // --- what the network is trained on ------------------
                ui::Checkbox("network input", &g_show_netin);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The exact buffer handed to the optimiser: the feed\n"
                        "after the crop, the mirroring, the fit grid and the\n"
                        "head placement, with the trained pixels bright and\n"
                        "the rest dimmed.\n\n"
                        "The camera overlay says a frame is arriving. This\n"
                        "says what became of it -- which is the question a\n"
                        "fit that converges onto the wrong thing is asking.");
                }
                ui::BeginGate(g_show_netin);
                {
                    ImGui::PushItemWidth(110);
                    ui::SliderInt("input size", &g_netin_pip_w, 160, 640);
                    ImGui::SameLine();
                    const char* ncorners[] = {"top-left", "top-right",
                                              "bottom-left", "bottom-right"};
                    // Distinct *labels*, not distinct ids: "##net" is
                    // stripped before naming, so "size##net" registers as
                    // the camera overlay's own "size" and the two controls
                    // become one parameter.
                    ImGui::Combo("input corner", &g_netin_corner, ncorners, 4);
                    ui::DeclareInt("input corner", &g_netin_corner, 0, 3);
                    ui::SliderFloat("untrained dim", &g_netin_dim, 0.f, 1.f, "%.2f");
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "How far down the pixels outside the mask are\n"
                            "taken. 0 is what the optimiser effectively\n"
                            "sees; turn it up to check the crop is on the\n"
                            "person rather than beside them.");
                    }
                    ImGui::PopItemWidth();
                }
                ui::EndGate();
            }
            ui::EndGate();
            ui::PopSection();               // "debug"
            DrawBankSaveUI(ui::Bank::Debug);
            ui::EndTab();
            ui::BeginTab("look", g_panel_test && g_panel_test_tab == panel_test_tab_i++);
            // "cloth", not "transition", and the rename is load-bearing.
            //
            // These controls now drive RootScene's cloth rather than the
            // retired TransitionScene, and the Look bank keys are built from
            // the section name -- so keeping the old name would make every
            // saved .set file quietly load TransitionScene-era numbers onto
            // it. They are not interchangeable: that scene pressed and settled
            // the mask against a sheet sized to its own small fixed frustum;
            // this one has no press or settle at all, only a hold before the
            // release lets the film fall. Renaming orphans those keys, which
            // are then ignored on load, and
            // RootScene keeps its own defaults until someone saves new ones.
            ui::PushSection("cloth");
            // The transition page is a category of settings, not a cue to
            // play one: what is on screen is the phase navigator's business,
            // so these declare and draw whenever the look tab is open.
            {
                ImGui::Text("%s   t=%.2fs   release %.0f%%",
                            pf.roots.clothPhaseName(), pf.roots.clothClock(),
                            pf.roots.clothRelease() * 100.f);
                ImGui::SameLine();
                if (ImGui::Button("replay")) pf.roots.restartCloth();

                // --- the locked fit ------------------------------------
                //
                // The one instant the effect turns on: the film stops being
                // live and every vertex keeps the texel it was covering. Shown
                // here because it is the thing that goes wrong invisibly --
                // an unlocked run looks almost right until the head moves, and
                // then the face slides across the mask like a slide projection.
                //
                // Still TransitionScene's, and so no longer part of the live
                // show: RootScene bakes the film onto the mask as vertex colour
                // (setFaceColors) instead of locking a uv against a frozen
                // film, so there is no lock instant to expose. The buttons
                // remain because the capture *files* they produce are still
                // what the piece replays.
                ImGui::SameLine();
                if (pf.trans.fitLocked()) {
                    ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "locked");
                } else {
                    ImGui::TextDisabled("live");
                }
                ImGui::SameLine();
                if (ImGui::Button(pf.trans.fitLocked() ? "unlock" : "lock now")) {
                    if (pf.trans.fitLocked()) pf.trans.unlockFit(); else pf.trans.lockFit();
                }
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Freeze the film and nail the mask's uv to it.\n\n"
                        "Before the lock the mask wears this frame's\n"
                        "projection of the live pond, which is what makes it\n"
                        "invisible against the film it is behind. After it the\n"
                        "film is a picture and each vertex keeps the texel it\n"
                        "was covering, so the face travels with the mesh.\n\n"
                        "Recomputing the uv after the freeze is the failure\n"
                        "this prevents: geometry and texture then move in\n"
                        "different frames and the face reads as a still\n"
                        "projected onto a moving mask from a fixed lamp.");
                }
                ui::Checkbox("lock when the press starts", &pf.trans.autoLock);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The press starting is the last frame on which the\n"
                        "mask and the film are still in register -- after it\n"
                        "the mask is coming through the sheet and the pond\n"
                        "behind it is no longer a picture of the face.");
                }
                ImGui::SameLine();
                ui::Checkbox("save a capture on lock", &g_capture_auto);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Write the frozen film, the mesh, the locked uv and\n"
                        "the baked vertex colours to captures/<id>/, so this\n"
                        "sitter can be worn again later -- next scene, or next\n"
                        "night. The id is the local date and time.");
                }
                if (!g_capture_msg.empty()) ImGui::TextDisabled("%s", g_capture_msg.c_str());

                if (ImGui::TreeNode("captures")) {
                    if (ImGui::Button("refresh")) {
                        g_capture_ids = mirror::ListCaptures();
                        g_capture_sel = -1;
                    }
                    ImGui::SameLine();
                    if (g_capture_loaded.empty()) {
                        ImGui::TextDisabled("masks: live fit");
                    } else {
                        ImGui::Text("masks: %s", g_capture_loaded.c_str());
                        ImGui::SameLine();
                        if (ImGui::Button("release")) {
                            g_capture_loaded.clear();
                            pf.roots.clearFittedFace();
                            g_capture_msg = "masks back to the live fit";
                        }
                    }
                    ImGui::BeginChild("caplist", ImVec2(0, 120), true);
                    for (int i = 0; i < (int)g_capture_ids.size(); ++i) {
                        if (ImGui::Selectable(g_capture_ids[i].c_str(), g_capture_sel == i))
                            g_capture_sel = i;
                    }
                    ImGui::EndChild();
                    const bool has_sel = g_capture_sel >= 0 &&
                                         g_capture_sel < (int)g_capture_ids.size();
                    ImGui::BeginDisabled(!has_sel);
                    if (ImGui::Button("wear on the masks")) {
                        mirror::FaceCapture cap;
                        std::string cerr;
                        if (mirror::LoadCapture(g_capture_ids[g_capture_sel], cap, cerr)) {
                            // Mesh and colour together, in that order: the
                            // colours are per vertex of *this* mesh, and
                            // uploading them against the previous one paints
                            // one person's face onto another's geometry.
                            pf.roots.setFittedFace(cap.verts, cap.tris);
                            pf.roots.setFaceColors(cap.colors);
                            g_capture_loaded = cap.id;
                            g_capture_msg = "masks wearing " + cap.id;
                        } else {
                            g_capture_msg = cerr;
                        }
                    }
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Load onto the root scene's masks. The capture\n"
                            "then outranks the live tracker -- which is the\n"
                            "point: by the time the roots are up, the sitter\n"
                            "has gone, and driving the masks from whoever is\n"
                            "in front of the sensor now would overwrite the\n"
                            "face the transition just handed over.");
                    }
                    ImGui::SameLine();
                    if (ImGui::Button("load into the transition")) {
                        mirror::FaceCapture cap;
                        std::string cerr;
                        if (mirror::LoadCapture(g_capture_ids[g_capture_sel], cap, cerr) &&
                            pf.trans.applyCapture(cap)) {
                            g_capture_msg = "transition replaying " + cap.id;
                        } else {
                            g_capture_msg = cerr.empty() ? std::string("capture has no film")
                                                         : cerr;
                        }
                    }
                    ImGui::SameLine();
                    if (ImGui::Button("delete")) {
                        std::string cerr;
                        const std::string id = g_capture_ids[g_capture_sel];
                        if (mirror::DeleteCapture(id, cerr)) {
                            if (g_capture_loaded == id) g_capture_loaded.clear();
                            g_capture_msg = "deleted " + id;
                        } else {
                            g_capture_msg = cerr;
                        }
                        g_capture_ids = mirror::ListCaptures();
                        g_capture_sel = -1;
                    }
                    ImGui::EndDisabled();
                    ImGui::TreePop();
                }

                if (!pf.roots.usingFittedFace()) {
                    ImGui::TextDisabled("no mask -- load face_basis.bin");
                } else if (!g_track_on || !g_face.valid) {
                    ImGui::TextDisabled("no tracked face -- showing the neutral mask");
                }
                ImGui::SeparatorText("timing (seconds)");
                ImGui::PushItemWidth(110);
                ui::SliderFloat("hold",    &pf.roots.clothTiming.hold,    0.f, 3.f);
                ImGui::SameLine();
                ui::SliderFloat("release", &pf.roots.clothTiming.release, 0.05f, 3.f);
                ui::SliderFloat("fall",    &pf.roots.clothTiming.fall,    0.5f, 6.f);
                ImGui::PopItemWidth();
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "hold: the flat film, which is the pond exactly.\n"
                        "release: the pins letting go, corners first.\n"
                        "fall: draping off the face and away.");
                }
                ImGui::SeparatorText("clearance -- merges into the root scene once cleared");
                ui::SliderFloat("clear distance (world units)", &pf.roots.clothClearDistance,
                                0.2f, 5.f, "%.2f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How far the sheet's average depth has to recede past\n"
                        "the mask's own front surface before the merged\n"
                        "Transition/Roots handoff treats it as \"cleared\" --\n"
                        "see root scene beat 1's clear-tail control.");
                }
                ui::SliderFloat("side force delay (s into release)", &pf.roots.sideForceDelay,
                                0.f, 30.f, "%.1f");
                ui::SliderFloat("side force magnitude", &pf.roots.sideForceMag, 0.f, 15.f, "%.1f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "A visitor holding still could otherwise stall release\n"
                        "indefinitely. This many seconds into release, a\n"
                        "lateral force (this magnitude) is added so the sheet\n"
                        "always slides clear on a bounded schedule.");
                }
                ImGui::SeparatorText("look");
                ui::SliderFloat("refraction", &pf.roots.renderer().cloth.refract, 0.f, 0.25f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How much the film bends the image where the fabric\n"
                        "bends. Driven by the cloth's own normals, so it is\n"
                        "exactly zero on the flat sheet -- the opening frame\n"
                        "has to be the pond, not a displaced copy of it.");
                }
                ui::SliderFloat("film relief", &pf.roots.renderer().cloth.reliefSharp, 0.f, 3.f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How hard the film's own curvature is drawn.\n\n"
                        "Lambert over a tented sheet is a soft wash -- the\n"
                        "normals turn slowly, so the brow and the nose shade\n"
                        "barely differently from the cheek beside them, and\n"
                        "the press reads as the image stretching rather than\n"
                        "as a face coming through the fabric. What a viewer\n"
                        "actually reads a covered face by is the sign of the\n"
                        "surface's second derivative: convex on the brow and\n"
                        "the nose, concave in the sockets. This is that term,\n"
                        "and it is zero on a flat sheet.");
                }
                ui::SliderFloat("film sheen", &pf.roots.renderer().cloth.sheen, 0.f, 1.5f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "A raking specular on the fabric's bends. Wet film is\n"
                        "not matte, and the streak along a fold is the other\n"
                        "half of what says surface rather than printed image.\n"
                        "Gated to the pressed area like the relief, so the\n"
                        "untouched film stays exactly the pond.");
                }
                ui::SliderFloat("mask relief", &pf.trans.depthScale, 0.2f, 4.f);
                ui::SliderFloat("shading span", &pf.trans.shadeSpan, 1.f, 10.f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The size the mask is shaded at, in the root scene's\n"
                        "world units. Its marble, light falloff and spot cone\n"
                        "are world-space quantities tuned against a mask about\n"
                        "four units across; this scene places the mask by\n"
                        "projection at whatever size the fit gives it, so the\n"
                        "shading space is scaled back to that reference rather\n"
                        "than every parameter being re-tuned.");
                }
                ImGui::TextDisabled("material: the roots' mask (look -> roots -> mask)");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The mask's material, environment, exposure and tonemap\n"
                        "are the root scene's own, copied in every frame -- not\n"
                        "a second set of knobs. The transition ends with the\n"
                        "mask alone on screen and the roots phase begins with\n"
                        "the same mask in a tangle; sharing them is what makes\n"
                        "that cut land on one object rather than two that\n"
                        "happen to be tuned alike.\n\n"
                        "The film is deliberately not on that material: it is\n"
                        "the mirror's output, display-referred, and has to stay\n"
                        "identical to the scene the piece cuts from.");
                }
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Depth exaggeration of the mask. 1 is the fit's own\n"
                        "proportions; the fit is solved from one view, so a\n"
                        "little more relief often reads better on screen.");
                }
                ImGui::SeparatorText("registration -- NOT driving the show");
                // Everything from here down still edits the old TransitionScene,
                // which nothing draws any more: the press lives in RootScene now
                // and places the mask in the anchor's own cavity frame rather
                // than by solving a per-frame projection, so there is no
                // registration to set and no equivalent control to move these
                // onto. Left reachable because --transhot still drives a
                // TransitionScene of its own and these are how it is set up;
                // labelled so nobody tunes them expecting the stage to change.
                ImGui::TextDisabled("edits the retired TransitionScene (--transhot only)");
                ui::Checkbox("align mask", &pf.trans.alignMask);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Hold the mask fully pressed through a flat film and\n"
                        "stop the timeline, so the mask and the face it is\n"
                        "supposed to sit on are both on screen. This is the\n"
                        "state to set the scale and offset in; everywhere else\n"
                        "the mask is either hidden behind the sheet or moving.");
                }
                ImGui::PushItemWidth(110);
                ui::SliderFloat("mask scale x", &pf.trans.maskScale[0], 0.6f, 1.4f);
                ImGui::SameLine();
                ui::SliderFloat("mask scale y", &pf.trans.maskScale[1], 0.6f, 1.4f);
                ui::SliderFloat("mask offset x", &pf.trans.maskOffset[0], -0.2f, 0.2f);
                ImGui::SameLine();
                ui::SliderFloat("mask offset y", &pf.trans.maskOffset[1], -0.2f, 0.2f);
                ImGui::PopItemWidth();
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "The mask is placed by the fit's projection, which is a\n"
                        "2D similarity -- no perspective, no out-of-plane\n"
                        "foreshortening. On a face looking at the camera it\n"
                        "lands on the features; on a head with real pitch it\n"
                        "comes out too tall, eyes high and mouth low, and\n"
                        "nothing downstream can recover that. Scale is per-axis\n"
                        "because the error is.\n\n"
                        "The texture moves with the geometry, so correcting\n"
                        "where the mask sits keeps it wearing what it covers.");
                }
                if (ImGui::Button("reset registration")) {
                    pf.trans.maskScale[0] = pf.trans.maskScale[1] = 1.f;
                    pf.trans.maskOffset[0] = pf.trans.maskOffset[1] = 0.f;
                }

                ImGui::SeparatorText("cloth");
                ui::Checkbox("show cloth", &pf.roots.showCloth);
                ImGui::SameLine();
                ui::Checkbox("show mask", &pf.roots.showFace);
                ImGui::SameLine();
                ui::Checkbox("wireframe", &pf.trans.wireframe);
                ui::SliderFloat("gravity back (-z)", &pf.roots.clothGravityBack, 0.f, 20.f);
                ui::SliderFloat("gravity down (-y)", &pf.roots.clothGravityDown, 0.f, 8.f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Zero by default. A -y pull drags the whole film out of\n"
                        "frame, so the mask ends up uncovered by something that\n"
                        "has nothing to do with it. With gravity straight back,\n"
                        "what takes the film off is the mask's own asymmetry --\n"
                        "a turned head makes the tangential forces stop\n"
                        "cancelling, and the fabric peels from the shallow side.");
                }
                ui::SliderFloat("friction", &pf.roots.clothFriction, 0.f, 1.f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Tangential grip where the sheet touches the mask.\n"
                        "This is what makes it drape over the brow and the\n"
                        "nose instead of sliding off them like glass.");
                }
                ui::SliderFloat("stretch", &pf.roots.clothStretch, 0.f, 0.98f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How freely the film lengthens. At 0 it is\n"
                        "inextensible and bridges the face instead of\n"
                        "wrapping it; toward 1 it stretches over the form\n"
                        "the way a dipped film does. Compression stays stiff\n"
                        "either way, which is what keeps the canvas taut.");
                }
                ui::SliderFloat("set (plasticity)", &pf.roots.clothPlastic, 0.f, 8.f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How fast a held stretch becomes the sheet's own\n"
                        "shape. At 0 every bit of tension stored during the\n"
                        "press comes back at once when the pins let go, and\n"
                        "the sheet snaps off the face.");
                }
                ui::SliderFloat("damping", &pf.roots.clothDamping, 0.9f, 1.f);
                ui::SliderFloat("relief shading", &pf.roots.renderer().cloth.reliefShade, 0.f, 1.f);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How far shading swings either side of the flat\n"
                        "sheet's value. The flat sheet always reads 1, so\n"
                        "this changes how much the folds show without ever\n"
                        "changing the film's overall brightness.");
                }
                ui::SliderFloat("sheet oversize", &pf.roots.clothOversize, 1.f, 1.3f);
                ImGui::PushItemWidth(110);
                ui::SliderInt("substeps", &pf.roots.clothSubsteps, 1, 8);
                ImGui::SameLine();
                ui::SliderInt("iterations", &pf.roots.clothIterations, 4, 64);
                ui::SliderInt("sheet res", &pf.roots.clothSheetRes, 16, 128);
                ImGui::PopItemWidth();
                ImGui::TextDisabled("%d verts, %zu tris, minZ %.2f",
                                    (int)pf.roots.cloth().pos.size(),
                                    pf.roots.cloth().tris.size() / 3, pf.roots.cloth().minZ());
            }
            // (the transition page is a category of settings, not a cue to
            //  play one: what is on screen is the navigator's business)
            ui::PopSection();               // "cloth"

            // --- text overlay -------------------------------------------
            // Outside the per-scene blocks: it composites in the present pass,
            // so it is available over every scene.
            ui::PushSection("text");
            ui::BeginHeader("text overlay", /*default_open=*/false);
            {
                ui::Checkbox("show text", &pf.textp.on);
                static char buf[256] = {};
                static bool buf_init = false;
                if (!buf_init) {
                    std::snprintf(buf, sizeof(buf), "%s", pf.textp.text.c_str());
                    buf_init = true;
                }
                if (ImGui::InputTextMultiline("##text", buf, sizeof(buf),
                                              ImVec2(-1, 46))) {
                    pf.textp.text = buf;
                }
                ImGui::TextDisabled("newlines split lines");

                ui::SliderFloat("size", &pf.textp.size, 0.02f, 0.6f);
                ui::SliderFloat("x", &pf.textp.cx, -2.f, 2.f);
                ui::SliderFloat("y", &pf.textp.cy, -1.f, 1.f);
                ui::SliderFloat("inversion", &pf.textp.strength, 0.f, 1.f);
                ui::SliderFloat("text refraction", &pf.textp.warp, 0.f, 2.f);
                // Antialiasing, not a glow -- the field only carries distance
                // out to its spread, and the shader clamps the ramp there.
                ui::SliderFloat("edge softness", &pf.textp.softness, 0.2f, 3.f);
                ui::SliderFloat("stroke weight", &pf.textp.dilate, -0.02f, 0.02f,
                                "%.4f");

                ImGui::Separator();
                // The one to bind to a fader: it is the whole emerge/dissolve
                // timeline, and the three under it only shape what it looks
                // like on the way through.
                ui::SliderFloat("reveal", &pf.textp.reveal, 0.f, 1.f);
                ui::SliderFloat("turbulence", &pf.textp.turbulence, 0.f, 1.f);
                ui::SliderFloat("turb scale", &pf.textp.turb_scale, 0.5f, 30.f);
                ui::SliderFloat("turb drift", &pf.textp.turb_speed, 0.f, 2.f);
                ImGui::Separator();
                // These rebuild the field rather than moving a uniform, which is
                // why they sit apart from the live knobs above: dragging one
                // re-rasterises the glyphs and re-runs the distance transform.
                ui::SliderFloat("tracking", &pf.textp.tracking, -0.1f, 0.5f);
                static char fontbuf[128] = {};
                static bool font_init = false;
                if (!font_init) {
                    std::snprintf(fontbuf, sizeof(fontbuf), "%s",
                                  pf.textp.font.c_str());
                    font_init = true;
                }
                if (ImGui::InputText("font", fontbuf, sizeof(fontbuf))) {
                    pf.textp.font = fontbuf;
                }
                ui::SliderInt("raster px", &pf.textp.raster_px, 64, 1024);
                ImGui::TextDisabled("field %dx%d", pf.text.fieldW(), pf.text.fieldH());
                if (pf.textp.on && pf.scene != (int)Scene::Mirror && pf.textp.warp > 0.f) {
                    ImGui::TextDisabled("(no ripples in this scene: unwarped)");
                }
            }
            ui::EndHeader();
            ui::PopSection();               // "text"
            DrawBankSaveUI(ui::Bank::Look);

            ui::EndTab();

            ui::BeginTab("mirror", g_panel_test && g_panel_test_tab == panel_test_tab_i++);
            {
                ui::PushSection("mirror");
                mirror::PondParams& P = pf.mirror.params();
                // ripples
                ui::SliderFloat("ring freq", &P.ring_freq, 0.3f, 10.0f);
                ui::SliderFloat("ripple decay", &P.decay, 0.0f, 5.0f);
                ui::SliderFloat("ripple speed", &P.speed, 0.0f, 6.0f);
                ui::SliderFloat("ripple phase", &P.ripple_offset, 0.0f, 2.0f * (float)M_PI);
                ui::SliderFloat("refraction (warp)", &P.warp, 0.0f, 1.0f);
                ui::Checkbox("raindrops", &P.drops_on);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Only takes hold in Idle -- main.mm drives this every\n"
                        "frame while the show runs (on in Idle, off everywhere\n"
                        "else, Fitting especially: the ripple field is signal\n"
                        "the network's target does not contain). This checkbox\n"
                        "is only the last word when the show isn't running.\n\n"
                        "Every drop is a hit: a pluck-bed marker from Wwise\n"
                        "(below), or the 'drop one' button. Nothing falls on\n"
                        "its own.");
                }
                ui::BeginGroup("rain", true, P.drops_on);
                {
                    mirror::DropSpawnParams& S = P.spawn;
                    if (ui::Visible()) {
                        ImGui::Text("%d in flight, %d spawned",
                                    (int)pf.mirror.pond().spawner().drops().size(),
                                    pf.mirror.pond().spawner().spawnCount());
                        if (ImGui::Button("drop one")) pf.mirror.pond().triggerDrop();
                        ImGui::SameLine();
                        ImGui::TextDisabled("(a hit, same as a marker)");
                    }

                    ui::SliderFloat("size", &S.width, 0.02f, 0.6f);
                    ui::SliderFloat("size jitter", &S.width_jitter, 0.0f, 1.0f);
                    ui::SliderFloat("strength", &S.amp, 0.0f, 2.0f);
                    ui::SliderFloat("strength jitter", &S.amp_jitter, 0.0f, 1.0f);
                    ui::SliderFloat("reject below (strength)", &S.reject_below_amp,
                                     0.0f, 2.0f);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "A candidate drop -- rain or triggered, after\n"
                            "jitter and any hit scaling -- quieter than this\n"
                            "never spawns at all. 0 rejects nothing.");
                    }
                    ui::SliderFloat("weak decay boost", &S.weak_decay_gain, 0.0f, 4.0f);
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "How much faster a drop's rings fade with radius\n"
                            "the quieter it is, relative to \"strength\" above.\n"
                            "0 = every drop decays the same; higher makes weak\n"
                            "drops die out sooner than strong ones.");
                    }
                    ui::SliderFloat("spread jitter", &S.speed_jitter, 0.0f, 1.0f);
                    ui::SliderFloat("area x", &S.area_x, 0.0f, 1.2f);
                    ui::SliderFloat("area y", &S.area_y, 0.0f, 1.2f);
                    ui::SliderFloat("area centre x", &S.bias_x, -1.5f, 1.5f);
                    ui::SliderFloat("area centre y", &S.bias_y, -1.0f, 1.0f);
                    ui::SliderInt("max in flight", &S.max_active, 1, 24);
                }
                ui::EndGroup();

                // Section name kept from when the OnsetTap bus tap fed it too:
                // it is the preset key for the three sliders, and only marker
                // hits arrive here now.
                ui::BeginGroup("rain from audio", true, P.drops_on);
                {
                    // How much of the drop the hit gets to decide. At 0 across
                    // the board the audio only chooses *when*, which is a real
                    // setting: a steady shower on the beat.
                    ui::SliderFloat("hit -> strength", &P.spawn.hit_amp, 0.0f, 1.0f);
                    ui::SliderFloat("hit -> size", &P.spawn.hit_width, 0.0f, 1.0f);
                    ui::SliderFloat("hit -> position", &P.spawn.hit_pan, 0.0f, 1.0f);
                }
                ui::EndGroup();

                ui::BeginGroup("pluck onsets (idle/fitting)", true, P.drops_on);
                {
                    // Threshold is tuned offline, in tools/embed_pluck_markers.py
                    // against the FirePlucker source -- these markers are baked
                    // into Racine.bnk, not live-adjustable from here. This is
                    // just whether the mirror reacts to them right now.
                    //
                    // Not behind `if (ui::Visible())`: these two were, which
                    // meant the preset's "spawn drops = 1" only ever reached
                    // g_pluck_drops on a frame this group was actually drawn
                    // -- the mirror tab open, in Idle. Until then the code
                    // default (off) stood and no drop ever landed, and opening
                    // the tab "fixed" it. See PANEL.md: declaring is not
                    // drawing.
                    ui::Checkbox("pluck onsets spawn drops", &g_pluck_drops);
                    ui::SliderFloat("pluck onset gain", &g_pluck_drop_gain, 0.1f, 4.0f);
                }
                ui::EndGroup();

                ui::Checkbox("moving ripple", &P.orbit_on);
                ui::Checkbox("soft centers (anti-alias)", &P.core_rolloff);
                ui::BeginGate(P.core_rolloff);
                {
                    ImGui::SameLine(); ImGui::SetNextItemWidth(120);
                    ui::SliderFloat("radius", &P.core_radius, 0.02f, 0.5f);
                }
                ui::EndGate();
                ImGui::Separator();
                // --- the network itself -----------------------------------
                ui::PushSection("network");
                ui::BeginHeader("network", /*default_open=*/false);
                {
                ui::SliderInt("sine layers (0 = tanh only)", &P.sine_layers,
                                 0, 5);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "SIREN sine activations on the leading hidden layers,\n"
                        "tanh behind them. One layer is enough: measured on a\n"
                        "face fit, 1 sine layer scores 0.00250 against 0.00273\n"
                        "for all-sine and 0.00562 for all-tanh.\n\n"
                        "Changing this rebuilds the weights (sine layers are\n"
                        "SIREN-initialised) and recompiles the kernel.");
                }
                ImGui::BeginDisabled(P.sine_layers == 0);
                ui::SliderFloat("sine w0 (composition)", &P.sine_w0, 1.0f, 60.0f,
                                   "%.1f", ImGuiSliderFlags_Logarithmic);
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "How many regions the field breaks into. Low (2-10)\n"
                        "gives large open areas with detail only at the\n"
                        "boundaries; past ~40 the frame is uniform texture with\n"
                        "no background left.\n\n"
                        "Pairs with 'detail' below, which sets how hard those\n"
                        "boundaries are without changing the layout.");
                }

                ImGui::EndDisabled();
                ImGui::Separator();
                // weight shaping
                ui::SliderFloat("detail (w hidden)", &P.detail, 0.5f, 10.0f);
                ui::SliderFloat("gain tilt (front<->back)", &P.gain_tilt, -3.0f, 3.0f);
                ui::SliderFloat("w shape (gauss<->uniform)", &P.uniform_mix, 0.0f, 1.0f);
                ui::SliderFloat("contrast (w out)", &P.contrast, 1.0f, 12.0f);
                if (ImGui::Button("reseed network")) pf.mirror.reseed();
                }
                ui::EndHeader();
                ui::PopSection();

                // --- colour & tone ----------------------------------------
                ui::PushSection("colour");
                ui::BeginHeader("colour & tone", /*default_open=*/false);
                {
                ui::Checkbox("sRGB fix", &P.srgb_fix); ImGui::SameLine();
                if (ImGui::Button("reset color")) { P.srgb_fix = false; P.gamma = 1.0f; }
                ui::SliderFloat("gamma (>1 darkens)", &P.gamma, 0.3f, 2.0f);
                ui::SliderFloat("color mix (0 grey -> 1 RGB)", &P.color_mix, 0.0f, 1.0f);
                if (ui::Visible() && g_colour_fit_on && g_colour_idle >= 0.f) {
                    ImGui::TextDisabled(
                        "(the fit is driving this -- fit tab, 'colour follows "
                        "the fit')");
                }
                ImGui::SameLine(); ImGui::SetNextItemWidth(90);
                const char* greyItems[] = {"R", "G", "B"};
                ImGui::Combo("grey ch", &P.grey_channel, greyItems, 3);
                ui::DeclareInt("grey ch", &P.grey_channel, 0, 2);
                ui::Checkbox("ripple amp -> color", &P.amp_drives_color);
                ui::BeginGate(P.amp_drives_color);
                {
                    ImGui::SameLine(); ImGui::SetNextItemWidth(120);
                    ui::SliderFloat("amp gain", &P.amp_gain, 0.2f, 6.0f);
                }
                ui::EndGate();
                ui::Checkbox("swap R/B", &P.swap_rb);
                ui::Checkbox("color travel (palette follows orbit)", &P.color_travel);
                }
                ui::EndHeader();
                ui::PopSection();

                // --- the z latent -----------------------------------------
                ui::PushSection("z");
                ui::BeginHeader("z latent", /*default_open=*/false);
                {
                // z latent
                ImGui::Text("z phase = %6.2f  (circular morph)", P.z);
                ImGui::DragFloat("z", &P.z, 0.02f);
                ui::SliderFloat("z amplitude", &P.z_amp, 0.0f, 3.0f);
                // Range narrowed from -2..2: at that scale nearly the whole
                // slider was unusable (the pond tears apart well under 1/s),
                // so a range of 0..0.2 is plenty and gives four times the
                // precision across the values anyone actually dials in. This
                // does not clamp values a preset already holds outside the
                // new range -- ImGui sliders never clamp unless AlwaysClamp
                // is set -- it only narrows the widget's drag span.
                ui::SliderFloat("z auto-rate /s", &P.z_rate, 0.0f, 0.2f, "%.4f");
                ui::SliderFloat("z step size", &P.z_step, 0.01f, 1.0f);
                if (ImGui::Button("z - step")) P.z -= P.z_step; ImGui::SameLine();
                if (ImGui::Button("z + step")) P.z += P.z_step; ImGui::SameLine();
                if (ImGui::Button("z = 0")) P.z = 0.0f;
                ui::SliderFloat("drops add z speed /s", &P.z_drop_boost, 0.0f, 0.5f,
                                "%.4f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Each landed drop (an onset, a MIDI hit, the 'drop\n"
                        "one' button -- not the passive rain scheduler) bumps\n"
                        "a decaying envelope by this much times the drop's\n"
                        "strength (0..1; an unspecified strength counts as a\n"
                        "full hit). The envelope adds on top of the z\n"
                        "auto-rate above while it is live, so a run of drops\n"
                        "briefly speeds up the latent travel. Only active\n"
                        "while raindrops are on.");
                }
                ui::SliderFloat("movement adds z speed /s", &P.z_move_boost, 0.0f, 0.2f,
                                "%.4f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Added to the z auto-rate, times the visitor's\n"
                        "movement (the presence signal, 0..1) -- so the\n"
                        "latent travels a little faster while someone is\n"
                        "moving about.");
                }
                ui::SliderFloat("drop boost decay s", &P.z_drop_boost_tau, 0.05f,
                                5.0f, "%.3f");
                if (ImGui::IsItemHovered()) {
                    ImGui::SetTooltip(
                        "Time constant the drop-boost envelope decays back\n"
                        "toward zero with after a drop lands. The envelope's\n"
                        "attack -- how fast it rises to a bump -- eases in\n"
                        "over a quarter of this, so a hit ramps the z speed\n"
                        "up rather than stepping it.");
                }
                }
                ui::EndHeader();
                ui::PopSection();

                // --- clock & render ---------------------------------------
                ui::PushSection("render");
                ui::BeginHeader("clock & render", /*default_open=*/false);
                {
                // time
                ui::SliderFloat("ripple time scale", &P.time_scale, 0.0f, 4.0f);
                ui::Checkbox("pause", &P.paused);
                ui::SliderInt("downscale", &pf.downscale, 1, 10);
                ImGui::Text("render %d x %d -> %d x %d", pf.mirror.lowW(), pf.mirror.lowH(), pf.fbw, pf.fbh);
                }
                ui::EndHeader();
                ui::PopSection();
                // mask emergence transition
                ui::PushSection("mask emergence (transition)");
                ui::BeginHeader("mask emergence (transition)", /*default_open=*/false);
                {
                    ui::SliderFloat("transition (0 pond -> 1 mask)", &P.transition, 0.0f, 1.0f);
                    ui::Checkbox("auto-play", &P.trans_auto); ImGui::SameLine();
                    if (ImGui::Button("reset t")) { P.transition = 0.0f; P.trans_auto = false; }
                    ui::SliderFloat("play rate /s", &P.trans_rate, 0.05f, 1.0f);
                    ui::SliderFloat("relief height", &P.relief_h, 0.0f, 1.5f);
                    ui::SliderFloat("mask width", &P.mask_ax, 0.2f, 1.0f);
                    ui::SliderFloat("mask height", &P.mask_ay, 0.2f, 1.2f);
                    ui::SliderFloat("light azimuth", &P.light_az, -(float)M_PI, (float)M_PI);
                    ui::SliderFloat("light elevation", &P.light_elev, 0.1f, (float)M_PI / 2.0f);
                    ui::SliderFloat("wet sheen (spec)", &P.spec_amt, 0.0f, 1.5f);
                    ui::SliderFloat("sheen tightness", &P.shininess, 4.0f, 96.0f);
                    ui::SliderFloat("background dim", &P.bg_dim, 0.0f, 1.0f);
                }
                ui::EndHeader();
                ui::PopSection();
                ui::PopSection();          // "mirror"
                DrawBankSaveUI(ui::Bank::Mirror);
            }
            ui::EndTab();

            ui::BeginTab("roots", g_panel_test && g_panel_test_tab == panel_test_tab_i++);
            {
                DrawRootsTab(pf.roots, pf.fieldGrid, pf.rootSeed, pf.fbw, pf.fbh);
                DrawBankSaveUI(ui::Bank::Roots);
            }
            ui::EndTab();

            ui::BeginTab("midi", g_panel_test && g_panel_test_tab == panel_test_tab_i++);
            // --- midi ------------------------------------------------------
            //
            // Near the end on purpose. It is the page that is set up once and
            // then left alone, and putting it first would push the controls it
            // binds one tab further away every session.
            {
                ImGui::Text("MIDI");
                ImGui::SameLine();
                if (g_midi.isOpen()) {
                    ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "%s",
                                       g_midi.deviceInfo().c_str());
                } else {
                    ImGui::TextDisabled("closed");
                }
                ImGui::SameLine();
                ImGui::TextDisabled("| %llu msgs",
                                    (unsigned long long)g_midi.received());

                if (ImGui::Button(g_midi.isOpen() ? "close MIDI" : "open MIDI")) {
                    if (g_midi.isOpen()) {
                        g_midi.close();
                    } else {
                        std::string merr;
                        if (!g_midi.open(merr)) g_midi_err = merr;
                        else g_midi_err.clear();
                    }
                }
                ImGui::SameLine();
                if (ImGui::Button("rescan devices")) g_midi.rescan();
                ImGui::SameLine();
                ImGui::TextDisabled("%d bound", ui::BindingCount());
                if (!g_midi_err.empty())
                    ImGui::TextColored(ImVec4(1.f, 0.5f, 0.5f, 1.f), "%s",
                                       g_midi_err.c_str());

                if (!ui::LearnTarget().empty()) {
                    ImGui::TextColored(ImVec4(1.f, 0.85f, 0.4f, 1.f),
                                       "learning: %s -- move a control",
                                       ui::LearnTarget().c_str());
                    ImGui::SameLine();
                    if (ImGui::SmallButton("cancel")) ui::SetLearnTarget("");
                } else {
                    ImGui::TextDisabled("right-click any slider to bind it");
                }

                // The last few messages, so a controller that is sending
                // something other than what you expect can be seen doing it --
                // "nothing is bound" and "nothing is arriving" look identical
                // otherwise.
                if (ImGui::TreeNode("incoming")) {
                    const auto& r = ui::RecentMessages();
                    if (r.empty()) ImGui::TextDisabled("(nothing yet)");
                    for (const auto& m : r)
                        ImGui::TextDisabled("ch %2d  cc %3d  %3d", m.channel + 1,
                                            m.cc, m.value);
                    ImGui::TreePop();
                }
                if (ImGui::TreeNode("bindings")) {
                    struct Row { std::string path; int ch, cc; };
                    static std::vector<Row> rows;
                    rows.clear();
                    ui::ForEachBinding(&rows, [](void* u, const char* p, int ch, int cc) {
                        static_cast<std::vector<Row>*>(u)->push_back({p, ch, cc});
                    });
                    if (rows.empty()) ImGui::TextDisabled("(none)");
                    for (const Row& r : rows) {
                        ImGui::PushID(r.path.c_str());
                        if (ImGui::SmallButton("x")) ui::ClearBinding(r.path);
                        ImGui::SameLine();
                        ImGui::TextDisabled("ch%d cc%-3d  %s", r.ch + 1, r.cc,
                                            r.path.c_str());
                        ImGui::PopID();
                    }
                    if (!rows.empty() && ImGui::SmallButton("clear all"))
                        ui::ClearAllBindings();
                    ImGui::TreePop();
                }

            }
            ui::EndTab();

            // --- save --------------------------------------------------------
            //
            // Its own tab, not a footer under the MIDI setup. Saving is the one
            // thing here done *during* a session rather than once before it, and
            // having to scroll past the device list to reach it every time was
            // the reason presets went unsaved.
            ui::BeginTab("settings", g_panel_test && g_panel_test_tab == panel_test_tab_i++);
            {
                // Per-bank save/load lives on the tab that edits that bank --
                // DrawBankSaveUI(...) at the bottom of show/machine/fit/debug/
                // look/mirror/roots. What is left here is cross-cutting: it does
                // not belong to any one bank.
                ImGui::Text("%d params declared", ui::DeclaredCount());

                static bool show_retired = ui::ShowRetired();
                if (ImGui::Checkbox("show retired controls", &show_retired))
                    ui::SetShowRetired(show_retired);
                if (ImGui::IsItemHovered())
                    ImGui::SetTooltip(
                        "Retired controls are still loaded and still saved --\n"
                        "they are only hidden. Nothing in a preset breaks.");
                // --- what nobody has classified ---------------------------
                // Loud on purpose. A parameter in no bank is saved by nothing
                // that anyone loads, which looks exactly like a control that
                // does not work.
                ImGui::Separator();
                const auto& unassigned = ui::UnassignedParams();
                if (!unassigned.empty()) {
                    ImGui::TextColored(ImVec4(1.f, 0.5f, 0.5f, 1.f),
                                       "%zu parameter(s) in no bank",
                                       unassigned.size());
                    if (ImGui::IsItemHovered()) {
                        std::string t = "Add a rule to kBankRules in ui_params.cpp:\n\n";
                        for (size_t i = 0; i < unassigned.size() && i < 30; ++i)
                            t += unassigned[i] + "\n";
                        ImGui::SetTooltip("%s", t.c_str());
                    }
                }
                if (!ui::UnclaimedKeys().empty()) {
                    ImGui::TextColored(ImVec4(1.f, 0.85f, 0.4f, 1.f),
                                       "%zu key(s) no control claimed",
                                       ui::UnclaimedKeys().size());
                    if (ImGui::IsItemHovered()) {
                        std::string t;
                        for (const std::string& k : ui::UnclaimedKeys()) t += k + "\n";
                        ImGui::SetTooltip("%s", t.c_str());
                    }
                }

                // The master document, written from the registry that is live
                // in this frame. Since declaring no longer depends on what is
                // open, one frame is the whole app -- which is what makes a
                // generated document worth having over a written one.
                static std::string doc_msg;
                if (ImGui::Button("write SETTINGS.md")) {
                    const std::string p =
                        std::string(MIRROR_APP_SRC_DIR) + "/../SETTINGS.md";
                    std::string e;
                    doc_msg = ui::WriteSettingsDoc(p, e) ? ("wrote " + p) : e;
                }
                if (!doc_msg.empty()) ImGui::TextDisabled("%s", doc_msg.c_str());

                // The whole registry in one file, banks and all. Kept for the
                // round-trip test and for taking a complete snapshot of a
                // machine mid-session; not the thing to load on a show night.
                if (ImGui::TreeNode("whole-registry dump")) {
                    static std::vector<std::string> sets = ui::ListPresets();
                    static char set_name[128] = "default";
                    static std::string set_msg;
                    ImGui::PushItemWidth(-90);
                    if (ImGui::BeginCombo("load##set", "choose...")) {
                        for (const std::string& nm : sets) {
                            if (!ImGui::Selectable(nm.c_str())) continue;
                            std::string e;
                            if (ui::LoadPreset(ui::PresetDir() + "/" + nm + ".set", e)) {
                                snprintf(set_name, sizeof(set_name), "%s", nm.c_str());
                                set_msg = "loaded " + nm;
                            } else {
                                set_msg = e;
                            }
                        }
                        ImGui::EndCombo();
                    }
                    ImGui::InputText("name##set", set_name, sizeof(set_name));
                    ImGui::PopItemWidth();
                    if (ImGui::Button("save##set")) {
                        std::string e;
                        set_msg = ui::SavePreset(ui::PresetDir() + "/" + set_name + ".set", e)
                                      ? ("saved " + std::string(set_name)) : e;
                        sets = ui::ListPresets();
                    }
                    ImGui::SameLine();
                    if (ImGui::Button("rescan##set")) sets = ui::ListPresets();
                    if (!set_msg.empty()) ImGui::TextDisabled("%s", set_msg.c_str());
                    ImGui::TreePop();
                }
            }
            ui::EndTab();
            ui::EndTabBar();

            // How tall the panel's content came out, which is the one number
            // that catches a hidden section drawing anyway.
            //
            // Declaring without drawing is not something the parameter counts
            // can check: a section that is declared *and* drawn while it should
            // be hidden looks perfectly healthy to them, and looks like six tab
            // pages of loose widgets stacked on top of each other on screen.
            // With the tabs working this is one page; with the raw ImGui calls
            // in the hidden bodies escaping, it was fourteen times that.
            g_panel_content_h = ImGui::GetCurrentWindow()->DC.CursorMaxPos.y -
                                ImGui::GetCurrentWindow()->Pos.y;
            ImGui::End();
            if (panel_hidden) ImGui::PopStyleVar();
}

void DrawOverlayWindows(PanelFrameArgs& pf) {
            // --- camera mask: the rectangle, on the frame ------------------
            //
            // Drawn over the scene rather than in the control panel: the mask
            // is a piece of set dressing aimed at a real room, and placing it
            // by numbers in a list means looking away from the thing being
            // aimed at.
            // --- camera debug: is it working, and where is the crop -------
            //
            // Two questions that are usually asked together and are usually
            // both answered "I think so" from the composition alone, which
            // cannot distinguish a closed sensor from a stale frame from a
            // tracker that is running but pointed at nothing. So this draws the
            // numbers rather than an impression: frame size, how long since the
            // last one, whether a face is believed and how long it has been
            // held -- over the raw frame, with the boxes on top.
            if (g_ui_visible && pf.scene == (int)Scene::Camera) {
                const ImGuiViewport* vp = ImGui::GetMainViewport();
                ImGui::SetNextWindowPos(vp->WorkPos);
                ImGui::SetNextWindowSize(vp->WorkSize);
                ImGui::Begin("##camera_debug", nullptr,
                             ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_NoBringToFrontOnFocus |
                             ImGuiWindowFlags_NoBackground |
                             ImGuiWindowFlags_NoFocusOnAppearing |
                             ImGuiWindowFlags_NoInputs);
                ImDrawList* dl = ImGui::GetWindowDrawList();
                const ImVec2 o = vp->WorkPos, sz = vp->WorkSize;
                auto box = [&](float cx, float cy, float hx, float hy,
                               ImU32 col, float th) {
                    dl->AddRect(ImVec2(o.x + (cx - hx) * sz.x, o.y + (cy - hy) * sz.y),
                                ImVec2(o.x + (cx + hx) * sz.x, o.y + (cy + hy) * sz.y),
                                col, 0.f, 0, th);
                };

                // The raw detection, thin and grey, and the smoothed padded box
                // the fit is actually handed, bright. Both, because the gap
                // between them *is* what "pad" and "head smoothing" do -- with
                // only one drawn those two sliders are guesswork.
                if (g_face.valid) {
                    box(g_face.centre_x, g_face.centre_y,
                        0.5f * (g_face.max_x - g_face.min_x),
                        0.5f * (g_face.max_y - g_face.min_y),
                        IM_COL32(170, 170, 170, 170), 1.5f);
                }
                if (g_head_valid) {
                    const ImU32 c = g_face_held ? IM_COL32(255, 210, 100, 235)
                                                : IM_COL32(120, 235, 150, 235);
                    box(g_head_cx, g_head_cy, g_head_hx, g_head_hy, c, 2.5f);
                    dl->AddLine(ImVec2(o.x + g_head_cx * sz.x, o.y),
                                ImVec2(o.x + g_head_cx * sz.x, o.y + sz.y),
                                IM_COL32(255, 255, 255, 40), 1.f);
                    dl->AddLine(ImVec2(o.x, o.y + g_head_cy * sz.y),
                                ImVec2(o.x + sz.x, o.y + g_head_cy * sz.y),
                                IM_COL32(255, 255, 255, 40), 1.f);
                }
                // Where the camera mask will cut, if it is on: the crop has to
                // be set inside it or the fit is handed pixels that the rest of
                // the app has already blacked out.
                if (g_cam_mask_on) {
                    dl->AddRect(ImVec2(o.x + g_cam_x0 * sz.x, o.y + g_cam_y0 * sz.y),
                                ImVec2(o.x + g_cam_x1 * sz.x, o.y + g_cam_y1 * sz.y),
                                IM_COL32(255, 120, 120, 150), 0.f, 0, 1.5f);
                }

                char l1[192], l2[192];
                snprintf(l1, sizeof(l1), "camera  %s   %dx%d",
                         SourceReady() ? "ready" : "NO FRAMES", pf.pipW, pf.pipH);
                if (!g_track_on)
                    snprintf(l2, sizeof(l2), "tracking off");
                else if (g_face_held)
                    snprintf(l2, sizeof(l2), "face held %.2fs of %.2f",
                             pf.nowT - g_face_last_seen, g_face_hold_secs);
                else if (g_face.valid)
                    snprintf(l2, sizeof(l2), "face  streak %d   crop %s",
                             g_face_streak, HaveCrop() ? "live" : "off");
                else
                    snprintf(l2, sizeof(l2), "no face  (streak %d of %d)",
                             g_face_streak, g_face_acquire);
                const ImVec2 at(o.x + 14.f, o.y + 14.f);
                dl->AddRectFilled(ImVec2(at.x - 6, at.y - 4),
                                  ImVec2(at.x + 330, at.y + 40),
                                  IM_COL32(0, 0, 0, 150), 4.f);
                dl->AddText(at, SourceReady() ? IM_COL32(200, 240, 210, 255)
                                              : IM_COL32(255, 130, 130, 255), l1);
                dl->AddText(ImVec2(at.x, at.y + 19), IM_COL32(220, 220, 220, 255), l2);
                ImGui::End();
            }

            if (g_ui_visible && pf.scene == (int)Scene::CamMask) {
                const ImGuiViewport* vp = ImGui::GetMainViewport();
                ImGui::SetNextWindowPos(vp->WorkPos);
                ImGui::SetNextWindowSize(vp->WorkSize);
                ImGui::Begin("##cammask_overlay", nullptr,
                             ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_NoBringToFrontOnFocus |
                             ImGuiWindowFlags_NoBackground |
                             ImGuiWindowFlags_NoFocusOnAppearing);
                ImDrawList* dl = ImGui::GetWindowDrawList();
                const ImVec2 o = vp->WorkPos, sz = vp->WorkSize;
                auto toScreen = [&](float u, float v) {
                    return ImVec2(o.x + u * sz.x, o.y + v * sz.y);
                };

                float* xs[2] = {&g_cam_x0, &g_cam_x1};
                float* ys[2] = {&g_cam_y0, &g_cam_y1};
                const ImU32 col = g_cam_mask_on ? IM_COL32(255, 210, 120, 230)
                                                : IM_COL32(150, 150, 150, 140);
                dl->AddRect(toScreen(*xs[0], *ys[0]), toScreen(*xs[1], *ys[1]), col,
                            0.f, 0, 2.f);

                // One handle per corner. Corners rather than edges because a
                // rectangle has four degrees of freedom and four handles is the
                // fewest that reach all of them without a mode.
                const float grab = 12.f;
                for (int i = 0; i < 4; ++i) {
                    float* px = xs[i & 1];
                    float* py = ys[i >> 1];
                    const ImVec2 c = toScreen(*px, *py);
                    ImGui::SetCursorScreenPos(ImVec2(c.x - grab, c.y - grab));
                    ImGui::PushID(i);
                    ImGui::InvisibleButton("h", ImVec2(grab * 2, grab * 2));
                    const bool hot = ImGui::IsItemHovered() || ImGui::IsItemActive();
                    if (ImGui::IsItemActive()) {
                        const ImVec2 d = ImGui::GetIO().MouseDelta;
                        *px = std::min(1.f, std::max(0.f, *px + d.x / sz.x));
                        *py = std::min(1.f, std::max(0.f, *py + d.y / sz.y));
                    }
                    dl->AddCircleFilled(c, hot ? 8.f : 5.f, col);
                    ImGui::PopID();
                }

                // Drag the body to move the whole rectangle.
                const ImVec2 a = toScreen(std::min(g_cam_x0, g_cam_x1),
                                          std::min(g_cam_y0, g_cam_y1));
                const ImVec2 b = toScreen(std::max(g_cam_x0, g_cam_x1),
                                          std::max(g_cam_y0, g_cam_y1));
                ImGui::SetCursorScreenPos(ImVec2(a.x + grab, a.y + grab));
                ImGui::InvisibleButton("##body",
                                       ImVec2(std::max(1.f, b.x - a.x - grab * 2),
                                              std::max(1.f, b.y - a.y - grab * 2)));
                if (ImGui::IsItemActive()) {
                    const ImVec2 d = ImGui::GetIO().MouseDelta;
                    const float du = d.x / sz.x, dv = d.y / sz.y;
                    g_cam_x0 += du; g_cam_x1 += du;
                    g_cam_y0 += dv; g_cam_y1 += dv;
                }
                ImGui::End();
            }

            // --- source overlay: the raw frame, in a corner ----------------
            //
            // Answers one question the mirror's own output cannot: is anything
            // actually arriving, and is it what the fit is being pointed at.
            if (g_ui_visible && g_show_source && pf.srcTex && pf.srcTexW > 0) {
                const ImGuiViewport* vp = ImGui::GetMainViewport();
                const float pad = 16.f;
                const bool right = (g_source_corner == 1 || g_source_corner == 3);
                const bool bottom = (g_source_corner == 2 || g_source_corner == 3);
                ImGui::SetNextWindowPos(
                    ImVec2(vp->WorkPos.x + (right ? vp->WorkSize.x - pad : pad),
                           vp->WorkPos.y + (bottom ? vp->WorkSize.y - pad : pad)),
                    ImGuiCond_Always,
                    ImVec2(right ? 1.f : 0.f, bottom ? 1.f : 0.f));
                ImGui::SetNextWindowBgAlpha(0.35f);
                ImGui::Begin("##source_pip", nullptr,
                             ImGuiWindowFlags_NoDecoration |
                             ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_AlwaysAutoResize |
                             ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_NoFocusOnAppearing |
                             ImGuiWindowFlags_NoNav);
                const float iw = (float)g_source_pip_w;
                const float ih = iw * (float)pf.srcTexH / (float)pf.srcTexW;
                const ImVec2 p0 = ImGui::GetCursorScreenPos();
                ImGui::Image((ImTextureID)(intptr_t)(__bridge void*)pf.srcTex,
                             ImVec2(iw, ih));
                // Landmarks on top, in the overlay's own coordinates: they are
                // normalised, so this is the same mapping the mask uses -- if
                // they sit off the face here, they sit off the face there.
                if (g_pip_landmarks && g_track_on && g_face.valid) {
                    ImDrawList* dl = ImGui::GetWindowDrawList();
                    for (const mirror::FaceLandmark& L : g_face.landmarks) {
                        dl->AddRectFilled(
                            ImVec2(p0.x + L.x * iw, p0.y + L.y * ih),
                            ImVec2(p0.x + L.x * iw + 1.5f, p0.y + L.y * ih + 1.5f),
                            IM_COL32(120, 255, 170, 200));
                    }
                    // The crop the fit is supervised on, drawn where its pixels
                    // are *taken from* -- so in the centred mode this stays on
                    // the head even though the fit places it in the middle.
                    // Drawn from the smoothed box the mask is built from, which
                    // makes the smoothing itself visible: if this lags the face
                    // badly, that is the setting to turn up.
                    if (g_mask_fit && g_head_valid &&
                        g_mask_shape == (int)MaskShape::Box) {
                        const float px = pf.fit_w > 0 ? float(g_mask_dilate) / pf.fit_w : 0.f;
                        const float py = pf.fit_h > 0 ? float(g_mask_dilate) / pf.fit_h : 0.f;
                        dl->AddRect(
                            ImVec2(p0.x + (g_head_cx - g_head_hx - px) * iw,
                                   p0.y + (g_head_cy - g_head_hy - py) * ih),
                            ImVec2(p0.x + (g_head_cx + g_head_hx + px) * iw,
                                   p0.y + (g_head_cy + g_head_hy + py) * ih),
                            IM_COL32(255, 210, 120, 220));
                    }
                }
                const bool live = g_fit_live && pf.mirror.pond().fitting() &&
                                  pf.scene == (int)Scene::Mirror;
                ImGui::TextDisabled("%s%s", g_source == (int)Source::Photo
                                                ? "photo" : "sensor",
                                    pf.srcFresh ? "" : "  (stale)");
                ImGui::SameLine();
#if MIRROR_HAVE_KINECT
                if (g_source == (int)Source::Kinect) {
                    ImGui::TextDisabled("| %llu frames",
                                        (unsigned long long)g_kinect.frames());
                    ImGui::SameLine();
                }
#endif
                if (live) {
                    ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "| fitting this");
                } else {
                    ImGui::TextDisabled("| not the fit target");
                }
                ImGui::End();
            }

            // --- the network's input, in a corner -------------------------
            //
            // Everything the fit is given, in one picture. What to look for
            // when a fit will not take: the subject the right way round, the
            // bright (trained) region actually on them, the grid fine enough
            // that a face is more than a smudge.
            if (g_ui_visible && g_show_netin && pf.netTex && pf.netTexW > 0) {
                const ImGuiViewport* vp = ImGui::GetMainViewport();
                const float pad = 16.f;
                const bool right = (g_netin_corner == 1 || g_netin_corner == 3);
                const bool bottom = (g_netin_corner == 2 || g_netin_corner == 3);
                ImGui::SetNextWindowPos(
                    ImVec2(vp->WorkPos.x + (right ? vp->WorkSize.x - pad : pad),
                           vp->WorkPos.y + (bottom ? vp->WorkSize.y - pad : pad)),
                    ImGuiCond_Always,
                    ImVec2(right ? 1.f : 0.f, bottom ? 1.f : 0.f));
                ImGui::SetNextWindowBgAlpha(0.35f);
                ImGui::Begin("##netin_pip", nullptr,
                             ImGuiWindowFlags_NoDecoration |
                             ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_AlwaysAutoResize |
                             ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_NoFocusOnAppearing |
                             ImGuiWindowFlags_NoNav);
                const float iw = (float)g_netin_pip_w;
                const float ih = iw * (float)pf.netTexH / (float)pf.netTexW;
                const ImVec2 p0 = ImGui::GetCursorScreenPos();
                ImGui::Image((ImTextureID)(intptr_t)(__bridge void*)pf.netTex,
                             ImVec2(iw, ih));
                ImDrawList* dl = ImGui::GetWindowDrawList();
                // The region the resample actually produced. With a crop up
                // this is the whole of what exists -- outside it the buffer is
                // last frame's, deliberately, because nothing reads it. Drawn
                // so that emptiness reads as intended rather than as a fault.
                if (g_have_mask && g_mask_bbox.w > 0) {
                    const float sx = iw / (float)pf.netTexW, sy = ih / (float)pf.netTexH;
                    dl->AddRect(ImVec2(p0.x + g_mask_bbox.x * sx,
                                       p0.y + g_mask_bbox.y * sy),
                                ImVec2(p0.x + (g_mask_bbox.x + g_mask_bbox.w) * sx,
                                       p0.y + (g_mask_bbox.y + g_mask_bbox.h) * sy),
                                IM_COL32(120, 200, 255, 200));
                }
                ImGui::TextDisabled("%dx%d", pf.netTexW, pf.netTexH);
                ImGui::SameLine();
                if (pf.mirror.pond().fitting()) {
                    ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f),
                                       "| %d px | loss %.5f",
                                       pf.mirror.pond().fitPixels(), pf.mirror.lastLoss());
                } else {
                    ImGui::TextDisabled("| not training");
                }
                if (!pf.netFresh) {
                    ImGui::SameLine();
                    ImGui::TextDisabled("(held)");
                }
                ImGui::End();
            }

            // --- the running order, as text -------------------------------
            //
            // Drawn whether or not the panel is up: this is for watching the
            // piece run, and the moment it is most needed is the one where a
            // phase is not advancing and there is nothing on screen saying what
            // it is waiting for.
            if (g_show_hud) {
                const ImGuiViewport* vp = ImGui::GetMainViewport();
                ImGui::SetNextWindowPos(ImVec2(vp->WorkPos.x + 16.f,
                                               vp->WorkPos.y + vp->WorkSize.y - 16.f),
                                        ImGuiCond_Always, ImVec2(0.f, 1.f));
                ImGui::SetNextWindowBgAlpha(0.55f);
                ImGui::Begin("##showhud", nullptr,
                             ImGuiWindowFlags_NoDecoration |
                             ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_AlwaysAutoResize |
                             ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_NoFocusOnAppearing |
                             ImGuiWindowFlags_NoNav |
                             ImGuiWindowFlags_NoInputs);

                const show::Phase ph = g_show.phase();
                const show::PhaseGraph& g = show::Graph(ph);
                const float ps_max = g_show.maxTime(ph);
                const float ps_min = g_show.minTime(ph);

                ImGui::TextColored(ImVec4(0.7f, 0.9f, 1.f, 1.f), "%s",
                                   show::PhaseName(ph));
                ImGui::SameLine();
                ImGui::Text("%.1fs", g_show.phaseTime());
                if (ps_max > 0.f) {
                    ImGui::SameLine();
                    ImGui::TextDisabled("/ %.0fs", ps_max);
                }
                ImGui::SameLine();
                if (!g_show_on)          ImGui::TextDisabled("| held (show off)");
                else if (g_show_paused)  ImGui::TextDisabled("| paused");
                else if (g_show.phaseTime() < ps_min)
                    ImGui::TextDisabled("| floor %.1fs", ps_min - g_show.phaseTime());
                else ImGui::TextDisabled("| open");
                if (g_view_override >= 0) {
                    ImGui::SameLine();
                    ImGui::TextColored(ImVec4(1.f, 0.85f, 0.4f, 1.f), "| view override");
                }
                ImGui::TextDisabled("via %s", g_show.lastReason().c_str());

                // What it is waiting for, in the graph's own priority order --
                // the first of these to come true is the one that moves it.
                ImGui::Separator();
                for (int i = 0; i < g.edge_count; ++i) {
                    const show::Edge& e = g.edges[i];
                    ImGui::TextDisabled("%s -> %s", show::EventName(e.event),
                                        show::PhaseName(e.target));
                }

                ImGui::Separator();
                const bool face = ShowFacePresent();
                const bool fit_conv = ShowFitConverged();
                ImGui::Text("face"); ImGui::SameLine();
                if (face) ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "yes");
                else      ImGui::TextDisabled("no");
                ImGui::SameLine(); ImGui::Text("| converged"); ImGui::SameLine();
                if (fit_conv) ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "yes");
                else          ImGui::TextDisabled("no");

                // The identity residual is what "converged" is actually
                // measuring, so it is shown against the threshold rather than
                // on its own -- a number with no scale beside it is not a
                // diagnosis.
                if (g_id_residual >= 0.f) {
                    ImGui::TextDisabled("identity %.2f px (needs <= %.2f)%s  %d solve%s",
                                        g_id_residual, g_show_fit_px,
                                        g_collect_id ? "  re-solving" : "",
                                        g_id_solves, g_id_solves == 1 ? "" : "s");
                } else if (g_collect_id) {
                    ImGui::TextDisabled("identity collecting %.1fs",
                                        g_id_collect_secs - (pf.nowT - g_id_started));
                } else {
                    ImGui::TextDisabled("identity not fitted");
                }

                ImGui::Text("fit"); ImGui::SameLine();
                if (pf.mirror.pond().fitting()) {
                    ImGui::TextColored(ImVec4(0.6f, 1.f, 0.7f, 1.f), "training");
                } else if (pf.mirror.pond().fitted()) {
                    ImGui::TextColored(ImVec4(1.f, 0.85f, 0.4f, 1.f), "held");
                } else {
                    ImGui::TextDisabled("none");
                }
                ImGui::SameLine();
                ImGui::TextDisabled("| %d steps | loss %.5f | %d px",
                                    pf.mirror.pond().fitSteps(), pf.mirror.lastLoss(),
                                    pf.mirror.pond().fitPixels());
                {
                    const FitTune& t = g_have_mask ? g_tune_crop : g_tune_full;
                    ImGui::TextDisabled("grid %dx%d %s | %d step-s | lr %.4f",
                                        pf.fit_w, pf.fit_h,
                                        g_have_mask ? "cropped" : "whole feed",
                                        t.steps, t.lr);
                }
                if (!g_fit_live) {
                    ImGui::TextColored(ImVec4(1.f, 0.6f, 0.5f, 1.f),
                                       "live feed not armed");
                }
                // The tuned, interpretable readout: fit_level against the
                // threshold ShowFitConverged() actually gates on (loss above
                // is the raw number these two dials are tuned against, not
                // what the show waits for), and the chord's own checkpoint --
                // together, "how close is it, and what does that sound like
                // right now".
                {
                    const ImVec4 col = g_fit_level_now >= g_show_fit_score
                        ? ImVec4(0.6f, 1.f, 0.7f, 1.f) : ImVec4(1.f, 1.f, 1.f, 1.f);
                    ImGui::TextColored(col, "fit_level %.2f / %.2f to convert",
                                       g_fit_level_now, g_show_fit_score);
                    ImGui::SameLine();
                    ImGui::TextDisabled("| chord stage %d/%d",
                                        g_chord.stage(), mirror::Chord::kStages - 1);
                }
                // --- rates ------------------------------------------
                //
                // Sampled over a second rather than shown per frame: the thing
                // being diagnosed is a rate going to zero, and a per-frame
                // reading of a 30 Hz source under a 60 fps loop alternates
                // between two values and reads as broken when it is fine.
                {
                    static double rate_t0 = 0.0;
                    static unsigned long long sensor_prev = 0;
                    static unsigned swaps_prev = 0, steps_prev = 0;
                    static float sensor_hz = 0.f, swap_hz = 0.f, step_hz = 0.f;
                    const unsigned steps_now = (unsigned)pf.mirror.pond().fitSteps();
#if MIRROR_HAVE_KINECT
                    const unsigned long long sensor_now = g_kinect.frames();
#else
                    const unsigned long long sensor_now = 0;
#endif
                    if (rate_t0 == 0.0) rate_t0 = pf.nowT;
                    const double dtr = pf.nowT - rate_t0;
                    if (dtr >= 1.0) {
                        sensor_hz = float((sensor_now - sensor_prev) / dtr);
                        swap_hz   = float((g_target_swaps - swaps_prev) / dtr);
                        step_hz   = float((steps_now - steps_prev) / dtr);
                        sensor_prev = sensor_now;
                        swaps_prev = g_target_swaps;
                        steps_prev = steps_now;
                        rate_t0 = pf.nowT;
                    }
                    // Each stage feeds the next, so the first zero along the
                    // chain is the one that matters.
                    ImGui::TextDisabled("sensor %.0f/s -> target %.0f/s -> steps %.0f/s",
                                        sensor_hz, swap_hz, step_hz);
                    if (pf.mirror.pond().fitting() && sensor_hz > 0.f && swap_hz == 0.f) {
                        ImGui::TextColored(ImVec4(1.f, 0.6f, 0.5f, 1.f),
                                           "frames arriving, target not swapping");
                    }
                }
                if (g_vp_skips || g_vp_relayers) {
                    ImGui::TextDisabled("panel: %u occluded, %u re-layered",
                                        g_vp_skips, g_vp_relayers);
                }
                ImGui::TextDisabled("%.0f fps", pf.fpsShown);
                if (!g_frame_profile.empty()) {
                    ImGui::TextDisabled("%s", g_frame_profile.c_str());
                    if (ImGui::IsItemHovered()) {
                        ImGui::SetTooltip(
                            "Where the frame goes, ms averaged over the last\n"
                            "half second. 'drawable' is time blocked waiting\n"
                            "for the display -- large when the GPU is the\n"
                            "limit. 'scene' is the active scene's step and\n"
                            "encode; 'gpu' the whole command buffer.\n"
                            "MIRROR_PROFILE=1 prints this every 2 s.");
                    }
                }
                ImGui::End();
            }
}
