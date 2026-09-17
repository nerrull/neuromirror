# Gallery machine -- the checklist

The authoritative list. [README.md](README.md) explains *why* each step is
the way it is; this is *what to do, in order*, and where things stand.
Tick boxes are the state as of 2026-09-16.

Paths are from the repo root. Two trees live on this machine:

| | |
|---|---|
| `~/Documents/Development/jardins_racine` | **dev** -- where the show is tuned |
| `/Users/Shared/racine/jardins_racine` | **show** -- what `expo` runs. Sibling `neuromirror` beside it. |

## 1. One-time setup

### The show tree

- [x] Both checkouts copied to `/Users/Shared/racine/` (rsync, `.git` included,
      minus `build/`, captures, coverage, Wwise profiling sessions).
- [x] `libfreenect2`'s CMake config made location-relative in both trees
      (it had the dev tree's absolute prefix baked in from its original build).
- [x] Configured and built there:
      `cmake -B build -DCMAKE_BUILD_TYPE=Release -DWWISE_CONFIG=Profile`.
      **Profile, not Release** -- the custom plug-ins only exist for Profile;
      Release configures silently with no sound engine.
- [x] Every rpath in the binary resolves under `/Users/Shared/racine`
      (`otool -l build/mirror_app/mirror_app | grep -A2 LC_RPATH`).
- [x] Signed with the Apple Development identity
      `DE5193F0519AD4207DA3778BABC7E3EE0EFA7892` (team `B6C64D8M6K`, valid
      to 2027-04). `racine build` uses it by default. No self-signed cert needed.
- [x] `--roottest` passes on the show build.
- [x] `dev` git remote in the show tree -> the dev checkout; the show branch tracks it.

### The kiosk account

- [ ] Create **`expo`**: Standard (not admin), no Apple Account, no iCloud.
- [ ] Users & Groups -> Login Options -> Automatic login: `expo`.
      Requires **FileVault off** (System Settings -> Privacy & Security).
- [ ] Disable the Guest account; hide the fast-user-switching menu.

### Wire it up

- [ ] Dry run and read it:
      `sudo mirror_app/install/setup-kiosk.sh --user expo --launch-only`
- [ ] `sudo mirror_app/install/setup-kiosk.sh --user expo --launch-only --apply`
      (tree perms, `/Users/Shared/racine/logs`, LaunchAgent in
      `~expo/Library/LaunchAgents`, Start/Stop shortcuts on expo's Desktop,
      no idle sleep, wake for network). Without `--launch-only` it also installs the show-day
      gate, autorestart and the schedule notes -- later, if wanted.

### Permissions (a human, once)

- [ ] Log in as `expo`, open Terminal, run
      `/Users/Shared/racine/jardins_racine/build/mirror_app/mirror_app`,
      click **Allow** for camera and microphone, quit, log out.

### Remote access

- [ ] Jump Desktop Connect, installed *for all users*, signed into your account.
- [ ] Grant it Screen Recording + Accessibility **while logged in as `expo`**.
- [ ] SSH to your account works from your laptop (Remote Login on; `womp` is
      set by the script).

### Schedule

- [ ] `mirror_app/install/show-days.txt` -- confirm the real dates. Today it
      lists 2026-09-12..13, 19..20, 26..27, 10-03.
- [ ] Daily wake/sleep, to the venue's hours:
      `sudo pmset repeat wakeorpoweron MTWRFSU 09:30:00 sleep MTWRFSU 22:00:00`
- [ ] Test the gate once: move `show-days.txt` aside,
      `sudo mirror_app/install/show-gate.sh` -- it should sleep the machine in
      ~45 s. Put the file back. `racine keep-awake on` while you're working
      in front of it; `off` before you leave.

### Dress rehearsal

- [ ] Hold power 5 s, wait 10 s, press once. Within ~1 min: auto-login,
      fullscreen, no panel, sound, camera tracking.
- [ ] `mirror_app/install/racine status` shows the agent owns the process;
      `racine log` is clean.
- [ ] Kill the app (`racine restart`, or `kill` it) -- KeepAlive brings it back
      within 10 s.
- [ ] Ctrl+C / Cmd+Q from a keyboard does not leave a desktop on screen.
- [ ] Laminated staff card by the machine (text at the end of README.md).

### Physical (from todo_sep_13.md)

- [ ] fit screen, black tape
- [ ] attach camera, set angle
- [ ] bolts + spacers for the frame
- [ ] wire diagram
- [ ] wall timer plug, if the venue's power is unreliable (README, "The wall timer")

## 2. Updating the show build

Tune in the dev tree, commit, then:

    cd /Users/Shared/racine/jardins_racine
    git pull                                   # tracks dev/mirror/cloth-in-roots
    mirror_app/install/racine build            # cmake + codesign, same identity
    mirror_app/install/racine restart

`dev` is a git remote pointing at the dev checkout (`git remote -v`), and the
show branch tracks it, so nothing goes through GitHub. To run a different
branch: `git checkout -t dev/<branch>`.

`racine build` must be used, not bare `cmake --build`: an unsigned rebuild
gets a new identity and the camera prompt comes back behind the fullscreen
window. Uncommitted dev changes do not travel -- commit them, or `rsync` the
specific files across and note that you did.

If the Wwise banks changed, they are gitignored: after a bank build in Wwise
Authoring copy `WwiseProject/GeneratedSoundBanks/` across too.

    rsync -a --delete ~/Documents/Development/jardins_racine/WwiseProject/GeneratedSoundBanks/ \
        /Users/Shared/racine/jardins_racine/WwiseProject/GeneratedSoundBanks/

Presets saved from the panel *in the show tree* stay in the show tree
(`setup-kiosk.sh` made `mirror_app/presets/` writable by `expo`); copy them
back to dev if they're keepers.

If the CMake config was ever wiped (`rm build/CMakeCache.txt`), reconfigure with
`-DWWISE_CONFIG=Profile` -- the default is Profile too, but check the configure
output says `Wwise sound engine enabled`.

## 3. Day-to-day

**As `expo`, to get out:** Cmd-Tab to Finder, double-click **Stop Racine**
on the Desktop. The agent is unloaded for this login session, so nothing
respawns; log out freely. **Start Racine** brings it back, and so does the
next login. Same from Terminal: `racine stop` / `racine start` (no sudo
needed from the expo account).

    mirror_app/install/racine start | stop | restart | status | log
    mirror_app/install/racine days                # is today a show day? + pmset
    mirror_app/install/racine keep-awake [on|off] # override the gate

From your own account these `sudo` into `expo`'s launchd domain. Logs:
`/Users/Shared/racine/logs/mirror.log`, gate in `gate.log`.

If you change `show-days.txt`, nothing needs restarting -- the gate reads it
each morning.

## 4. Known gaps

- `racine` is at `mirror_app/install/racine`; older notes said `install/racine`.
- `WWISE_CONFIG=Release` is untested end to end; stay on Profile for this run.
- The Apple Development identity expires 2027-04. After that, any stable
  identity will do (`RACINE_SIGNING_ID=...`), and the camera/mic grant has to
  be re-clicked once as `expo`.
