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
| `net.jardinsracine.gate.plist.in` | the show-day gate's LaunchDaemon. |
| `show-days.txt` | **the calendar** -- the days the piece runs. Edit this. |
| `show-gate.sh` | reads it, and sleeps the machine on days that aren't listed. |
| `racine` | start / stop / restart / status / log / build / days / keep-awake. |

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
behaviour: never sleep or blank on idle, wake for network, and come back on by
itself after a power cut or a power reconnect (see "Ending the day").

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

## 6. Ending the day

This machine is an **Apple silicon Mac mini (M4)**, and that decides the shape of
the daily cycle: Apple silicon does not support scheduled power-on from a full
shutdown. `pmset repeat poweron` accepts the command without complaint and the
machine simply never comes back -- a scheduled `shutdown` is a day that doesn't
start again. Wake from *sleep*, by contrast, works normally.

So the day ends in sleep, not shutdown -- and the schedule is set for *every*
day, deliberately, with the calendar handled separately (see "Days it doesn't
run"):

    sudo pmset repeat wakeorpoweron MTWRFSU 09:30:00 sleep MTWRFSU 22:00:00

    sudo pmset repeat cancel     # after the run

An M4 mini asleep draws on the order of a watt, so "not running for a month" is
satisfied about as well as by a shutdown. The piece is still running when it
wakes -- the process was never killed, so there's no relaunch to wait for and the
display is live within a couple of seconds.

Two settings make this work, both applied by `setup-kiosk.sh`:

- `sleep 0 displaysleep 0` -- never sleep or blank *on idle*, so the piece runs
  all day untouched. Note this is **not** `disablesleep 1`, the kiosk hammer:
  that one blocks all sleep including the scheduled kind, and the machine would
  never end its day.
- `womp 1` -- wake for network, so Jump Desktop can reach it while it sleeps.

The scheduled sleep only fires if the machine is awake to receive it, which idle
sleep being off guarantees.

### Verify it before the show

Neither of these is worth trusting on description. A week ahead, with the show
build in place:

    sudo pmset schedule sleep "$(date -v+3M '+%m/%d/%y %H:%M:%S')"
    sudo pmset schedule wake  "$(date -v+8M '+%m/%d/%y %H:%M:%S')"
    pmset -g sched                       # both events listed?

Then watch it sleep, wake five minutes later, and check the piece is still on
screen. If you'd rather use shutdown anyway, test that the same way -- schedule a
`poweron` a few minutes out, shut down, and see whether it returns. Expect it
not to.

## Days it doesn't run

`pmset repeat` holds exactly one wake and one sleep event, each with a weekday
mask, so it can say "weekends" (`SU` -- S is Saturday, U is Sunday) but not "the
three weekends in September plus the Saturday after". And a run of scattered
one-time `pmset schedule` events is a queue that silently runs out.

So pmset is left saying *every day*, and a gate decides which mornings survive.
The dates live in **`show-days.txt`**:

    2026-09-12..2026-09-13      # opening weekend
    2026-09-19..2026-09-20
    2026-10-03                  # closing

One date per line as `YYYY-MM-DD`, or an inclusive range with `..`; `#` starts a
comment. `show-gate.sh` reads it from a LaunchDaemon that runs **at boot and one
minute after the scheduled wake**. If today isn't listed, it waits 45 seconds for
the session to settle and calls `pmset sleepnow`.

A dark day therefore costs about ninety seconds of wake and nothing else, and
changing the calendar is editing one text file -- no `pmset` to re-run, no
account to log into, nothing to re-verify.

It is a **daemon** rather than an agent for two reasons: `pmset sleepnow` wants
root, and it has to be able to act at boot before anyone logs in. That second one
matters more than it looks. `autorestart` will boot this machine whenever power
returns — including at 3am on a Tuesday in the middle of the run. Without the
gate that's a machine playing to an empty room until someone notices; with it,
the piece comes up, the gate runs, and it's asleep again inside a minute.

Two behaviours worth knowing:

- **It fails awake.** A missing, unreadable or empty `show-days.txt` means the
  piece runs. A show that runs on a dark day is a smaller failure than a dark
  show on an open one.
- **It will sleep the machine on you.** The morning you're stood in front of it
  working is, as far as the gate knows, a dark day. Override it:

      racine keep-awake on      # gate off, machine stays up
      racine keep-awake off     # gate back in charge
      racine keep-awake         # which is it right now

  The override is a visible file (`/Users/Shared/racine/keep-awake`) precisely so
  it's hard to leave set by accident — a gate quietly overridden for the whole
  run is the failure mode this design has.

To see where you stand:

    racine days

which reports whether today is a show day, lists the calendar, and prints the
pmset events underneath it. `--check` never sleeps, so this is safe mid-show.

Test the sleeping half once on the real machine before the run — move
`show-days.txt` aside so today is definitely not a show day, then:

    sudo install/show-gate.sh

It should log the date, wait 45 seconds, and sleep the machine. Put the file
back afterwards.

### If the run is a simple weekly pattern

Weekends only, every weekend, no exceptions? Then skip the gate and let pmset say
it directly:

    sudo pmset repeat wakeorpoweron SU 09:30:00 sleep SU 22:00:00

A 7-day mechanical timer plug expresses the same thing in hardware, and is the
better answer if the venue's own power is unreliable.

### Autorestart, and what it does not cover

`autorestart 1` is the SMC's *restart after power failure*: if the machine loses
power while on or asleep, it boots itself when power returns. It is the answer to
a tripped breaker or a kicked cable -- the piece is back inside a minute with
nobody in the room.

It does **not** undo a clean shutdown. A machine that was shut down properly
stays off when power returns; only power *loss* arms it. That is the other reason
the day ends in sleep: a slept machine that then loses power overnight still
comes back on its own in the morning, where a shut-down one would not.

`autorestartatconnect 1` is the companion -- boot when power is *reconnected*,
however it went off. Which opens the most reliable option of all:

### The wall timer

A mechanical timer plug on the socket -- power cut at 22:30, restored at 09:15 --
schedules the day without involving macOS at all, and works whatever Apple does
to `pmset`. Pair it with the scheduled sleep above, so the machine is asleep
rather than mid-render when the socket dies, and with `autorestartatconnect`, so
it boots when the socket comes back. Nothing to verify, nothing to go stale, and
the venue can see at a glance that it is set right.

If the venue kills power at a breaker overnight anyway, you have this setup
whether you chose it or not -- so make sure the nightly sleep lands before they
do it.

## Running it

From either account — as `expo` it uses its own launchd domain, from anywhere
else it targets `expo`'s by uid and asks for `sudo`:

    install/racine start | stop | restart | status | log | build
    install/racine days | keep-awake [on|off]

`restart` is a `launchctl kickstart -k`: the process is killed and launchd starts
a fresh one. `stop` boots the agent out entirely, so `KeepAlive` doesn't
immediately undo it — remember to `start` again. `days` and `keep-awake` belong
to the show-day gate, above.

Logs land in `/Users/Shared/racine/logs/mirror.log`, the gate's in `gate.log`
beside it.

### For gallery staff

One card, laminated, near the machine:

> **To restart the piece:** hold the power button for 5 seconds until the screen
> goes black, wait 10 seconds, press it once. It comes back on its own in about
> a minute. **At the end of the day:** leave it — it puts itself to sleep, and
> wakes up on its own in the morning.

## What runs at power-on

    power on  (button, scheduled wake, or autorestart after a power cut)
      -> net.jardinsracine.gate: is today in show-days.txt?
      |    no -> pmset sleepnow, and the day is over
      -> automatic login as expo (no password, FileVault off)
        -> launchd loads ~expo/Library/LaunchAgents/net.jardinsracine.mirror.plist
          -> mirror_app --fullscreen --no-panel, cwd = the checkout
            -> exits or is quit? KeepAlive starts it again, 10s throttle
      ...
    22:00 -> scheduled sleep. The process is never killed, so tomorrow's wake
             puts the piece back on screen in a couple of seconds.

The panel is hidden from the first frame; **F1** or **`** brings it back if you
have a keyboard on the machine or a Jump Desktop session open.
