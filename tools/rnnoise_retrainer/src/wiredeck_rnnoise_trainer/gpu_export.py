from __future__ import annotations

import json
import struct
from dataclasses import asdict, is_dataclass
from pathlib import Path

import torch


MAGIC = b"WDGP"
VERSION = 1
ALIGNMENT = 16
DTYPE_CODES = {
    torch.float32: 1,
    torch.float16: 2,
    torch.int32: 3,
    torch.int8: 4,
}


def align_up(value: int, alignment: int = ALIGNMENT) -> int:
    return ((value + alignment - 1) // alignment) * alignment


def serialize_model(
    model: torch.nn.Module,
    output_path: Path,
    metadata: dict,
) -> None:
    state = model.state_dict()
    tensors: list[dict] = []
    payload = bytearray()

    for name, tensor in state.items():
        cpu_tensor = tensor.detach().cpu().contiguous()
        dtype = cpu_tensor.dtype
        if dtype not in DTYPE_CODES:
            raise ValueError(f"unsupported dtype for export: {dtype}")

        tensor_bytes = cpu_tensor.numpy().tobytes(order="C")
        offset = align_up(len(payload))
        if offset > len(payload):
            payload.extend(b"\x00" * (offset - len(payload)))
        payload.extend(tensor_bytes)
        tensors.append(
            {
                "name": name,
                "dtype_code": DTYPE_CODES[dtype],
                "shape": list(cpu_tensor.shape),
                "offset": offset,
                "byte_length": len(tensor_bytes),
            }
        )

    metadata_blob = json.dumps(metadata, indent=2, sort_keys=True).encode("utf-8")
    tensor_table_blob = json.dumps(tensors, indent=2, sort_keys=True).encode("utf-8")

    header = struct.pack(
        "<4sIIII",
        MAGIC,
        VERSION,
        len(tensors),
        len(metadata_blob),
        len(tensor_table_blob),
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as handle:
        handle.write(header)
        handle.write(metadata_blob)
        handle.write(tensor_table_blob)
        padding = align_up(handle.tell()) - handle.tell()
        if padding > 0:
            handle.write(b"\x00" * padding)
        handle.write(payload)


def build_metadata(
    model_name: str,
    sample_rate_hz: int,
    stft_size: int,
    hop_size: int,
    config: object,
) -> dict:
    config_dict = asdict(config) if is_dataclass(config) else dict(config)
    metadata = {
        "model_name": model_name,
        "export_format": "wiredeck_gpu_model_v1",
        "sample_rate_hz": sample_rate_hz,
        "stft_size": stft_size,
        "hop_size": hop_size,
        "input_layout": "BTF",
        "runtime_layout": "NHWC",
        "config": config_dict,
    }
    metadata.update(config_dict)
    return metadata
