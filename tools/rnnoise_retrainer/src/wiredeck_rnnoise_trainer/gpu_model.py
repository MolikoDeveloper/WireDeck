from __future__ import annotations

from dataclasses import dataclass

import torch
from torch import nn


@dataclass(slots=True)
class WireDeckVoiceDenoiserConfig:
    bands: int = 64
    channels: int = 48
    hidden_channels: int = 96
    residual_blocks: int = 6
    kernel_time: int = 5
    kernel_freq: int = 3
    lookahead_frames: int = 2


class ResidualConvBlock(nn.Module):
    def __init__(self, channels: int, kernel_time: int, kernel_freq: int) -> None:
        super().__init__()
        padding = (kernel_time // 2, kernel_freq // 2)
        self.norm1 = nn.GroupNorm(1, channels)
        self.conv1 = nn.Conv2d(channels, channels, kernel_size=(kernel_time, kernel_freq), padding=padding)
        self.norm2 = nn.GroupNorm(1, channels)
        self.conv2 = nn.Conv2d(channels, channels, kernel_size=(kernel_time, kernel_freq), padding=padding)
        self.activation = nn.SiLU()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        residual = x
        x = self.activation(self.norm1(x))
        x = self.conv1(x)
        x = self.activation(self.norm2(x))
        x = self.conv2(x)
        return x + residual


class WireDeckVoiceDenoiser(nn.Module):
    def __init__(self, config: WireDeckVoiceDenoiserConfig | None = None) -> None:
        super().__init__()
        self.config = config or WireDeckVoiceDenoiserConfig()

        self.input_proj = nn.Conv2d(1, self.config.channels, kernel_size=1)
        self.blocks = nn.Sequential(
            *[
                ResidualConvBlock(
                    self.config.channels,
                    self.config.kernel_time,
                    self.config.kernel_freq,
                )
                for _ in range(self.config.residual_blocks)
            ]
        )
        self.bottleneck = nn.Sequential(
            nn.GroupNorm(1, self.config.channels),
            nn.SiLU(),
            nn.Conv2d(self.config.channels, self.config.hidden_channels, kernel_size=1),
            nn.SiLU(),
            nn.Conv2d(self.config.hidden_channels, self.config.channels, kernel_size=1),
        )
        self.mask_head = nn.Sequential(
            nn.GroupNorm(1, self.config.channels),
            nn.SiLU(),
            nn.Conv2d(self.config.channels, 1, kernel_size=1),
            nn.Sigmoid(),
        )
        self.vad_head = nn.Sequential(
            nn.Conv1d(
                self.config.channels,
                self.config.hidden_channels,
                kernel_size=self.config.kernel_time,
                padding=self.config.kernel_time // 2,
            ),
            nn.SiLU(),
            nn.Conv1d(self.config.hidden_channels, 1, kernel_size=1),
            nn.Sigmoid(),
        )

    def forward(self, features: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        # Input layout: [batch, frames, bands]
        x = features.unsqueeze(1)
        x = self.input_proj(x)
        x = self.blocks(x)
        x = x + self.bottleneck(x)
        mask = self.mask_head(x).squeeze(1)
        vad_features = x.mean(dim=3)
        vad = self.vad_head(vad_features).transpose(1, 2)
        return mask, vad
