"""Convert ONNX raw YOLOX Nano head outputs into pixel-space boxes.

The GitHub release yolox_nano.onnx uses *undecoded* YOLOX head outputs.
The Pureline image-filter adapter expects decoded pixel cx/cy/w/h instead.
This wrapper is diagnostic until a pinned model exported with
model.head.decode_in_inference=True replaces the raw release asset.
"""
from __future__ import annotations

import numpy as np


class RawYOLOXDecodedSession:
    def __init__(self, inner, input_size: int = 416) -> None:
        self.inner = inner
        self.inputs = inner.inputs
        self.outputs = inner.outputs
        self.input_size = input_size
        grids = []
        strides = []
        for stride in (8, 16, 32):
            if input_size % stride:
                raise ValueError("YOLOX input size incompatible with stride")
            size = input_size // stride
            xx, yy = np.meshgrid(np.arange(size), np.arange(size), indexing="xy")
            grids.append(np.stack((xx, yy), axis=-1).reshape(-1, 2))
            strides.append(np.full((size * size, 1), stride, dtype=np.float32))
        self.grid = np.concatenate(grids, axis=0).astype(np.float32)
        self.strides = np.concatenate(strides, axis=0)
        self.number_boxes = len(self.grid)

    def run(self, feeds, output_names=None):
        outputs = self.inner.run(feeds, output_names)
        raw = np.asarray(outputs[0], dtype=np.float32)
        if raw.shape != (1, self.number_boxes, 85):
            raise ValueError(f"unexpected raw YOLOX output: {raw.shape}")
        decoded = raw.copy()
        decoded[:, :, 0:2] = (raw[:, :, 0:2] + self.grid) * self.strides
        decoded[:, :, 2:4] = np.exp(np.clip(raw[:, :, 2:4], -12, 12)) * self.strides
        if not np.isfinite(decoded).all():
            raise ValueError("non-finite YOLOX box output")
        return [decoded]


def patch_raw_yolox_pipeline(pipeline):
    decoder = pipeline.person_detector.detector
    decoder.session = RawYOLOXDecodedSession(
        decoder.session, input_size=decoder.input_size
    )
