from __future__ import annotations

import json
import math
import random
import wave
from dataclasses import asdict
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn
from torch.utils.data import DataLoader, Dataset

from wiredeck_rnnoise_trainer.gpu_model import WireDeckVoiceDenoiser, WireDeckVoiceDenoiserConfig


def choose_training_device(force_device: str | None = None, allow_cpu: bool = False) -> torch.device:
    if force_device:
        device = torch.device(force_device)
    elif torch.cuda.is_available():
        device = torch.device("cuda")
    elif getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        device = torch.device("mps")
    elif allow_cpu:
        device = torch.device("cpu")
    else:
        raise RuntimeError("no GPU backend available; use --device or --allow-cpu for development")
    return device


def list_wav_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*.wav") if path.is_file())


def build_weighted_noise_file_list(
    noise_root: Path,
    *,
    contrib_repeat: int,
    synthetic_repeat: int,
    foreground_repeat: int,
    background_repeat: int,
    musan_repeat: int,
    speech_noise_repeat: int,
) -> list[Path]:
    weighted: list[Path] = []
    all_files = list_wav_files(noise_root)
    for path in all_files:
        name = path.name.lower()
        repeat = 1
        speech_like_noise = any(
            keyword in name
            for keyword in (
                "people",
                "talk",
                "speech",
                "voice",
                "crowd",
                "conversation",
                "office",
                "cafe",
                "tv",
                "radio",
            )
        )
        if "contrib_noise" in name:
            repeat = max(1, contrib_repeat)
        elif "synthetic_noise" in name:
            repeat = max(1, synthetic_repeat)
        elif "foreground_noise" in name:
            repeat = max(1, foreground_repeat)
        elif "background_noise" in name:
            repeat = max(1, background_repeat)
        elif "musan" in name:
            repeat = max(1, musan_repeat)
        elif speech_like_noise:
            repeat = max(1, speech_noise_repeat)
        weighted.extend([path] * repeat)
    return weighted


def _read_segment(path: Path, target_samples: int, rng: random.Random) -> np.ndarray:
    with wave.open(str(path), "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        sample_rate = handle.getframerate()
        total_frames = handle.getnframes()
        if channels != 1:
            raise ValueError(f"{path} is not mono")
        if width != 2:
            raise ValueError(f"{path} is not 16-bit PCM")
        if sample_rate != 48_000:
            raise ValueError(f"{path} is not 48 kHz")

        if total_frames <= target_samples:
            start = 0
            frames_to_read = total_frames
        else:
            start = rng.randint(0, total_frames - target_samples)
            frames_to_read = target_samples
        handle.setpos(start)
        raw = handle.readframes(frames_to_read)

    audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if audio.shape[0] < target_samples:
        padded = np.zeros(target_samples, dtype=np.float32)
        if audio.shape[0] > 0:
            repeats = math.ceil(target_samples / audio.shape[0])
            tiled = np.tile(audio, repeats)[:target_samples]
            padded[:] = tiled
        audio = padded
    return audio[:target_samples]


def _compress_to_bands(magnitude: torch.Tensor, bands: int) -> torch.Tensor:
    # Input: [batch, frames, freq_bins] -> output: [batch, frames, bands]
    if magnitude.shape[-1] == bands:
        return magnitude
    resized = F.interpolate(
        magnitude.unsqueeze(1),
        size=(magnitude.shape[1], bands),
        mode="bilinear",
        align_corners=False,
    )
    return resized.squeeze(1)


class NoisySpeechDataset(Dataset):
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
        self.seed = seed
        self.window = torch.hann_window(stft_size)

    def __len__(self) -> int:
        return self.samples_per_epoch

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        rng = random.Random(self.seed + index)
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
        return features, mask_target, vad_target

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


def save_checkpoint(
    model: nn.Module,
    optimizer: torch.optim.Optimizer,
    output_dir: Path,
    epoch: int,
    config: WireDeckVoiceDenoiserConfig,
    metrics: dict[str, float],
) -> Path:
    checkpoint_dir = output_dir / "checkpoints"
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = checkpoint_dir / f"wiredeck_gpu_epoch_{epoch:03d}.pt"
    torch.save(
        {
            "epoch": epoch,
            "state_dict": model.state_dict(),
            "optimizer_state_dict": optimizer.state_dict(),
            "config": asdict(config),
            "metrics": metrics,
        },
        checkpoint,
    )
    return checkpoint


def _load_existing_history(summary_path: Path) -> list[dict[str, float]]:
    if not summary_path.exists():
        return []
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    history = summary.get("history")
    return history if isinstance(history, list) else []


def train_gpu_model(
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

    dataset = NoisySpeechDataset(
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
    model = WireDeckVoiceDenoiser(config).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate)
    start_epoch = 0
    summary_path = output_dir / "training_summary.json"
    history: list[dict[str, float]] = _load_existing_history(summary_path)

    if initial_checkpoint is not None:
        state = torch.load(initial_checkpoint, map_location="cpu")
        if isinstance(state, dict) and "state_dict" in state:
            model.load_state_dict(state["state_dict"], strict=False)
            optimizer_state = state.get("optimizer_state_dict")
            if isinstance(optimizer_state, dict):
                optimizer.load_state_dict(optimizer_state)
                for group in optimizer.param_groups:
                    group["lr"] = learning_rate
                    group["initial_lr"] = learning_rate
            saved_epoch = state.get("epoch")
            if isinstance(saved_epoch, int) and saved_epoch >= 0:
                start_epoch = saved_epoch
        else:
            model.load_state_dict(state, strict=False)

    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=max(1, epochs))

    best_mask_loss = float("inf")
    best_checkpoint: Path | None = None

    for epoch in range(start_epoch + 1, start_epoch + epochs + 1):
        model.train()
        total_loss = 0.0
        total_mask_loss = 0.0
        total_vad_loss = 0.0
        batches = 0

        for features, mask_target, vad_target in dataloader:
            features = features.to(device=device, dtype=torch.float32, non_blocking=True)
            mask_target = mask_target.to(device=device, dtype=torch.float32, non_blocking=True)
            vad_target = vad_target.to(device=device, dtype=torch.float32, non_blocking=True)

            optimizer.zero_grad(set_to_none=True)
            mask_pred, vad_pred = model(features)
            mask_loss = F.l1_loss(mask_pred, mask_target)
            vad_loss = F.binary_cross_entropy(vad_pred.clamp(1.0e-4, 1.0 - 1.0e-4), vad_target)
            loss = mask_loss + vad_loss_weight * vad_loss
            loss.backward()
            optimizer.step()

            total_loss += float(loss.detach().cpu())
            total_mask_loss += float(mask_loss.detach().cpu())
            total_vad_loss += float(vad_loss.detach().cpu())
            batches += 1

        scheduler.step()
        metrics = {
            "loss": total_loss / max(1, batches),
            "mask_loss": total_mask_loss / max(1, batches),
            "vad_loss": total_vad_loss / max(1, batches),
            "learning_rate": float(scheduler.get_last_lr()[0]),
        }
        history.append(metrics)
        checkpoint = save_checkpoint(model, optimizer, output_dir, epoch, config, metrics)
        if metrics["mask_loss"] < best_mask_loss:
            best_mask_loss = metrics["mask_loss"]
            best_checkpoint = checkpoint
        print(
            "[wiredeck-rnnoise] epoch {epoch:03d}/{epochs:03d} loss={loss:.5f} mask={mask:.5f} vad={vad:.5f} lr={lr:.6f}".format(
                epoch=epoch,
                epochs=start_epoch + epochs,
                loss=metrics["loss"],
                mask=metrics["mask_loss"],
                vad=metrics["vad_loss"],
                lr=metrics["learning_rate"],
            )
        )

    summary = {
        "device": str(device),
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
        "initial_checkpoint": str(initial_checkpoint.resolve()) if initial_checkpoint is not None else None,
        "history": history,
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return summary
