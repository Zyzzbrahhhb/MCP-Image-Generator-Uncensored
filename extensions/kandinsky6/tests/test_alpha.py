"""Transparent video tests (CPU only). Run from the repository folder: uv run pytest extensions/kandinsky6/tests"""

import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from video_ext import alpha  # noqa: E402

SIZE = 128


def _subject(color, soft=True) -> Image.Image:
    """A disk of one color on a transparent background."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(img).ellipse((32, 32, 96, 96), fill=color + (255,))
    if soft:
        img.putalpha(img.getchannel("A").filter(ImageFilter.GaussianBlur(1.5)))
    return img


def _frames(source: Image.Image, key: str, n: int = 6) -> list[Image.Image]:
    """What the video model returns: the subject on the key color, with a little noise and shading."""
    rng = np.random.default_rng(1)
    base = np.asarray(alpha.flatten(source, key), dtype=np.float32)
    shade = np.linspace(0.92, 1.0, SIZE, dtype=np.float32)[None, :, None]
    out = []
    for _ in range(n):
        f = base * shade + rng.normal(0, 3, base.shape)
        out.append(Image.fromarray(np.clip(f, 0, 255).astype(np.uint8), "RGB"))
    return out


def test_choose_key():
    assert alpha.choose_key(None) == "green"
    assert alpha.choose_key(_subject((200, 40, 30))) == "green"  # red: green is fine
    assert alpha.choose_key(_subject((120, 220, 40))) != "green"  # yellow-green, like a potion
    assert alpha.choose_key(_subject((30, 160, 60))) != "green"


def test_flatten_puts_the_subject_on_the_key():
    flat = alpha.flatten(_subject((200, 40, 30)), "green")
    assert flat.mode == "RGB"
    assert flat.getpixel((2, 2)) == alpha.KEYS["green"]
    assert flat.getpixel((64, 64)) == (200, 40, 30)


@pytest.mark.parametrize("key", ["green", "magenta", "blue"])
def test_key_frames_removes_the_background(key):
    color = (200, 40, 30) if key != "magenta" else (40, 160, 60)
    source = _subject(color)
    frames = alpha.key_frames(_frames(source, key), key, source=source)
    assert len(frames) == 6 and all(f.mode == "RGBA" for f in frames)
    a = np.asarray(frames[3].getchannel("A"))
    want = np.asarray(source.getchannel("A"))
    assert (a[want < 10] < 20).mean() > 0.99  # background gone
    assert (a[want > 250] > 235).mean() > 0.99  # no holes in the subject


def test_key_frames_keeps_see_through_parts():
    """Half see-through white (steam) over the key: partly transparent, not removed and not solid."""
    source = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(source)
    d.rectangle((16, 16, 60, 112), fill=(220, 30, 30, 255))
    d.rectangle((70, 16, 112, 112), fill=(255, 255, 255, 128))
    frames = alpha.key_frames(_frames(source, "green"), "green", source=source)
    a = np.asarray(frames[2].getchannel("A"), dtype=np.float32) / 255
    steam = a[30:100, 80:104]
    assert 0.2 < steam.mean() < 0.85


def test_despill_removes_the_key_tint():
    rgb = np.array([[[0.5, 0.8, 0.4]]], dtype=np.float32)  # greenish edge pixel
    out = alpha._despill(rgb, np.array([[0.5]], dtype=np.float32), "green")
    assert out[0, 0, 1] <= max(out[0, 0, 0], out[0, 0, 2]) + 0.03


def test_gif_frames_transparent_index():
    source = _subject((200, 40, 30), soft=False)
    frames, index = alpha.gif_frames([source, source])
    assert index == 255 and frames[0].mode == "P"
    assert frames[0].getpixel((2, 2)) == 255
    assert frames[0].getpixel((64, 64)) != 255


def test_write_webp_keeps_alpha(tmp_path):
    source = _subject((200, 40, 30))
    moving = [source.transform(source.size, Image.AFFINE, (1, 0, i - 12, 0, 1, 0)) for i in range(24)]
    path = tmp_path / "a.webp"
    alpha.write_webp(moving, str(path), 24, width=64, fps=12)
    with Image.open(path) as im:
        assert im.n_frames == 12 and im.size == (64, 64)
        im.seek(0)
        rgba = im.convert("RGBA")
        assert rgba.getpixel((1, 1))[3] < 10 and rgba.getpixel((26, 32))[3] > 245


def test_write_webm_has_alpha_and_sound(tmp_path):
    av = pytest.importorskip("av")
    source = _subject((200, 40, 30))
    path = tmp_path / "a.webm"
    audio = np.sin(np.linspace(0, 440 * 2 * np.pi, 44100))[None].astype(np.float32) * 0.2
    alpha.write_webm([source] * 24, str(path), 24, audio, 44100)
    with av.open(str(path)) as c:
        assert c.streams.audio and c.streams.video
        ctx = av.CodecContext.create("libvpx-vp9", "r")  # the alpha plane needs libvpx to decode
        frame = next(f for p in c.demux(c.streams.video[0]) for f in ctx.decode(p))
        a = frame.to_ndarray(format="rgba")[..., 3]
        assert a[1, 1] < 10 and a[64, 64] > 245
