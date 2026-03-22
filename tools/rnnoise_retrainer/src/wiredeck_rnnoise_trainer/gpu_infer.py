from __future__ import annotations

import json
import math
import shutil
import subprocess
import tempfile
import wave
from dataclasses import asdict
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

from wiredeck_rnnoise_trainer.gpu_model import WireDeckVoiceDenoiser, WireDeckVoiceDenoiserConfig
from wiredeck_rnnoise_trainer.gpu_train import choose_training_device


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


def _expand_from_bands(mask: torch.Tensor, freq_bins: int) -> torch.Tensor:
    if mask.shape[-1] == freq_bins:
        return mask
    resized = F.interpolate(
        mask.unsqueeze(1),
        size=(mask.shape[1], freq_bins),
        mode="bilinear",
        align_corners=False,
    )
    return resized.squeeze(1)


def _ensure_wav_48k_mono_s16(source: Path) -> Path:
    try:
        with wave.open(str(source), "rb") as handle:
            if (
                handle.getnchannels() == 1
                and handle.getsampwidth() == 2
                and handle.getframerate() == 48_000
            ):
                return source
    except (wave.Error, EOFError):
        pass
    return _convert_audio_to_temp_wav(source)


def _convert_audio_to_temp_wav(source: Path) -> Path:
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise FileNotFoundError("ffmpeg is required for offline denoise commands")
    temp_dir = Path(tempfile.mkdtemp(prefix="wiredeck-rnnoise-infer-"))
    output = temp_dir / f"{source.stem}.wav"
    cmd = [
        ffmpeg,
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
        "-vn",
        "-ac",
        "1",
        "-ar",
        "48000",
        "-c:a",
        "pcm_s16le",
        str(output),
    ]
    subprocess.run(cmd, check=True)
    return output


def load_audio_mono_48k(source: Path, max_seconds: float | None = None) -> np.ndarray:
    wav_source = _ensure_wav_48k_mono_s16(source)
    try:
        with wave.open(str(wav_source), "rb") as handle:
            sample_rate = handle.getframerate()
            if sample_rate != 48_000:
                raise ValueError(f"{source} is not 48 kHz after conversion")
            frame_count = handle.getnframes()
            if max_seconds is not None:
                frame_count = min(frame_count, int(max_seconds * sample_rate))
            raw = handle.readframes(frame_count)
            audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
            return audio
    finally:
        if wav_source != source:
            shutil.rmtree(wav_source.parent, ignore_errors=True)


def write_audio_mono_48k(target: Path, audio: np.ndarray) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    clipped = np.clip(audio, -1.0, 1.0)
    pcm = np.round(clipped * 32767.0).astype(np.int16)
    with wave.open(str(target), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(48_000)
        handle.writeframes(pcm.tobytes())


def load_checkpoint_model(
    checkpoint_path: Path,
    *,
    device_name: str | None,
    allow_cpu: bool,
) -> tuple[WireDeckVoiceDenoiser, WireDeckVoiceDenoiserConfig, torch.device]:
    device = choose_training_device(force_device=device_name, allow_cpu=allow_cpu)
    state = torch.load(checkpoint_path, map_location="cpu")
    config_dict = state.get("config") if isinstance(state, dict) else None
    config = WireDeckVoiceDenoiserConfig(**config_dict) if isinstance(config_dict, dict) else WireDeckVoiceDenoiserConfig()
    model = WireDeckVoiceDenoiser(config)
    state_dict = state["state_dict"] if isinstance(state, dict) and "state_dict" in state else state
    model.load_state_dict(state_dict, strict=False)
    model.eval()
    model.to(device)
    return model, config, device


def denoise_audio_file(
    checkpoint_path: Path,
    input_path: Path,
    output_path: Path,
    *,
    device_name: str | None = None,
    allow_cpu: bool = False,
    max_seconds: float | None = None,
    sample_rate_hz: int = 48_000,
    stft_size: int = 512,
    hop_size: int = 128,
    vad_json_path: Path | None = None,
) -> dict[str, object]:
    model, config, device = load_checkpoint_model(
        checkpoint_path,
        device_name=device_name,
        allow_cpu=allow_cpu,
    )

    waveform_np = load_audio_mono_48k(input_path, max_seconds=max_seconds)
    if waveform_np.size == 0:
        raise ValueError(f"{input_path} produced no audio samples")

    waveform = torch.from_numpy(waveform_np)
    original_length = int(waveform.shape[0])
    window = torch.hann_window(stft_size)
    with torch.no_grad():
        noisy_spec = torch.stft(
            waveform.to(dtype=torch.float32),
            n_fft=stft_size,
            hop_length=hop_size,
            win_length=stft_size,
            window=window,
            center=True,
            return_complex=True,
        )
        noisy_spec_tf = noisy_spec.transpose(0, 1)
        noisy_mag = noisy_spec_tf.abs().unsqueeze(0)
        features = torch.log1p(_compress_to_bands(noisy_mag, config.bands)).to(device=device, dtype=torch.float32)
        mask, vad = model(features)
        mask = mask.detach().cpu()
        vad = vad.detach().cpu()
        mask_full = _expand_from_bands(mask, noisy_spec_tf.shape[1]).squeeze(0)
        enhanced_spec_tf = noisy_spec_tf * mask_full.to(dtype=noisy_spec_tf.dtype)
        enhanced_waveform = torch.istft(
            enhanced_spec_tf.transpose(0, 1),
            n_fft=stft_size,
            hop_length=hop_size,
            win_length=stft_size,
            window=window,
            center=True,
            length=original_length,
        )

    enhanced_np = enhanced_waveform[:original_length].cpu().numpy()
    write_audio_mono_48k(output_path, enhanced_np)

    summary = {
        "checkpoint": str(checkpoint_path.resolve()),
        "input": str(input_path.resolve()),
        "output": str(output_path.resolve()),
        "device": str(device),
        "config": asdict(config),
        "sample_rate_hz": sample_rate_hz,
        "stft_size": stft_size,
        "hop_size": hop_size,
        "input_samples": original_length,
        "output_samples": int(enhanced_np.shape[0]),
        "vad_frames": vad.squeeze(0).squeeze(-1).tolist(),
        "vad_mean": float(vad.mean().item()),
        "mask_mean": float(mask.mean().item()),
        "max_seconds": max_seconds,
    }
    if vad_json_path is not None:
        vad_json_path.parent.mkdir(parents=True, exist_ok=True)
        vad_json_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return summary
