#!/usr/bin/env python3
"""
Measure the REAL sherpa-onnx KWS on the REAL bundled model, with the exact
keyword buffer the app builds.

Compares the OLD tuning (score 1.0 / threshold 0.25 / trailing blanks 1) with
the NEW tuning (score 1.6 / threshold 0.15 / trailing blanks 2) on:
  * positives  - "Help me" at several loudness levels
  * negatives  - near-miss speech ("help" alone, "she helped me", ...), other
                 speech, and noise

Reports recall % and false alarms per hour, exactly like the icefall
RESULTS.md methodology.

Usage:  python kws_bench.py <model_dir> <wav_dir>
"""
import os
import sys
import wave
import glob
import math
import random

import numpy as np
import sherpa_onnx

MODEL_DIR = sys.argv[1]
WAV_DIR = sys.argv[2]

OLD = dict(keywords_score=1.0, keywords_threshold=0.25, num_trailing_blanks=1)
NEW = dict(keywords_score=1.6, keywords_threshold=0.15, num_trailing_blanks=2)

KEYWORD = "\u2581HELP \u2581ME"


def make_spotter(cfg, token_string=None):
    # The Python API takes a keywords FILE (the Dart API takes a buffer); the
    # file format is the same one the app builds at runtime, including the
    # per-keyword ":score #threshold" suffix.
    line = "%s :%.2f #%.2f" % (token_string or KEYWORD, cfg["keywords_score"],
                               cfg["keywords_threshold"])
    kf = os.path.join(WAV_DIR, "_kw_%s.txt" % ("old" if cfg is OLD else "new"))
    with open(kf, "w", encoding="utf-8") as f:
        f.write(line + "\n")
    return sherpa_onnx.KeywordSpotter(
        tokens=os.path.join(MODEL_DIR, "tokens.txt"),
        encoder=os.path.join(MODEL_DIR, "encoder-epoch-12-avg-2-chunk-16-left-64.onnx"),
        decoder=os.path.join(MODEL_DIR, "decoder-epoch-12-avg-2-chunk-16-left-64.onnx"),
        joiner=os.path.join(MODEL_DIR, "joiner-epoch-12-avg-2-chunk-16-left-64.onnx"),
        num_threads=2,
        provider="cpu",
        keywords_file=kf,
        keywords_score=cfg["keywords_score"],
        keywords_threshold=cfg["keywords_threshold"],
        num_trailing_blanks=cfg["num_trailing_blanks"],
        max_active_paths=4,
    )


def decode_hits(spotter, path):
    """Decode a wav, return True if the keyword fired."""
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        n = w.getnframes()
        raw = w.readframes(n)
    data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if sr != 16000:
        # simple linear resample
        idx = np.linspace(0, len(data) - 1, int(len(data) * 16000 / sr))
        data = np.interp(idx, np.arange(len(data)), data).astype(np.float32)
    stream = spotter.create_stream()
    # Canonical sherpa-onnx pattern: feed the whole utterance, then decode
    # every ready step. The model does its own chunking internally.
    stream.accept_waveform(16000, data)
    hit = False
    while spotter.is_ready(stream):
        spotter.decode_stream(stream)
        if spotter.get_result(stream):
            hit = True
            break
    return hit, len(data) / 16000.0


CONFIGS = [
    ("app cfg  s0.7 t0.10 b1", dict(keywords_score=0.7, keywords_threshold=0.10, num_trailing_blanks=1)),
    ("APP SHIPPED HELP ME", dict(keywords_score=0.7, keywords_threshold=0.10, num_trailing_blanks=1), "\u2581HELP \u2581ME"),
    ("APP SHIPPED EMERGENCY", dict(keywords_score=0.7, keywords_threshold=0.10, num_trailing_blanks=1), "\u2581E M ER G EN C Y"),
    ("old default 1.0/0.25", dict(keywords_score=1.0, keywords_threshold=0.25, num_trailing_blanks=1)),
]


def main():
    positives = sorted(glob.glob(os.path.join(WAV_DIR, "pos_*.wav")))
    negatives = sorted(glob.glob(os.path.join(WAV_DIR, "neg_*.wav")))
    if not positives or not negatives:
        print("need pos_*.wav and neg_*.wav in", WAV_DIR)
        sys.exit(2)

    print("%-24s %8s %6s %10s" % ("config", "recall", "FA", "FA/hour"))
    print("-" * 54)
    for entry in CONFIGS:
        label, cfg = entry[0], entry[1]
        tok = entry[2] if len(entry) > 2 else None
        spotter = make_spotter(cfg, tok)
        tp = fp = 0
        neg_secs = 0.0
        misses = []
        fps = []
        for p in positives:
            hit, _ = decode_hits(spotter, p)
            if hit:
                tp += 1
            else:
                misses.append(os.path.basename(p))
        for p in negatives:
            hit, secs = decode_hits(spotter, p)
            neg_secs += secs
            if hit:
                fp += 1
                fps.append(os.path.basename(p))
        recall = 100.0 * tp / len(positives)
        fa_hr = (fp / neg_secs) * 3600.0 if neg_secs else 0.0
        print("%-24s %7.1f%% %6d %9.1f" % (label, recall, fp, fa_hr))
        if misses:
            print("      missed: %s" % ", ".join(misses))
        if fps:
            print("      FA on : %s" % ", ".join(fps))
    print("=" * 54)


if __name__ == "__main__":
    main()
