#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

SPEECH_DIR=${SPEECH_DIR:-"$SCRIPT_DIR/data/normalized_speec/audio"}
NOISE_DIR=${NOISE_DIR:-"$SCRIPT_DIR/data/normalized_noise/audio"}
OUTPUT_DIR=${OUTPUT_DIR:-"$SCRIPT_DIR/artifacts/gpu-supervised-run"}
INITIAL_CHECKPOINT=${INITIAL_CHECKPOINT:-}
PREVIEW_AUDIO=${PREVIEW_AUDIO:-}

EPOCHS=${EPOCHS:-24}
SAMPLES_PER_EPOCH=${SAMPLES_PER_EPOCH:-4096}
BATCH_SIZE=${BATCH_SIZE:-16}
LR=${LR:-5e-5}
CLIP_SECONDS=${CLIP_SECONDS:-4}

CHANNELS=${CHANNELS:-40}
HIDDEN_CHANNELS=${HIDDEN_CHANNELS:-80}
RESIDUAL_BLOCKS=${RESIDUAL_BLOCKS:-4}
KERNEL_TIME=${KERNEL_TIME:-5}
KERNEL_FREQ=${KERNEL_FREQ:-3}
LOOKAHEAD_FRAMES=${LOOKAHEAD_FRAMES:-1}

CONTRIB_REPEAT=${CONTRIB_REPEAT:-1}
SYNTHETIC_REPEAT=${SYNTHETIC_REPEAT:-1}
FOREGROUND_REPEAT=${FOREGROUND_REPEAT:-1}
BACKGROUND_REPEAT=${BACKGROUND_REPEAT:-1}
MUSAN_REPEAT=${MUSAN_REPEAT:-1}
SPEECH_NOISE_REPEAT=${SPEECH_NOISE_REPEAT:-3}

CLEAN_PROBABILITY=${CLEAN_PROBABILITY:-0.18}
NOISE_ONLY_PROBABILITY=${NOISE_ONLY_PROBABILITY:-0.10}
SNR_MIN_DB=${SNR_MIN_DB:--8}
SNR_MAX_DB=${SNR_MAX_DB:-12}
SPEECH_GAIN_MIN_DB=${SPEECH_GAIN_MIN_DB:--18}
SPEECH_GAIN_MAX_DB=${SPEECH_GAIN_MAX_DB:-3}
LOW_SPEECH_PROBABILITY=${LOW_SPEECH_PROBABILITY:-0.25}
LOW_SPEECH_EXTRA_MIN_DB=${LOW_SPEECH_EXTRA_MIN_DB:--12}
LOW_SPEECH_EXTRA_MAX_DB=${LOW_SPEECH_EXTRA_MAX_DB:--4}
VAD_POSITIVE_SNR_DB=${VAD_POSITIVE_SNR_DB:-3}
VAD_NEGATIVE_SNR_DB=${VAD_NEGATIVE_SNR_DB:--6}
VAD_ENERGY_THRESHOLD=${VAD_ENERGY_THRESHOLD:-0.02}
VAD_LOSS_WEIGHT=${VAD_LOSS_WEIGHT:-0.30}
STATE_LOSS_WEIGHT=${STATE_LOSS_WEIGHT:-0.08}
STATE_NOISE_ENERGY_THRESHOLD=${STATE_NOISE_ENERGY_THRESHOLD:-0.01}
STATE_SPEECH_DOMINANT_SNR_DB=${STATE_SPEECH_DOMINANT_SNR_DB:-6}
STATE_NOISE_DOMINANT_SNR_DB=${STATE_NOISE_DOMINANT_SNR_DB:--3}

EXTRA_ARGS=${EXTRA_ARGS:-}

set -- \
  python3 -m wiredeck_rnnoise_trainer.cli train-gpu-supervised \
  "$SPEECH_DIR" \
  "$NOISE_DIR" \
  "$OUTPUT_DIR" \
  --device cuda \
  --epochs "$EPOCHS" \
  --samples-per-epoch "$SAMPLES_PER_EPOCH" \
  --batch-size "$BATCH_SIZE" \
  --lr "$LR" \
  --clip-seconds "$CLIP_SECONDS" \
  --channels "$CHANNELS" \
  --hidden-channels "$HIDDEN_CHANNELS" \
  --residual-blocks "$RESIDUAL_BLOCKS" \
  --kernel-time "$KERNEL_TIME" \
  --kernel-freq "$KERNEL_FREQ" \
  --lookahead-frames "$LOOKAHEAD_FRAMES" \
  --contrib-repeat "$CONTRIB_REPEAT" \
  --synthetic-repeat "$SYNTHETIC_REPEAT" \
  --foreground-repeat "$FOREGROUND_REPEAT" \
  --background-repeat "$BACKGROUND_REPEAT" \
  --musan-repeat "$MUSAN_REPEAT" \
  --speech-noise-repeat "$SPEECH_NOISE_REPEAT" \
  --clean-probability "$CLEAN_PROBABILITY" \
  --noise-only-probability "$NOISE_ONLY_PROBABILITY" \
  --snr-min-db "$SNR_MIN_DB" \
  --snr-max-db "$SNR_MAX_DB" \
  --speech-gain-min-db "$SPEECH_GAIN_MIN_DB" \
  --speech-gain-max-db "$SPEECH_GAIN_MAX_DB" \
  --low-speech-probability "$LOW_SPEECH_PROBABILITY" \
  --low-speech-extra-min-db "$LOW_SPEECH_EXTRA_MIN_DB" \
  --low-speech-extra-max-db "$LOW_SPEECH_EXTRA_MAX_DB" \
  --no-noise-amplify \
  --vad-positive-snr-db "$VAD_POSITIVE_SNR_DB" \
  --vad-negative-snr-db "$VAD_NEGATIVE_SNR_DB" \
  --vad-energy-threshold "$VAD_ENERGY_THRESHOLD" \
  --vad-loss-weight "$VAD_LOSS_WEIGHT" \
  --state-loss-weight "$STATE_LOSS_WEIGHT" \
  --state-noise-energy-threshold "$STATE_NOISE_ENERGY_THRESHOLD" \
  --state-speech-dominant-snr-db "$STATE_SPEECH_DOMINANT_SNR_DB" \
  --state-noise-dominant-snr-db "$STATE_NOISE_DOMINANT_SNR_DB"

if [ -n "$INITIAL_CHECKPOINT" ]; then
  set -- "$@" --initial-checkpoint "$INITIAL_CHECKPOINT"
fi

if [ -n "$PREVIEW_AUDIO" ]; then
  set -- "$@" --preview-audio "$PREVIEW_AUDIO"
fi

if [ -n "$EXTRA_ARGS" ]; then
  # shellcheck disable=SC2086
  set -- "$@" $EXTRA_ARGS
fi

cd "$SCRIPT_DIR"
PYTHONPATH=src "$@"
