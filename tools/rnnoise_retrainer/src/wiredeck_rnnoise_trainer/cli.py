from __future__ import annotations

import argparse
from pathlib import Path


def ensure_exists(path: Path, description: str) -> Path:
    if path.exists():
        return path
    raise FileNotFoundError(f"missing {description}: {path}")


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


def list_checkpoint_files(checkpoint_dir: Path) -> list[Path]:
    candidates = sorted(path for path in checkpoint_dir.iterdir() if path.is_file() and path.suffix in {".pt", ".pth"})
    if not candidates:
        raise FileNotFoundError(f"no checkpoint files found in {checkpoint_dir}")
    return candidates


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
            config_kwargs.update(state["config"])

    config = WireDeckVoiceDenoiserConfig(**config_kwargs)
    model = WireDeckVoiceDenoiser(config)

    if state is not None:
        if not isinstance(state, dict):
            raise SystemExit("could not read a compatible state_dict from checkpoint")
        state_dict = state.get("state_dict", state)
        if not isinstance(state_dict, dict):
            raise SystemExit("could not read a compatible state_dict from checkpoint")
        if any(key.startswith("base_model.") for key in state_dict):
            export_state = {
                key[len("base_model."):]: value
                for key, value in state_dict.items()
                if key.startswith("base_model.")
            }
        else:
            export_state = state_dict
        model.load_state_dict(export_state, strict=False)

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
    manifest = normalize_corpus(input_root, output_root, ffmpeg_bin=args.ffmpeg or "ffmpeg", limit=args.limit)
    print(f"[wiredeck-rnnoise] normalized files: {manifest['count']}")
    if manifest.get("failed_count"):
        print(f"[wiredeck-rnnoise] skipped unreadable files: {manifest['failed_count']}")
        print(f"[wiredeck-rnnoise] failed files log: {output_root / 'failed_files.json'}")
    print(f"[wiredeck-rnnoise] manifest: {output_root / 'manifest.json'}")
    return 0


def cmd_train_gpu_supervised(args: argparse.Namespace) -> int:
    try:
        from wiredeck_rnnoise_trainer.gpu_model import WireDeckVoiceDenoiserConfig
        from wiredeck_rnnoise_trainer.gpu_train_supervised import train_gpu_supervised_model
    except ModuleNotFoundError as exc:
        raise SystemExit("torch is required for GPU training commands; install project dependencies first") from exc

    speech_dir = ensure_exists(Path(args.speech_dir).resolve(), "normalized speech directory")
    noise_dir = ensure_exists(Path(args.noise_dir).resolve(), "normalized noise directory")
    output_dir = Path(args.output).resolve()
    initial_checkpoint = Path(args.initial_checkpoint).resolve() if args.initial_checkpoint else None
    if initial_checkpoint is not None:
        initial_checkpoint = ensure_exists(initial_checkpoint, "initial gpu checkpoint")
    preview_audio_path = Path(args.preview_audio).resolve() if args.preview_audio else None
    if preview_audio_path is not None:
        preview_audio_path = ensure_exists(preview_audio_path, "preview audio")

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
        allow_noise_amplification=not args.no_noise_amplify,
        vad_positive_snr_db=args.vad_positive_snr_db,
        vad_negative_snr_db=args.vad_negative_snr_db,
        vad_energy_threshold=args.vad_energy_threshold,
        vad_loss_weight=args.vad_loss_weight,
        state_loss_weight=args.state_loss_weight,
        state_noise_energy_threshold=args.state_noise_energy_threshold,
        state_speech_dominant_snr_db=args.state_speech_dominant_snr_db,
        state_noise_dominant_snr_db=args.state_noise_dominant_snr_db,
        state_hidden_channels=args.state_hidden_channels,
        realtime_supervision=args.realtime_supervision,
        preview_audio_path=preview_audio_path,
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

    checkpoint = ensure_exists(Path(args.checkpoint).resolve(), "gpu checkpoint")
    input_path = ensure_exists(Path(args.input).resolve(), "input audio")
    output_path = Path(args.output).resolve()

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

    checkpoint_dir = ensure_exists(Path(args.checkpoint_dir).resolve(), "checkpoint directory")
    input_path = ensure_exists(Path(args.input).resolve(), "input audio")
    output_dir = Path(args.output_dir).resolve()
    if not checkpoint_dir.is_dir():
        raise SystemExit(f"checkpoint directory is not a directory: {checkpoint_dir}")

    checkpoints = list_checkpoint_files(checkpoint_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    for checkpoint in checkpoints:
        output_name = f"{checkpoint.stem} - {input_path.stem}.wav"
        summary = denoise_audio_file(
            checkpoint,
            input_path,
            output_dir / output_name,
            device_name=args.device,
            allow_cpu=args.allow_cpu,
            max_seconds=args.max_seconds,
            sample_rate_hz=args.sample_rate_hz,
            stft_size=args.stft_size,
            hop_size=args.hop_size,
        )
        print(
            "[wiredeck-rnnoise] checkpoint: {checkpoint} -> {output} vad_mean={vad:.4f} mask_mean={mask:.4f}".format(
                checkpoint=checkpoint.name,
                output=output_name,
                vad=summary["vad_mean"],
                mask=summary["mask_mean"],
            )
        )
    print(f"[wiredeck-rnnoise] processed checkpoints: {len(checkpoints)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wiredeck-rnnoise")
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_gpu_parser = subparsers.add_parser("export-gpu-model", help="export a GPU denoiser binary for the LV2 runtime")
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

    prepare_parser = subparsers.add_parser("prepare-speech-corpus", help="normalize audio files to 48 kHz mono training WAVs")
    prepare_parser.add_argument("input", help="dataset directory or archive path")
    prepare_parser.add_argument("output", help="normalized corpus output directory")
    prepare_parser.add_argument("--limit", type=int, help="normalize only the first N audio files")
    prepare_parser.add_argument("--ffmpeg", help="explicit ffmpeg binary")
    prepare_parser.set_defaults(func=cmd_prepare_speech_corpus)

    prepare_audio_parser = subparsers.add_parser("prepare-audio-corpus", help="alias of prepare-speech-corpus")
    prepare_audio_parser.add_argument("input", help="dataset directory or archive path")
    prepare_audio_parser.add_argument("output", help="normalized corpus output directory")
    prepare_audio_parser.add_argument("--limit", type=int, help="normalize only the first N audio files")
    prepare_audio_parser.add_argument("--ffmpeg", help="explicit ffmpeg binary")
    prepare_audio_parser.set_defaults(func=cmd_prepare_speech_corpus)

    train_parser = subparsers.add_parser("train-gpu-supervised", help="train the supervised GPU denoiser")
    train_parser.add_argument("speech_dir", help="directory with normalized speech WAV files")
    train_parser.add_argument("noise_dir", help="directory with normalized noise WAV files")
    train_parser.add_argument("output", help="training output directory")
    train_parser.add_argument("--epochs", type=int, default=20)
    train_parser.add_argument("--batch-size", type=int, default=16)
    train_parser.add_argument("--samples-per-epoch", type=int, default=2048)
    train_parser.add_argument("--clip-seconds", type=float, default=2.0)
    train_parser.add_argument("--lr", type=float, default=2e-4)
    train_parser.add_argument("--num-workers", type=int, default=2)
    train_parser.add_argument("--device", help="explicit torch device, e.g. cuda, cuda:0, mps")
    train_parser.add_argument("--allow-cpu", action="store_true", help="allow CPU fallback if no GPU backend is available")
    train_parser.add_argument("--initial-checkpoint", help="resume GPU training from an existing .pt checkpoint")
    train_parser.add_argument("--seed", type=int, default=0)
    train_parser.add_argument("--bands", type=int, default=64)
    train_parser.add_argument("--channels", type=int, default=48)
    train_parser.add_argument("--hidden-channels", type=int, default=96)
    train_parser.add_argument("--residual-blocks", type=int, default=6)
    train_parser.add_argument("--kernel-time", type=int, default=5)
    train_parser.add_argument("--kernel-freq", type=int, default=3)
    train_parser.add_argument("--lookahead-frames", type=int, default=2)
    train_parser.add_argument("--sample-rate-hz", type=int, default=48_000)
    train_parser.add_argument("--stft-size", type=int, default=512)
    train_parser.add_argument("--hop-size", type=int, default=128)
    train_parser.add_argument("--contrib-repeat", type=int, default=1)
    train_parser.add_argument("--synthetic-repeat", type=int, default=1)
    train_parser.add_argument("--foreground-repeat", type=int, default=1)
    train_parser.add_argument("--background-repeat", type=int, default=1)
    train_parser.add_argument("--musan-repeat", type=int, default=1)
    train_parser.add_argument("--speech-noise-repeat", type=int, default=3)
    train_parser.add_argument("--clean-probability", type=float, default=0.18)
    train_parser.add_argument("--noise-only-probability", type=float, default=0.10)
    train_parser.add_argument("--snr-min-db", type=float, default=-8.0)
    train_parser.add_argument("--snr-max-db", type=float, default=12.0)
    train_parser.add_argument("--speech-gain-min-db", type=float, default=-18.0)
    train_parser.add_argument("--speech-gain-max-db", type=float, default=3.0)
    train_parser.add_argument("--low-speech-probability", type=float, default=0.25)
    train_parser.add_argument("--low-speech-extra-min-db", type=float, default=-12.0)
    train_parser.add_argument("--low-speech-extra-max-db", type=float, default=-4.0)
    train_parser.add_argument("--no-noise-amplify", action="store_true", help="never scale noise above its original level when matching the target SNR")
    train_parser.add_argument("--vad-positive-snr-db", type=float, default=3.0)
    train_parser.add_argument("--vad-negative-snr-db", type=float, default=-6.0)
    train_parser.add_argument("--vad-energy-threshold", type=float, default=0.02)
    train_parser.add_argument("--vad-loss-weight", type=float, default=0.30)
    train_parser.add_argument("--state-loss-weight", type=float, default=0.08)
    train_parser.add_argument("--state-noise-energy-threshold", type=float, default=0.01)
    train_parser.add_argument("--state-speech-dominant-snr-db", type=float, default=6.0)
    train_parser.add_argument("--state-noise-dominant-snr-db", type=float, default=-3.0)
    train_parser.add_argument("--state-hidden-channels", type=int, help="hidden width for the auxiliary supervision head")
    train_parser.add_argument("--realtime-supervision", action="store_true", help="train on short streaming windows aligned to the LV2 runtime and compute losses only on the exported target frame")
    train_parser.add_argument("--preview-audio", help="optional fixed 48 kHz mono WAV used to render the same preview sample every epoch")
    train_parser.set_defaults(func=cmd_train_gpu_supervised)

    denoise_audio_parser = subparsers.add_parser("denoise-audio", help="run offline denoise on an audio file using a GPU checkpoint")
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

    denoise_checkpoints_parser = subparsers.add_parser("denoise-checkpoints", help="run offline denoise for every checkpoint in a directory using the same input audio")
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


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
