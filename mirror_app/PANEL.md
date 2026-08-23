# Building the control panel

How the panel and the parameter registry fit together, and the rules that keep
them working. Read this before adding a control, a section or a tab.

The registry itself is `src/ui_params.h` / `.cpp`; the panel is built in
`src/panel.mm` (`DrawControlPanel`/`DrawOverlayWindows`), called once per frame
from `main.mm`'s loop. `SETTINGS.md` is **generated** from the live registry and lists
every parameter and its bank — do not edit it by hand.

---

## The one rule: declaring is not drawing

**Every control must declare itself every frame, whether or not it is on
screen.** The panel body always runs, top to bottom. Visibility — a folded
header, an unselected tab, a feature that is switched off — decides only whether
ImGui *draws*.

The registry is what MIDI routes into, what presets are written from, and what
the settings document is generated from. A control that only declares itself on
the frames it is visible is in none of those on every other frame. Two failures
follow, and both are silent:

- a preset loads into whatever happens to be on screen and nothing else;
- a save writes every undrawn control from the value it was **last seen with**,
  so loading a preset with a section folded and re-saving it quietly rewrites
  that section with stale numbers.

So: **never wrap panel code in a plain `if`.** Pass the condition in instead.

```cpp
// NO -- the body does not run, so nothing inside is declared
if (P.drops_on) {
    ui::SliderFloat("rate", &S.rate, 0.02f, 12.0f);
}

// YES -- the body always runs; only the drawing is conditional
ui::BeginGate(P.drops_on);
ui::SliderFloat("rate", &S.rate, 0.02f, 12.0f);
ui::EndGate();
```

Both arms of a two-way branch must declare, or whichever mode is off at save
time gets written from a stale cache and the two drift apart across a round
trip:

```cpp
ui::BeginGate(autoScale);
ui::SliderInt("target px", &targetDim, 720, 3840);
ui::EndGate();
ui::BeginGate(!autoScale);
ui::SliderInt("downscale", &downscale, 1, 6);
ui::EndGate();
```

### Hiding stops ImGui too

The bodies these guard are not only wrapped controls — they are full of raw
`ImGui::Text`, `Button`, `Combo`, `SeparatorText`. Since the body always runs,
those would draw anyway: every hidden tab page laid out on top of the visible
one, with duplicate labels among them colliding on id.

So a hidden section sets ImGui's own `SkipItems`, the flag a collapsed window
uses. Every widget tests it and returns immediately — no drawing, no layout, no
id — and `Begin`/`End`-style calls all report failure while it is set, so their
pairing still works out. This is handled inside `ui_params.cpp`; nothing in the
panel has to think about it.

The consequence worth knowing: **raw ImGui calls inside a hidden section are
no-ops, but they still execute.** Keep side effects out of them. A `Button`
returns false, so `if (ImGui::Button(...)) doThing();` is safe.

### Layout calls that must not run when hidden

`ImGui::SameLine()` and friends are harmless no-ops under `SkipItems`. Where
layout genuinely needs the condition, ask:

```cpp
ui::BeginGate(SP.coneSurfaceTravel);
if (ui::Visible()) { ImGui::SameLine(); ImGui::SetNextItemWidth(90); }
ui::SliderFloat("shell", &SP.coneShellThickness, 1.f, 20.f, "%.1f cm");
ui::EndGate();
```

---

## Names are a contract

A parameter's name is `section/section/label`, and it is what preset files and
MIDI maps are written in terms of. **Renaming a control or a section silently
invalidates every saved preset and binding that mentions it** — the loader
reports the orphaned keys rather than dropping them, but the value is gone.

Which is why the visibility wrappers add **no path level**:

| call | draws | adds a path level |
|---|---|---|
| `ui::PushSection(name)` / `Section` | — | **yes** |
| `ui::BeginGroup(name, open, visible)` | collapsing header | **yes** |
| `ui::BeginHeader(label, open, visible)` | collapsing header | no |
| `ui::BeginGate(visible)` | nothing | no |
| `ui::BeginTabBar(id)` / `ui::BeginTab(label)` | tab bar / tab | no |
| `ui::BeginRetired(label)` | collapsing header | no |

Most of the panel is `PushSection("z")` with a header reading `"z latent"` —
the section is the name, the header is the presentation. Use `BeginHeader`, not
`BeginGroup`, unless you actually want the extra level.

`PushSection` and a header-without-a-section (`BeginHeader`/`BeginRetired`)
also push a real Dear ImGui `PushID` scope, keyed on the section name or the
header's label. This is a second, independent thing from the path table
above: it decides which two *widgets* are the same widget for drag/hover/
focus purposes, and it is why two controls with the same literal label —
"size" under `fit` and "size" under `debug`, say — never collide on screen
even though nothing about their registry paths would have told Dear ImGui
that. `BeginGate` gets no such scope (it wraps pure visibility, often one
widget), and a tab gets one for free from `ImGui::BeginTabItem` itself.

`##id` suffixes are stripped from labels before naming, so a cosmetic id change
cannot invalidate a preset. Two characters are rewritten to `-`, because the
file format has already spent both:

* `/` — the section separator. `"z rate /s"` would otherwise register as a
  parameter `s` inside a section `z rate `.
* `=` — the key/value separator. This one silently broke saving: a label like
  `"sine layers (0 = tanh only)"` wrote a key the reader split at the `=`
  *inside the name*, so it came back as `mirror/network/sine layers (0` with the
  value `tanh only) = 1` and no control ever claimed it. Every label that
  documented its zero case in parentheses was quietly unsaveable.

Rewriting at declaration rather than escaping in the writer keeps the invariant
on the side that can enforce it: a name can never contain a separator, so the
reader's split-at-the-first-`=` is correct by construction. **Renaming a label
renames the key**, so migrate existing preset files when you change one.

---

## Banks: where a setting goes

Every parameter belongs to exactly one bank, which decides which file saves it.
The mapping from a top-level section name to a bank is `kBankRules` in
`ui_params.cpp` — **the one place that question is answered.**

| bank | file | what belongs here |
|---|---|---|
| `machine` | `presets/machine.machine` | the room, not the piece: sensor, screen, camera mask, MIDI map. Auto-loaded at startup, never carried to another venue. |
| `fit` | `presets/fit/*.fit` | how the face fit is set up: crop, head mode, head smoothing, identity capture, crop/feed grid-steps-lr, what happens outside the crop. |
| `debug` | `presets/debug/*.debug` | preview/diagnostic overlays: the camera-preview picture-in-picture, the network-input preview. Not calibration, not part of dialling in the fit — just what lets you see the pipeline while you work. |
| `show` | `presets/show/*.show` | the running order — what plays and when. |
| `look` | `presets/look/*.look` | composition that outlives one scene: text overlay, transition. |
| `mirror` | `presets/mirror/*.mirror` | the ripple scene. Many presets; dialled in per performance. |
| `roots` | `presets/roots/*.roots` | the root scene. |

The point of the split is that a mirror preset must be safe to load in any
venue — which it only is if it *cannot* carry the camera calibration. Only the
machine bank holds the MIDI map, for the same reason.

`fit` and `debug` each have their own tab, sitting right after `machine` in
the tab order. Fit's controls used to be drawn across two other tabs' pages
(the mirror tab, and a "face tracking" header on the machine tab) because
that was where you stood while dialling them in — but they were therefore
*saved* into `mirror` and `machine`, and loading a ripple preset to change
the palette silently rewrote whether the fit was tracking the camera at all.
Where a control is edited and where it is saved now line up at the tab
level for every bank, without exception; `SetBank` remains for the rare case
where a page is host to a handful of controls that belong to a different
bank entirely (see `mirror/mirror image` and the `roots` render-scale
controls, both Machine-bank facts drawn on the `machine` tab).

## Defaults: what a bank comes up in

`presets/defaults` names one preset per bank, and they are loaded at startup
right after `machine`:

```
fit = mirror_bw
mirror = mirror_bw
debug = debug
```

Set it from **\<bank's own tab\> → make default**, at the bottom of the tab
that edits that bank. The installation boots with nobody in front of it, so
a bank with no default comes up on the values compiled into its struct
however carefully it was dialled in the night before. A default naming a
preset that is no longer on disk is reported at startup and in the
**settings** tab, and skipped.

Loading several banks in one go **merges** into the staging table rather than
replacing it (`ReadFile(..., merge)` / `LoadBank(..., merge=true)`), since
values are not applied until each control next declares itself — without
that the last file read would discard every earlier one before a single
control had seen it. `LoadBankDefaults` does this at startup; `--roundtriptest`
does the same thing on demand.

A section matching no rule lands in `Unassigned`, and is reported loudly in
the **settings** tab and at the top of `SETTINGS.md`. That is deliberate: the
failure to design against is not a setting in the wrong bank, it is a setting
nobody ever decided about.

Bank lookup matches a named section **at any depth**, not just at the top level.
Nesting is a layout accident — a visibility gate wrapped around a page adds a
level without meaning to — and it must not decide classification.

Where a section straddles the line, override for part of it:

```cpp
ui::PushSection("mirror");
ui::SetBank(ui::Bank::Machine);   // which way round the sensor is mounted --
                                   // drawn on the mirror tab once, but a rig
                                   // fact, not part of the mirror's look
```

---

## Diagnostics

Two overlays and a readout, all independent of the panel so they work with the
UI hidden:

| what | where | shows |
|---|---|---|
| camera overlay | debug tab | the raw frame, mirroring and all: *is a frame arriving* |
| network input | debug tab | the exact buffer handed to the optimiser: *what became of it* |
| readout (F2) | show tab, or F2 | phase, what it is waiting for, fit state |

The two overlays answer consecutive questions and are worth reading in that
order. The camera overlay is upstream of everything; the network input is
downstream of the feed crop, the mirroring, the fit grid, the head placement and
the mask — every one of which is a way for the input to be wrong while each
stage looks fine on its own. It is drawn from `live_rgb` itself rather than
rebuilt from the same inputs, because a preview reconstructed from the parts
would agree with a broken pipeline.

Bright pixels in the network input are the ones the mask supervises; the dimmed
surround is what the network is free to invent. Under a face crop the surround
is *last frame's* — the resample is bounded to the mask's bounding box, drawn as
a blue rect — because nothing reads it. That emptiness is intended.

---

## Tabs

The tabs are **categories of parameter and nothing else**. They line up with the
banks, so where a setting is edited and where it is saved are the same answer.

A tab must never change what is on screen. Opening the roots tab to adjust a fog
value must not cut the projection to the root scene — what plays comes from the
phase navigator above the tabs, which goes through `show::Timeline` for
everything.

Order: `show · machine · fit · debug · look · mirror · roots · midi · settings`.

`fit` and `debug` sit right after `machine` rather than after `look`/`mirror`:
fitting a face is fundamentally a camera/face-tracking workflow, so it is one
tab-click from the rig settings (acquire, hold-on-loss, source, tracker px)
that stay on `machine`. `settings` (not `save`) is what is left once every
bank has its own save/load block on its own tab — see "A tab" below.

Tabs are siblings, never nested. `ui::BeginTab` must be matched by `ui::EndTab`
before the next `BeginTab` — a tab bar opened inside a tab item draws its pages
on top of the enclosing one.

`ui::BeginTabBar` is wrapped because `ImGui::BeginTabBar` can fail (a collapsed
window is the usual way) and `EndTabBar` must not be called when it did.

---

## Retiring a control

A control that is no longer worth showing should be **retired, not deleted**:

```cpp
ui::BeginRetired("old approach");
ui::SliderFloat("...", ...);
ui::EndRetired();
```

Retired controls still declare, still load and still save — they are only
hidden, behind **show retired controls** in the settings tab. Nothing in an
existing preset breaks. To remove one for good, delete the declaration *and*
the key from every preset file.

---

## Adding things: checklists

**A control.** Use the `ui::` wrapper, not the `ImGui::` call. Give it a label
you are willing to keep. If it sits behind a condition, use `BeginGate`.

**A section.** `ui::PushSection` / `PopSection`, and **add a rule to
`kBankRules`** — otherwise it lands in `Unassigned`. Regenerate `SETTINGS.md`
and check the unassigned list is empty.

**A tab.** `ui::BeginTab` / `EndTab` as a sibling of the others. Add
`DrawBankSaveUI(ui::Bank::X)` at the bottom of the tab's body if it owns a
bank — never in the `settings` tab, which stays cross-cutting only. Confirm
`--paneltest` still passes: content height is how a stray tab is caught, now
across every tab, not just whichever one is selected by default.

**A field on a params struct that should be saved.** Declare it. For
`rootsim::SimParams`, `visitSimParams` in `root_sim.h` is the canonical field
list and `--presettest` walks it, so a field added there and forgotten in the
panel fails the test by name.

---

## Tests

Run these after touching the panel. The first two are the ones that catch the
mistakes this document is about.

| command | what it checks |
|---|---|
| `--uitest` | headless. Declaration, MIDI routing, preset round-trip, that a folded header and a shut gate still take a loaded value and still save under their own names, and that two same-labelled controls in different sections never share a live Dear ImGui ID. |
| `--paneltest` | the real panel, every tab in turn. That **only the visited tab drew** — measured as content height — and that it declared no live-ID or registry-path collision. |
| `--presettest` | the real panel. Every `SimParams` field round-trips through the roots bank. |
| `--roundtriptest` | the real panel. Every live parameter, in every bank — not one struct — is mutated, saved, corrupted, reloaded, and checked back against the mutated value, one failure line per parameter that did not. |
| `--settings-doc` | writes `SETTINGS.md` and reports anything unassigned. |

`--paneltest` exists because the counts cannot see this class of bug. When the
raw ImGui calls in hidden bodies were escaping, the panel declared **289
parameters — exactly the right number** — and drew all seven pages on top of
each other. Declaring correctly while drawing when it should not looks perfectly
healthy from the inside, which is why the check is a measurement of the output
rather than a count of the inputs. Cycling every tab (not just whichever one
is selected by default) is what catches an ID or registry-path collision that
only exists once two particular controls share a tab — the reported bug (two
sliders both labelled "size") was invisible to a single-tab check since the
two were on different tabs before this reorganisation.

`--roundtriptest` exists because `--presettest` only ever proved one struct,
`rootsim::SimParams`, agrees with the roots bank — a real gap for the other
~185 parameters outside it. It walks `ui::Snapshot()`/`ui::StageValue()`
directly, so it covers whatever the panel currently declares without a
hand-written visitor to keep in step.
