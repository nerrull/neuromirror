#!/usr/bin/env python3
"""Plot the pop detector's state against the FirePlucker source, so the
bars in embed_pluck_markers.py can be moved with the waveform in view.

Top: the source (grey) and the high-passed band the detector listens to
(black). Bottom: the 1 ms peak envelope of that band in dBFS (black), the
local bed it is measured against (blue, its +/-BED_MS median), and the two
bars -- MIN_CLICK_DBFS (red dashed) and bed + PROM_DB (blue dotted). Every
local maximum is a tick at the bottom; the kept pops are green lines with
their strength label. Two sliders move the bars live.

Usage:
    python3 visualize_pluck_onsets.py [--start SEC] [--dur SEC] [--save PATH]

Narrow the window with --start/--dur: the whole file at 44.1 kHz is a lot
of samples, and the sample-level top panel is the point.
"""
import argparse

import matplotlib.pyplot as plt
from matplotlib.widgets import Slider
import numpy as np

from embed_pluck_markers import (
    IN_PATH, MIN_CLICK_DBFS, PROM_DB, click_strength, detect_pops, read_wav_mono,
)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--dur", type=float, default=10.0)
    ap.add_argument("--save", help="write the figure here instead of showing it")
    args = ap.parse_args()

    mono, sr = read_wav_mono(IN_PATH)
    _hits, st = detect_pops(mono, sr)
    hp, env, hop, bed = st["hp"], st["env"], st["hop"], st["bed"]
    s0 = int(args.start * sr)
    s1 = min(len(mono), int((args.start + args.dur) * sr))
    t = np.arange(s0, s1) / sr
    b0, b1 = s0 // hop, s1 // hop
    tb = (np.arange(b0, b1) + 0.5) * hop / sr

    fig, (ax_w, ax_e) = plt.subplots(2, 1, figsize=(16, 8), sharex=True)
    fig.subplots_adjust(bottom=0.18)
    ax_w.plot(t, mono[s0:s1], lw=0.3, color="0.7", label="source")
    ax_w.plot(t, hp[s0:s1], lw=0.3, color="k", label="high-passed")
    ax_w.legend(loc="upper right", fontsize=8)
    ax_e.plot(tb, env[b0:b1], lw=0.5, color="k")
    ax_e.plot(tb, bed[b0:b1], lw=0.8, color="tab:blue")
    ax_e.set_ylim(-60, 0)
    ax_e.set_ylabel("dBFS above 2 kHz")
    ax_e.set_xlabel("s")
    maxima = np.flatnonzero(st["is_max"][b0:b1]) + b0
    ax_e.vlines((maxima + 0.5) * hop / sr, -60, -57, color="0.5", lw=0.5)
    bar_abs = ax_e.axhline(MIN_CLICK_DBFS, color="r", ls="--", lw=0.8)
    (bar_prom,) = ax_e.plot(tb, bed[b0:b1] + PROM_DB, color="tab:blue", ls=":", lw=0.8)
    lines, texts = [], []

    def redraw(min_click, prom):
        for a in lines + texts:
            a.remove()
        lines.clear()
        texts.clear()
        bar_abs.set_ydata([min_click, min_click])
        bar_prom.set_ydata(bed[b0:b1] + prom)
        kept = [h for h in hits_at(min_click, prom) if s0 <= h[0] < s1]
        for off, strength, db, _pr in kept:
            x = off / sr
            lines.append(ax_e.axvline(x, color="g", lw=0.8, alpha=0.7))
            lines.append(ax_w.axvline(x, color="g", lw=0.8, alpha=0.7))
            texts.append(ax_e.text(x, db + 1, f"{strength:.2f}", fontsize=6, color="g",
                                   ha="center"))
        ax_e.set_title(f"{len(maxima)} clicks in view, {len(kept)} pops at "
                       f">= {min_click:.0f} dBFS and >= {prom:.0f} dB over the bed")
        fig.canvas.draw_idle()

    # The high-pass is the cost and it was done once above, so a slider move
    # re-applies the bars to the cached state rather than re-detecting.
    def hits_at(min_click, prom):
        out = []
        for i in np.flatnonzero(st["is_max"]):
            if env[i] >= min_click and env[i] - bed[i] >= prom:
                out.append((i * hop, click_strength(env[i]),
                            float(env[i]), float(env[i] - bed[i])))
        return out

    ax_s1 = fig.add_axes([0.15, 0.07, 0.7, 0.025])
    ax_s2 = fig.add_axes([0.15, 0.03, 0.7, 0.025])
    s_abs = Slider(ax_s1, "min click dBFS", -30.0, 0.0, valinit=MIN_CLICK_DBFS)
    s_prom = Slider(ax_s2, "prominence dB", 0.0, 40.0, valinit=PROM_DB)
    s_abs.on_changed(lambda v: redraw(s_abs.val, s_prom.val))
    s_prom.on_changed(lambda v: redraw(s_abs.val, s_prom.val))
    redraw(MIN_CLICK_DBFS, PROM_DB)

    if args.save:
        fig.savefig(args.save, dpi=110)
        print(f"wrote {args.save}")
    else:
        plt.show()


if __name__ == "__main__":
    main()
