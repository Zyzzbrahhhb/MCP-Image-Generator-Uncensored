"""Kandinsky 6 Lite distill (4-bit OrbitQuant) video pipeline: loading, GPU memory modes and rendering.

Modes (VIDEO_MODE), measured at 864x480, 121 frames (5 s), 10 steps, with sound:
  resident    everything on the GPU (~17 GB). RTX 5090: 43-70 s per clip.
  fast        each part visits the GPU while it runs, fused kernels (~11 GB).
  low-memory  like fast, with a memory cap (default 7.25 GiB; ~8.5-10 GB on the card). RTX 3080 Ti: 115-122 s.
  stream      the 4-bit models stream in block by block from RAM (~5.5 GB on the card), so the video can share a
              12 GB card with the image server. RTX 3080 Ti: 139-147 s.
"""

from __future__ import annotations

import gc
import json
import logging
import os
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

log = logging.getLogger("video.pipeline")

MODES = ("resident", "fast", "low-memory", "stream")
PATHS = Path(os.environ.get("VIDEO_MODELS", "/models")) / "paths.json"
FPS = 24
SEGMENT_FRAMES = 121          # 5.04 s at 24 fps (the model's training length)
SIZES = {"16:9": (864, 480), "9:16": (480, 864), "1:1": (640, 640)}
SMALL_SIZES = {"16:9": (576, 320), "9:16": (320, 576), "1:1": (448, 448)}


class Cancelled(Exception):
    """The request was cancelled; raised between denoising steps."""


@dataclass
class Clip:
    frames: list            # PIL images, 24 fps
    audio: object | None    # torch tensor (channels, samples) or None
    sample_rate: int
    segments: list[float] = field(default_factory=list)  # seconds per 5 s segment


def verify_codebooks() -> None:
    """Some CPUs miscompute the long codebook math (seen on an unstable i9-14900K), and OrbitQuant caches the result.
    Accept a codebook only when two computations match exactly."""
    from orbitquant.codebooks import lloyd_max

    original = lloyd_max._generate_codebook
    if getattr(original, "_verified", False):
        return

    def verified(dim, bits, algorithm_version=lloyd_max._ALGORITHM_VERSION):
        seen: dict[bytes, int] = {}
        for _ in range(12):
            try:
                book = original(dim, bits, algorithm_version)
            except Exception as error:  # noqa: BLE001 - a miscomputation; try again
                log.warning("codebook %sx%s: computation failed (%s), retrying", dim, bits, type(error).__name__)
                continue
            key = book.centroids.numpy().tobytes() + book.boundaries.numpy().tobytes()
            seen[key] = seen.get(key, 0) + 1
            if seen[key] >= 2:
                return book
        raise RuntimeError(f"codebook {dim}x{bits}: no two matching results in 12 tries")

    verified._verified = True
    lloyd_max._generate_codebook = verified


class VideoPipeline:
    """Loads on first use, renders one request at a time, and unloads after an idle period."""

    def __init__(self, mode: str, cap_gb: float | None, device: str = "cuda"):
        if mode not in MODES:
            raise ValueError(f"VIDEO_MODE must be one of {MODES}, not {mode!r}")
        self.mode, self.cap_gb, self.device = mode, cap_gb, device
        self.pipe = None
        self.loaded_at = 0.0
        self.last_used = 0.0
        self._lock = threading.Lock()

    # ------------------------------------------------------------------ loading
    def load(self) -> None:
        if self.pipe is not None:
            return
        os.environ["HF_HUB_OFFLINE"] = "1"
        import torch
        from diffusers import Kandinsky6TI2VAPipeline, Kandinsky6Transformer3DModel
        from transformers import Qwen2_5_VLForConditionalGeneration

        import orbitquant  # noqa: F401 -- registers the 4-bit quantizers

        verify_codebooks()
        paths = json.loads(PATHS.read_text())
        if self.device == "cuda":
            cap = self.cap_gb if self.cap_gb else (7.25 if self.mode == "low-memory" else None)
            if cap:
                total = torch.cuda.get_device_properties(0).total_memory
                torch.cuda.set_per_process_memory_fraction(min(1.0, cap * 1024**3 / total), 0)
        torch.backends.cudnn.benchmark = False
        start = time.perf_counter()
        quant = paths["quant"]["dir"]
        transformer = Kandinsky6Transformer3DModel.from_pretrained(quant, torch_dtype=torch.bfloat16,
                                                                   use_safetensors=True)
        encoder = Qwen2_5_VLForConditionalGeneration.from_pretrained(quant, subfolder="text_encoder",
                                                                     dtype=torch.bfloat16, use_safetensors=True)
        pipe = Kandinsky6TI2VAPipeline.from_pretrained(paths["source"]["dir"], transformer=transformer,
                                                        text_encoder=encoder, torch_dtype=torch.bfloat16,
                                                        use_safetensors=True)
        self.pipe = configure(pipe, self.mode)
        self.loaded_at = self.last_used = time.time()
        log.info("video model loaded in %.1f s (mode %s)", time.perf_counter() - start, self.mode)

    def unload(self) -> None:
        with self._lock:
            if self.pipe is None:
                return
            self.pipe = None
            gc.collect()
            try:
                import torch

                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
            except Exception:  # noqa: BLE001 - only memory housekeeping
                pass
            log.info("video model unloaded (idle)")

    # ------------------------------------------------------------------ rendering
    def render(self, prompts: list[str], *, width: int, height: int, seed: int, image=None, sound: bool = True,
               progress: Callable[[float, str], None] | None = None,
               cancelled: Callable[[], bool] | None = None) -> Clip:
        """Render one clip per prompt; each clip after the first starts on the previous clip's last frame."""
        import torch

        with self._lock:
            self.load()
            pipe = self.pipe
            steps = 10
            frames: list = []
            audio: list = []
            segments: list[float] = []
            total = len(prompts) * steps
            for n, prompt in enumerate(prompts):
                done_before = n * steps

                def on_step(_pipe, step, _t, kwargs, done_before=done_before, n=n):
                    if cancelled is not None and cancelled():
                        raise Cancelled()
                    if progress is not None:
                        progress((done_before + step + 1) / total,
                                 f"segment {n + 1}/{len(prompts)}, step {step + 1}/{steps}")
                    return kwargs

                kw = dict(prompt=prompt, width=width, height=height, num_frames=SEGMENT_FRAMES,
                          num_inference_steps=steps, guidance_scale=1.0, callback_on_step_end=on_step,
                          generator=torch.Generator(device=self.device).manual_seed(seed + n))
                if image is not None:
                    kw["image"] = image
                if not sound:
                    kw["sample_audio"] = False
                start = time.perf_counter()
                with torch.inference_mode():
                    out = pipe(**kw)
                segments.append(round(time.perf_counter() - start, 1))
                clip = [to_pil(f) for f in out.frames[0]]
                track = (out.audio[0].detach().float().cpu()  # stream mode leaves it on the GPU
                         if sound and getattr(out, "audio", None) is not None else None)
                if n:
                    # The clip starts on the previous clip's last frame: drop that repeat and 1/24 s of sound.
                    clip = clip[1:]
                    if track is not None:
                        track = track[..., int(round(pipe.audio_sample_rate / FPS)):]
                frames.extend(clip)
                if track is not None:
                    audio.append(track)
                image = clip[-1]
            self.last_used = time.time()
            if self.device == "cuda":
                torch.cuda.empty_cache()  # give the card back between requests (it may be shared)
            return Clip(frames, torch.cat(audio, dim=-1) if audio else None, pipe.audio_sample_rate, segments)


def configure(pipe, mode: str):
    """Apply the OrbitQuant runtime settings and the GPU memory mode."""
    import torch
    from orbitquant.runtime.kandinsky6 import (
        install_kandinsky6_attention,
        install_kandinsky6_norm_fusion,
        install_kandinsky6_pointwise,
        install_kandinsky6_projection_reuse,
        install_kandinsky6_qk_norm,
    )
    from orbitquant.runtime.kandinsky6_video import install_kandinsky6_video_io, install_kandinsky6_video_norm

    install_kandinsky6_attention(pipe.transformer)
    install_kandinsky6_pointwise(pipe.transformer)
    install_kandinsky6_projection_reuse(pipe.transformer)
    install_kandinsky6_norm_fusion(pipe.transformer)
    install_kandinsky6_qk_norm(pipe.transformer)
    install_kandinsky6_video_io(pipe)
    install_kandinsky6_video_norm(pipe)
    pipe.vae.enable_tiling(tile_sample_min_height=272, tile_sample_min_width=320,
                           tile_sample_stride_height=240, tile_sample_stride_width=288)
    if mode == "resident":
        pipe.to("cuda")
        return pipe
    if mode == "stream":
        stream_weights(pipe)
        return pipe
    if mode == "low-memory":
        decode = pipe.vae.decode

        def decode_after_reclaim(*args, **kwargs):
            pipe.maybe_free_model_hooks()
            return decode(*args, **kwargs)

        pipe.vae.decode = decode_after_reclaim
    pipe.enable_model_cpu_offload()  # fast and low-memory: each part visits the GPU only while it runs
    return pipe


def stream_weights(pipe) -> None:
    """Weights stay in RAM. The two 4-bit models are copied to the GPU one block at a time just before each block
    runs; the small parts visit the GPU only for their own step. The GPU holds activations plus about one block."""
    import torch
    from diffusers.hooks import apply_group_offloading

    cuda, cpu = torch.device("cuda"), torch.device("cpu")
    # record_stream: the allocator must not free (or unmap) a block while the side stream still copies it.
    stream = dict(onload_device=cuda, offload_device=cpu, offload_type="block_level", num_blocks_per_group=1,
                  use_stream=True, record_stream=True)
    apply_group_offloading(pipe.transformer, **stream)
    # The pipeline reads only the hidden states; the 1 GB vocabulary projection would be wasted work.
    pipe.text_encoder.lm_head = torch.nn.Identity()
    # The 1 GB word-embedding table is called from outside the streamed layers: it stays in RAM and looks up the
    # prompt's few hundred tokens on the CPU.
    language = pipe.text_encoder.model.language_model
    embed = language.embed_tokens
    delattr(language, "embed_tokens")
    # The text encoder runs once per clip: plain synchronous copies (async prefetch crashed on its second use).
    apply_group_offloading(language, **{**stream, "use_stream": False, "record_stream": False})
    language.embed_tokens = embed
    lookup = embed.forward
    embed.forward = lambda input_ids: lookup(input_ids.to(cpu)).to(input_ids.device)

    def on_gpu_during(module, method):
        original = getattr(module, method)

        def run(*args, **kwargs):
            module.to(cuda)
            try:
                return original(*args, **kwargs)
            finally:
                module.to(cpu)

        setattr(module, method, run)

    on_gpu_during(pipe.text_encoder_2, "forward")
    on_gpu_during(pipe.vae, "encode")
    on_gpu_during(pipe.vae, "decode")
    on_gpu_during(pipe.audio_vae, "decode")
    on_gpu_during(pipe.vocoder, "forward")


def to_pil(frame):
    if hasattr(frame, "save"):
        return frame
    import numpy as np
    from PIL import Image

    array = np.asarray(frame)
    if array.dtype != np.uint8:
        array = (np.clip(array, 0, 1) * 255).round().astype(np.uint8)
    return Image.fromarray(array)
