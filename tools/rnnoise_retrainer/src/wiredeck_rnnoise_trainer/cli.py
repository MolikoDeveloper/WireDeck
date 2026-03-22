from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from urllib.error import HTTPError, URLError
from dataclasses import asdict
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[4]


def vendor_root() -> Path:
    return repo_root() / "vendor" / "rnnoise"


def vendor_torch_root() -> Path:
    return vendor_root() / "torch" / "rnnoise"


def datasets_file() -> Path:
    return vendor_root() / "datasets.txt"


def train_script() -> Path:
    return vendor_torch_root() / "train_rnnoise.py"


def dump_script() -> Path:
    return vendor_torch_root() / "dump_rnnoise_weights.py"


def write_weights_source() -> Path:
    return vendor_root() / "src" / "write_weights.c"


def rnnoise_include_root() -> Path:
    return vendor_root() / "src"


def run(cmd: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    rendered = " ".join(cmd)
    print(f"[wiredeck-rnnoise] running: {rendered}")
    subprocess.run(cmd, cwd=cwd, env=env, check=True)


def capture(cmd: list[str], cwd: Path | None = None) -> str:
    rendered = " ".join(cmd)
    print(f"[wiredeck-rnnoise] running: {rendered}")
    result = subprocess.run(cmd, cwd=cwd, check=True, text=True, capture_output=True)
    return result.stdout


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _resolve_existing_path(path: Path) -> Path | None:
    if path.exists():
        return path

    candidate = path
    parts = list(candidate.parts)
    if not parts:
        return None

    resolved_parts: list[str] = []
    if candidate.is_absolute():
        current = Path(parts[0])
        resolved_parts.append(parts[0])
        remaining = parts[1:]
    else:
        current = Path(".")
        remaining = parts

    changed = False
    for part in remaining:
        next_path = current / part
        if next_path.exists():
            current = next_path
            resolved_parts.append(part)
            continue

        try:
            sibling_names = [entry.name for entry in current.iterdir()]
        except OSError:
            return None

        matches = difflib.get_close_matches(part, sibling_names, n=1, cutoff=0.72)
        if not matches:
            return None
        replacement = matches[0]
        current = current / replacement
        resolved_parts.append(replacement)
        changed = True

    return current if changed and current.exists() else None


def ensure_exists(path: Path, description: str) -> Path:
    if path.exists():
        return path
    resolved = _resolve_existing_path(path)
    if resolved is not None:
        print(f"[wiredeck-rnnoise] note: resolved {description} path {path} -> {resolved}")
        return resolved
    raise FileNotFoundError(f"missing {description}: {path}")


def require_tool(name: str) -> str:
    resolved = shutil.which(name)
    if resolved is None:
        raise FileNotFoundError(f"required tool not found in PATH: {name}")
    return resolved


def parse_dataset_urls() -> list[str]:
    text = datasets_file().read_text(encoding="utf-8")
    urls: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("https://"):
            urls.append(stripped)
    return urls


def latest_checkpoint(checkpoint_dir: Path) -> Path:
    candidates = sorted(checkpoint_dir.glob("*.pth"))
    if not candidates:
        raise FileNotFoundError(f"no checkpoints found in {checkpoint_dir}")
    return candidates[-1]


def list_checkpoint_files(checkpoint_dir: Path) -> list[Path]:
    candidates = sorted(path for path in checkpoint_dir.iterdir() if path.is_file() and path.suffix in {".pt", ".pth"})
    if not candidates:
        raise FileNotFoundError(f"no checkpoint files found in {checkpoint_dir}")
    return candidates


def classify_checkpoint(checkpoint: Path) -> str:
    try:
        import torch
    except ModuleNotFoundError:
        return "unknown"

    state = torch.load(checkpoint, map_location="cpu")
    if not isinstance(state, dict):
        return "unknown"
    state_dict = state.get("state_dict")
    if not isinstance(state_dict, dict):
        return "unknown"
    keys = tuple(state_dict.keys())
    if any(key.startswith("input_proj.") or key.startswith("blocks.") or key.startswith("mask_head.") for key in keys):
        return "gpu"
    if "model_kwargs" in state or any(key.startswith("gru.") or key.startswith("conv1.") or key.startswith("vad_dense.") for key in keys):
        return "rnnoise"
    return "unknown"


def normalize_gpu_export_output(path: Path) -> Path:
    if path.exists() and path.is_dir():
        resolved = path / "wiredeck_gpu_model.bin"
        print(f"[wiredeck-rnnoise] note: output path is a directory; exporting to {resolved}")
        return resolved
    if not path.suffix:
        resolved = path / "wiredeck_gpu_model.bin"
        print(f"[wiredeck-rnnoise] note: output path has no file extension; exporting to {resolved}")
        return resolved
    return path


def cmd_list_datasets(args: argparse.Namespace) -> int:
    urls = parse_dataset_urls()
    for index, url in enumerate(urls, start=1):
        print(f"{index:02d}. {url}")
    print(f"[wiredeck-rnnoise] total datasets: {len(urls)}")
    return 0


def download_file(url: str, target: Path, *, chunk_size: int = 1024 * 1024) -> None:
    try:
        from tqdm import tqdm
    except ModuleNotFoundError:
        tqdm = None

    print(f"[wiredeck-rnnoise] downloading: {url}")
    with urllib.request.urlopen(url) as response, target.open("wb") as handle:
        total = response.headers.get("Content-Length")
        total_bytes = int(total) if total is not None else None
        if tqdm is None:
            while True:
                chunk = response.read(chunk_size)
                if not chunk:
                    break
                handle.write(chunk)
            return

        with tqdm(
            total=total_bytes,
            unit="B",
            unit_scale=True,
            unit_divisor=1024,
            desc=target.name,
            dynamic_ncols=True,
        ) as progress:
            while True:
                chunk = response.read(chunk_size)
                if not chunk:
                    break
                handle.write(chunk)
                progress.update(len(chunk))


def cmd_download_datasets(args: argparse.Namespace) -> int:
    output_dir = Path(args.output).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    urls = parse_dataset_urls()
    if args.limit is not None:
        urls = urls[: args.limit]

    for url in urls:
        filename = url.rsplit("/", 1)[-1]
        target = output_dir / filename
        if target.exists() and not args.force:
            print(f"[wiredeck-rnnoise] skipping existing file: {target}")
            continue
        download_file(url, target)

    manifest = {
        "source": str(datasets_file().resolve()),
        "count": len(urls),
        "files": [url.rsplit("/", 1)[-1] for url in urls],
    }
    manifest_path = output_dir / "datasets_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"[wiredeck-rnnoise] wrote manifest: {manifest_path}")
    return 0


def cmd_list_noise_datasets(args: argparse.Namespace) -> int:
    from wiredeck_rnnoise_trainer.noise_datasets import CURATED_NOISE_DATASETS

    for index, dataset in enumerate(CURATED_NOISE_DATASETS, start=1):
        print(
            f"{index:02d}. [{dataset.category}] {dataset.key}\n"
            f"    url: {dataset.url}\n"
            f"    source: {dataset.source}\n"
            f"    note: {dataset.description}"
        )
    print(f"[wiredeck-rnnoise] total curated noise datasets: {len(CURATED_NOISE_DATASETS)}")
    return 0


def cmd_download_noise_datasets(args: argparse.Namespace) -> int:
    from wiredeck_rnnoise_trainer.noise_datasets import CURATED_NOISE_DATASETS

    output_dir = Path(args.output).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    datasets = list(CURATED_NOISE_DATASETS)
    if args.limit is not None:
        datasets = datasets[: args.limit]

    files: list[dict[str, str]] = []
    failures: list[dict[str, str]] = []
    for dataset in datasets:
        filename = dataset.url.rsplit("/", 1)[-1]
        target = output_dir / filename
        try:
            if target.exists() and not args.force:
                print(f"[wiredeck-rnnoise] skipping existing file: {target}")
                status = "existing"
            else:
                download_file(dataset.url, target)
                status = "downloaded"
            files.append(
                {
                    "key": dataset.key,
                    "category": dataset.category,
                    "filename": filename,
                    "url": dataset.url,
                    "source": dataset.source,
                    "status": status,
                }
            )
        except (HTTPError, URLError) as exc:
            message = f"{type(exc).__name__}: {exc}"
            print(f"[wiredeck-rnnoise] warning: failed to download {dataset.key}: {message}")
            failures.append(
                {
                    "key": dataset.key,
                    "category": dataset.category,
                    "url": dataset.url,
                    "source": dataset.source,
                    "error": message,
                }
            )
            if args.strict:
                raise

    manifest_path = output_dir / "noise_datasets_manifest.json"
    manifest = {
        "count": len(files),
        "files": files,
        "failures": failures,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"[wiredeck-rnnoise] wrote manifest: {manifest_path}")
    return 0


def dump_features_binary() -> Path:
    return repo_root() / "tools" / "rnnoise_retrainer" / ".cache" / "dump_features"


def build_dump_features() -> Path:
    binary = dump_features_binary()
    binary.parent.mkdir(parents=True, exist_ok=True)
    compiler = os.environ.get("CC", "cc")

    cmd = [
        compiler,
        "-O2",
        "-DTRAINING=1",
        "-I",
        str(vendor_root() / "include"),
        "-I",
        str(vendor_root()),
        str(vendor_root() / "src" / "dump_features.c"),
        str(vendor_root() / "src" / "denoise.c"),
        str(vendor_root() / "src" / "pitch.c"),
        str(vendor_root() / "src" / "celt_lpc.c"),
        str(vendor_root() / "src" / "kiss_fft.c"),
        str(vendor_root() / "src" / "parse_lpcnet_weights.c"),
        str(vendor_root() / "src" / "rnnoise_tables.c"),
        str(vendor_root() / "src" / "rnn.c"),
        str(vendor_root() / "src" / "nnet.c"),
        str(vendor_root() / "src" / "nnet_default.c"),
        str(vendor_root() / "src" / "rnnoise_data.c"),
        "-lm",
        "-o",
        str(binary),
    ]
    run(cmd)
    return binary


def convert_audio_to_pcm48_mono(source: Path, temp_dir: Path) -> Path:
    suffix = source.suffix.lower()
    if suffix == ".pcm":
        return source

    ffmpeg = require_tool("ffmpeg")
    output = temp_dir / f"{source.stem}.pcm"
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        str(source),
        "-f",
        "s16le",
        "-acodec",
        "pcm_s16le",
        "-ac",
        "1",
        "-ar",
        "48000",
        str(output),
    ]
    run(cmd)
    return output


def cat_files(inputs: list[Path], output: Path) -> None:
    with output.open("wb") as out_handle:
        for path in inputs:
            with path.open("rb") as in_handle:
                shutil.copyfileobj(in_handle, out_handle)


def cmd_generate_features(args: argparse.Namespace) -> int:
    speech = Path(args.speech).resolve()
    noise = Path(args.noise).resolve()
    output = Path(args.output).resolve()
    speech = ensure_exists(speech, "speech audio")
    noise = ensure_exists(noise, "noise audio")
    if args.rir_list:
        ensure_exists(Path(args.rir_list).resolve(), "rir list")

    dump_features = build_dump_features()
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="wiredeck-rnnoise-features-") as temp_dir_str:
        temp_dir = Path(temp_dir_str)
        speech_pcm = convert_audio_to_pcm48_mono(speech, temp_dir)
        noise_pcm = convert_audio_to_pcm48_mono(noise, temp_dir)

        if args.workers <= 1:
            cmd = [str(dump_features)]
            if args.rir_list:
                cmd.extend(["-rir_list", str(Path(args.rir_list).resolve())])
            cmd.extend([str(speech_pcm), str(noise_pcm), str(output), str(args.count)])
            run(cmd)
            return 0

        partials: list[Path] = []
        for index in range(args.workers):
            partial = temp_dir / f"features.part{index:03d}.f32"
            partials.append(partial)
            cmd = [str(dump_features)]
            if args.rir_list:
                cmd.extend(["-rir_list", str(Path(args.rir_list).resolve())])
            cmd.extend([str(speech_pcm), str(noise_pcm), str(partial), str(args.count)])
            run(cmd)

        cat_files(partials, output)
        print(f"[wiredeck-rnnoise] merged {len(partials)} partial feature files into {output}")
        return 0


def cmd_train(args: argparse.Namespace) -> int:
    features = Path(args.features).resolve()
    output = Path(args.output).resolve()
    features = ensure_exists(features, "feature file")
    output.mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable,
        str(train_script()),
        str(features),
        str(output),
        "--epochs",
        str(args.epochs),
        "--batch-size",
        str(args.batch_size),
        "--sequence-length",
        str(args.sequence_length),
        "--lr",
        str(args.lr),
        "--lr-decay",
        str(args.lr_decay),
        "--cond-size",
        str(args.cond_size),
        "--gru-size",
        str(args.gru_size),
        "--gamma",
        str(args.gamma),
        "--suffix",
        args.suffix,
    ]
    if args.initial_checkpoint:
        cmd.extend(["--initial-checkpoint", str(Path(args.initial_checkpoint).resolve())])
    run(cmd)

    checkpoint = latest_checkpoint(output / "checkpoints")
    print(f"[wiredeck-rnnoise] latest checkpoint: {checkpoint}")
    return 0


def export_c(checkpoint: Path, export_dir: Path, quantize: bool) -> tuple[Path, Path]:
    checkpoint = ensure_exists(checkpoint, "checkpoint")
    export_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable,
        str(dump_script()),
        str(checkpoint),
        str(export_dir),
        "--export-filename",
        "rnnoise_data",
    ]
    if quantize:
        cmd.append("--quantize")
    run(cmd)

    c_path = export_dir / "rnnoise_data.c"
    h_path = export_dir / "rnnoise_data.h"
    ensure_exists(c_path, "exported C weights source")
    ensure_exists(h_path, "exported C weights header")
    return c_path, h_path


def build_blob(export_dir: Path, checkpoint: Path, quantize: bool) -> tuple[Path, Path]:
    c_path, h_path = export_c(checkpoint, export_dir, quantize)
    compiler = os.environ.get("CC", "cc")

    with tempfile.TemporaryDirectory(prefix="wiredeck-rnnoise-blob-") as temp_dir_str:
        temp_dir = Path(temp_dir_str)
        temp_write_weights = temp_dir / "write_weights.c"
        shutil.copy2(write_weights_source(), temp_write_weights)
        shutil.copy2(c_path, temp_dir / "rnnoise_data.c")
        shutil.copy2(h_path, temp_dir / "rnnoise_data.h")

        binary = temp_dir / "dump_weights_blob"
        compile_cmd = [
            compiler,
            "-O2",
            "-DDUMP_BINARY_WEIGHTS",
            "-I",
            str(rnnoise_include_root()),
            str(temp_write_weights),
            "-lm",
            "-o",
            str(binary),
        ]
        run(compile_cmd, cwd=temp_dir)
        run([str(binary)], cwd=temp_dir)

        blob_path = temp_dir / "weights_blob.bin"
        blob_path = ensure_exists(blob_path, "weights blob")
        final_blob = export_dir / "weights_blob.bin"
        shutil.copy2(blob_path, final_blob)

    manifest_path = export_dir / "manifest.json"
    manifest = {
        "checkpoint": str(checkpoint.resolve()),
        "checkpoint_sha256": sha256_file(checkpoint),
        "blob": str((export_dir / "weights_blob.bin").resolve()),
        "blob_sha256": sha256_file(export_dir / "weights_blob.bin"),
        "quantized": quantize,
        "export_dir": str(export_dir.resolve()),
        "vendor_rnnoise": str(vendor_root().resolve()),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return export_dir / "weights_blob.bin", manifest_path


def cmd_export_blob(args: argparse.Namespace) -> int:
    checkpoint = Path(args.checkpoint).resolve()
    checkpoint = ensure_exists(checkpoint, "checkpoint")
    checkpoint_kind = classify_checkpoint(checkpoint)
    if checkpoint_kind == "gpu":
        output = Path(args.output).resolve()
        raise SystemExit(
            "export-blob only supports classic RNNoise checkpoints.\n"
            f"The checkpoint looks like a WireDeck GPU checkpoint: {checkpoint}\n"
            "Use:\n"
            f"  wiredeck-rnnoise export-gpu-model {output} --checkpoint {checkpoint}"
        )

    export_dir = Path(args.output).resolve()
    if export_dir.suffix:
        raise SystemExit(
            "export-blob expects an output directory, not a file path.\n"
            f"Received: {export_dir}\n"
            "Example:\n"
            f"  wiredeck-rnnoise export-blob {checkpoint} ./artifacts/run-001/export --quantize"
        )
    blob_path, manifest_path = build_blob(export_dir, checkpoint, args.quantize)
    print(f"[wiredeck-rnnoise] blob: {blob_path}")
    print(f"[wiredeck-rnnoise] manifest: {manifest_path}")
    return 0


def cmd_install_blob(args: argparse.Namespace) -> int:
    blob = Path(args.blob).resolve()
    manifest = Path(args.manifest).resolve()
    target_dir = Path(args.target).resolve()
    blob = ensure_exists(blob, "blob")
    manifest = ensure_exists(manifest, "manifest")
    target_dir.mkdir(parents=True, exist_ok=True)

    target_blob = target_dir / "weights_blob.bin"
    target_manifest = target_dir / "manifest.json"
    shutil.copy2(blob, target_blob)
    shutil.copy2(manifest, target_manifest)

    print(f"[wiredeck-rnnoise] installed blob to: {target_blob}")
    print(f"[wiredeck-rnnoise] installed manifest to: {target_manifest}")
    return 0


def cmd_describe_gpu_model(args: argparse.Namespace) -> int:
    try:
        from wiredeck_rnnoise_trainer.gpu_model import WireDeckVoiceDenoiser, WireDeckVoiceDenoiserConfig
    except ModuleNotFoundError as exc:
        raise SystemExit("torch is required for GPU model commands; install project dependencies first") from exc

    config = WireDeckVoiceDenoiserConfig(
        bands=args.bands,
        channels=args.channels,
        hidden_channels=args.hidden_channels,
        residual_blocks=args.residual_blocks,
        kernel_time=args.kernel_time,
        kernel_freq=args.kernel_freq,
        lookahead_frames=args.lookahead_frames,
    )
    model = WireDeckVoiceDenoiser(config)
    param_count = sum(param.numel() for param in model.parameters())
    description = {
        "model": "WireDeckVoiceDenoiser",
        "parameter_count": param_count,
        "config": asdict(config),
        "runtime_target": "Vulkan compute via Zig",
        "input_layout": "BTF",
        "runtime_layout": "NHWC",
    }
    print(json.dumps(description, indent=2))
    return 0


def cmd_export_gpu_model(args: argparse.Namespace) -> int:
    try:
        import torch
        from wiredeck_rnnoise_trainer.gpu_export import build_metadata, serialize_model
        from wiredeck_rnnoise_trainer.gpu_model import WireDeckVoiceDenoiser, WireDeckVoiceDenoiserConfig
    except ModuleNotFoundError as exc:
        raise SystemExit("torch is required for GPU model commands; install project dependencies first") from exc

    checkpoint = Path(args.checkpoint).resolve() if args.checkpoint else None
    output = normalize_gpu_export_output(Path(args.output).resolve())

    config_kwargs = {
        "bands": args.bands,
        "channels": args.channels,
        "hidden_channels": args.hidden_channels,
        "residual_blocks": args.residual_blocks,
        "kernel_time": args.kernel_time,
        "kernel_freq": args.kernel_freq,
        "lookahead_frames": args.lookahead_frames,
    }
    state: object | None = None

    if checkpoint is not None:
        checkpoint = ensure_exists(checkpoint, "gpu checkpoint")
        state = torch.load(checkpoint, map_location="cpu")
        if isinstance(state, dict) and isinstance(state.get("config"), dict):
            checkpoint_config = state["config"]
            if isinstance(checkpoint_config, dict):
                config_kwargs.update(checkpoint_config)

    config = WireDeckVoiceDenoiserConfig(**config_kwargs)
    model = WireDeckVoiceDenoiser(config)

    if state is not None:
        if isinstance(state, dict) and "state_dict" in state:
            model.load_state_dict(state["state_dict"], strict=False)
        else:
            model.load_state_dict(state, strict=False)

    metadata = build_metadata(
        model_name="WireDeckVoiceDenoiser",
        sample_rate_hz=args.sample_rate_hz,
        stft_size=args.stft_size,
        hop_size=args.hop_size,
        config=config,
    )
    serialize_model(model, output, metadata)
    print(f"[wiredeck-rnnoise] exported gpu model to: {output}")
    return 0


def cmd_prepare_speech_corpus(args: argparse.Namespace) -> int:
    try:
        from wiredeck_rnnoise_trainer.audio_corpus import normalize_corpus
    except ModuleNotFoundError as exc:
        raise SystemExit("audio corpus tooling is unavailable") from exc

    input_root = Path(args.input).resolve()
    output_root = Path(args.output).resolve()
    input_root = ensure_exists(input_root, "speech dataset directory or archive")
    ffmpeg = require_tool("ffmpeg")
    manifest = normalize_corpus(input_root, output_root, ffmpeg_bin=ffmpeg, limit=args.limit)
    print(f"[wiredeck-rnnoise] normalized files: {manifest['count']}")
    if manifest.get("failed_count"):
        print(f"[wiredeck-rnnoise] skipped unreadable files: {manifest['failed_count']}")
        print(f"[wiredeck-rnnoise] failed files log: {output_root / 'failed_files.json'}")
    print(f"[wiredeck-rnnoise] manifest: {output_root / 'manifest.json'}")
    return 0


def cmd_train_gpu(args: argparse.Namespace) -> int:
    try:
        from wiredeck_rnnoise_trainer.gpu_model import WireDeckVoiceDenoiserConfig
        from wiredeck_rnnoise_trainer.gpu_train import train_gpu_model
    except ModuleNotFoundError as exc:
        raise SystemExit("torch is required for GPU training commands; install project dependencies first") from exc

    speech_dir = Path(args.speech_dir).resolve()
    noise_dir = Path(args.noise_dir).resolve()
    output_dir = Path(args.output).resolve()
    initial_checkpoint = Path(args.initial_checkpoint).resolve() if args.initial_checkpoint else None
    speech_dir = ensure_exists(speech_dir, "normalized speech directory")
    noise_dir = ensure_exists(noise_dir, "normalized noise directory")
    if initial_checkpoint is not None:
        initial_checkpoint = ensure_exists(initial_checkpoint, "initial gpu checkpoint")

    config = WireDeckVoiceDenoiserConfig(
        bands=args.bands,
        channels=args.channels,
        hidden_channels=args.hidden_channels,
        residual_blocks=args.residual_blocks,
        kernel_time=args.kernel_time,
        kernel_freq=args.kernel_freq,
        lookahead_frames=args.lookahead_frames,
    )
    summary = train_gpu_model(
        speech_dir=speech_dir,
        noise_dir=noise_dir,
        output_dir=output_dir,
        config=config,
        epochs=args.epochs,
        batch_size=args.batch_size,
        learning_rate=args.lr,
        samples_per_epoch=args.samples_per_epoch,
        sample_rate_hz=args.sample_rate_hz,
        clip_seconds=args.clip_seconds,
        stft_size=args.stft_size,
        hop_size=args.hop_size,
        num_workers=args.num_workers,
        device_name=args.device,
        allow_cpu=args.allow_cpu,
        initial_checkpoint=initial_checkpoint,
        seed=args.seed,
        contrib_repeat=args.contrib_repeat,
        synthetic_repeat=args.synthetic_repeat,
        foreground_repeat=args.foreground_repeat,
        background_repeat=args.background_repeat,
        musan_repeat=args.musan_repeat,
        speech_noise_repeat=args.speech_noise_repeat,
        clean_probability=args.clean_probability,
        noise_only_probability=args.noise_only_probability,
        snr_min_db=args.snr_min_db,
        snr_max_db=args.snr_max_db,
        speech_gain_min_db=args.speech_gain_min_db,
        speech_gain_max_db=args.speech_gain_max_db,
        low_speech_probability=args.low_speech_probability,
        low_speech_extra_min_db=args.low_speech_extra_min_db,
        low_speech_extra_max_db=args.low_speech_extra_max_db,
        vad_positive_snr_db=args.vad_positive_snr_db,
        vad_negative_snr_db=args.vad_negative_snr_db,
        vad_energy_threshold=args.vad_energy_threshold,
        vad_loss_weight=args.vad_loss_weight,
    )
    print(f"[wiredeck-rnnoise] device: {summary['device']}")
    print(f"[wiredeck-rnnoise] best checkpoint: {summary['best_checkpoint']}")
    print(f"[wiredeck-rnnoise] summary: {output_dir / 'training_summary.json'}")
    return 0


def cmd_train_gpu_supervised(args: argparse.Namespace) -> int:
    try:
        from wiredeck_rnnoise_trainer.gpu_model import WireDeckVoiceDenoiserConfig
        from wiredeck_rnnoise_trainer.gpu_train_supervised import train_gpu_supervised_model
    except ModuleNotFoundError as exc:
        raise SystemExit("torch is required for GPU training commands; install project dependencies first") from exc

    speech_dir = Path(args.speech_dir).resolve()
    noise_dir = Path(args.noise_dir).resolve()
    output_dir = Path(args.output).resolve()
    initial_checkpoint = Path(args.initial_checkpoint).resolve() if args.initial_checkpoint else None
    speech_dir = ensure_exists(speech_dir, "normalized speech directory")
    noise_dir = ensure_exists(noise_dir, "normalized noise directory")
    if initial_checkpoint is not None:
        initial_checkpoint = ensure_exists(initial_checkpoint, "initial gpu checkpoint")

    config = WireDeckVoiceDenoiserConfig(
        bands=args.bands,
        channels=args.channels,
        hidden_channels=args.hidden_channels,
        residual_blocks=args.residual_blocks,
        kernel_time=args.kernel_time,
        kernel_freq=args.kernel_freq,
        lookahead_frames=args.lookahead_frames,
    )
    summary = train_gpu_supervised_model(
        speech_dir=speech_dir,
        noise_dir=noise_dir,
        output_dir=output_dir,
        config=config,
        epochs=args.epochs,
        batch_size=args.batch_size,
        learning_rate=args.lr,
        samples_per_epoch=args.samples_per_epoch,
        sample_rate_hz=args.sample_rate_hz,
        clip_seconds=args.clip_seconds,
        stft_size=args.stft_size,
        hop_size=args.hop_size,
        num_workers=args.num_workers,
        device_name=args.device,
        allow_cpu=args.allow_cpu,
        initial_checkpoint=initial_checkpoint,
        seed=args.seed,
        contrib_repeat=args.contrib_repeat,
        synthetic_repeat=args.synthetic_repeat,
        foreground_repeat=args.foreground_repeat,
        background_repeat=args.background_repeat,
        musan_repeat=args.musan_repeat,
        speech_noise_repeat=args.speech_noise_repeat,
        clean_probability=args.clean_probability,
        noise_only_probability=args.noise_only_probability,
        snr_min_db=args.snr_min_db,
        snr_max_db=args.snr_max_db,
        speech_gain_min_db=args.speech_gain_min_db,
        speech_gain_max_db=args.speech_gain_max_db,
        low_speech_probability=args.low_speech_probability,
        low_speech_extra_min_db=args.low_speech_extra_min_db,
        low_speech_extra_max_db=args.low_speech_extra_max_db,
        vad_positive_snr_db=args.vad_positive_snr_db,
        vad_negative_snr_db=args.vad_negative_snr_db,
        vad_energy_threshold=args.vad_energy_threshold,
        vad_loss_weight=args.vad_loss_weight,
        state_loss_weight=args.state_loss_weight,
        state_noise_energy_threshold=args.state_noise_energy_threshold,
        state_speech_dominant_snr_db=args.state_speech_dominant_snr_db,
        state_noise_dominant_snr_db=args.state_noise_dominant_snr_db,
        state_hidden_channels=args.state_hidden_channels,
    )
    print(f"[wiredeck-rnnoise] device: {summary['device']}")
    print(f"[wiredeck-rnnoise] best checkpoint: {summary['best_checkpoint']}")
    print(f"[wiredeck-rnnoise] summary: {output_dir / 'training_summary.json'}")
    return 0


def cmd_denoise_audio(args: argparse.Namespace) -> int:
    try:
        from wiredeck_rnnoise_trainer.gpu_infer import denoise_audio_file
    except ModuleNotFoundError as exc:
        raise SystemExit("torch is required for offline denoise commands; install project dependencies first") from exc

    checkpoint = Path(args.checkpoint).resolve()
    input_path = Path(args.input).resolve()
    output_path = Path(args.output).resolve()
    checkpoint = ensure_exists(checkpoint, "gpu checkpoint")
    input_path = ensure_exists(input_path, "input audio")

    summary = denoise_audio_file(
        checkpoint,
        input_path,
        output_path,
        device_name=args.device,
        allow_cpu=args.allow_cpu,
        max_seconds=args.max_seconds,
        sample_rate_hz=args.sample_rate_hz,
        stft_size=args.stft_size,
        hop_size=args.hop_size,
        vad_json_path=Path(args.vad_json).resolve() if args.vad_json else None,
    )
    print(f"[wiredeck-rnnoise] device: {summary['device']}")
    print(f"[wiredeck-rnnoise] output: {output_path}")
    print(f"[wiredeck-rnnoise] vad_mean: {summary['vad_mean']:.4f}")
    print(f"[wiredeck-rnnoise] mask_mean: {summary['mask_mean']:.4f}")
    if args.vad_json:
        print(f"[wiredeck-rnnoise] vad summary: {Path(args.vad_json).resolve()}")
    return 0


def cmd_denoise_checkpoints(args: argparse.Namespace) -> int:
    try:
        from wiredeck_rnnoise_trainer.gpu_infer import denoise_audio_file
    except ModuleNotFoundError as exc:
        raise SystemExit("torch is required for offline denoise commands; install project dependencies first") from exc

    checkpoint_dir = Path(args.checkpoint_dir).resolve()
    input_path = Path(args.input).resolve()
    output_dir = Path(args.output_dir).resolve()
    checkpoint_dir = ensure_exists(checkpoint_dir, "checkpoint directory")
    input_path = ensure_exists(input_path, "input audio")
    if not checkpoint_dir.is_dir():
        raise SystemExit(f"checkpoint directory is not a directory: {checkpoint_dir}")

    checkpoints = list_checkpoint_files(checkpoint_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    for checkpoint in checkpoints:
        output_name = f"{checkpoint.stem} - {input_path.stem}.wav"
        output_path = output_dir / output_name
        summary = denoise_audio_file(
            checkpoint,
            input_path,
            output_path,
            device_name=args.device,
            allow_cpu=args.allow_cpu,
            max_seconds=args.max_seconds,
            sample_rate_hz=args.sample_rate_hz,
            stft_size=args.stft_size,
            hop_size=args.hop_size,
            vad_json_path=None,
        )
        print(
            "[wiredeck-rnnoise] checkpoint: {checkpoint} -> {output} vad_mean={vad:.4f} mask_mean={mask:.4f}".format(
                checkpoint=checkpoint.name,
                output=output_path,
                vad=summary["vad_mean"],
                mask=summary["mask_mean"],
            )
        )

    print(f"[wiredeck-rnnoise] processed checkpoints: {len(checkpoints)}")
    print(f"[wiredeck-rnnoise] output directory: {output_dir}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wiredeck-rnnoise",
        description="Train, evaluate, and export RNNoise-compatible denoisers for WireDeck.",
        epilog=(
            "Common workflows:\n"
            "  wiredeck-rnnoise list-datasets\n"
            "  wiredeck-rnnoise prepare-speech-corpus ./speech_archives ./data/normalized_speech\n"
            "  wiredeck-rnnoise prepare-audio-corpus ./noise_archives ./data/normalized_noise\n"
            "  wiredeck-rnnoise train-gpu ./data/normalized_speech/audio ./data/normalized_noise/audio ./artifacts/run-001\n"
            "  wiredeck-rnnoise export-gpu-model ./artifacts/run-001/wiredeck_gpu_model.bin --checkpoint ./artifacts/run-001/checkpoints/wiredeck_gpu_epoch_020.pt"
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    subparsers = parser.add_subparsers(
        dest="command",
        required=True,
        title="commands",
        metavar="COMMAND",
    )

    list_parser = subparsers.add_parser("list-datasets", help="list speech datasets from vendor/rnnoise/datasets.txt")
    list_parser.set_defaults(func=cmd_list_datasets)

    list_noise_parser = subparsers.add_parser("list-noise-datasets", help="list curated noise datasets for GPU/RNNoise training")
    list_noise_parser.set_defaults(func=cmd_list_noise_datasets)

    download_parser = subparsers.add_parser("download-datasets", help="download speech datasets listed in vendor/rnnoise/datasets.txt")
    download_parser.add_argument("output", help="directory where archives will be stored")
    download_parser.add_argument("--limit", type=int, help="download only the first N datasets")
    download_parser.add_argument("--force", action="store_true", help="re-download files even if they already exist")
    download_parser.set_defaults(func=cmd_download_datasets)

    download_noise_parser = subparsers.add_parser("download-noise-datasets", help="download curated noise datasets for denoiser training")
    download_noise_parser.add_argument("output", help="directory where archives will be stored")
    download_noise_parser.add_argument("--limit", type=int, help="download only the first N datasets")
    download_noise_parser.add_argument("--force", action="store_true", help="re-download files even if they already exist")
    download_noise_parser.add_argument("--strict", action="store_true", help="fail immediately if any curated noise URL is unavailable")
    download_noise_parser.set_defaults(func=cmd_download_noise_datasets)

    generate_parser = subparsers.add_parser("generate-features", help="generate features.f32 from speech and noise audio")
    generate_parser.add_argument("speech", help="speech audio file (.wav or .pcm)")
    generate_parser.add_argument("noise", help="noise audio file (.wav or .pcm)")
    generate_parser.add_argument("output", help="output features.f32 path")
    generate_parser.add_argument("--count", type=int, required=True, help="number of sequences to generate per worker")
    generate_parser.add_argument("--workers", type=int, default=1, help="number of extractor runs to concatenate")
    generate_parser.add_argument("--rir-list", help="optional path to RIR list file")
    generate_parser.set_defaults(func=cmd_generate_features)

    train_parser = subparsers.add_parser("train", help="train an RNNoise checkpoint")
    train_parser.add_argument("features", help="path to features.f32")
    train_parser.add_argument("output", help="training output directory")
    train_parser.add_argument("--epochs", type=int, default=200)
    train_parser.add_argument("--batch-size", type=int, default=128)
    train_parser.add_argument("--sequence-length", type=int, default=2000)
    train_parser.add_argument("--lr", type=float, default=1e-3)
    train_parser.add_argument("--lr-decay", type=float, default=5e-5)
    train_parser.add_argument("--cond-size", type=int, default=128)
    train_parser.add_argument("--gru-size", type=int, default=384)
    train_parser.add_argument("--gamma", type=float, default=0.1667)
    train_parser.add_argument("--suffix", default="")
    train_parser.add_argument("--initial-checkpoint")
    train_parser.set_defaults(func=cmd_train)

    export_blob_parser = subparsers.add_parser("export-blob", help="export a checkpoint to weights_blob.bin")
    export_blob_parser.add_argument("checkpoint", help="path to .pth checkpoint")
    export_blob_parser.add_argument("output", help="export directory")
    export_blob_parser.add_argument("--quantize", action="store_true")
    export_blob_parser.set_defaults(func=cmd_export_blob)

    install_blob_parser = subparsers.add_parser("install-blob", help="copy a generated blob and manifest to a target directory")
    install_blob_parser.add_argument("blob", help="path to weights_blob.bin")
    install_blob_parser.add_argument("manifest", help="path to manifest.json")
    install_blob_parser.add_argument("target", help="target directory")
    install_blob_parser.set_defaults(func=cmd_install_blob)

    describe_gpu_parser = subparsers.add_parser("describe-gpu-model", help="describe the GPU-first denoiser architecture")
    describe_gpu_parser.add_argument("--bands", type=int, default=64)
    describe_gpu_parser.add_argument("--channels", type=int, default=48)
    describe_gpu_parser.add_argument("--hidden-channels", type=int, default=96)
    describe_gpu_parser.add_argument("--residual-blocks", type=int, default=6)
    describe_gpu_parser.add_argument("--kernel-time", type=int, default=5)
    describe_gpu_parser.add_argument("--kernel-freq", type=int, default=3)
    describe_gpu_parser.add_argument("--lookahead-frames", type=int, default=2)
    describe_gpu_parser.set_defaults(func=cmd_describe_gpu_model)

    export_gpu_parser = subparsers.add_parser("export-gpu-model", help="export a GPU-first model binary for Zig/Vulkan")
    export_gpu_parser.add_argument("output", help="output binary path")
    export_gpu_parser.add_argument("--checkpoint", help="optional checkpoint path")
    export_gpu_parser.add_argument("--bands", type=int, default=64)
    export_gpu_parser.add_argument("--channels", type=int, default=48)
    export_gpu_parser.add_argument("--hidden-channels", type=int, default=96)
    export_gpu_parser.add_argument("--residual-blocks", type=int, default=6)
    export_gpu_parser.add_argument("--kernel-time", type=int, default=5)
    export_gpu_parser.add_argument("--kernel-freq", type=int, default=3)
    export_gpu_parser.add_argument("--lookahead-frames", type=int, default=2)
    export_gpu_parser.add_argument("--sample-rate-hz", type=int, default=48_000)
    export_gpu_parser.add_argument("--stft-size", type=int, default=512)
    export_gpu_parser.add_argument("--hop-size", type=int, default=128)
    export_gpu_parser.set_defaults(func=cmd_export_gpu_model)

    prepare_speech_parser = subparsers.add_parser(
        "prepare-speech-corpus",
        help="extract archives and normalize speech audio to 48 kHz mono PCM WAV",
    )
    prepare_speech_parser.add_argument("input", help="dataset directory or archive path")
    prepare_speech_parser.add_argument("output", help="normalized corpus output directory")
    prepare_speech_parser.add_argument("--limit", type=int, help="normalize only the first N audio files")
    prepare_speech_parser.set_defaults(func=cmd_prepare_speech_corpus)

    prepare_audio_parser = subparsers.add_parser(
        "prepare-audio-corpus",
        help="extract archives and normalize arbitrary audio corpora to 48 kHz mono PCM WAV",
    )
    prepare_audio_parser.add_argument("input", help="dataset directory or archive path")
    prepare_audio_parser.add_argument("output", help="normalized corpus output directory")
    prepare_audio_parser.add_argument("--limit", type=int, help="normalize only the first N audio files")
    prepare_audio_parser.set_defaults(func=cmd_prepare_speech_corpus)

    train_gpu_parser = subparsers.add_parser("train-gpu", help="train the GPU-first denoiser on normalized speech/noise corpora")
    train_gpu_parser.add_argument("speech_dir", help="directory with normalized speech WAV files")
    train_gpu_parser.add_argument("noise_dir", help="directory with normalized noise WAV files")
    train_gpu_parser.add_argument("output", help="training output directory")
    train_gpu_parser.add_argument("--epochs", type=int, default=20)
    train_gpu_parser.add_argument("--batch-size", type=int, default=16)
    train_gpu_parser.add_argument("--samples-per-epoch", type=int, default=2048)
    train_gpu_parser.add_argument("--clip-seconds", type=float, default=2.0)
    train_gpu_parser.add_argument("--lr", type=float, default=2e-4)
    train_gpu_parser.add_argument("--num-workers", type=int, default=2)
    train_gpu_parser.add_argument("--device", help="explicit torch device, e.g. cuda, cuda:0, mps")
    train_gpu_parser.add_argument("--allow-cpu", action="store_true", help="allow CPU fallback if no GPU backend is available")
    train_gpu_parser.add_argument("--initial-checkpoint", help="resume GPU training from an existing .pt checkpoint")
    train_gpu_parser.add_argument("--seed", type=int, default=0)
    train_gpu_parser.add_argument("--bands", type=int, default=64)
    train_gpu_parser.add_argument("--channels", type=int, default=48)
    train_gpu_parser.add_argument("--hidden-channels", type=int, default=96)
    train_gpu_parser.add_argument("--residual-blocks", type=int, default=6)
    train_gpu_parser.add_argument("--kernel-time", type=int, default=5)
    train_gpu_parser.add_argument("--kernel-freq", type=int, default=3)
    train_gpu_parser.add_argument("--lookahead-frames", type=int, default=2)
    train_gpu_parser.add_argument("--sample-rate-hz", type=int, default=48_000)
    train_gpu_parser.add_argument("--stft-size", type=int, default=512)
    train_gpu_parser.add_argument("--hop-size", type=int, default=128)
    train_gpu_parser.add_argument("--contrib-repeat", type=int, default=5, help="oversample contrib_noise clips during training")
    train_gpu_parser.add_argument("--synthetic-repeat", type=int, default=5, help="oversample synthetic_noise clips during training")
    train_gpu_parser.add_argument("--foreground-repeat", type=int, default=2, help="oversample foreground transient clips during training")
    train_gpu_parser.add_argument("--background-repeat", type=int, default=1, help="repeat background_noise clips during training")
    train_gpu_parser.add_argument("--musan-repeat", type=int, default=1, help="repeat MUSAN-derived clips during training")
    train_gpu_parser.add_argument("--speech-noise-repeat", type=int, default=4, help="oversample custom noise clips whose filename suggests human speech/crowd/background voices")
    train_gpu_parser.add_argument("--clean-probability", type=float, default=0.0, help="fraction of training samples with clean speech only, to preserve voice identity")
    train_gpu_parser.add_argument("--noise-only-probability", type=float, default=0.15, help="fraction of training samples with noise only, to teach the VAD that loud noise is not speech")
    train_gpu_parser.add_argument("--snr-min-db", type=float, default=-5.0, help="minimum SNR for noisy training mixtures")
    train_gpu_parser.add_argument("--snr-max-db", type=float, default=20.0, help="maximum SNR for noisy training mixtures")
    train_gpu_parser.add_argument("--speech-gain-min-db", type=float, default=-18.0, help="minimum random speech gain applied before mixing")
    train_gpu_parser.add_argument("--speech-gain-max-db", type=float, default=3.0, help="maximum random speech gain applied before mixing")
    train_gpu_parser.add_argument("--low-speech-probability", type=float, default=0.35, help="fraction of examples that receive extra attenuation to simulate quiet voices")
    train_gpu_parser.add_argument("--low-speech-extra-min-db", type=float, default=-18.0, help="minimum extra attenuation for quiet-speech examples")
    train_gpu_parser.add_argument("--low-speech-extra-max-db", type=float, default=-6.0, help="maximum extra attenuation for quiet-speech examples")
    train_gpu_parser.add_argument("--vad-positive-snr-db", type=float, default=3.0, help="minimum per-frame speech-over-noise SNR for a confident VAD target")
    train_gpu_parser.add_argument("--vad-negative-snr-db", type=float, default=-6.0, help="per-frame speech-over-noise SNR that maps to a zero VAD target")
    train_gpu_parser.add_argument("--vad-energy-threshold", type=float, default=0.02, help="minimum clean speech band energy for VAD supervision")
    train_gpu_parser.add_argument("--vad-loss-weight", type=float, default=0.5, help="relative weight of the VAD loss during training")
    train_gpu_parser.set_defaults(func=cmd_train_gpu)

    train_gpu_supervised_parser = subparsers.add_parser("train-gpu-supervised", help="train the GPU denoiser with extra frame-state supervision")
    train_gpu_supervised_parser.add_argument("speech_dir", help="directory with normalized speech WAV files")
    train_gpu_supervised_parser.add_argument("noise_dir", help="directory with normalized noise WAV files")
    train_gpu_supervised_parser.add_argument("output", help="training output directory")
    train_gpu_supervised_parser.add_argument("--epochs", type=int, default=20)
    train_gpu_supervised_parser.add_argument("--batch-size", type=int, default=16)
    train_gpu_supervised_parser.add_argument("--samples-per-epoch", type=int, default=2048)
    train_gpu_supervised_parser.add_argument("--clip-seconds", type=float, default=2.0)
    train_gpu_supervised_parser.add_argument("--lr", type=float, default=2e-4)
    train_gpu_supervised_parser.add_argument("--num-workers", type=int, default=2)
    train_gpu_supervised_parser.add_argument("--device", help="explicit torch device, e.g. cuda, cuda:0, mps")
    train_gpu_supervised_parser.add_argument("--allow-cpu", action="store_true", help="allow CPU fallback if no GPU backend is available")
    train_gpu_supervised_parser.add_argument("--initial-checkpoint", help="resume GPU training from an existing .pt checkpoint")
    train_gpu_supervised_parser.add_argument("--seed", type=int, default=0)
    train_gpu_supervised_parser.add_argument("--bands", type=int, default=64)
    train_gpu_supervised_parser.add_argument("--channels", type=int, default=48)
    train_gpu_supervised_parser.add_argument("--hidden-channels", type=int, default=96)
    train_gpu_supervised_parser.add_argument("--residual-blocks", type=int, default=6)
    train_gpu_supervised_parser.add_argument("--kernel-time", type=int, default=5)
    train_gpu_supervised_parser.add_argument("--kernel-freq", type=int, default=3)
    train_gpu_supervised_parser.add_argument("--lookahead-frames", type=int, default=2)
    train_gpu_supervised_parser.add_argument("--sample-rate-hz", type=int, default=48_000)
    train_gpu_supervised_parser.add_argument("--stft-size", type=int, default=512)
    train_gpu_supervised_parser.add_argument("--hop-size", type=int, default=128)
    train_gpu_supervised_parser.add_argument("--contrib-repeat", type=int, default=5)
    train_gpu_supervised_parser.add_argument("--synthetic-repeat", type=int, default=5)
    train_gpu_supervised_parser.add_argument("--foreground-repeat", type=int, default=2)
    train_gpu_supervised_parser.add_argument("--background-repeat", type=int, default=1)
    train_gpu_supervised_parser.add_argument("--musan-repeat", type=int, default=1)
    train_gpu_supervised_parser.add_argument("--speech-noise-repeat", type=int, default=4)
    train_gpu_supervised_parser.add_argument("--clean-probability", type=float, default=0.0)
    train_gpu_supervised_parser.add_argument("--noise-only-probability", type=float, default=0.15)
    train_gpu_supervised_parser.add_argument("--snr-min-db", type=float, default=-5.0)
    train_gpu_supervised_parser.add_argument("--snr-max-db", type=float, default=20.0)
    train_gpu_supervised_parser.add_argument("--speech-gain-min-db", type=float, default=-18.0)
    train_gpu_supervised_parser.add_argument("--speech-gain-max-db", type=float, default=3.0)
    train_gpu_supervised_parser.add_argument("--low-speech-probability", type=float, default=0.35)
    train_gpu_supervised_parser.add_argument("--low-speech-extra-min-db", type=float, default=-18.0)
    train_gpu_supervised_parser.add_argument("--low-speech-extra-max-db", type=float, default=-6.0)
    train_gpu_supervised_parser.add_argument("--vad-positive-snr-db", type=float, default=3.0)
    train_gpu_supervised_parser.add_argument("--vad-negative-snr-db", type=float, default=-6.0)
    train_gpu_supervised_parser.add_argument("--vad-energy-threshold", type=float, default=0.02)
    train_gpu_supervised_parser.add_argument("--vad-loss-weight", type=float, default=0.5)
    train_gpu_supervised_parser.add_argument("--state-loss-weight", type=float, default=0.2, help="relative weight of the auxiliary frame-state loss")
    train_gpu_supervised_parser.add_argument("--state-noise-energy-threshold", type=float, default=0.01, help="minimum per-frame noise band energy used to label a frame as noise-present")
    train_gpu_supervised_parser.add_argument("--state-speech-dominant-snr-db", type=float, default=6.0, help="per-frame SNR threshold above which speech-dominant frames become the speech class")
    train_gpu_supervised_parser.add_argument("--state-noise-dominant-snr-db", type=float, default=-3.0, help="per-frame SNR threshold below which frames become the noise class")
    train_gpu_supervised_parser.add_argument("--state-hidden-channels", type=int, help="hidden width for the auxiliary supervision head; defaults to hidden-channels")
    train_gpu_supervised_parser.set_defaults(func=cmd_train_gpu_supervised)

    denoise_audio_parser = subparsers.add_parser("denoise-audio", help="run offline denoise on a noisy audio file using a GPU checkpoint")
    denoise_audio_parser.add_argument("checkpoint", help="path to a trained .pt checkpoint")
    denoise_audio_parser.add_argument("input", help="path to noisy input audio")
    denoise_audio_parser.add_argument("output", help="path to denoised WAV output")
    denoise_audio_parser.add_argument("--device", help="explicit torch device, e.g. cuda:1")
    denoise_audio_parser.add_argument("--allow-cpu", action="store_true", help="allow CPU fallback if no GPU backend is available")
    denoise_audio_parser.add_argument("--max-seconds", type=float, help="optionally limit processing to the first N seconds")
    denoise_audio_parser.add_argument("--sample-rate-hz", type=int, default=48_000)
    denoise_audio_parser.add_argument("--stft-size", type=int, default=512)
    denoise_audio_parser.add_argument("--hop-size", type=int, default=128)
    denoise_audio_parser.add_argument("--vad-json", help="optional path to write a VAD summary JSON")
    denoise_audio_parser.set_defaults(func=cmd_denoise_audio)

    denoise_checkpoints_parser = subparsers.add_parser(
        "denoise-checkpoints",
        help="run offline denoise for every checkpoint in a directory using the same input audio",
    )
    denoise_checkpoints_parser.add_argument("checkpoint_dir", help="directory containing .pt or .pth checkpoints")
    denoise_checkpoints_parser.add_argument("input", help="path to noisy input audio")
    denoise_checkpoints_parser.add_argument("output_dir", help="directory where one WAV per checkpoint will be written")
    denoise_checkpoints_parser.add_argument("--device", help="explicit torch device, e.g. cuda:1")
    denoise_checkpoints_parser.add_argument("--allow-cpu", action="store_true", help="allow CPU fallback if no GPU backend is available")
    denoise_checkpoints_parser.add_argument("--max-seconds", type=float, help="optionally limit processing to the first N seconds")
    denoise_checkpoints_parser.add_argument("--sample-rate-hz", type=int, default=48_000)
    denoise_checkpoints_parser.add_argument("--stft-size", type=int, default=512)
    denoise_checkpoints_parser.add_argument("--hop-size", type=int, default=128)
    denoise_checkpoints_parser.set_defaults(func=cmd_denoise_checkpoints)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
