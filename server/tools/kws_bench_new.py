#!/usr/bin/env python3
"""Benchmark the 2025-12-20 zh-en model (chunk-8 int8 and chunk-16 fp32)
against the current bundled gigaspeech model, on the same clips."""
import os
import glob
import sys
import wave

import numpy as np
import sherpa_onnx

NEW = r"E:\revapk\kaaval_uthavi_full_apk\zelda1\mobile\assets\kws"
WAV = os.path.join(os.environ["TEMP"], "kws_clips")


def build(dirn, enc, dec, joi, kw, sc, th):
    kf = os.path.join(WAV, "_kw_%s_%.2f_%.2f.txt" % (os.path.basename(dirn)[:6], sc, th))
    with open(kf, "w", encoding="utf-8") as f:
        f.write("%s :%.2f #%.2f\n" % (kw, sc, th))
    return sherpa_onnx.KeywordSpotter(
        tokens=os.path.join(dirn, "tokens.txt"),
        encoder=os.path.join(dirn, enc),
        decoder=os.path.join(dirn, dec),
        joiner=os.path.join(dirn, joi),
        num_threads=2, provider="cpu", keywords_file=kf,
        keywords_score=sc, keywords_threshold=th,
        num_trailing_blanks=1, max_active_paths=4)


def hit(spotter, path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
    d = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if sr != 16000:
        idx = np.linspace(0, len(d) - 1, int(len(d) * 16000 / sr))
        d = np.interp(idx, np.arange(len(d)), d).astype(np.float32)
    st = spotter.create_stream()
    st.accept_waveform(16000, d)
    while spotter.is_ready(st):
        spotter.decode_stream(st)
        if spotter.get_result(st):
            return True, len(d) / 16000.0
    return False, len(d) / 16000.0


def run(label, spotter, pos, neg):
    tp = fp = 0
    ns = 0.0
    for p in pos:
        h, _ = hit(spotter, p)
        tp += 1 if h else 0
    for p in neg:
        h, s = hit(spotter, p)
        ns += s
        fp += 1 if h else 0
    print("  %-42s recall %6.1f%%   FA %d  (%.1f/hr)"
          % (label, 100.0 * tp / len(pos), fp, (fp / ns) * 3600 if ns else 0))


pos = sorted(glob.glob(os.path.join(WAV, "pos_*.wav")))
neg = sorted(glob.glob(os.path.join(WAV, "neg_*.wav")))
print("positives %d  negatives %d" % (len(pos), len(neg)))
print("=" * 78)

for sc, th in [(0.7, 0.10), (0.7, 0.05), (0.6, 0.05), (0.8, 0.10)]:
    s = build(NEW,
              "encoder-epoch-13-avg-2-chunk-16-left-64.onnx",
              "decoder-epoch-13-avg-2-chunk-16-left-64.onnx",
              "joiner-epoch-13-avg-2-chunk-16-left-64.onnx",
              "HH EH1 L P M IY1", sc, th)
    run("NEW 2025 chunk-16 fp32  s%.1f t%.2f" % (sc, th), s, pos, neg)

for sc, th in [(0.7, 0.05), (0.6, 0.05)]:
    s = build(NEW,
              "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
              "decoder-epoch-13-avg-2-chunk-8-left-64.onnx",
              "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
              "HH EH1 L P M IY1", sc, th)
    run("NEW 2025 chunk-8  int8   s%.1f t%.2f" % (sc, th), s, pos, neg)
print("=" * 78)
