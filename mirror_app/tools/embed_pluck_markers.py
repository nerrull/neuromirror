#!/usr/bin/env python3
"""Find the pops in the FirePlucker source and embed them as WAV cue
markers, so Wwise picks them up as Markers on re-import and the mirror app
can react to Play_FirePlucker's AK_Marker notifications.

What the piece reacts to is the pop -- the literal click of a fibre letting
go. Measured on this file (NHU05008080.wav) a click is a broadband
transient a millisecond or two long; the bed around it is a dense crackle
of smaller clicks sitting on a slow low-frequency rumble (a ~100-200 Hz
swell of +/-0.05, about -26 dBFS). That rumble is what made the previous
detectors unreliable: it dominates a full-band peak or envelope, so a bump
in it read as an onset with no click in it, while a real click on a quiet
stretch of it fell under the bar, and an envelope's rise put the marker
anywhere within +/-25 ms of the click.

So the detector works above the rumble:

  1. mono mix, high-passed at HP_HZ (a windowed-sinc FIR, zero phase). In
     this band the bed's own peaks sit at -35 dBFS and below, and a click's
     size is simply its peak.
  2. a 1 ms peak envelope of that, in dBFS.
  3. a candidate is a local maximum of the envelope over +/-MIN_INTERVAL_MS
     /2 -- non-max suppression, so a burst of sub-clicks is one pop, and
     the loudest one in a window wins rather than the first.
  4. two gates: the click's absolute level, MIN_CLICK_DBFS, and its
     prominence over the local bed, PROM_DB above the median of the
     envelope in +/-BED_MS around it. Prominence is what keeps the fade-in
     and fade-out honest and rejects a click inside a burst of equals.
  5. the marker goes at the click's first sample above half its peak --
     the click itself, not an envelope's guess at it.

Click level on this file is a continuum, -45..0 dBFS above 2 kHz, with no
gap between "crackle" and "pop": MIN_CLICK_DBFS is a taste decision about
how many pops per second the piece should get, not a class boundary. The
script prints the rate at a few settings so it can be moved with its
consequence in view. -16 dBFS is ~1.1 pops/s, which is what the old marker
set delivered, but now the right ones and on the click.

Each cue's label is the hit's 0..1 strength as plain text ("0.734") --
the click's peak, STRENGTH_FLOOR_DBFS..0 dBFS mapped to 0..1 -- which
WwiseAudio::MarkerCallback (wwise_audio.cpp) parses back out at runtime;
this is how a marker hit gets a variable raindrop size instead of a fixed
one. A hit that made it into the bank was already a pop, so "only the real
plucks" isn't something the app has to filter live.

    python3 embed_pluck_markers.py            # rewrite the markers in IN_PATH
    python3 embed_pluck_markers.py --dry-run  # print the stats, touch nothing
    python3 embed_pluck_markers.py --sheet hits.png   # + a contact sheet of every hit
"""
import argparse
import struct
import sys
import wave

import numpy as np

IN_PATH = "/Users/erichan/Documents/Development/jardins_racine/WwiseProject/Originals/SFX/NHU05008080.wav"

HP_HZ = 2000.0            # the rumble is gone by 1 kHz; 2 kHz leaves margin
HP_TAPS = 255
ENV_MS = 1.0              # peak-envelope hop
MIN_INTERVAL_MS = 120.0   # one pop per window (non-max suppression)
BED_MS = 150.0            # half-width of the local-median window
MIN_CLICK_DBFS = -16.0    # the pop bar -- see the module docstring
PROM_DB = 20.0            # the click over the bed around it (kept pops sit 30+ over it;
                          # this is the fade-in and fade-out gate)
# The label's 0..1: the click's peak over this range. -30 puts the quietest
# kept pop (-16 dBFS) at 0.47, so a drop is never sized from a zero.
STRENGTH_FLOOR_DBFS = -30.0


def highpass(mono, sr, fc=HP_HZ, taps=HP_TAPS):
    n = np.arange(taps) - (taps - 1) / 2
    h = -np.sinc(2 * fc / sr * n) * 2 * fc / sr
    h[(taps - 1) // 2] += 1.0
    h *= np.hamming(taps)
    return np.convolve(mono.astype(np.float64), h, mode="same")


def peak_envelope(y, sr, ms=ENV_MS):
    hop = max(1, int(sr * ms * 0.001))
    n = len(y) // hop
    pk = np.abs(y[:n * hop]).reshape(n, hop).max(axis=1)
    return 20.0 * np.log10(pk + 1e-9), hop


def sliding(x, half, pad_value=None):
    """(len(x), 2*half+1) view of x around each index, edge-padded (or with
    pad_value at the ends)."""
    from numpy.lib.stride_tricks import sliding_window_view
    if pad_value is None:
        p = np.pad(x, (half, half), mode="edge")
    else:
        p = np.pad(x, (half, half), mode="constant", constant_values=pad_value)
    return sliding_window_view(p, 2 * half + 1)


def click_strength(db, floor_db=STRENGTH_FLOOR_DBFS):
    return float(np.clip((db - floor_db) / max(-floor_db, 1.0), 0.0, 1.0))


def detect_pops(mono, sr, min_click_dbfs=MIN_CLICK_DBFS, prom_db=PROM_DB,
                min_interval_ms=MIN_INTERVAL_MS, bed_ms=BED_MS):
    """All the clicks that clear the bars, as (sample_offset, strength,
    click_dbfs, prominence_db), time-ordered. Also returns everything the
    detector looked at, for the sheet and the visualiser."""
    hp = highpass(mono, sr)
    env, hop = peak_envelope(hp, sr)
    half_nms = max(1, int(round(min_interval_ms * 0.5 / ENV_MS)))
    half_bed = max(1, int(round(bed_ms / ENV_MS)))
    is_max = env >= sliding(env, half_nms, pad_value=-200.0).max(axis=1)
    bed = np.median(sliding(env, half_bed), axis=1)
    prom = env - bed

    hits = []
    for i in np.flatnonzero(is_max):
        if env[i] < min_click_dbfs or prom[i] < prom_db:
            continue
        # The click's own first sample above half its peak, within its
        # envelope bin (and one bin of slack before it for a click that
        # straddles the boundary).
        a = max(0, (i - 1) * hop)
        seg = np.abs(hp[a:(i + 1) * hop])
        first = a + int(np.argmax(seg >= 0.5 * seg.max()))
        hits.append((first, click_strength(env[i]), float(env[i]), float(prom[i])))
    state = dict(hp=hp, env=env, hop=hop, bed=bed, is_max=is_max)
    return hits, state


def read_wav_mono(path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        n = w.getnframes()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        raw = w.readframes(n)
    if sw != 2:
        raise ValueError(f"expected 16-bit PCM, got {sw * 8}-bit")
    data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        data = data.reshape(-1, ch).mean(axis=1)
    return data, sr


def build_cue_chunk(hits, sample_rate):
    n = len(hits)
    body = struct.pack("<I", n)
    for idx, (sample_off, _strength) in enumerate(hits):
        cue_id = idx + 1
        body += struct.pack(
            "<II4sIII",
            cue_id,        # dwName
            sample_off,    # dwPosition (play order, == sample offset here)
            b"data",       # fccChunk
            0,             # dwChunkStart
            0,             # dwBlockStart
            sample_off,    # dwSampleOffset
        )
    chunk = b"cue " + struct.pack("<I", len(body)) + body
    if len(body) % 2:
        chunk += b"\x00"
    return chunk


def build_list_adtl_chunk(hits):
    # 'labl' sub-chunks under a 'LIST'/'adtl' chunk carry each cue's text --
    # this is where the strength value rides through to Wwise's Markers tab
    # and back out through AkMarkerCallbackInfo::strLabel at runtime.
    body = b"adtl"
    for idx, (_sample_off, strength) in enumerate(hits):
        cue_id = idx + 1
        text = f"{strength:.3f}".encode("ascii") + b"\x00"
        labl = struct.pack("<I", cue_id) + text
        if len(labl) % 2:
            labl += b"\x00"
        body += b"labl" + struct.pack("<I", len(labl)) + labl
    chunk = b"LIST" + struct.pack("<I", len(body)) + body
    return chunk


def contact_sheet(mono, sr, state, hits, path, rejected=12, cols=8):
    """One strip per hit -- 40 ms before to 60 ms after, full band over the
    high-passed band -- sorted loudest first, then the loudest clicks that
    did NOT make the bar, so the cut can be judged by eye."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    env, hop, hp = state["env"], state["hop"], state["hp"]
    order = sorted(hits, key=lambda h: -h[2])
    kept_bins = {h[0] // hop for h in hits}
    below = [i for i in np.flatnonzero(state["is_max"])
             if env[i] < MIN_CLICK_DBFS and (env[i] - state["bed"][i]) >= PROM_DB
             and i not in kept_bins]
    below = sorted(below, key=lambda i: -env[i])[:rejected]
    panels = [("kept", h[0], h[2], h[3]) for h in order] + \
             [("rejected", int(i) * hop, float(env[i]), float(env[i] - state["bed"][i])) for i in below]
    rows = (len(panels) + cols - 1) // cols
    fig, axs = plt.subplots(rows, cols, figsize=(3.2 * cols, 2.0 * rows), squeeze=False)
    pre, post = int(0.040 * sr), int(0.060 * sr)
    for k, (kind, s, db, pr) in enumerate(panels):
        ax = axs[k // cols][k % cols]
        a, b = max(0, s - pre), min(len(mono), s + post)
        t = (np.arange(a, b) - s) / sr * 1000.0
        ax.plot(t, mono[a:b], lw=0.3, color="0.6")
        ax.plot(t, hp[a:b], lw=0.3, color="k" if kind == "kept" else "r")
        lim = max(0.05, float(np.abs(mono[a:b]).max()) * 1.1)
        ax.set_ylim(-lim, lim)
        ax.set_title(f"{kind} {s / sr:.2f}s  {db:.1f} dB  +{pr:.0f}", fontsize=7)
        ax.tick_params(labelsize=5)
    for k in range(len(panels), rows * cols):
        axs[k // cols][k % cols].axis("off")
    fig.tight_layout()
    fig.savefig(path, dpi=70)
    print(f"wrote {path}: {len(order)} kept + {len(below)} loudest rejected")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print the stats, leave the file alone")
    ap.add_argument("--sheet", metavar="PNG", help="write a contact sheet of every hit")
    ap.add_argument("--min-click-dbfs", type=float, default=MIN_CLICK_DBFS)
    ap.add_argument("--prom-db", type=float, default=PROM_DB)
    args = ap.parse_args()

    mono, sr = read_wav_mono(IN_PATH)
    dur = len(mono) / sr
    hits, state = detect_pops(mono, sr, args.min_click_dbfs, args.prom_db)

    env, prom = state["env"], state["env"] - state["bed"]
    maxima = np.flatnonzero(state["is_max"] & (env > -50.0))
    print(f"{len(maxima)} clicks over {dur:.1f}s above 2 kHz; per second at a bar of")
    for bar in (-10.0, -12.0, -14.0, -16.0, -18.0, -20.0):
        n = int(((env[maxima] >= bar) & (prom[maxima] >= args.prom_db)).sum())
        print(f"   {bar:6.1f} dBFS: {n:4d}  ({n / dur:.2f}/s)")
    print(f"gate: click >= {args.min_click_dbfs} dBFS and >= {args.prom_db} dB over the bed: "
          f"{len(hits)} pops ({len(hits) / dur:.2f}/s)")
    if hits:
        s = np.array([h[1] for h in hits])
        print("strength  min %.2f  median %.2f  max %.2f" % (s.min(), np.median(s), s.max()))
        gaps = np.diff([h[0] for h in hits]) / sr
        print("gap (s)   min %.2f  median %.2f  max %.2f" % (gaps.min(), np.median(gaps), gaps.max()))
    if args.sheet:
        contact_sheet(mono, sr, state, hits, args.sheet)
    if args.dry_run:
        return
    if not hits:
        print("nothing cleared the gate -- leaving the file untouched")
        sys.exit(1)

    with open(IN_PATH, "rb") as f:
        data = f.read()

    # Strip any pre-existing cue/LIST-adtl chunks so re-running this script is
    # idempotent instead of stacking duplicate markers.
    out = bytearray(data[:12])
    i = 12
    while i < len(data) - 8:
        cid = data[i:i + 4]
        size = struct.unpack("<I", data[i + 4:i + 8])[0]
        chunk_end = i + 8 + size + (size % 2)
        if cid not in (b"cue ", b"LIST"):
            out += data[i:chunk_end]
        i = chunk_end

    cues = [(off, strength) for off, strength, _db, _pr in hits]
    out += build_cue_chunk(cues, sr)
    out += build_list_adtl_chunk(cues)

    riff_size = len(out) - 8
    out[4:8] = struct.pack("<I", riff_size)

    with open(IN_PATH, "wb") as f:
        f.write(out)

    print(f"wrote {len(cues)} cue markers into {IN_PATH}")
    print("first 10 (s, strength):", [(round(o / sr, 3), round(st, 2)) for o, st in cues[:10]])


if __name__ == "__main__":
    main()
