"""Qwen-Image-2.1-Turbo: one fixed 8-step schedule at guidance 1, whatever the generation settings say."""
import pytest

from imagegen_mcp.config import Config
from imagegen_mcp.models import diffusion_file
from imagegen_mcp.schedule import TURBO_STEPS, turbo_sigmas
from imagegen_mcp.server import create_server
from imagegen_mcp.service import ImageService, merge_negative
from test_server import StubService


def _cfg(tmp_path, **model) -> Config:
    return Config.model_validate({"outputs_dir": str(tmp_path), "models_dir": str(tmp_path / "m"),
                                  "model": {"variant": "turbo", **model},
                                  "generation": {"steps": 40, "cfg_scale": 4.0, "edit_cfg_scale": 4.0,
                                                 "sampler": "dpm++2m", "schedule": "official"}})


def test_turbo_schedule_is_the_checkpoints_own():
    assert turbo_sigmas() == [1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568, 0.0]
    assert TURBO_STEPS == 8


def test_turbo_settings_follow_the_model(tmp_path):
    cfg = _cfg(tmp_path)
    assert cfg.is_turbo and cfg.fixed_steps == 8 and cfg.default_steps == 8 and cfg.schedule == "turbo"
    assert cfg.default_cfg_scale == 1.0 and cfg.edit_cfg_scale == 1.0
    base = Config.model_validate({"model": {"variant": "uncensored"}, "generation": {"steps": 40}})
    assert base.fixed_steps is None and base.default_steps == 40 and base.schedule == "official"


def test_turbo_files(tmp_path):
    f = diffusion_file(_cfg(tmp_path))
    assert f.filename == "Qwen-Image-2.1-Turbo-AD-Q4_K.gguf" and f.size == 4201694944
    assert "/AtomicChat/Qwen-Image-2.1-Turbo-GGUF/resolve/bb25d06bc74119c12207243d68917951e6d9c232/" in f.url
    assert diffusion_file(_cfg(tmp_path, quant="AD-Q5_K")).filename == "Qwen-Image-2.1-Turbo-AD-Q5_K.gguf"
    assert diffusion_file(_cfg(tmp_path, quant="Q8_0")).filename == "Qwen-Image-2.1-Turbo-Q8_0.gguf"
    with pytest.raises(ValueError):
        _cfg(tmp_path, quant="Q4_0")


def test_turbo_requests_use_the_fixed_schedule(tmp_path):
    svc = ImageService(_cfg(tmp_path))
    for steps in (1, 8, 40):  # the warm-up asks for 1 step, a caller may ask for 40
        sample = svc._body("a cube", "", 1024, 1024, steps=steps, seed=1)["sample_params"]
        assert sample["custom_sigmas"] == turbo_sigmas() and sample["sample_steps"] == 8  # = len(sigmas) - 1
        assert sample["sample_method"] == "euler" and sample["guidance"]["txt_cfg"] == 1.0
    notes: list[str] = []
    assert svc._steps(30, notes) == 8 and "fixed at 8" in notes[0]
    assert svc._steps(None, []) == 8
    assert merge_negative("blurry", "text", 1.0, notes, turbo=True) == "" and "Turbo" in notes[-1]


async def test_turbo_tool_descriptions(tmp_path):
    tools = {t.name: t for t in await create_server(StubService(_cfg(tmp_path), tmp_path)).list_tools()}
    gen, edit = tools["generate_image"].description, tools["edit_image"].description
    for d in (gen, edit):
        assert "leave unset (8: this Turbo model runs one fixed 8-step schedule)" in d
        assert "distilled for guidance 1" in d and "cfg_scale 4" not in d and "3-5" not in d
        assert "no effect with this Turbo model" in d and "the server already applies" not in d
    assert "defaults here: 8 steps" in tools["generate_panorama"].description
    assert all(len(t.description) < 2048 for t in tools.values())
