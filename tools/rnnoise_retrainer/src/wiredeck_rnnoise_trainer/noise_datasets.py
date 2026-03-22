from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class NoiseDataset:
    key: str
    url: str
    category: str
    description: str
    source: str


CURATED_NOISE_DATASETS: tuple[NoiseDataset, ...] = (
    NoiseDataset(
        key="xiph-background-noise-v2",
        url="https://media.xiph.org/rnnoise/data/background_noise_v2.sw",
        category="background",
        description="Official RNNoise v2 background-noise corpus in 48 kHz 16-bit PCM.",
        source="https://github.com/xiph/rnnoise",
    ),
    NoiseDataset(
        key="xiph-foreground-noise-v2",
        url="https://media.xiph.org/rnnoise/data/foreground_noise_v2.sw",
        category="transient",
        description="Official RNNoise v2 foreground transients such as keyboard clicks and short events.",
        source="https://github.com/xiph/rnnoise",
    ),
    NoiseDataset(
        key="xiph-contrib-noise",
        url="https://media.xiph.org/rnnoise/data/contrib_noise.sw",
        category="mixed",
        description="Official RNNoise contributed noise bed; the README recommends repeating this file multiple times during mixing.",
        source="https://github.com/xiph/rnnoise",
    ),
    NoiseDataset(
        key="xiph-synthetic-noise",
        url="https://media.xiph.org/rnnoise/data/synthetic_noise.sw",
        category="synthetic",
        description="Official RNNoise synthetic noise corpus; the README recommends repeating this file multiple times during mixing.",
        source="https://github.com/xiph/rnnoise",
    ),
    NoiseDataset(
        key="musan",
        url="https://www.openslr.org/resources/17/musan.tar.gz",
        category="mixed",
        description="MUSAN corpus with music, speech and noise; useful to broaden non-stationary conditions beyond the official RNNoise assets.",
        source="https://www.openslr.org/17/",
    ),
)
