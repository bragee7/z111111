#!/usr/bin/env python3
"""
Compare the CURRENT bundled model (gigaspeech BPE, chunk-16, 320 ms) with the
NEW candidate (zh-en-3M 2025-12-20, phone tokens, chunk-8, 160 ms).

Both run the same clip set and the same trigger phrase, so the numbers are
directly comparable.

Usage: python kws_bench_models.py <old_model_dir> <new_model_dir> <wav_dir>
"""
import os
import sys
import glob
import wave

import numpy as np
import sherpa_onnx

OLD_DIR, NEW_DIR, WAV_DIR = sys.argv[1], sys.argv[2], sys.argv[3]

CFG = dict(keywords_score=0.7, keywords_threshold=0.10, num_trailing_blanks=1)


def build(model_dir, enc, dec, joi, kw_line):
    kf = os.path.join(WAV_DIR, "_kw_%s.txt" % os.path.basename(model_dir))
    with open(kf, "w", encoding="utf-8") as f:
        f.write(kw_line + " :%.2f #%.2f\n" % (CFG["keywords_score"], CFG["keywords_threshold"]))
    return sherpa_onnx.KeywordSpotter(
        tokens=os.path.join(model_dir, "tokens.txt"),
        encoder=os.path.join(model_dir, enc),
        decoder=os.path.join(model_dir, dec),
        joiner=os.path.join(model_dir, joi),
        num_threads=2, provider="cpu",
        keywords_file=kf,
        keywords_score=CFG["keywords_score"],
        keywords_threshold=CFG["keywords_threshold"],
        num_trailing_blanks=CFG["num_trailing_blanks"],
        max_active_paths=4,
    )


def decode_hit(spotter, path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
    data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if sr != 16000:
        idx = np.linspace(0, len(data) - 1, int(len(data) * 16000 / sr))
        data = np.interp(idx, np.arange(len(data)), data).astype(np.float32)
    st = spotter.create_stream()
    st.accept_waveform(16000, data)
    while spotter.is_ready(st):
        spotter.decode_stream(st)
        if spotter.get_result(st):
            return True, len(data) / 16000.0
    return False, len(data) / 16000.0


def run(label, spotter, positives, negatives):
    tp = fp = 0
    neg_s = 0.0
    for p in positives:
        hit, _ = decode_hit(spotter, p)
        tp += 1 if hit else 0
    for p in negatives:
        hit, s = decode_hit(spotter, p)
        neg_s += s
        fp += 1 if hit else 0
    print("  %-34s recall %6.1f%%   FA %d / %.0fs  (%.1f/hr)"
          % (label, 100.0 * tp / len(positives), fp, neg_s,
             (fp / neg_s) * 3600 if neg_s else 0))


pos = sorted(glob.glob(os.path.join(WAV_DIR, "pos_*.wav")))
neg = sorted(glob.glob(os.path.join(WAV_DIR, "neg_*.wav")))
print("positives: %d   negatives: %d" % (len(pos), len(neg)))
print("=" * 78)

old = build(OLD_DIR,
            "encoder-epoch-12-avg-2-chunk-16-left-64.onnx",
            "decoder-epoch-12-avg-2-chunk-16-left-64.onnx",
            "joiner-epoch-12-avg-2-chunk-16-left-64.onnx",
            "\u2581HELP \u2581ME")
run("OLD gigaspeech BPE chunk-16 (320ms)", old, pos, neg)

new = build(NEW_DIR,
            "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
            "decoder-epoch-13-avg-2-chunk-8-left-64.onnx",
            "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
            "HH EH1 L P M IY1")
run("NEW zh-en-3M phone chunk-8 (160ms)", new, pos, neg)

# the new model must also understand a phone-tokenised "EMERGENCY"
new2 = build(NEW_DIR,
             "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
             "decoder-epoch-13-avg-2-chunk-8-left-64.onnx",
             "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
             "IH0 M ER1 JH AH0 N S IY0")
run("NEW zh-en-3M phone EMERGENCY", new2, pos, neg)
print("=" * 78)
