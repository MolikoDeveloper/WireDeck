PYTHONPATH=src python3 -m wiredeck_rnnoise_trainer.cli train-gpu \
  /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/data/normalized_speec/audio \
  /home/moliko/projects/wiredeck_2.0/tools/rnnoise_retrainer/data/normalized_noise/audio \
  ./artifacts/gpu-run-from-scratch-max \
  --device cuda \
  --epochs 100 \
  --samples-per-epoch 8192 \
  --batch-size 16 \
  --lr 2e-4 \
  --contrib-repeat 6 \
  --synthetic-repeat 6 \
  --foreground-repeat 4 \
  --background-repeat 4 \
  --musan-repeat 6 \
  --speech-noise-repeat 4 \
  --snr-min-db -10 \
  --snr-max-db 12 \
  --speech-gain-min-db -24 \
  --speech-gain-max-db 3 \
  --low-speech-probability 0.5 \
  --low-speech-extra-min-db -20 \
  --low-speech-extra-max-db -6