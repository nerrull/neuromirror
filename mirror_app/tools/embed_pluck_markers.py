#!/usr/bin/env python3
"""Detect crackle onsets in the FirePlucker source and embed them as WAV cue
markers, so Wwise picks them up as Markers on re-import and the mirror app
can react to Play_FirePlucker's AK_Marker notifications.

Onset detector is a direct Python port of mi::OnsetDetector
(wwise_plugins/mi_common/onset_detector.h): thr = mean(rise) + sensitivity *
stddev(rise) over a rolling window of the envelope's per-hop dB rise, with a
floor, a minimum rise, and a refractory period. Ported rather than reused so
this script has no build dependency, but every constant and the control flow
match the header -- see it for why each guard exists.

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
MIN_STRENGTH = 0.5


def coeff(ms, dt):
    return 0.0 if ms <= 0.0 else np.exp(-dt / (ms * 0.001))


def detect_onsets(mono, sr):
    n_hops = len(mono) // HOP
    hop_seconds = HOP / sr
    atk = coeff(ATTACK_MS, hop_seconds)
    rel = coeff(RELEASE_MS, hop_seconds)
    hist_len = max(8, min(8192, int(WINDOW_MS * 0.001 * sr / HOP)))

    history = np.zeros(hist_len, dtype=np.float64)
    hist_pos = 0
    hist_filled = 0
    running_sum = 0.0
    running_sumsq = 0.0

    env = 0.0
    prev_db = -200.0
    since_hit = 1e9

    hits = []  # (sample_offset, strength)

    frames = mono[: n_hops * HOP].reshape(n_hops, HOP)
    rms = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))

    for i in range(n_hops):
        r = rms[i]
        c = atk if r > env else rel
        env = c * env + (1.0 - c) * r
        db = 20.0 * np.log10(env + 1e-9)
        rise = 0.0 if prev_db <= -199.0 else (db - prev_db)
        prev_db = db
        odf = rise if rise > 0.0 else 0.0
        since_hit += hop_seconds

        mean = running_sum / hist_filled if hist_filled else 0.0
        if hist_filled >= 2:
            var = running_sumsq / hist_filled - mean * mean
            sd = np.sqrt(var) if var > 0.0 else 0.0
        else:
            sd = 0.0
        thr = max(mean + SENSITIVITY * sd, MIN_RISE_DB)

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

        loud_enough = db > FLOOR_DB
        cleared_bar = odf > thr
        armed = since_hit >= MIN_INTERVAL_MS * 0.001
        if loud_enough and cleared_bar and armed:
            since_hit = 0.0
            span = max(-FLOOR_DB, 1.0)
            strength = np.clip((db - FLOOR_DB) / span, 0.0, 1.0)
            hits.append((i * HOP, float(strength)))

    return hits


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
