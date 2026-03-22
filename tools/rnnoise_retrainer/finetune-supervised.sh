PYTHONPATH=src python3 -m wiredeck_rnnoise_trainer.cli train-gpu \
  /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/data/normalized_speec/audio \
  /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/data/normalized_noise/audio \
  /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/artifacts/gpu-finetune-rt-medium \
  --device cuda \
  --initial-checkpoint /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/artifacts/gpu-run-finetune-single-noise/checkpoints/wiredeck_gpu_epoch_115.pt \
  --epochs 8 \
  --samples-per-epoch 4096 \
  --batch-size 6 \
  --lr 2e-5 \
  --channels 48 \
  --hidden-channels 86 \
  --residual-blocks 4 \
  --kernel-time 5 \
  --kernel-freq 3 \
  --lookahead-frames 1 \
  --contrib-repeat 1 \
  --synthetic-repeat 1 \
  --foreground-repeat 1 \
  --background-repeat 1 \
  --musan-repeat 1 \
  --speech-noise-repeat 2 \
  --clean-probability 0.10 \
  --noise-only-probability 0.10 \
  --snr-min-db -10 \
  --snr-max-db 12 \
  --speech-gain-min-db -18 \
  --speech-gain-max-db 3 \
  --low-speech-probability 0.30 \
  --low-speech-extra-min-db -12 \
  --low-speech-extra-max-db -4 \
  --vad-positive-snr-db 3 \
  --vad-negative-snr-db -6 \
  --vad-energy-threshold 0.02 \
  --vad-loss-weight 0.35 \
  --clip-seconds 6

