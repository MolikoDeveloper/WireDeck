from __future__ import annotations

import json
import random
from dataclasses import asdict
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn
from torch.utils.data import DataLoader, Dataset

from wiredeck_rnnoise_trainer.gpu_infer import write_audio_mono_48k
from wiredeck_rnnoise_trainer.gpu_model import WireDeckVoiceDenoiser, WireDeckVoiceDenoiserConfig
from wiredeck_rnnoise_trainer.gpu_train import (
    _compress_to_bands,
    _load_existing_history,
    _read_segment,
    build_weighted_noise_file_list,
    choose_training_device,
    load_compatible_state_dict,
    list_wav_files,
    save_checkpoint,
)


class SupervisedNoisySpeechDataset(Dataset):
    def __init__(
        self,
        speech_files: list[Path],
        noise_files: list[Path],
        segment_samples: int,
        bands: int,
        stft_size: int,
        hop_size: int,
        samples_per_epoch: int,
        clean_probability: float,
        noise_only_probability: float,
        snr_min_db: float,
        snr_max_db: float,
        speech_gain_min_db: float,
        speech_gain_max_db: float,
        low_speech_probability: float,
        low_speech_extra_min_db: float,
        low_speech_extra_max_db: float,
        vad_positive_snr_db: float,
        vad_negative_snr_db: float,
        vad_energy_threshold: float,
        state_noise_energy_threshold: float,
        state_speech_dominant_snr_db: float,
        state_noise_dominant_snr_db: float,
        seed: int = 0,
    ) -> None:
        self.speech_files = speech_files
        self.noise_files = noise_files
        self.segment_samples = segment_samples
        self.bands = bands
        self.stft_size = stft_size
        self.hop_size = hop_size
        self.samples_per_epoch = samples_per_epoch
        self.clean_probability = clean_probability
        self.noise_only_probability = noise_only_probability
        self.snr_min_db = snr_min_db
        self.snr_max_db = snr_max_db
        self.speech_gain_min_db = speech_gain_min_db
        self.speech_gain_max_db = speech_gain_max_db
        self.low_speech_probability = low_speech_probability
        self.low_speech_extra_min_db = low_speech_extra_min_db
        self.low_speech_extra_max_db = low_speech_extra_max_db
        self.vad_positive_snr_db = vad_positive_snr_db
        self.vad_negative_snr_db = vad_negative_snr_db
        self.vad_energy_threshold = vad_energy_threshold
        self.state_noise_energy_threshold = state_noise_energy_threshold
        self.state_speech_dominant_snr_db = state_speech_dominant_snr_db
        self.state_noise_dominant_snr_db = state_noise_dominant_snr_db
        self.seed = seed
        self.window = torch.hann_window(stft_size)

    def __len__(self) -> int:
        return self.samples_per_epoch

    def _build_example(self, rng: random.Random) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        speech_path = self.speech_files[rng.randrange(len(self.speech_files))]
        noise_path = self.noise_files[rng.randrange(len(self.noise_files))]

        clean = torch.from_numpy(_read_segment(speech_path, self.segment_samples, rng))
        noise = torch.from_numpy(_read_segment(noise_path, self.segment_samples, rng))

        speech_gain_db = rng.uniform(self.speech_gain_min_db, self.speech_gain_max_db)
        if rng.random() < self.low_speech_probability:
            speech_gain_db += rng.uniform(self.low_speech_extra_min_db, self.low_speech_extra_max_db)
        speech_gain = 10.0 ** (speech_gain_db / 20.0)
        clean = clean * speech_gain

        scenario_draw = rng.random()
        if scenario_draw < self.noise_only_probability:
            clean = torch.zeros_like(clean)
        elif scenario_draw < (self.noise_only_probability + self.clean_probability):
            noise = torch.zeros_like(clean)
        else:
            target_snr_db = rng.uniform(self.snr_min_db, self.snr_max_db)
            clean_rms = clean.square().mean().sqrt().clamp_min(1.0e-4)
            noise_rms = noise.square().mean().sqrt().clamp_min(1.0e-4)
            desired_noise_rms = clean_rms / (10.0 ** (target_snr_db / 20.0))
            noise = noise * (desired_noise_rms / noise_rms)

        noisy = torch.clamp(clean + noise, -1.0, 1.0)
        clean_mag, noise_mag, noisy_mag = self._spectrogram_triplet(clean, noise, noisy)
        features = torch.log1p(noisy_mag)
        mask_target = (clean_mag / (clean_mag + noise_mag).clamp_min(1.0e-4)).clamp(0.0, 1.0)

        speech_energy = clean_mag.mean(dim=1, keepdim=True)
        noise_energy = noise_mag.mean(dim=1, keepdim=True)
        frame_snr_db = 20.0 * torch.log10(speech_energy.clamp_min(1.0e-4) / noise_energy.clamp_min(1.0e-4))
        snr_span = max(1.0e-3, self.vad_positive_snr_db - self.vad_negative_snr_db)
        vad_snr_score = ((frame_snr_db - self.vad_negative_snr_db) / snr_span).clamp(0.0, 1.0)
        vad_energy_gate = (speech_energy > self.vad_energy_threshold).to(dtype=torch.float32)
        vad_target = vad_energy_gate * vad_snr_score
        state_target = self._build_state_target(speech_energy.squeeze(1), noise_energy.squeeze(1), frame_snr_db.squeeze(1))
        return features, mask_target, vad_target, state_target, clean, noise, noisy

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        rng = random.Random(self.seed + index)
        features, mask_target, vad_target, state_target, _, _, _ = self._build_example(rng)
        return features, mask_target, vad_target, state_target

    def build_preview(self, epoch: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        rng = random.Random((self.seed * 100_003) + epoch)
        return self._build_example(rng)

    def _spectrogram_triplet(
        self,
        clean: torch.Tensor,
        noise: torch.Tensor,
        noisy: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        window = self.window
        clean_spec = torch.stft(
            clean,
            n_fft=self.stft_size,
            hop_length=self.hop_size,
            win_length=self.stft_size,
            window=window,
            center=False,
            return_complex=True,
        ).transpose(0, 1)
        noise_spec = torch.stft(
            noise,
            n_fft=self.stft_size,
            hop_length=self.hop_size,
            win_length=self.stft_size,
            window=window,
            center=False,
            return_complex=True,
        ).transpose(0, 1)
        noisy_spec = torch.stft(
            noisy,
            n_fft=self.stft_size,
            hop_length=self.hop_size,
            win_length=self.stft_size,
            window=window,
            center=False,
            return_complex=True,
        ).transpose(0, 1)
        clean_mag = _compress_to_bands(clean_spec.abs().unsqueeze(0), self.bands).squeeze(0)
        noise_mag = _compress_to_bands(noise_spec.abs().unsqueeze(0), self.bands).squeeze(0)
        noisy_mag = _compress_to_bands(noisy_spec.abs().unsqueeze(0), self.bands).squeeze(0)
        return clean_mag, noise_mag, noisy_mag

    def _build_state_target(self, speech_energy: torch.Tensor, noise_energy: torch.Tensor, frame_snr_db: torch.Tensor) -> torch.Tensor:
        speech_present = speech_energy > self.vad_energy_threshold
        noise_present = noise_energy > self.state_noise_energy_threshold
        state_target = torch.zeros_like(speech_energy, dtype=torch.long)

        speech_only = speech_present & (~noise_present | (frame_snr_db >= self.state_speech_dominant_snr_db))
        noise_only = (~speech_present) | (noise_present & (frame_snr_db <= self.state_noise_dominant_snr_db))
        mixed = speech_present & noise_present & (~speech_only) & (~noise_only)

        state_target = torch.where(speech_only, torch.ones_like(state_target), state_target)
        state_target = torch.where(mixed, torch.full_like(state_target, 2), state_target)
        return state_target


class WireDeckSupervisedVoiceDenoiser(nn.Module):
    def __init__(self, config: WireDeckVoiceDenoiserConfig | None = None, state_hidden_channels: int | None = None) -> None:
        super().__init__()
        self.base_model = WireDeckVoiceDenoiser(config)
        self.config = self.base_model.config
        state_hidden = state_hidden_channels or self.config.hidden_channels
        self.state_head = nn.Sequential(
            nn.Conv1d(
                self.config.channels,
                state_hidden,
                kernel_size=self.config.kernel_time,
                padding=self.config.kernel_time // 2,
            ),
            nn.SiLU(),
            nn.Conv1d(state_hidden, 3, kernel_size=1),
        )

    def forward(self, features: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        x = features.unsqueeze(1)
        x = self.base_model.input_proj(x)
        x = self.base_model.blocks(x)
        x = x + self.base_model.bottleneck(x)
        mask = self.base_model.mask_head(x).squeeze(1)
        vad_features = x.mean(dim=3)
        vad = self.base_model.vad_head(vad_features).transpose(1, 2)
        state_logits = self.state_head(vad_features).transpose(1, 2)
        return mask, vad, state_logits


def _tensor_rms(value: torch.Tensor) -> float:
    return float(value.square().mean().sqrt().item())


def _render_preview(
    model: WireDeckSupervisedVoiceDenoiser,
    config: WireDeckVoiceDenoiserConfig,
    device: torch.device,
    output_dir: Path,
    epoch: int,
    preview: tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor],
    *,
    stft_size: int,
    hop_size: int,
) -> dict[str, float | str]:
    features, _, _, state_target, clean, noise, noisy = preview
    preview_dir = output_dir / "epoch_audio"
    preview_dir.mkdir(parents=True, exist_ok=True)

    clean_cpu = clean.to(dtype=torch.float32).cpu()
    noise_cpu = noise.to(dtype=torch.float32).cpu()
    noisy_cpu = noisy.to(dtype=torch.float32).cpu()
    features_batch = _build_centered_features(noisy_cpu, config.bands, stft_size, hop_size).unsqueeze(0).to(device=device, dtype=torch.float32)
    window = torch.hann_window(stft_size)

    with torch.no_grad():
        mask_pred, vad_pred, state_logits = model(features_batch)
        mask_pred_cpu = mask_pred.squeeze(0).cpu()
        vad_pred_cpu = vad_pred.squeeze(0).squeeze(-1).cpu()
        state_probs = torch.softmax(state_logits.squeeze(0), dim=-1).cpu()

    noisy_spec = torch.stft(
        noisy_cpu,
        n_fft=stft_size,
        hop_length=hop_size,
        win_length=stft_size,
        window=window,
        center=True,
        return_complex=True,
    ).transpose(0, 1)
    freq_bins = noisy_spec.shape[1]
    mask_full = _compress_to_freq_bins(mask_pred_cpu, freq_bins)
    enhanced_spec = noisy_spec * mask_full.to(dtype=noisy_spec.dtype)
    enhanced = torch.istft(
        enhanced_spec.transpose(0, 1),
        n_fft=stft_size,
        hop_length=hop_size,
        win_length=stft_size,
        window=window,
        center=True,
        length=int(noisy_cpu.shape[0]),
    ).cpu()

    sample_path = preview_dir / f"epoch-{epoch:03d}-sample.wav"
    noise_path = preview_dir / f"epoch-{epoch:03d}-noise.wav"
    voice_path = preview_dir / f"epoch-{epoch:03d}-voice.wav"
    output_path = preview_dir / f"epoch-{epoch:03d}-output.wav"
    write_audio_mono_48k(sample_path, noisy_cpu.numpy())
    write_audio_mono_48k(noise_path, noise_cpu.numpy())
    write_audio_mono_48k(voice_path, clean_cpu.numpy())
    write_audio_mono_48k(output_path, enhanced.numpy())

    residual = enhanced - clean_cpu
    noise_rms = max(_tensor_rms(noise_cpu), 1.0e-6)
    residual_rms = _tensor_rms(residual)
    cancellation_pct = max(0.0, min(100.0, 100.0 * (1.0 - (residual_rms / noise_rms))))
    noise_detected_pct = float(state_probs[:, 0].mean().item() * 100.0)
    speech_detected_pct = float(state_probs[:, 1].mean().item() * 100.0)
    mixed_detected_pct = float(state_probs[:, 2].mean().item() * 100.0)
    vad_mean_pct = float(vad_pred_cpu.mean().item() * 100.0)
    output_rms = _tensor_rms(enhanced)
    input_rms = _tensor_rms(noisy_cpu)

    enhanced_spec_for_metrics = torch.stft(
        enhanced,
        n_fft=stft_size,
        hop_length=hop_size,
        win_length=stft_size,
        window=window,
        center=True,
        return_complex=True,
    ).transpose(0, 1)
    enhanced_mag = _compress_to_bands(enhanced_spec_for_metrics.abs().unsqueeze(0), config.bands).squeeze(0)
    clean_spec_for_metrics = torch.stft(
        clean_cpu,
        n_fft=stft_size,
        hop_length=hop_size,
        win_length=stft_size,
        window=window,
        center=True,
        return_complex=True,
    ).transpose(0, 1)
    clean_mag = _compress_to_bands(clean_spec_for_metrics.abs().unsqueeze(0), config.bands).squeeze(0)
    noise_spec_for_metrics = torch.stft(
        noise_cpu,
        n_fft=stft_size,
        hop_length=hop_size,
        win_length=stft_size,
        window=window,
        center=True,
        return_complex=True,
    ).transpose(0, 1)
    noise_mag = _compress_to_bands(noise_spec_for_metrics.abs().unsqueeze(0), config.bands).squeeze(0)

    frame_output_energy = enhanced_mag.mean(dim=1)
    frame_clean_energy = clean_mag.mean(dim=1)
    frame_noise_energy = noise_mag.mean(dim=1)

    # Preview metrics mix frame labels from the training example with a
    # centered STFT render for WAV export, so lengths can differ slightly.
    metric_frames = min(
        int(frame_output_energy.shape[0]),
        int(frame_clean_energy.shape[0]),
        int(frame_noise_energy.shape[0]),
        int(state_target.shape[0]),
    )
    frame_output_energy = frame_output_energy[:metric_frames]
    frame_clean_energy = frame_clean_energy[:metric_frames]
    frame_noise_energy = frame_noise_energy[:metric_frames]
    state_target = state_target[:metric_frames]

    voice_frames = state_target == 1
    noise_frames = state_target == 0
    mixed_frames = state_target == 2

    def _mean_ratio(numerator: torch.Tensor, denominator: torch.Tensor, mask: torch.Tensor) -> float:
        if int(mask.sum().item()) <= 0:
            return 0.0
        values = (numerator[mask] / denominator[mask].clamp_min(1.0e-6)).clamp(0.0, 4.0)
        return float(values.mean().item())

    def _noise_reduction(mask: torch.Tensor) -> float:
        if int(mask.sum().item()) <= 0:
            return 0.0
        values = 1.0 - (frame_output_energy[mask] / frame_noise_energy[mask].clamp_min(1.0e-6))
        values = values.clamp(-1.0, 1.0)
        return float(values.mean().item() * 100.0)

    voice_preservation_pct = _mean_ratio(frame_output_energy, frame_clean_energy, voice_frames) * 100.0
    mixed_voice_preservation_pct = _mean_ratio(frame_output_energy, frame_clean_energy, mixed_frames) * 100.0
    noise_only_reduction_pct = _noise_reduction(noise_frames)
    mixed_noise_reduction_pct = _noise_reduction(mixed_frames)

    return {
        "preview_sample_path": str(sample_path.resolve()),
        "preview_noise_path": str(noise_path.resolve()),
        "preview_voice_path": str(voice_path.resolve()),
        "preview_output_path": str(output_path.resolve()),
        "preview_mask_mean": float(mask_pred_cpu.mean().item()),
        "preview_vad_mean_pct": vad_mean_pct,
        "preview_cancellation_pct": cancellation_pct,
        "preview_noise_detected_pct": noise_detected_pct,
        "preview_speech_detected_pct": speech_detected_pct,
        "preview_mixed_detected_pct": mixed_detected_pct,
        "preview_voice_preservation_pct": voice_preservation_pct,
        "preview_mixed_voice_preservation_pct": mixed_voice_preservation_pct,
        "preview_noise_only_reduction_pct": noise_only_reduction_pct,
        "preview_mixed_noise_reduction_pct": mixed_noise_reduction_pct,
        "preview_input_rms": input_rms,
        "preview_output_rms": output_rms,
        "preview_noise_rms": noise_rms,
        "preview_residual_rms": residual_rms,
    }


def _compress_to_freq_bins(mask: torch.Tensor, freq_bins: int) -> torch.Tensor:
    if mask.shape[-1] == freq_bins:
        return mask
    resized = F.interpolate(
        mask.unsqueeze(0).unsqueeze(0),
        size=(mask.shape[0], freq_bins),
        mode="bilinear",
        align_corners=False,
    )
    return resized.squeeze(0).squeeze(0)


def _build_centered_features(waveform: torch.Tensor, bands: int, stft_size: int, hop_size: int) -> torch.Tensor:
    window = torch.hann_window(stft_size)
    noisy_spec = torch.stft(
        waveform,
        n_fft=stft_size,
        hop_length=hop_size,
        win_length=stft_size,
        window=window,
        center=True,
        return_complex=True,
    ).transpose(0, 1)
    noisy_mag = noisy_spec.abs().unsqueeze(0)
    return torch.log1p(_compress_to_bands(noisy_mag, bands)).squeeze(0)


def train_gpu_supervised_model(
    speech_dir: Path,
    noise_dir: Path,
    output_dir: Path,
    *,
    config: WireDeckVoiceDenoiserConfig,
    epochs: int,
    batch_size: int,
    learning_rate: float,
    samples_per_epoch: int,
    sample_rate_hz: int,
    clip_seconds: float,
    stft_size: int,
    hop_size: int,
    num_workers: int,
    device_name: str | None,
    allow_cpu: bool,
    initial_checkpoint: Path | None,
    seed: int,
    contrib_repeat: int,
    synthetic_repeat: int,
    foreground_repeat: int,
    background_repeat: int,
    musan_repeat: int,
    speech_noise_repeat: int,
    clean_probability: float,
    noise_only_probability: float,
    snr_min_db: float,
    snr_max_db: float,
    speech_gain_min_db: float,
    speech_gain_max_db: float,
    low_speech_probability: float,
    low_speech_extra_min_db: float,
    low_speech_extra_max_db: float,
    vad_positive_snr_db: float,
    vad_negative_snr_db: float,
    vad_energy_threshold: float,
    vad_loss_weight: float,
    state_loss_weight: float,
    state_noise_energy_threshold: float,
    state_speech_dominant_snr_db: float,
    state_noise_dominant_snr_db: float,
    state_hidden_channels: int | None,
) -> dict[str, object]:
    if sample_rate_hz != 48_000:
        raise ValueError("the current trainer expects 48 kHz normalized WAV files")
    if clean_probability < 0.0 or noise_only_probability < 0.0:
        raise ValueError("clean and noise-only probabilities must be >= 0")
    if clean_probability + noise_only_probability >= 1.0:
        raise ValueError("clean_probability + noise_only_probability must be < 1.0")
    if speech_gain_max_db < speech_gain_min_db:
        raise ValueError("speech_gain_max_db must be >= speech_gain_min_db")
    if not 0.0 <= low_speech_probability <= 1.0:
        raise ValueError("low_speech_probability must be between 0 and 1")
    if low_speech_extra_max_db < low_speech_extra_min_db:
        raise ValueError("low_speech_extra_max_db must be >= low_speech_extra_min_db")
    if vad_positive_snr_db <= vad_negative_snr_db:
        raise ValueError("vad_positive_snr_db must be greater than vad_negative_snr_db")
    if state_speech_dominant_snr_db <= state_noise_dominant_snr_db:
        raise ValueError("state_speech_dominant_snr_db must be greater than state_noise_dominant_snr_db")

    speech_files = list_wav_files(speech_dir)
    base_noise_files = list_wav_files(noise_dir)
    noise_files = build_weighted_noise_file_list(
        noise_dir,
        contrib_repeat=contrib_repeat,
        synthetic_repeat=synthetic_repeat,
        foreground_repeat=foreground_repeat,
        background_repeat=background_repeat,
        musan_repeat=musan_repeat,
        speech_noise_repeat=speech_noise_repeat,
    )
    if not speech_files:
        raise FileNotFoundError(f"no speech wav files found in {speech_dir}")
    if not base_noise_files:
        raise FileNotFoundError(f"no noise wav files found in {noise_dir}")

    output_dir.mkdir(parents=True, exist_ok=True)
    device = choose_training_device(force_device=device_name, allow_cpu=allow_cpu)
    segment_samples = int(sample_rate_hz * clip_seconds)

    dataset = SupervisedNoisySpeechDataset(
        speech_files=speech_files,
        noise_files=noise_files,
        segment_samples=segment_samples,
        bands=config.bands,
        stft_size=stft_size,
        hop_size=hop_size,
        samples_per_epoch=samples_per_epoch,
        clean_probability=clean_probability,
        noise_only_probability=noise_only_probability,
        snr_min_db=snr_min_db,
        snr_max_db=snr_max_db,
        speech_gain_min_db=speech_gain_min_db,
        speech_gain_max_db=speech_gain_max_db,
        low_speech_probability=low_speech_probability,
        low_speech_extra_min_db=low_speech_extra_min_db,
        low_speech_extra_max_db=low_speech_extra_max_db,
        vad_positive_snr_db=vad_positive_snr_db,
        vad_negative_snr_db=vad_negative_snr_db,
        vad_energy_threshold=vad_energy_threshold,
        state_noise_energy_threshold=state_noise_energy_threshold,
        state_speech_dominant_snr_db=state_speech_dominant_snr_db,
        state_noise_dominant_snr_db=state_noise_dominant_snr_db,
        seed=seed,
    )
    dataloader = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=False,
        num_workers=num_workers,
        pin_memory=device.type == "cuda",
        drop_last=False,
    )

    torch.manual_seed(seed)
    model = WireDeckSupervisedVoiceDenoiser(config, state_hidden_channels=state_hidden_channels).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate)
    start_epoch = 0
    summary_path = output_dir / "training_summary.json"
    history: list[dict[str, float]] = _load_existing_history(summary_path)

    if initial_checkpoint is not None:
        state = torch.load(initial_checkpoint, map_location="cpu")
        if isinstance(state, dict) and "state_dict" in state:
            skipped_missing, skipped_shape = load_compatible_state_dict(model, state["state_dict"])
            if skipped_missing or skipped_shape:
                print(
                    "[wiredeck-rnnoise] warm start loaded compatible weights only "
                    f"(missing={len(skipped_missing)} shape_mismatch={len(skipped_shape)})"
                )
            optimizer_state = state.get("optimizer_state_dict")
            if isinstance(optimizer_state, dict):
                try:
                    optimizer.load_state_dict(optimizer_state)
                except ValueError:
                    print("[wiredeck-rnnoise] optimizer state skipped due to parameter mismatch")
                else:
                    for group in optimizer.param_groups:
                        group["lr"] = learning_rate
                        group["initial_lr"] = learning_rate
            saved_epoch = state.get("epoch")
            if isinstance(saved_epoch, int) and saved_epoch >= 0:
                start_epoch = saved_epoch
        else:
            skipped_missing, skipped_shape = load_compatible_state_dict(model, state)
            if skipped_missing or skipped_shape:
                print(
                    "[wiredeck-rnnoise] warm start loaded compatible weights only "
                    f"(missing={len(skipped_missing)} shape_mismatch={len(skipped_shape)})"
                )

    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=max(1, epochs))
    best_mask_loss = float("inf")
    best_checkpoint: Path | None = None

    for epoch in range(start_epoch + 1, start_epoch + epochs + 1):
        model.train()
        total_loss = 0.0
        total_mask_loss = 0.0
        total_vad_loss = 0.0
        total_state_loss = 0.0
        batches = 0

        for features, mask_target, vad_target, state_target in dataloader:
            features = features.to(device=device, dtype=torch.float32, non_blocking=True)
            mask_target = mask_target.to(device=device, dtype=torch.float32, non_blocking=True)
            vad_target = vad_target.to(device=device, dtype=torch.float32, non_blocking=True)
            state_target = state_target.to(device=device, dtype=torch.long, non_blocking=True)

            optimizer.zero_grad(set_to_none=True)
            mask_pred, vad_pred, state_logits = model(features)
            mask_loss = F.l1_loss(mask_pred, mask_target)
            vad_loss = F.binary_cross_entropy(vad_pred.clamp(1.0e-4, 1.0 - 1.0e-4), vad_target)
            state_loss = F.cross_entropy(state_logits.reshape(-1, 3), state_target.reshape(-1))
            loss = mask_loss + vad_loss_weight * vad_loss + state_loss_weight * state_loss
            loss.backward()
            optimizer.step()

            total_loss += float(loss.detach().cpu())
            total_mask_loss += float(mask_loss.detach().cpu())
            total_vad_loss += float(vad_loss.detach().cpu())
            total_state_loss += float(state_loss.detach().cpu())
            batches += 1

        scheduler.step()
        metrics = {
            "loss": total_loss / max(1, batches),
            "mask_loss": total_mask_loss / max(1, batches),
            "vad_loss": total_vad_loss / max(1, batches),
            "state_loss": total_state_loss / max(1, batches),
            "learning_rate": float(scheduler.get_last_lr()[0]),
        }
        model.eval()
        preview_metrics = _render_preview(
            model,
            config,
            device,
            output_dir,
            epoch,
            dataset.build_preview(epoch),
            stft_size=stft_size,
            hop_size=hop_size,
        )
        metrics.update(preview_metrics)
        history.append(metrics)
        checkpoint = save_checkpoint(model, optimizer, output_dir, epoch, config, metrics)
        if metrics["mask_loss"] < best_mask_loss:
            best_mask_loss = metrics["mask_loss"]
            best_checkpoint = checkpoint
        print(
            "[wiredeck-rnnoise] epoch {epoch:03d}/{epochs:03d} loss={loss:.5f} mask={mask:.5f} vad={vad:.5f} state={state:.5f} lr={lr:.6f} cancel={cancel:.2f}% noise_detected={noise_detected:.2f}%".format(
                epoch=epoch,
                epochs=start_epoch + epochs,
                loss=metrics["loss"],
                mask=metrics["mask_loss"],
                vad=metrics["vad_loss"],
                state=metrics["state_loss"],
                lr=metrics["learning_rate"],
                cancel=metrics["preview_cancellation_pct"],
                noise_detected=metrics["preview_noise_detected_pct"],
            )
        )
        print(
            "[wiredeck-rnnoise] preview epoch {epoch:03d} vad={vad:.2f}% speech={speech:.2f}% mixed={mixed:.2f}% voice_preserve={voice_preserve:.2f}% noise_only_reduction={noise_reduction:.2f}% mixed_voice_preserve={mixed_voice:.2f}% mixed_noise_reduction={mixed_noise:.2f}% input_rms={input_rms:.6f} output_rms={output_rms:.6f}".format(
                epoch=epoch,
                vad=metrics["preview_vad_mean_pct"],
                speech=metrics["preview_speech_detected_pct"],
                mixed=metrics["preview_mixed_detected_pct"],
                voice_preserve=metrics["preview_voice_preservation_pct"],
                noise_reduction=metrics["preview_noise_only_reduction_pct"],
                mixed_voice=metrics["preview_mixed_voice_preservation_pct"],
                mixed_noise=metrics["preview_mixed_noise_reduction_pct"],
                input_rms=metrics["preview_input_rms"],
                output_rms=metrics["preview_output_rms"],
            )
        )

    summary = {
        "device": str(device),
        "trainer": "train-gpu-supervised",
        "speech_files": len(speech_files),
        "noise_files": len(base_noise_files),
        "weighted_noise_files": len(noise_files),
        "epochs": epochs,
        "start_epoch": start_epoch,
        "end_epoch": start_epoch + epochs,
        "batch_size": batch_size,
        "samples_per_epoch": samples_per_epoch,
        "sample_rate_hz": sample_rate_hz,
        "clip_seconds": clip_seconds,
        "stft_size": stft_size,
        "hop_size": hop_size,
        "best_checkpoint": str(best_checkpoint.resolve()) if best_checkpoint else None,
        "noise_weighting": {
            "contrib_repeat": contrib_repeat,
            "synthetic_repeat": synthetic_repeat,
            "foreground_repeat": foreground_repeat,
            "background_repeat": background_repeat,
            "musan_repeat": musan_repeat,
            "speech_noise_repeat": speech_noise_repeat,
        },
        "clean_probability": clean_probability,
        "noise_only_probability": noise_only_probability,
        "snr_min_db": snr_min_db,
        "snr_max_db": snr_max_db,
        "speech_gain_min_db": speech_gain_min_db,
        "speech_gain_max_db": speech_gain_max_db,
        "low_speech_probability": low_speech_probability,
        "low_speech_extra_min_db": low_speech_extra_min_db,
        "low_speech_extra_max_db": low_speech_extra_max_db,
        "vad_positive_snr_db": vad_positive_snr_db,
        "vad_negative_snr_db": vad_negative_snr_db,
        "vad_energy_threshold": vad_energy_threshold,
        "vad_loss_weight": vad_loss_weight,
        "state_loss_weight": state_loss_weight,
        "state_noise_energy_threshold": state_noise_energy_threshold,
        "state_speech_dominant_snr_db": state_speech_dominant_snr_db,
        "state_noise_dominant_snr_db": state_noise_dominant_snr_db,
        "state_hidden_channels": state_hidden_channels or config.hidden_channels,
        "initial_checkpoint": str(initial_checkpoint.resolve()) if initial_checkpoint is not None else None,
        "preview_audio_dir": str((output_dir / "epoch_audio").resolve()),
        "history": history,
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return summary
