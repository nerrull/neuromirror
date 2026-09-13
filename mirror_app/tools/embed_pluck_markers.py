#!/usr/bin/env python3
"""Detect crackle onsets in the FirePlucker source and embed them as WAV cue
markers, so Wwise picks them up as Markers on re-import and the mirror app
can react to Play_FirePlucker's AK_Marker notifications.

Onset detector is a Python port of mi::OnsetDetector
(wwise_plugins/mi_common/onset_detector.h): thr = mean(rise) + sensitivity *
stddev(rise) over a rolling window of the envelope's per-hop dB rise, with a
floor and a minimum rise. Ported rather than reused so this script has no
build dependency.

Departure from the plugin: the plugin gates hits with a fixed refractory
period counted from the *last accepted hit*, which lets a weak hit block a
much louder one that follows within the window. Here every hop that clears
the floor/threshold bar is collected as a candidate first, then
suppress_neighbors() runs greedy non-max suppression -- take the strongest
remaining candidate, drop every other candidate within MIN_INTERVAL_MS of
it, repeat -- so the window is centered on the loudest onset instead of
whichever one happened to fire first.

A third gate, transient_ratio(), catches what NMS and MIN_STRENGTH can't:
the decaying tail of a loud pluck ripples enough to clear the ODF/threshold
bar again on its way down, and because the ripple happens well outside
MIN_INTERVAL_MS of the original peak, NMS treats it as an unrelated event.
These retriggers still have a respectable dB-rise strength (they're riding
on an already-elevated envelope), so MIN_STRENGTH doesn't catch them either
-- but the raw waveform right after them is quiet relative to what came
just before, because there's no new percussive click, just noise-floor
wobble on a decay curve. transient_ratio() measures exactly that: peak
sample amplitude in the ~30ms after the hit, divided by RMS amplitude in
the ~50ms before it. A real pluck's click peak dwarfs its own lead-in noise
(ratio commonly 10-25x in this source); a decay-tail retrigger or ambient
bump does not (commonly <4x). MIN_TRANSIENT_RATIO below is the cut.

Each cue's label is the hit's 0..1 strength as plain text ("0.734"), which
WwiseAudio::MarkerCallback (wwise_audio.cpp) parses back out at runtime --
this is how a marker hit gets a variable raindrop size instead of a fixed one.

MIN_STRENGTH below drops the quiet end of that same distribution before any
cue is ever written, so "only the loud plucks" isn't something the app has to
filter live -- a hit that made it into the bank was already loud enough to
want a drop.
"""
import struct
import sys
import wave

import numpy as np

IN_PATH = "/Users/erichan/Documents/Development/jardins_racine/WwiseProject/Originals/SFX/NHU05008080.wav"

HOP = 64
SENSITIVITY = 2.5
FLOOR_DB = -50.0       # tighter than the plugin default (-60): this source's
                       # own noise floor sits close to -60, so -60 fired on it
MIN_RISE_DB = 2.0
MIN_INTERVAL_MS = 120.0
WINDOW_MS = 1000.0
ATTACK_MS = 1.0
RELEASE_MS = 60.0

# Hits below this normalized strength (see detect_onsets' `strength`, 0..1
# across floorDb..0 dBFS) are dropped before the cue chunk is ever written --
# "very loud plucks only". Print the full distribution below and re-run with
# a higher number if too much still gets through, or lower if too little does.
MIN_STRENGTH = 0.35

# See transient_ratio() docstring above for what this measures and why.
# Set to 0 (disabled) -- an amplitude filter at the Wwise program level now
# does this job at playback time, so decay-tail retriggers no longer need to
# be filtered out of the marker set itself.
TRANSIENT_PRE_MS = 50.0
TRANSIENT_POST_MS = 30.0
MIN_TRANSIENT_RATIO = 0.0


def coeff(ms, dt):
    return 0.0 if ms <= 0.0 else np.exp(-dt / (ms * 0.001))


def transient_ratio(mono, sr, offset, pre_ms=TRANSIENT_PRE_MS, post_ms=TRANSIENT_POST_MS):
    pre = mono[max(0, offset - int(pre_ms * 0.001 * sr)):offset]
    post = mono[offset:offset + int(post_ms * 0.001 * sr)]
    pre_rms = np.sqrt(np.mean(pre.astype(np.float64) ** 2)) if len(pre) else 0.0
    post_peak = np.max(np.abs(post)) if len(post) else 0.0
    return float(post_peak / (pre_rms + 1e-9))


def detect_onsets(mono, sr, params=None, debug=False):
    p = dict(
        sensitivity=SENSITIVITY, floor_db=FLOOR_DB, min_rise_db=MIN_RISE_DB,
        min_interval_ms=MIN_INTERVAL_MS, window_ms=WINDOW_MS,
        attack_ms=ATTACK_MS, release_ms=RELEASE_MS,
        transient_pre_ms=TRANSIENT_PRE_MS, transient_post_ms=TRANSIENT_POST_MS,
        min_transient_ratio=MIN_TRANSIENT_RATIO,
    )
    if params:
        p.update(params)

    n_hops = len(mono) // HOP
    hop_seconds = HOP / sr
    atk = coeff(p["attack_ms"], hop_seconds)
    rel = coeff(p["release_ms"], hop_seconds)
    hist_len = max(8, min(8192, int(p["window_ms"] * 0.001 * sr / HOP)))

    history = np.zeros(hist_len, dtype=np.float64)
    hist_pos = 0
    hist_filled = 0
    running_sum = 0.0
    running_sumsq = 0.0

    env = 0.0
    prev_db = -200.0

    candidates = []  # (sample_offset, strength) -- every hop clearing the bar

    frames = mono[: n_hops * HOP].reshape(n_hops, HOP)
    rms = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))

    if debug:
        db_trace = np.empty(n_hops)
        odf_trace = np.empty(n_hops)
        thr_trace = np.empty(n_hops)

    for i in range(n_hops):
        r = rms[i]
        c = atk if r > env else rel
        env = c * env + (1.0 - c) * r
        db = 20.0 * np.log10(env + 1e-9)
        rise = 0.0 if prev_db <= -199.0 else (db - prev_db)
        prev_db = db
        odf = rise if rise > 0.0 else 0.0

        mean = running_sum / hist_filled if hist_filled else 0.0
        if hist_filled >= 2:
            var = running_sumsq / hist_filled - mean * mean
            sd = np.sqrt(var) if var > 0.0 else 0.0
        else:
            sd = 0.0
        thr = max(mean + p["sensitivity"] * sd, p["min_rise_db"])

        # push history (fixed-size ring, running sums -- matches PushHistory)
        old = history[hist_pos]
        if hist_filled == hist_len:
            running_sum -= old
            running_sumsq -= old * old
        else:
            hist_filled += 1
        history[hist_pos] = odf
        running_sum += odf
        running_sumsq += odf * odf
        hist_pos = (hist_pos + 1) % hist_len

        loud_enough = db > p["floor_db"]
        cleared_bar = odf > thr
        if loud_enough and cleared_bar:
            span = max(-p["floor_db"], 1.0)
            strength = np.clip((db - p["floor_db"]) / span, 0.0, 1.0)
            candidates.append((i * HOP, float(strength)))

        if debug:
            db_trace[i] = db
            odf_trace[i] = odf
            thr_trace[i] = thr

    survivors = suppress_neighbors(candidates, sr, p["min_interval_ms"])
    hits = [
        (off, strength) for off, strength in survivors
        if transient_ratio(mono, sr, off, p["transient_pre_ms"], p["transient_post_ms"])
        >= p["min_transient_ratio"]
    ]

    if debug:
        return hits, {
            "db": db_trace, "odf": odf_trace, "thr": thr_trace, "hop": HOP,
            "candidates": candidates, "survivors": survivors,
        }
    return hits


def suppress_neighbors(candidates, sr, min_interval_ms):
    """Greedy non-max suppression: repeatedly take the strongest remaining
    candidate and drop every other candidate within min_interval_ms of it,
    so a loud onset can no longer be swallowed by a weaker one that happened
    to fire microseconds earlier (the old fixed refractory-from-last-hit gate
    did exactly that -- see NHU05008080.wav at 10.169s/10.210s)."""
    if not candidates:
        return []
    min_interval_samples = min_interval_ms * 0.001 * sr
    remaining = sorted(candidates, key=lambda c: c[0])
    offsets = np.array([c[0] for c in remaining], dtype=np.float64)
    strengths = np.array([c[1] for c in remaining], dtype=np.float64)
    alive = np.ones(len(remaining), dtype=bool)

    order = np.argsort(-strengths)  # strongest first
    kept = []
    for idx in order:
        if not alive[idx]:
            continue
        kept.append((int(offsets[idx]), float(strengths[idx])))
        alive &= np.abs(offsets - offsets[idx]) > min_interval_samples
        alive[idx] = False

    kept.sort(key=lambda h: h[0])
    return kept


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


def main():
    mono, sr = read_wav_mono(IN_PATH)
    all_hits = detect_onsets(mono, sr)
    print(f"{len(all_hits)} onsets detected over {len(mono)/sr:.1f}s "
          f"({len(all_hits)/(len(mono)/sr):.2f}/s)")
    if not all_hits:
        print("no onsets found -- aborting, leaving the file untouched")
        sys.exit(1)

    strengths = np.array([s for _off, s in all_hits])
    pct = np.percentile(strengths, [10, 25, 50, 75, 90, 99])
    print(f"strength distribution: min {strengths.min():.2f}  "
          f"p10 {pct[0]:.2f}  p25 {pct[1]:.2f}  median {pct[2]:.2f}  "
          f"p75 {pct[3]:.2f}  p90 {pct[4]:.2f}  p99 {pct[5]:.2f}  "
          f"max {strengths.max():.2f}")

    hits = [(off, s) for off, s in all_hits if s >= MIN_STRENGTH]
    print(f"MIN_STRENGTH={MIN_STRENGTH}: keeping {len(hits)}/{len(all_hits)} onsets "
          f"({len(hits)/(len(mono)/sr):.2f}/s)")
    if not hits:
        print("MIN_STRENGTH filtered out everything -- aborting, "
              "leaving the file untouched; lower MIN_STRENGTH and re-run")
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

    out += build_cue_chunk(hits, sr)
    out += build_list_adtl_chunk(hits)

    riff_size = len(out) - 8
    out[4:8] = struct.pack("<I", riff_size)

    with open(IN_PATH, "wb") as f:
        f.write(out)

    print(f"wrote {len(hits)} cue markers into {IN_PATH}")
    print("first 10 (sample offset, strength):",
          [(s, round(st, 2)) for s, st in hits[:10]])


if __name__ == "__main__":
    main()
