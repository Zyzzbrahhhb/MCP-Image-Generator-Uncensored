"""vectorize_image: the clean-up and tracing (no GPU), the tool result and the SVG serving rules."""

import re

import pytest
from PIL import Image, ImageDraw
from starlette.testclient import TestClient

from imagegen_mcp import vectorize as vz
from imagegen_mcp.config import Config
from imagegen_mcp.server import build_app, create_server
from imagegen_mcp.service import ImageService

pytestmark = pytest.mark.skipif(not vz.available(), reason="vtracer or resvg-py is not installed")


def _logo(size=512) -> Image.Image:
    """A flat 'logo': a red disc and a black bar on white, with soft (anti-aliased) edges like an AI image."""
    big = Image.new("RGB", (size * 4, size * 4), (255, 255, 255))
    d = ImageDraw.Draw(big)
    d.ellipse([size, size // 2, size * 3, size * 5 // 2], fill=(210, 20, 25))
    d.rectangle([size // 2, size * 3, size * 7 // 2, size * 7 // 2], fill=(0, 0, 0))
    return big.resize((size, size), Image.LANCZOS)  # the downscale makes blended edge colours


def _fills(svg: str) -> set[str]:
    return {f.upper() for f in re.findall(r'fill="(#[0-9A-Fa-f]{6})"', svg)}


def test_auto_picks_logo_and_keeps_only_the_real_colours():
    v = vz.vectorize(_logo())
    assert v.preset == "logo"
    assert v.svg.lstrip().startswith(("<?xml", "<svg")) and v.paths >= 2
    assert len(_fills(v.svg)) == 3  # white, red, black: the soft-edge blends are not colours of their own
    assert v.width == vz.WORK_MIN  # a small image is enlarged first, for smoother curves
    assert v.preview.mode == "RGB" and not v.transparent and not v.notes


def test_black_and_white_keeps_its_white_background():
    img = Image.new("RGB", (800, 800), (255, 255, 255))
    ImageDraw.Draw(img).polygon([(100, 700), (400, 120), (700, 700)], fill=(0, 0, 0))
    v = vz.vectorize(img)
    assert v.preset == "bw" and not v.transparent and v.preview.mode == "RGB"
    assert v.preview.getpixel((5, 5)) == (255, 255, 255)  # white parts are traced, never see-through
    assert 'stroke="' not in v.svg  # two colours: no seam to hide


def test_transparency_is_kept():
    img = Image.new("RGBA", (800, 800), (0, 0, 0, 0))
    ImageDraw.Draw(img).ellipse([200, 200, 600, 600], fill=(30, 120, 220, 255))
    v = vz.vectorize(img)
    assert v.transparent and v.preview.mode == "RGBA"
    alpha = v.preview.getchannel("A")
    assert alpha.getpixel((5, 5)) == 0 and alpha.getpixel((alpha.width // 2, alpha.height // 2)) == 255


def test_a_cut_out_keeps_its_light_colours():
    """The transparent background must not take part in the colour reduction: it once pulled a light grey rocket
    body to white, which looked see-through."""
    img = Image.new("RGBA", (800, 800), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([250, 100, 550, 700], 80, fill=(215, 222, 222, 255), outline=(30, 30, 30, 255), width=14)
    d.ellipse([340, 220, 460, 340], fill=(70, 190, 220, 255))
    v = vz.vectorize(img)
    fills = {tuple(int(f[i:i + 2], 16) for i in (1, 3, 5)) for f in _fills(v.svg)}
    assert any(max(abs(a - b) for a, b in zip(f, (215, 222, 222))) <= 6 for f in fills)
    assert not any(min(f) >= 245 for f in fills)  # no white invented


def test_small_solid_colours_next_to_similar_ones_are_kept():
    """A small brown door next to a red-brown chimney: 28 apart in RGB but clearly different (delta E 14)."""
    img = Image.new("RGB", (1024, 1024), (253, 253, 253))
    d = ImageDraw.Draw(img)
    d.rectangle([200, 200, 260, 300], fill=(129, 61, 42))
    d.rectangle([600, 500, 660, 620], fill=(114, 82, 53))
    d.rectangle([300, 700, 800, 900], fill=(56, 70, 80))
    fills = [tuple(int(f[i:i + 2], 16) for i in (1, 3, 5)) for f in _fills(vz.vectorize(img).svg)]
    assert len(fills) == 4
    for want in ((129, 61, 42), (114, 82, 53)):
        assert any(max(abs(a - b) for a, b in zip(f, want)) <= 6 for f in fills), want


def test_fine_lines_are_traced_at_twice_the_size_and_kept_whole():
    img = Image.new("RGB", (1024, 1024), (255, 255, 255))
    d = ImageDraw.Draw(img)
    for i in range(12):  # 1 px strokes, as in a colouring page or a blueprint
        d.line([(100, 100 + i * 60), (900, 140 + i * 60)], fill=(0, 0, 0), width=1)
    v = vz.vectorize(img)
    assert v.width == 2048
    out = vz.render(v.svg, 1024).convert("L")
    rows = [min(out.getpixel((500, y)) for y in range(118 + i * 60, 128 + i * 60)) for i in range(12)]
    assert all(r < 128 for r in rows)  # every stroke is still there, unbroken in the middle


def test_photos_and_gradients_are_posterized_as_illustrations():
    import numpy as np
    x, y = np.meshgrid(np.linspace(0, 1, 512), np.linspace(0, 1, 512))
    img = Image.fromarray((np.stack([x, y, (x + y) / 2], -1) * 255).astype(np.uint8))
    assert vz.vectorize(img).preset == "illustration"


def test_seams_between_three_or_more_colours_are_outlined():
    v = vz.vectorize(_logo())
    assert v.svg.count('stroke="#') == v.paths  # every shape outlined in its own colour
    assert all(f'fill="{c}" stroke="{c}"' in v.svg for c in _fills(v.svg))


def test_fills_are_snapped_to_the_cleaned_palette():
    svg = '<svg><path fill="#D2141A" d="M0 0"/><path fill="#CF1519" d="M1 1"/><path fill="#FEFEFE" d="M2 2"/></svg>'
    out = vz.snap_fills(svg, [(210, 20, 25), (255, 255, 255)])
    assert _fills(out) == {"#D21419", "#FFFFFF"}


def test_blends_and_near_duplicates_are_not_colours_but_accents_are():
    kept = [(255, 255, 255), (0, 0, 0), (210, 20, 25)]
    assert vz._near_kept((128, 128, 128), kept)              # the edge between black and white
    assert vz._near_kept((232, 137, 140), kept)              # the edge between red and white
    assert vz._near_kept((205, 22, 27), kept, blends=False)  # a near-duplicate of the red
    assert not vz._near_kept((250, 175, 0), kept)            # a yellow accent is a real colour


def test_bad_arguments_are_rejected():
    with pytest.raises(ValueError):
        vz.vectorize(_logo(), preset="photo")
    with pytest.raises(ValueError):
        vz.vectorize(_logo(), colors=1)


class _Svc(ImageService):
    def __init__(self, cfg, tmp_path):
        super().__init__(cfg)
        self.outputs = tmp_path
        self.state = "ready"


def _cfg(tmp_path) -> Config:
    return Config.model_validate({"outputs_dir": str(tmp_path), "models_dir": str(tmp_path / "m")})


async def test_tool_returns_preview_svg_link_and_code(tmp_path):
    svc = _Svc(_cfg(tmp_path), tmp_path)
    (tmp_path / "2026-01-01").mkdir()
    _logo().save(tmp_path / "2026-01-01" / "logo.png")
    mcp = create_server(svc)
    schema = {t.name: t for t in await mcp.list_tools()}["vectorize_image"].input_schema
    assert schema["required"] == ["image"] and {"preset", "colors", "remove_background"} <= set(schema["properties"])
    r = await mcp.call_tool("vectorize_image", {"image": "2026-01-01/logo.png"})
    assert not r.is_error
    assert [c.type for c in r.content] == ["image", "text", "text"]
    assert r.content[2].text.startswith("SVG code:\n")
    svg = r.structured_content["svg"]
    assert svg["file"].endswith(".svg") and svg["url"].endswith(svg["file"]) and "text" not in svg
    assert (tmp_path / svg["file"]).is_file()
    png = r.structured_content["images"][0]["file"]
    assert png == svg["file"][:-4] + ".png" and (tmp_path / png).is_file()
    assert r.structured_content["info"]["preset"] == "logo"
    # The SVG's own file name, given as an input to another tool, means its PNG twin.
    assert svc.loader.local_path(svg["file"]) == (tmp_path / png).resolve()


async def test_svg_is_served_with_a_strict_policy_but_never_listed(tmp_path):
    svc = _Svc(_cfg(tmp_path), tmp_path)
    (tmp_path / "2026-01-01").mkdir()
    _logo().save(tmp_path / "2026-01-01" / "logo.png")
    mcp = create_server(svc)
    r = await mcp.call_tool("vectorize_image", {"image": "2026-01-01/logo.png"})
    rel = r.structured_content["svg"]["file"]
    _, app = build_app(svc)
    with TestClient(app) as client:
        got = client.get("/outputs/" + rel)
        assert got.status_code == 200 and got.headers["content-type"].startswith("image/svg+xml")
        assert "default-src 'none'" in got.headers["content-security-policy"]
        assert got.headers["x-content-type-options"] == "nosniff"
        assert client.get("/outputs/" + rel.replace(".svg", "-missing.svg")).status_code == 404
        assert client.get("/outputs/../secret.svg").status_code == 404
        listed = [e["file"] for e in client.get("/api/images").json()["outputs_and_uploads"]]
    assert rel not in listed and rel[:-4] + ".png" in listed
