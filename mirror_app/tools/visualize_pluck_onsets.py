#!/usr/bin/env python3
"""Plot the onset detector's internal state against the FirePlucker source so
threshold constants can be tuned by eye instead of by trial-and-error runs of
embed_pluck_markers.py. Three sliders recompute and redraw live:
"sensitivity" (mean + sensitivity*stddev -- what counts as a candidate at
all), "min transient ratio" (MIN_TRANSIENT_RATIO -- kills decay-tail
retriggers and ambient wobble that clear the ODF bar without a real
percussive click; see transient_ratio() in embed_pluck_markers.py), and
"min strength" (MIN_STRENGTH -- the final keep/drop cut over what's left,
i.e. what actually ships as a cue marker).

Top panel: waveform (min/max-decimated so the whole file renders fast).
Middle panel: envelope dB (blue) vs FLOOR_DB (dashed) -- onsets below the
floor never fire no matter how sharp the rise.
Bottom panel: the onset detection function (dB rise per hop, black) vs its
adaptive threshold (red, mean + sensitivity*stddev, floored at MIN_RISE_DB).
Vertical lines mark hits after non-max suppression (suppress_neighbors in
embed_pluck_markers.py -- the strongest candidate in each MIN_INTERVAL_MS
window wins, not whichever fired first); green = kept (strength >=
MIN_STRENGTH), grey dotted = suppressed or below MIN_STRENGTH. The title
always shows candidates -> after-NMS -> kept counts for the visible window.
Per-hit strength labels only draw when the visible window is under 30s wide,
to keep a whole-file view legible.

Usage:
    python3 visualize_pluck_onsets.py [--start SEC] [--dur SEC]
        [--sensitivity F] [--floor-db F] [--min-rise-db F]
        [--min-interval-ms F] [--min-strength F] [--save PATH]

Defaults to the whole file. Drag either slider at the bottom to explore --
both the waveform and the env/odf traces are decimated for display, so
dragging stays responsive even at whole-file zoom. Narrow the window with
--start/--dur to inspect one region in full per-hop detail.
"""
import argparse

import matplotlib.pyplot as plt
from matplotlib.widgets import Slider
import numpy as np

from embed_pluck_markers import (
    IN_PATH, HOP, SENSITIVITY, FLOOR_DB, MIN_RISE_DB, MIN_INTERVAL_MS,
    MIN_STRENGTH, MIN_TRANSIENT_RATIO, detect_onsets, read_wav_mono,
)

MAX_WAVE_BINS = 4000
MAX_LINE_POINTS = 4000
ANNOTATE_BELOW_SECONDS = 30.0


def minmax_bins(x, sr, s0, s1, max_bins):
    n = s1 - s0
    n_bins = min(max_bins, n)
    if n_bins <= 0:
        return np.array([]), np.array([]), np.array([])
    bin_size = max(1, n // n_bins)
    n_bins = n // bin_size
    seg = x[s0:s0 + n_bins * bin_size].reshape(n_bins, bin_size)
    t = (s0 + np.arange(n_bins) * bin_size + bin_size / 2) / sr
    return t, seg.min(axis=1), seg.max(axis=1)


def decimate(t, y, max_points):
    if len(t) <= max_points:
        return t, y
    stride = max(1, len(t) // max_points)
    return t[::stride], y[::stride]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--start", type=float, default=0.0, help="window start, seconds")
    ap.add_argument("--dur", type=float, default=None, help="window length, seconds (default: whole file)")
    ap.add_argument("--sensitivity", type=float, default=SENSITIVITY)
    ap.add_argument("--floor-db", type=float, default=FLOOR_DB)
    ap.add_argument("--min-rise-db", type=float, default=MIN_RISE_DB)
    ap.add_argument("--min-interval-ms", type=float, default=MIN_INTERVAL_MS)
    ap.add_argument("--min-strength", type=float, default=MIN_STRENGTH)
    ap.add_argument("--min-transient-ratio", type=float, default=MIN_TRANSIENT_RATIO)
    ap.add_argument("--save", default=None, help="write PNG to this path instead of showing a window")
    args = ap.parse_args()

    mono, sr = read_wav_mono(IN_PATH)

    t0 = args.start
    t1 = t0 + args.dur if args.dur else len(mono) / sr
    s0, s1 = int(t0 * sr), min(int(t1 * sr), len(mono))

    fig, (ax_wave, ax_env, ax_odf) = plt.subplots(
        3, 1, figsize=(14, 9), sharex=True,
        gridspec_kw={"height_ratios": [1, 1.2, 1.4]},
    )
    plt.subplots_adjust(bottom=0.26)

    wt, wmin, wmax = minmax_bins(mono, sr, s0, s1, MAX_WAVE_BINS)
    ax_wave.fill_between(wt, wmin, wmax, color="tab:gray", linewidth=0)
    ax_wave.set_ylabel("waveform")

    (env_line,) = ax_env.plot([], [], color="tab:blue", linewidth=0.8, label="envelope dB")
    ax_env.axhline(args.floor_db, color="black", linestyle="--", linewidth=1, label="FLOOR_DB")
    ax_env.set_ylabel("dB")
    ax_env.legend(loc="upper right", fontsize=8)

    (odf_line,) = ax_odf.plot([], [], color="black", linewidth=0.6, label="ODF (dB rise)")
    (thr_line,) = ax_odf.plot([], [], color="tab:red", linewidth=1, label="adaptive threshold")
    ax_odf.set_ylabel("dB rise")
    ax_odf.set_xlabel("time (s)")
    ax_odf.legend(loc="upper right", fontsize=8)

    marker_artists = []

    def clear_markers():
        for a in marker_artists:
            a.remove()
        marker_artists.clear()

    def render(_=None):
        sensitivity = sens_slider.val
        min_strength = thr_slider.val
        min_transient_ratio = ratio_slider.val
        clear_markers()
        params = dict(
            sensitivity=sensitivity, floor_db=args.floor_db,
            min_rise_db=args.min_rise_db, min_interval_ms=args.min_interval_ms,
            min_transient_ratio=min_transient_ratio,
        )
        hits, dbg = detect_onsets(mono, sr, params=params, debug=True)
        n_candidates = len(dbg["candidates"])
        n_survivors = len(dbg["survivors"])
        hit_set = set(hits)
        kept = [(o, s) for o, s in hits if s >= min_strength]
        dropped_or_suppressed = [
            (o, s) for o, s in dbg["candidates"]
            if (o, s) not in hit_set or s < min_strength
        ]

        h0, h1 = s0 // HOP, min(len(dbg["db"]), (s1 // HOP) + 1)
        t_hop = np.arange(h0, h1) * HOP / sr
        et, ed = decimate(t_hop, dbg["db"][h0:h1], MAX_LINE_POINTS)
        ot, od = decimate(t_hop, dbg["odf"][h0:h1], MAX_LINE_POINTS)
        tt, td = decimate(t_hop, dbg["thr"][h0:h1], MAX_LINE_POINTS)
        env_line.set_data(et, ed)
        odf_line.set_data(ot, od)
        thr_line.set_data(tt, td)

        annotate = (t1 - t0) < ANNOTATE_BELOW_SECONDS
        kept_in_view = 0
        dropped_in_view = 0
        for off, strength in dropped_or_suppressed:
            t = off / sr
            if t0 <= t <= t1:
                dropped_in_view += 1
                marker_artists.append(
                    ax_wave.axvline(t, color="gray", alpha=0.35, linewidth=1, linestyle=":"))

        for off, strength in kept:
            t = off / sr
            if t0 <= t <= t1:
                kept_in_view += 1
                for ax in (ax_wave, ax_env, ax_odf):
                    marker_artists.append(
                        ax.axvline(t, color="tab:green", alpha=0.6, linewidth=1))
                if annotate:
                    marker_artists.append(ax_odf.annotate(
                        f"{strength:.2f}", (t, 1.0), xycoords=("data", "axes fraction"),
                        fontsize=7, color="tab:green", rotation=90, va="top", ha="right"))

        for ax in (ax_env, ax_odf):
            ax.relim()
            ax.autoscale_view()

        fig.suptitle(
            f"{IN_PATH.split('/')[-1]}  [{t0:.2f}s-{t1:.2f}s]   "
            f"sensitivity={sensitivity:.2f}  min_transient_ratio={min_transient_ratio:.1f}  "
            f"min_strength={min_strength:.2f}\n"
            f"whole file: {n_candidates} candidates -> {n_survivors} after NMS -> "
            f"{len(hits)} after transient filter -> {len(kept)} kept "
            f"({len(kept)/(len(mono)/sr):.2f}/s)   "
            f"in view: {kept_in_view} kept, {dropped_in_view} dropped/suppressed"
        )
        fig.canvas.draw_idle()

    ax_sens = fig.add_axes([0.2, 0.14, 0.6, 0.03])
    sens_slider = Slider(ax_sens, "sensitivity", 0.2, 6.0, valinit=args.sensitivity, valstep=0.05)
    sens_slider.on_changed(render)

    ax_ratio = fig.add_axes([0.2, 0.08, 0.6, 0.03])
    ratio_slider = Slider(ax_ratio, "min transient ratio", 0.0, 15.0,
                           valinit=args.min_transient_ratio, valstep=0.5)
    ratio_slider.on_changed(render)

    ax_thr = fig.add_axes([0.2, 0.03, 0.6, 0.03])
    thr_slider = Slider(ax_thr, "min strength", 0.0, 1.0, valinit=args.min_strength, valstep=0.01)
    thr_slider.on_changed(render)

    render()

    if args.save:
        plt.savefig(args.save, dpi=150)
        print(f"wrote {args.save}")
    else:
        plt.show()


if __name__ == "__main__":
    main()
