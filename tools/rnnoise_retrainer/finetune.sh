PYTHONPATH=src python3 -m wiredeck_rnnoise_trainer.cli train-gpu \
  /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/data/normalized_speec/audio \
  /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/data/normalized_noise/me \
  /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/artifacts/gpu-run-finetune-single-noise \
  --device cuda \
  --initial-checkpoint /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/artifacts/gpu-run-finetune-single-noise/checkpoints/wiredeck_gpu_epoch_105.pt \
  --epochs 10 \
  --samples-per-epoch 2048 \
  --batch-size 16 \
  --lr 5e-5 \
  --contrib-repeat 1 \
  --synthetic-repeat 1 \
  --foreground-repeat 1 \
  --background-repeat 1 \
  --musan-repeat 1 \
  --speech-noise-repeat 1 \
  --clean-probability 0.05 \
  --noise-only-probability 0.10 \
  --snr-min-db -12 \
  --snr-max-db 8 \
  --speech-gain-min-db -24 \
  --speech-gain-max-db 3 \
  --low-speech-probability 0.5 \
  --low-speech-extra-min-db -20 \
  --low-speech-extra-max-db -6 \
  --vad-positive-snr-db 3 \
  --vad-negative-snr-db -6 \
  --vad-energy-threshold 0.02 \
  --vad-loss-weight 0.5