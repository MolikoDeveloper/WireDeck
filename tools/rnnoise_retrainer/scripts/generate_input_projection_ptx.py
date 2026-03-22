from __future__ import annotations

from pathlib import Path

from cuda import nvrtc


CUDA_SOURCE = r"""
extern "C" __global__ void input_projection(
    const float* input,
    const float* weight,
    const float* bias,
    float* output,
    unsigned int frames,
    unsigned int bands,
    unsigned int channels) {
  unsigned int band = blockIdx.x * blockDim.x + threadIdx.x;
  unsigned int frame = blockIdx.y * blockDim.y + threadIdx.y;
  unsigned int channel = blockIdx.z;
  if (band >= bands || frame >= frames || channel >= channels) return;
  unsigned int input_index = frame * bands + band;
  unsigned int output_index = (channel * frames + frame) * bands + band;
  output[output_index] = input[input_index] * weight[channel] + bias[channel];
}
"""


def main() -> int:
    repo_root = Path(__file__).resolve().parents[3]
    output = repo_root / "src" / "gpu" / "kernels" / "input_projection.ptx"
    output.parent.mkdir(parents=True, exist_ok=True)

    result, program = nvrtc.nvrtcCreateProgram(CUDA_SOURCE.encode(), b"input_projection.cu", 0, [], [])
    if int(result) != 0:
        raise RuntimeError(f"nvrtcCreateProgram failed: {result}")

    options = [b"--gpu-architecture=compute_86"]
    compile_result = nvrtc.nvrtcCompileProgram(program, len(options), options)[0]

    log_size = nvrtc.nvrtcGetProgramLogSize(program)[1]
    log = bytearray(log_size)
    nvrtc.nvrtcGetProgramLog(program, log)
    log_text = bytes(log).decode("utf-8", "ignore").strip("\x00")
    if log_text:
        print(log_text)

    if int(compile_result) != 0:
        raise RuntimeError(f"nvrtcCompileProgram failed: {compile_result}")

    ptx_size = nvrtc.nvrtcGetPTXSize(program)[1]
    ptx = bytearray(ptx_size)
    nvrtc.nvrtcGetPTX(program, ptx)
    output.write_bytes(bytes(ptx))
    print(f"[wiredeck-rnnoise] wrote PTX: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
