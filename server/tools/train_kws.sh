#!/usr/bin/env bash
# train_kws.sh — fine-tune the gigaspeech KWS checkpoint on a "Help me" set.
#
# Run on a machine with a CUDA GPU (Colab T4 is plenty).
# Time: ~20 min for 5 epochs on a T4.
#
# Usage:
#   bash train_kws.sh --data-dir /path/to/kws_dataset --exp-dir /path/to/kws_exp \
#        --checkpoint /path/to/icefall-kws-zipformer-gigaspeech-20240219.tar.gz

set -eou pipefail
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

data_dir=""
exp_dir=""
checkpoint=""
stage=0
stop_stage=100

. shared/parse_options.sh 2>/dev/null || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)   data_dir="$2"; shift 2 ;;
    --exp-dir)    exp_dir="$2"; shift 2 ;;
    --checkpoint) checkpoint="$2"; shift 2 ;;
    --stage)      stage="$2"; shift 2 ;;
    --stop-stage) stop_stage="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$data_dir" || -z "$exp_dir" || -z "$checkpoint" ]] && {
  echo "missing --data-dir / --exp-dir / --checkpoint"; exit 1; }

export PYTHONPATH=/content/icefall:$PYTHONPATH
export CUDA_VISIBLE_DEVICES="0"

if [ "$stage" -le 0 ] && [ "$stop_stage" -ge 0 ]; then
  echo "Stage 0: fine-tune from the published checkpoint"
  python /content/icefall/egs/gigaspeech/KWS/zipformer/train.py \
      --world-size 1 --exp-dir "$exp_dir" \
      --decoder-dim 320 --joiner-dim 320 \
      --num-encoder-layers 1,1,1,1,1,1 \
      --feedforward-dim 192,192,192,192,192,192 \
      --encoder-dim 128,128,128,128,128,128 \
      --encoder-unmasked-dim 128,128,128,128,128,128 \
      --num-epochs 5 --lr-epochs 3 --use-fp16 1 --start-epoch 1 \
      --subset custom --data-dir "$data_dir/data" \
      --bpe-model data/lang_bpe_500/bpe.model \
      --causal 1 --max-duration 1000 \
      --pretrained-ckpt "$checkpoint"
fi

if [ "$stage" -le 1 ] && [ "$stop_stage" -ge 1 ]; then
  echo "Stage 1: export to ONNX"
  python /content/icefall/egs/gigaspeech/KWS/zipformer/export.py \
      --epoch 5 --avg 2 --exp-dir "$exp_dir" \
      --tokens data/lang_bpe_500/tokens.txt \
      --causal 1 --chunk-size 16 --left-context-frames 64 \
      --decoder-dim 320 --joiner-dim 320 \
      --num-encoder-layers 1,1,1,1,1,1 \
      --feedforward-dim 192,192,192,192,192,192 \
      --encoder-dim 128,128,128,128,128,128 \
      --encoder-unmasked-dim 128,128,128,128,128,128
  python /content/icefall/egs/gigaspeech/KWS/zipformer/export-onnx-streaming.py \
      --exp-dir "$exp_dir" --tokens data/lang_bpe_500/tokens.txt \
      --epoch 5 --avg 2 --chunk-size 16 --left-context-frames 128 \
      --decoder-dim 320 --joiner-dim 320 \
      --num-encoder-layers 1,1,1,1,1,1 \
      --feedforward-dim 192,192,192,192,192,192 \
      --encoder-dim 128,128,128,128,128,128 \
      --encoder-unmasked-dim 128,128,128,128,128,128 --causal 1
fi

echo "done. ONNX files are in $exp_dir/exported/"
