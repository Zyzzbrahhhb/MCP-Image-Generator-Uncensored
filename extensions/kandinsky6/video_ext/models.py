"""Download the video model once (with network), check every weight file, and precompute OrbitQuant's codebooks.

The serving container runs without network access, so everything it needs is fetched and checked here.
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from pathlib import Path

from .pipeline import PATHS, verify_codebooks

log = logging.getLogger("video.models")

QUANT_REPO = "WaveCut/Kandinsky-6.0-Lite-distill-5s-OrbitQuant-W4A4"
QUANT_REVISION = "7fa0dea311de63036ef77a369bc3be105cbb50b0"  # tested; pinned so an upload can't change the model
SKIP = ["assets/*", "workflows/*", "*.mp4", "*.gif", "*.webp", "*.jpg", "*.png",
        # No code and no pickle-format weights from the model repos: safetensors and configs only.
        "*.py", "*.bin", "*.pt", "*.pth", "*.ckpt", "*.pkl"]
# The source repo's full-size transformer (6.4 GB) and text encoder (16.6 GB) are replaced by the 4-bit ones.
SOURCE_SKIP = SKIP + ["transformer/*", "text_encoder/*"]


def download(revision: str = QUANT_REVISION) -> None:
    from huggingface_hub import hf_hub_download, snapshot_download

    meta = json.loads(Path(hf_hub_download(QUANT_REPO, "artifact_metadata.json", revision=revision)).read_text())
    source = meta["source_model"]
    quant_dir = snapshot_download(QUANT_REPO, revision=revision, ignore_patterns=SKIP)
    source_dir = snapshot_download(source["repo_id"], revision=source["revision"], ignore_patterns=SOURCE_SKIP)
    checked = verify(QUANT_REPO, revision, Path(quant_dir)) + verify(source["repo_id"], source["revision"],
                                                                     Path(source_dir))
    PATHS.write_text(json.dumps({
        "quant": {"repo": QUANT_REPO, "revision": revision, "dir": quant_dir},
        "source": {"repo": source["repo_id"], "revision": source["revision"], "dir": source_dir},
        "runtime": meta.get("runtime"), "sha256_checked": checked,
    }, indent=1))
    for name, folder in (("4-bit models", quant_dir), ("VAEs, CLIP and vocoder", source_dir)):
        size = sum(p.stat().st_size for p in Path(folder).rglob("*") if p.is_file())
        print(f"{name}: {size / 1e9:.2f} GB", flush=True)


def verify(repo: str, revision: str, folder: Path) -> int:
    """Check every downloaded weight file against the SHA-256 that Hugging Face records for it."""
    from huggingface_hub import HfApi

    expected = {}
    for item in HfApi().list_repo_tree(repo, revision=revision, recursive=True):
        lfs = getattr(item, "lfs", None)
        sha = getattr(lfs, "sha256", None) or (lfs.get("sha256") if isinstance(lfs, dict) else None)
        if sha:
            expected[item.path] = sha
    checked = 0
    for path in sorted(p for p in folder.rglob("*") if p.is_file() and p.suffix == ".safetensors"):
        name = path.relative_to(folder).as_posix()
        if name not in expected:
            raise SystemExit(f"{repo}: no recorded SHA-256 for {name}")
        digest = hashlib.sha256()
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(1 << 24), b""):
                digest.update(block)
        if digest.hexdigest() != expected[name]:
            raise SystemExit(f"{repo}: SHA-256 mismatch for {name}; delete it and run the download again")
        checked += 1
    print(f"{repo}: SHA-256 ok for {checked} weight files", flush=True)
    return checked


def codebooks() -> None:
    """List every codebook the two 4-bit models need, then compute (verified twice) and cache the missing ones, so
    serving never runs that CPU-heavy math. Safe to run again: cached ones are skipped."""
    import os

    import torch
    from diffusers import Kandinsky6Transformer3DModel
    from transformers import Qwen2_5_VLForConditionalGeneration

    import orbitquant  # noqa: F401
    from orbitquant.codebooks import lloyd_max

    os.environ["HF_HUB_OFFLINE"] = "1"
    needed: set[tuple[int, int, int]] = set()
    original_generate, original_write = lloyd_max._generate_codebook, lloyd_max._write_cached_codebook

    def record(dim, bits, algorithm_version=lloyd_max._ALGORITHM_VERSION):
        needed.add((dim, bits, algorithm_version))
        levels = 2**bits
        return lloyd_max.LloydMaxCodebook(dim=dim, bits=bits, centroids=torch.linspace(-1, 1, levels),
                                          boundaries=torch.linspace(-1, 1, levels - 1),
                                          algorithm_version=algorithm_version)

    lloyd_max._generate_codebook, lloyd_max._write_cached_codebook = record, (lambda book: None)
    try:
        quant = json.loads(PATHS.read_text())["quant"]["dir"]
        Kandinsky6Transformer3DModel.from_pretrained(quant, torch_dtype=torch.bfloat16, use_safetensors=True)
        Qwen2_5_VLForConditionalGeneration.from_pretrained(quant, subfolder="text_encoder", dtype=torch.bfloat16,
                                                           use_safetensors=True)
    finally:
        lloyd_max._generate_codebook, lloyd_max._write_cached_codebook = original_generate, original_write
        lloyd_max.get_codebook.cache_clear()
    missing = sorted(n for n in needed if not lloyd_max.codebook_cache_path(*n).exists())
    print(f"codebooks: {len(needed)} needed, {len(missing)} to compute", flush=True)
    verify_codebooks()
    for dim, bits, version in missing:
        start = time.perf_counter()
        lloyd_max.get_codebook(dim, bits, version)
        print(f"  cached {dim}x{bits} in {time.perf_counter() - start:.1f} s", flush=True)
    print("codebooks ready", flush=True)
