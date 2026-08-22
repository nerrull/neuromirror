# Installing the piece on a show machine

The setup this describes: the Mac is powered off between expo days; on power-on
it logs in by itself, brings the piece up fullscreen with no operator, and puts
it back if it ever exits. Gallery staff need one gesture — the power button.
Nobody in the room can reach the artist's account, and the artist can reach the
machine over Jump Desktop or SSH.

Files here:

| | |
|---|---|
| `setup-kiosk.sh` | the scriptable half. Dry-run by default; `--apply` to do it. |
| `net.jardinsracine.mirror.plist.in` | the LaunchAgent, templated on the checkout's path. |
| `racine` | start / stop / restart / status / log / build, from either account. |

## Why the checkout has to move

`mirror_app` resolves everything at compile time from the source tree — assets,
shaders, `shows/`, `presets/`, and the Wwise banks (`src/wwise_audio.cpp:10`,
`../../WwiseProject/GeneratedSoundBanks/Mac`) — and links MLX, MediaPipe and
libfreenect2 by absolute rpath into `/Users/erichan/Documents/Development`.

A second account cannot read any of that: macOS home directories are `0700`, and
opening one up would undo the separation the second account exists for. So both
checkouts move somewhere shared, and the app is rebuilt there:

    sudo mkdir -p /Users/Shared/racine
    sudo chown "$(id -un):staff" /Users/Shared/racine

    # keep them siblings -- NEUROMIRROR_DIR is ../../neuromirror
    #   /Users/Shared/racine/jardins_racine
    #   /Users/Shared/racine/neuromirror

    cd /Users/Shared/racine/jardins_racine
    cmake -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build --target mirror_app -j"$(sysctl -n hw.logicalcpu)"

Develop there too. Two trees means tuning the show in one and running the other.

## 1. The kiosk account

System Settings → Users & Groups → add **`expo`**:

- **Standard**, never Administrator. No sudo, no admin group, no path upward.
- No Apple Account, no iCloud. Its keychain holds nothing of yours.
- Login Options → **Automatic login: expo**.

Then hide the fast-user-switching menu and disable the Guest account.

**Automatic login requires FileVault to be off.** That is the one real trade-off
in this setup: with FileVault on, every boot stops at a password prompt only you
can answer, and staff can no longer restart the piece themselves. Off, the disk
is readable to anyone who carries the Mac away, but your account password still
keeps `expo` out of your files while it runs. For a show machine with nothing
precious on it, off is the right call — just don't leave anything on it you'd
mind losing.

## 2. Sign the binary, once

TCC keys the camera and microphone grants to the binary's code signature. An
unsigned or ad-hoc-signed build gets a *new* identity every rebuild, so the
grant evaporates and macOS asks again — behind a fullscreen window, with nobody
there to click Allow.

Make a self-signed code-signing certificate once (Keychain Access → Certificate
Assistant → Create a Certificate → name it `Racine Kiosk`, type *Code Signing*),
and from then on build through `racine build`, which signs every time:

    install/racine build

## 3. Run the setup script

Read what it intends to do first:

    sudo install/setup-kiosk.sh --user expo

It refuses to go on if the checkout is still under a home directory, if the
binary isn't built, or if `expo` doesn't exist — and warns if `expo` is an admin
or the binary is ad-hoc signed. When it looks right:

    sudo install/setup-kiosk.sh --user expo --apply

That makes the tree readable, makes `imgui.ini`, `mirror_panel.ini` and
`presets/` writable by the kiosk user, creates `/Users/Shared/racine/logs`,
writes the LaunchAgent into `~expo/Library/LaunchAgents`, and sets the power
behaviour: never sleep, never blank the display, wake for network, and come back
on by itself after a power cut.

## 4. Grant camera and microphone

Log in as `expo`, open Terminal, and run the binary by hand once:

    /Users/Shared/racine/jardins_racine/build/mirror_app/mirror_app

Click Allow on both prompts, quit, log out. The Kinect goes through libfreenect2
over libusb and needs no permission; it's the webcam path (MediaPipe face
tracking) and any audio input that ask.

## 5. Jump Desktop

Install **Jump Desktop Connect** (jumpdesktop.com/connect) *for all users*, sign
it into your Jump account, and grant it **Screen Recording** and
**Accessibility** while logged in as `expo` — those are per-user grants, and the
`expo` session is the one you'll be connecting to.

That is deliberate: auto-login puts `expo` at the console, so Jump Desktop shows
you the piece running, which is what you want to check from off-site. It gives
you no route into the admin account — which is the point.

For anything administrative, use SSH instead, and enable Remote Login for **your
account only** (System Settings → General → Sharing → Remote Login → *Only these
users*). Don't fast-user-switch to your account during show hours: it takes the
piece off the display while it keeps running.

The `--fullscreen` window floats above everything, so if you need the desktop
clear on a remote session, stop the show first (`racine stop`) rather than
hunting for a way behind it.

Two more things for a machine you'll only reach remotely: turn **automatic macOS
updates off** — an overnight update reboot mid-run is the classic installation
failure — and put the `expo` account in a Focus mode so no notification banner
lands on the projection.

## 6. The expo days

Once the dates are known, schedule power-on and shutdown so the machine is only
awake when the show is:

    sudo pmset repeat wakeorpoweron MTWRFSU 09:30:00 shutdown MTWRFSU 18:30:00

    sudo pmset repeat cancel     # afterwards

`autorestart` covers power cuts, so the piece is back on its own within a minute
of the power returning.

## Running it

From either account — as `expo` it uses its own launchd domain, from anywhere
else it targets `expo`'s by uid and asks for `sudo`:

    install/racine start | stop | restart | status | log | build

`restart` is a `launchctl kickstart -k`: the process is killed and launchd starts
a fresh one. `stop` boots the agent out entirely, so `KeepAlive` doesn't
immediately undo it — remember to `start` again.

Logs land in `/Users/Shared/racine/logs/mirror.log`.

### For gallery staff

One card, laminated, near the machine:

> **To restart the piece:** hold the power button for 5 seconds until the screen
> goes black, wait 10 seconds, press it once. It comes back on its own in about
> a minute. **At the end of the day:** leave it — it shuts itself down.

## What runs at power-on

    power on
      -> automatic login as expo (no password, FileVault off)
        -> launchd loads ~expo/Library/LaunchAgents/net.jardinsracine.mirror.plist
          -> mirror_app --fullscreen --no-panel, cwd = the checkout
            -> exits or is quit? KeepAlive starts it again, 10s throttle

The panel is hidden from the first frame; **F1** or **`** brings it back if you
have a keyboard on the machine or a Jump Desktop session open.
