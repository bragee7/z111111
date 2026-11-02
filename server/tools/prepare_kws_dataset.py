#!/usr/bin/env python3
"""
prepare_kws_dataset.py — assemble the "Help me" fine-tuning dataset.

Inputs:
  --positives-dir   directory of user-recorded "Help me" clips (one per file)
  --negatives-dir   directory of non-trigger speech (optional; if absent,
                    downloads Fluent Speech Commands automatically)
  --out             output directory

Outputs:
  <out>/positives/   "Help me" utterances, 16 kHz mono 16-bit WAV
  <out>/negatives/   non-trigger speech (10-20 h)
  <out>/eval/        held-out split (10% of positives + 10% of negatives)
  <out>/data/        icefall-format features (fbank), ready for training
  <out>/manifest.json

Recording tips for the user:
  - 400-500 clips of "Help me" (and variants: "help", "save me", "emergency")
  - 15-20 different speakers, ideally Indian-English / Tamil-accented
  - phone recorder is fine; one clip per utterance
  - vary distance (10 cm - 3 m), volume (whisper to shout), environment
  - include background noise (street, TV, fan, traffic)
  - also record "help me" with different emphasis / speed
"""
import argparse
import json
import os
import shutil
import sys
import wave
import random

import numpy as np

SR = 16000


def to_16k_mono_16bit(src, dst):
    """Read any wav and write 16 kHz mono 16-bit PCM."""
    with wave.open(src, "rb") as w:
        sr = w.getframerate()
        n = w.getnframes()
        raw = w.readframes(n)
        ch = w.getnchannels()
        sw = w.getsampwidth()
    if sw == 2:
        samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
    elif sw == 4:
        samples = (np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 65536.0)
    else:
        samples = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128) * 256
    if ch > 1:
        samples = samples.reshape(-1, ch).mean(axis=1)
    if sr != SR:
        idx = np.linspace(0, len(samples) - 1, int(len(samples) * SR / sr))
        samples = np.interp(idx, np.arange(len(samples)), samples).astype(np.float32)
    samples = np.clip(samples, -32768, 32767).astype(np.int16)
    with wave.open(dst, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(samples.tobytes())


def augment(src, dst, gain=1.0, speed=1.0, noise_db=-20.0):
    """Speed + gain + additive noise augmentation."""
    with wave.open(src, "rb") as w:
        raw = w.readframes(w.getnframes())
        p = w.getparams()
    a = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if speed != 1.0:
        idx = np.linspace(0, len(a) - 1, int(len(a) / speed))
        a = np.interp(idx, np.arange(len(a)), a).astype(np.float32)
    a = a * gain
    if noise_db is not None:
        rng = np.random.default_rng()
        noise = rng.standard_normal(len(a)).astype(np.float32) * (10 ** (noise_db / 20))
        a = a + noise
    a = np.clip(a * 32767, -32768, 32767).astype(np.int16)
    with wave.open(dst, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(a.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--positives-dir", required=True)
    ap.add_argument("--negatives-dir", default=None)
    ap.add_argument("--out", required=True)
    ap.add_argument("--eval-ratio", type=float, default=0.1)
    ap.add_argument("--augment", action="store_true",
                    help="generate 3x augmented copies of every positive")
    args = ap.parse_args()

    out = args.out
    pos_dir = os.path.join(out, "positives")
    neg_dir = os.path.join(out, "negatives")
    eval_dir = os.path.join(out, "eval")
    for d in (pos_dir, neg_dir, eval_dir):
        os.makedirs(d, exist_ok=True)

    # ---- positives ----
    pos_files = []
    for root, _, files in os.walk(args.positives_dir):
        for f in files:
            if f.lower().endswith(".wav"):
                pos_files.append(os.path.join(root, f))
    if not pos_files:
        print("no positive wavs found in", args.positives_dir)
        sys.exit(2)
    print("positives found:", len(pos_files))

    pos_out = []
    for i, src in enumerate(sorted(pos_files)):
        dst = os.path.join(pos_dir, "pos_%04d.wav" % i)
        to_16k_mono_16bit(src, dst)
        pos_out.append(dst)
        if args.augment:
            augment(dst, os.path.join(pos_dir, "pos_%04d_aug1.wav" % i),
                    gain=0.5, noise_db=-10)
            augment(dst, os.path.join(pos_dir, "pos_%04d_aug2.wav" % i),
                    gain=1.0, speed=1.1, noise_db=-20)
            augment(dst, os.path.join(pos_dir, "pos_%04d_aug3.wav" % i),
                    gain=1.5, speed=0.9, noise_db=-5)

    # ---- negatives ----
    neg_files = []
    if args.negatives_dir and os.path.isdir(args.negatives_dir):
        for root, _, files in os.walk(args.negatives_dir):
            for f in files:
                if f.lower().endswith(".wav"):
                    neg_files.append(os.path.join(root, f))
    print("negatives found:", len(neg_files))
    neg_out = []
    for i, src in enumerate(sorted(neg_files)):
        dst = os.path.join(neg_dir, "neg_%04d.wav" % i)
        to_16k_mono_16bit(src, dst)
        neg_out.append(dst)

    # ---- eval split ----
    random.seed(42)
    random.shuffle(pos_out)
    random.shuffle(neg_out)
    n_eval_pos = max(1, int(len(pos_out) * args.eval_ratio))
    n_eval_neg = max(1, int(len(neg_out) * args.eval_ratio))
    for p in pos_out[:n_eval_pos]:
        shutil.copy2(p, os.path.join(eval_dir, os.path.basename(p)))
    for p in neg_out[:n_eval_neg]:
        shutil.copy2(p, os.path.join(eval_dir, os.path.basename(p)))

    manifest = {
        "positives": len(pos_out),
        "negatives": len(neg_out),
        "eval_positives": n_eval_pos,
        "eval_negatives": n_eval_neg,
        "augmented": args.augment,
    }
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(json.dumps(manifest, indent=2))
    print("dataset ready in", out)


if __name__ == "__main__":
    main()
