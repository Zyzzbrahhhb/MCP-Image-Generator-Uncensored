"""Checks for the setup/start/update/stop scripts: both shells offer the same model choices, the config keys the
setup writes exist in config.example.yaml, and every launcher points at a script that exists."""
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
LIB_SH = (ROOT / "scripts" / "lib.sh").read_text(encoding="utf-8")
LIB_PS1 = (ROOT / "scripts" / "lib.ps1").read_text(encoding="utf-8")


def _sh_presets() -> list[str]:
    body = re.search(r"presets\(\) \{\n  cat <<'EOF'\n(.*?)\nEOF", LIB_SH, re.S)
    assert body, "presets() not found in scripts/lib.sh"
    return body.group(1).splitlines()


def _ps1_presets() -> list[str]:
    body = re.search(r"\$Presets = @\((.*?)\n\)", LIB_PS1, re.S)
    assert body, "$Presets not found in scripts/lib.ps1"
    return re.findall(r"'([^']+)'", body.group(1))


def test_both_shells_offer_the_same_models():
    sh, ps1 = _sh_presets(), _ps1_presets()
    assert sh == ps1
    assert len(sh) == int(re.search(r"^PRESET_COUNT=(\d+)", LIB_SH, re.M).group(1))
    for row in sh:
        name, variant, quant, te, sec, ram, img, img_bytes, te_file, te_bytes = row.split("|")
        assert variant in ("uncensored", "base", "turbo") and int(sec) > 0 and int(ram) > 0
        assert int(img_bytes) > 0 and int(te_bytes) > 0


def _shared(text: str, start: str, end: str) -> list[str]:
    body = text[text.index(start):]
    return re.findall(r"^\s*'?([a-z_]+/[^|']+\|\d+)'?\s*$", body[:body.index(end)], re.M)


def test_model_files_match_the_server():
    """The file names and sizes in the scripts (for "Download" and "GPU memory") are the server's files."""
    from imagegen_mcp import models
    from imagegen_mcp.config import Config

    base = yaml.safe_load((ROOT / "config.example.yaml").read_text(encoding="utf-8"))
    shared_sh = _shared(LIB_SH, "shared_files() {", "\nEOF")
    shared_ps1 = _shared(LIB_PS1, "$SharedFiles = @(", "\n)")
    assert shared_sh == shared_ps1
    for row in _sh_presets():
        name, variant, quant, te, _, _, img, img_bytes, te_file, te_bytes = row.split("|")
        cfg = Config.model_validate({**base, "model": {**base["model"], "variant": variant, "quant": quant,
                                                       "text_encoder_quant": te}})
        files = {f.dest: f.size for f in models.required_files(cfg)}
        assert files.pop(img) == int(img_bytes), name
        assert files.pop(te_file) == int(te_bytes), name
        assert sorted(f"{k}|{v}" for k, v in files.items()) == sorted(shared_sh), name


def test_turbo_choice_is_the_same():
    sh = int(re.search(r"^TURBO=(\d+)", LIB_SH, re.M).group(1))
    ps1 = int(re.search(r"^\$TurboChoice = (\d+)", LIB_PS1, re.M).group(1))
    assert sh == ps1 and _sh_presets()[sh - 1].split("|")[1] == "turbo"


def test_setup_keys_exist_in_the_example_config():
    cfg = yaml.safe_load((ROOT / "config.example.yaml").read_text(encoding="utf-8"))
    assert "device" in cfg
    for key in ("diffusion", "text_encoder", "vae", "max_vram_gb", "offload"):
        assert key in cfg["gpu"], f"gpu.{key}"
    for key in ("variant", "quant", "text_encoder_quant"):
        assert key in cfg["model"], f"model.{key}"
    assert "prefix_cache_type" in cfg["generation"]
    assert "port" in cfg["server"]


def test_lib_ps1_is_ascii():
    # Windows PowerShell 5.1 reads a file without a BOM as the ANSI code page.
    assert LIB_PS1.isascii()
    assert (ROOT / "scripts" / "imagegen.ps1").read_text(encoding="utf-8").isascii()


def test_launchers_point_at_existing_scripts():
    for action in ("setup", "start", "update", "stop"):
        cmd = (ROOT / f"{action}.cmd").read_text(encoding="utf-8")
        assert f'scripts\\imagegen.ps1" {action} %*' in cmd
        assert f"bash ./{action}.sh" in (ROOT / f"{action}.command").read_text(encoding="utf-8")
        assert (ROOT / f"{action}.sh").is_file()
    actions = re.search(r"ValidateSet\(([^)]*)\)", (ROOT / "scripts" / "imagegen.ps1").read_text(encoding="utf-8"))
    assert set(re.findall(r"'(\w+)'", actions.group(1))) == {"setup", "start", "update", "stop"}


def test_build_marker_is_ignored_by_git():
    marker = re.search(r"^BUILD_MARK=(\S+)", LIB_SH, re.M).group(1)
    assert re.search(rf"^\$BuildMark = '{re.escape(marker)}'", LIB_PS1, re.M)
    assert marker in (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
