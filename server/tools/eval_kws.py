#!/usr/bin/env python3
"""
eval_kws.py — measure a trained KWS model on a held-out eval set.

Reports recall + false-alarm-per-hour, in the same format as icefall's
RESULTS.md, so the number is comparable to the published 97.9 % / 1.3 FA.

Usage:
  python eval_kws.py --model-dir /path/to/exported --eval-dir /path/to/eval
"""
import argparse
import json
import os
import wave
import glob

import numpy as np
import sherpa_onnx


def decode(path, spotter):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
    d = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if sr != 16000:
        i = np.linspace(0, len(d) - 1, int(len(d) * 16000 / sr))
        d = np.interp(i, np.arange(len(d)), d).astype(np.float32)
    st = spotter.create_stream()
    st.accept_waveform(16000, d)
    while spotter.is_ready(st):
        spotter.decode_stream(st)
        if spotter.get_result(st):
            return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--eval-dir", required=True)
    ap.add_argument("--keywords-file", default=None)
    args = ap.parse_args()

    md = args.model_dir
    kw_file = args.keywords_file or os.path.join(md, "keywords.txt")
    spotter = sherpa_onnx.KeywordSpotter(
        tokens=os.path.join(md, "tokens.txt"),
        encoder=os.path.join(md, "encoder.onnx"),
        decoder=os.path.join(md, "decoder.onnx"),
        joiner=os.path.join(md, "joiner.onnx"),
        num_threads=2, provider="cpu",
        keywords_file=kw_file,
        keywords_score=0.7, keywords_threshold=0.10,
        num_trailing_blanks=1, max_active_paths=4,
    )

    pos = sorted(glob.glob(os.path.join(args.eval_dir, "pos_*.wav")))
    neg = sorted(glob.glob(os.path.join(args.eval_dir, "neg_*.wav")))
    if not pos or not neg:
        print("need pos_*.wav and neg_*.wav in", args.eval_dir)
        sys.exit(2)

    tp = fp = 0
    neg_s = 0.0
    misses = []
    fps = []
    for p in pos:
        if decode(p, spotter):
            tp += 1
        else:
            misses.append(os.path.basename(p))
    for p in neg:
        h = decode(p, spotter)
        neg_s += os.path.getsize(p) / (16000 * 2)  # approx
        if h:
            fp += 1
            fps.append(os.path.basename(p))

    recall = 100.0 * tp / len(pos)
    fa_hr = (fp / neg_s) * 3600.0 if neg_s else 0.0
    print("=" * 60)
    print("  positives : %d   negatives : %d" % (len(pos), len(neg)))
    print("  recall    : %.1f%%  (%d/%d)" % (recall, tp, len(pos)))
    print("  false alarm rate : %.2f / hour  (%d in %.0f s)" % (fa_hr, fp, neg_s))
    print("  missed    : %s" % (", ".join(misses) if misses else "none"))
    print("  false-fired on : %s" % (", ".join(fps) if fps else "none"))
    print("=" * 60)

    gate_ok = recall >= 95.0 and fa_hr <= 0.3
    print("  GATE: %s" % ("PASS" if gate_ok else "FAIL (recall<95 or FA>0.3/hr)"))
    sys.exit(0 if gate_ok else 1)


if __name__ == "__main__":
    main()
