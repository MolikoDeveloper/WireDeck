from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


PRESETS: tuple[dict[str, object], ...] = (
    {
        "name": "tiny_rt",
        "description": "Minimum latency oriented candidate",
        "channels": 24,
        "hidden_channels": 48,
        "residual_blocks": 3,
        "kernel_time": 3,
        "kernel_freq": 3,
        "lookahead_frames": 1,
    },
    {
        "name": "small_rt",
        "description": "Small real-time candidate",
        "channels": 32,
        "hidden_channels": 64,
        "residual_blocks": 4,
        "kernel_time": 3,
        "kernel_freq": 3,
        "lookahead_frames": 1,
    },
    {
        "name": "balanced_rt",
        "description": "Balanced clarity/latency candidate",
        "channels": 40,
        "hidden_channels": 80,
        "residual_blocks": 4,
        "kernel_time": 5,
        "kernel_freq": 3,
        "lookahead_frames": 1,
    },
    {
        "name": "baseline_full",
        "description": "Current stronger baseline",
        "channels": 48,
        "hidden_channels": 96,
        "residual_blocks": 6,
        "kernel_time": 5,
        "kernel_freq": 3,
        "lookahead_frames": 2,
    },
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def retrainer_root() -> Path:
    return repo_root() / "tools" / "rnnoise_retrainer"


def cli_module_args() -> list[str]:
    return [sys.executable, "-m", "wiredeck_rnnoise_trainer.cli"]


def run(cmd: list[str], cwd: Path) -> None:
    rendered = " ".join(cmd)
    print(f"[wiredeck-rnnoise-sweep] running: {rendered}")
    subprocess.run(cmd, cwd=cwd, check=True)


def read_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def write_markdown(path: Path, rows: list[dict[str, object]]) -> None:
    lines = [
        "# Training Sweep Summary",
        "",
        "| preset | description | checkpoint | bin_mb | epochs | batch | samples/epoch | channels | hidden | blocks | kt | kf | lookahead |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            "| {preset} | {description} | `{checkpoint}` | {bin_mb:.3f} | {epochs} | {batch_size} | {samples_per_epoch} | {channels} | {hidden_channels} | {residual_blocks} | {kernel_time} | {kernel_freq} | {lookahead_frames} |".format(
                **row
            )
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def selected_presets(preset_names: list[str] | None) -> list[dict[str, object]]:
    if not preset_names:
        return [dict(preset) for preset in PRESETS]
    by_name = {preset["name"]: preset for preset in PRESETS}
    selected: list[dict[str, object]] = []
    for name in preset_names:
        if name not in by_name:
            raise SystemExit(f"unknown preset: {name}")
        selected.append(dict(by_name[name]))
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description="Train and export a sweep of low-latency denoiser models")
    parser.add_argument("speech_dir")
    parser.add_argument("noise_dir")
    parser.add_argument("output_root")
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--samples-per-epoch", type=int, default=2048)
    parser.add_argument("--num-workers", type=int, default=2)
    parser.add_argument("--clip-seconds", type=float, default=2.0)
    parser.add_argument("--lr", type=float, default=2e-4)
    parser.add_argument("--sample-rate-hz", type=int, default=48_000)
    parser.add_argument("--stft-size", type=int, default=512)
    parser.add_argument("--hop-size", type=int, default=128)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--preset", action="append", help="run only selected preset(s)")
    args = parser.parse_args()

    cwd = retrainer_root()
    speech_dir = str(Path(args.speech_dir).resolve())
    noise_dir = str(Path(args.noise_dir).resolve())
    output_root = Path(args.output_root).resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    rows: list[dict[str, object]] = []
    for preset in selected_presets(args.preset):
        preset_name = str(preset["name"])
        run_dir = output_root / preset_name
        checkpoint_path = run_dir / "checkpoints" / f"wiredeck_gpu_epoch_{args.epochs:03d}.pt"
        export_path = run_dir / "export" / "wiredeck_gpu_model.bin"

        train_cmd = cli_module_args() + [
            "train-gpu",
            speech_dir,
            noise_dir,
            str(run_dir),
            "--device",
            args.device,
            "--epochs",
            str(args.epochs),
            "--batch-size",
            str(args.batch_size),
            "--samples-per-epoch",
            str(args.samples_per_epoch),
            "--num-workers",
            str(args.num_workers),
            "--clip-seconds",
            str(args.clip_seconds),
            "--lr",
            str(args.lr),
            "--sample-rate-hz",
            str(args.sample_rate_hz),
            "--stft-size",
            str(args.stft_size),
            "--hop-size",
            str(args.hop_size),
            "--seed",
            str(args.seed),
            "--channels",
            str(preset["channels"]),
            "--hidden-channels",
            str(preset["hidden_channels"]),
            "--residual-blocks",
            str(preset["residual_blocks"]),
            "--kernel-time",
            str(preset["kernel_time"]),
            "--kernel-freq",
            str(preset["kernel_freq"]),
            "--lookahead-frames",
            str(preset["lookahead_frames"]),
        ]
        run(train_cmd, cwd)

        if not checkpoint_path.exists():
            raise SystemExit(f"expected checkpoint not found: {checkpoint_path}")

        export_cmd = cli_module_args() + [
            "export-gpu-model",
            str(export_path),
            "--checkpoint",
            str(checkpoint_path),
            "--sample-rate-hz",
            str(args.sample_rate_hz),
            "--stft-size",
            str(args.stft_size),
            "--hop-size",
            str(args.hop_size),
            "--channels",
            str(preset["channels"]),
            "--hidden-channels",
            str(preset["hidden_channels"]),
            "--residual-blocks",
            str(preset["residual_blocks"]),
            "--kernel-time",
            str(preset["kernel_time"]),
            "--kernel-freq",
            str(preset["kernel_freq"]),
            "--lookahead-frames",
            str(preset["lookahead_frames"]),
        ]
        run(export_cmd, cwd)

        bin_bytes = export_path.stat().st_size
        row = {
            "preset": preset_name,
            "description": preset["description"],
            "checkpoint": str(checkpoint_path.relative_to(output_root)),
            "epochs": args.epochs,
            "batch_size": args.batch_size,
            "samples_per_epoch": args.samples_per_epoch,
            "channels": preset["channels"],
            "hidden_channels": preset["hidden_channels"],
            "residual_blocks": preset["residual_blocks"],
            "kernel_time": preset["kernel_time"],
            "kernel_freq": preset["kernel_freq"],
            "lookahead_frames": preset["lookahead_frames"],
            "bin_bytes": bin_bytes,
            "bin_mb": bin_bytes / (1024.0 * 1024.0),
            "run_dir": str(run_dir),
            "export_path": str(export_path),
            "training_summary": read_json(run_dir / "training_summary.json"),
        }
        rows.append(row)
        write_json(run_dir / "sweep_result.json", row)

    write_json(output_root / "sweep_summary.json", rows)
    write_markdown(output_root / "sweep_summary.md", rows)
    print(f"[wiredeck-rnnoise-sweep] summary: {output_root / 'sweep_summary.json'}")
    print(f"[wiredeck-rnnoise-sweep] summary: {output_root / 'sweep_summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
