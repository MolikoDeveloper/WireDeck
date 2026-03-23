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

from wiredeck_rnnoise_trainer.gpu_model import WireDeckVoiceDenoiserConfig


def choose_training_device(force_device: str | None = None, allow_cpu: bool = False) -> torch.device:
    if force_device:
        return torch.device(force_device)
    if torch.cuda.is_available():
        return torch.device("cuda")
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return torch.device("mps")
    if allow_cpu:
        return torch.device("cpu")
    raise RuntimeError("no GPU backend available; use --device or --allow-cpu for development")


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
            padded[:] = np.tile(audio, repeats)[:target_samples]
        audio = padded
    return audio[:target_samples]


def _compress_to_bands(magnitude: torch.Tensor, bands: int) -> torch.Tensor:
    if magnitude.shape[-1] == bands:
        return magnitude
    resized = F.interpolate(
        magnitude.unsqueeze(1),
        size=(magnitude.shape[1], bands),
        mode="bilinear",
        align_corners=False,
    )
    return resized.squeeze(1)


def save_checkpoint(
    model: nn.Module,
    optimizer: torch.optim.Optimizer,
    output_dir: Path,
    epoch: int,
    config: WireDeckVoiceDenoiserConfig,
    metrics: dict[str, float],
    scheduler: torch.optim.lr_scheduler.LRScheduler | None = None,
) -> Path:
    checkpoint_dir = output_dir / "checkpoints"
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = checkpoint_dir / f"wiredeck_gpu_epoch_{epoch:03d}.pt"
    torch.save(
        {
            "epoch": epoch,
            "state_dict": model.state_dict(),
            "optimizer_state_dict": optimizer.state_dict(),
            "scheduler_state_dict": scheduler.state_dict() if scheduler is not None else None,
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


def load_compatible_state_dict(model: nn.Module, state_dict: dict[str, torch.Tensor]) -> tuple[list[str], list[str]]:
    model_state = model.state_dict()
    compatible: dict[str, torch.Tensor] = {}
    skipped_missing: list[str] = []
    skipped_shape: list[str] = []

    for key, value in state_dict.items():
        if key not in model_state:
            skipped_missing.append(key)
            continue
        if model_state[key].shape != value.shape:
            skipped_shape.append(key)
            continue
        compatible[key] = value

    model_state.update(compatible)
    model.load_state_dict(model_state)
    return skipped_missing, skipped_shape
