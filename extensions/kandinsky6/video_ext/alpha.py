"""Transparent videos. The video model makes opaque video, so a transparent input image is put on a flat key color
(a "green screen"), the model is asked to keep that background, and the color is keyed out of every frame
afterwards. Writes WebM (VP9 with alpha, Opus sound), animated WebP and GIF. CPU only.
"""

from __future__ import annotations

import warnings

import numpy as np
from PIL import Image, ImageFilter

KEYS = {"green": (0, 177, 64), "magenta": (255, 0, 255), "blue": (0, 71, 187)}
KEEP_BACKGROUND = (" Static camera, locked off, the same framing as the first frame: no zoom, no pan, no crop. The "
                   "subject stays in place, at the same size and fully inside the frame. The background is a flat, "
                   "evenly lit, pure {name} screen that stays exactly the same color the whole time, with no "
                   "shadows, reflections, objects or scenery on it.")


def has_alpha(img: Image.Image) -> bool:
    if img.mode not in ("RGBA", "LA", "PA") and not (img.mode == "P" and "transparency" in img.info):
        return False
    return img.convert("RGBA").getchannel("A").getextrema()[0] < 250


def _chroma(rgb: np.ndarray) -> np.ndarray:
    """Cb, Cr (BT.601) of float RGB in 0..1: the color without its brightness, so shading on the screen matters less."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    return np.stack([-0.168736 * r - 0.331264 * g + 0.5 * b, 0.5 * r - 0.418688 * g - 0.081312 * b], axis=-1)


def choose_key(img: Image.Image | None) -> str:
    """Green, unless the subject has some of a green hue (a green potion, green steam): then blue or magenta,
    whichever has less of the subject's hues. Hue, not exact color, because a key that is only near the subject's color still
    eats its see-through parts (steam, glow) and spills on its edges."""
    if img is None:
        return "green"
    rgba = np.asarray(img.convert("RGBA"), dtype=np.float32) / 255
    subject = rgba[..., :3][rgba[..., 3] > 0.5]
    if len(subject) == 0:
        return "green"
    chroma = _chroma(subject[:: max(1, len(subject) // 20000)])
    strength = np.linalg.norm(chroma, axis=-1)
    angle = np.arctan2(chroma[:, 1], chroma[:, 0])
    shares = {}
    for name, color in KEYS.items():
        k = _chroma(np.asarray(color, dtype=np.float32)[None] / 255)[0]
        diff = np.abs((angle - np.arctan2(k[1], k[0]) + np.pi) % (2 * np.pi) - np.pi)
        shares[name] = float(np.mean((strength > 0.06) & (diff < np.radians(60))))  # colored pixels of that hue
    if shares["green"] < 0.03:
        return "green"
    # On a tie blue before magenta: magenta is green's opposite, so green steam or glow over it mixes to gray and
    # its color cannot be recovered; over blue it stays green.
    order = ("green", "blue", "magenta")
    return min(order, key=lambda n: (round(shares[n], 2), order.index(n)))


def fit(img: Image.Image, width: int, height: int) -> Image.Image:
    """The image on a transparent canvas of the video's size, scaled to fit and not cropped (the video model crops an
    image of another shape, and a crop or zoom is wrong for a cut-out). The subject keeps to the edges it touches:
    a waist-up portrait stays on the bottom edge."""
    rgba = img.convert("RGBA")
    scale = min(width / rgba.width, height / rgba.height)
    w, h = max(1, round(rgba.width * scale)), max(1, round(rgba.height * scale))
    a = np.asarray(rgba.getchannel("A")) > 128
    edge = {n: float(v.mean()) > 0.02 for n, v in
            (("left", a[:, :2]), ("right", a[:, -2:]), ("top", a[:2]), ("bottom", a[-2:]))}

    def place(free: int, start: bool, end: bool) -> int:
        return 0 if start and not end else free if end and not start else free // 2

    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    canvas.paste(rgba.resize((w, h), Image.LANCZOS),
                 (place(width - w, edge["left"], edge["right"]), place(height - h, edge["top"], edge["bottom"])))
    return canvas


def flatten(img: Image.Image, key: str) -> Image.Image:
    """The image on the key color (what the video model sees)."""
    bg = Image.new("RGBA", img.size, KEYS[key] + (255,))
    return Image.alpha_composite(bg, img.convert("RGBA")).convert("RGB")


def _excess(rgb: np.ndarray, key: str) -> np.ndarray:
    """How much the key's own channels rise above the others (color difference). The screen has a lot, the subject
    none (the key is chosen that way), and a mix of the two in between, in proportion to how see-through it is."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    if key == "green":
        return g - np.maximum(r, b)
    if key == "blue":
        return b - np.maximum(r, g)
    return np.minimum(r, b) - g  # magenta


def _screen_color(rgb: np.ndarray, mask: np.ndarray, fallback: np.ndarray) -> np.ndarray:
    """The screen's real color (the model never paints the exact key color): the median of the background."""
    px = rgb[mask]
    if len(px) < 500:
        return fallback
    return np.median(px[:: max(1, len(px) // 40000)], axis=0)


def _noise_floor(t: np.ndarray, mask: np.ndarray, fallback: float) -> float:
    """Where the screen's noise ends: median + 3 MAD of the screen pixels. Robust to a few see-through pixels
    (steam) among them; measured on every frame, because the first frames are often grainier than the rest."""
    v = t[mask]
    if len(v) < 2000:
        return fallback
    v = v[:: max(1, len(v) // 50000)]
    med = float(np.median(v))
    return float(np.clip(med + 3 * 1.4826 * float(np.median(np.abs(v - med))) + 0.02, 0.03, 0.35))


def _screen_excess(excess: np.ndarray, mask: np.ndarray, cells: int = 12) -> np.ndarray | None:
    """The screen's excess at every pixel (a screen is never evenly lit): background medians in a coarse grid,
    filled in where the subject covers a cell, then smoothed up to full size."""
    h, w = excess.shape
    ys, xs = np.linspace(0, h, cells + 1).astype(int), np.linspace(0, w, cells + 1).astype(int)
    grid = np.full((cells, cells), np.nan, np.float32)
    for i in range(cells):
        for j in range(cells):
            m = mask[ys[i]:ys[i + 1], xs[j]:xs[j + 1]]
            if m.sum() > 0.1 * m.size:
                grid[i, j] = np.median(excess[ys[i]:ys[i + 1], xs[j]:xs[j + 1]][m])
    if np.isnan(grid).all():
        return None
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)  # all-empty neighborhoods while filling
        while np.isnan(grid).any():
            padded = np.pad(grid, 1, constant_values=np.nan)
            near = np.stack([padded[1 + dy:1 + dy + cells, 1 + dx:1 + dx + cells]
                             for dy in (-1, 0, 1) for dx in (-1, 0, 1)])
            grid = np.where(np.isnan(grid), np.nanmean(near, axis=0), grid)
    return np.asarray(Image.fromarray(grid, "F").resize((w, h), Image.BILINEAR), dtype=np.float32)


def _despill(rgb: np.ndarray, alpha: np.ndarray, key: str, screen: np.ndarray | None = None) -> np.ndarray:
    """Take the screen's tint out: remove the part of each pixel's color (Cb, Cr) that points toward the screen's
    own hue (measured, so a pinkish magenta loses its red too). Colors pointing away from it are untouched. Full on
    soft and see-through pixels, a quarter inside the subject."""
    k = _chroma((np.asarray(KEYS[key], np.float32) / 255 if screen is None else np.asarray(screen, np.float32))[None])[0]
    k = k / max(float(np.linalg.norm(k)), 1e-6)
    weight = np.clip(1.6 - alpha, 0.25, 1)
    y = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    c = _chroma(rgb)
    c = c - (np.clip(c @ k, 0, None) * weight)[..., None] * k
    cb, cr = c[..., 0], c[..., 1]
    out = np.stack([y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb], axis=-1)
    return np.clip(out, 0, 1)


def key_frames(frames: list[Image.Image], key: str, source: Image.Image | None = None,
               progress=None) -> list[Image.Image]:
    """RGBA frames with the key color removed.

    A color difference key: the opacity is 1 minus the pixel's excess (see _excess) over the screen's excess at that
    place, so a see-through gray (steam) or a half-covered hair edge gets the right partial opacity. The screen is
    measured again on every frame. The range is calibrated on the first frame, which is the input image: where it
    is transparent is screen (its noise sets the start), where it is opaque is subject (its spill sets the end).
    Soft pixels get the screen color taken out of them; the matte is smoothed over three frames (less flicker),
    cleaned of specks, and solid deep inside the subject."""
    arrays = [np.asarray(f.convert("RGB"), dtype=np.float32) / 255 for f in frames]
    h, w = arrays[0].shape[:2]
    first = arrays[0]
    if source is not None:
        src = source.convert("RGBA")
        if abs(src.width / src.height - w / h) > 0.01:
            src = fit(src, w, h)
        src_alpha = np.asarray(src.resize((w, h), Image.LANCZOS).getchannel("A"), dtype=np.float32) / 255
        bg_mask, fg_mask = src_alpha < 0.05, src_alpha > 0.95
    else:  # no input image: the frame's border is background
        bg_mask = np.zeros((h, w), bool)
        bg_mask[:8, :], bg_mask[-8:, :], bg_mask[:, :8], bg_mask[:, -8:] = True, True, True, True
        fg_mask = ~bg_mask
    excess = _excess(first, key)
    bg_mask = bg_mask & (excess > 0.1)  # not a part of the subject that reaches into the border
    screen = _screen_excess(excess, bg_mask)
    if screen is None:
        screen = np.full((h, w), float(_excess(np.asarray(KEYS[key], np.float32) / 255, key)), np.float32)
    color = _screen_color(first, bg_mask, np.asarray(KEYS[key], dtype=np.float32) / 255)
    t = 1 - excess / np.maximum(screen, 0.05)
    lo = _noise_floor(t, bg_mask, 0.15)
    hi = float(np.percentile(t[fg_mask], 3)) if fg_mask.any() else 0.9
    hi = min(max(hi, 0.5), 0.95)  # the subject's own spill sets where it is solid
    core = max(3, round(min(w, h) / 120)) * 2 + 1  # the edge band (pixels) where the matte may be soft

    mattes, colors, ranges = [], [], []
    for a in arrays:
        excess = _excess(a, key)
        t = 1 - excess / np.maximum(screen, 0.05)
        background = (t < lo) & (excess > 0.1)
        if background.sum() > 2000:  # follow the screen's light and color as the video goes on
            screen = _screen_excess(excess, background)
            color = _screen_color(a, background, color)
            t = 1 - excess / np.maximum(screen, 0.05)
            lo = _noise_floor(t, (t < 0.35) & (excess > 0.05), lo)
        top = max(hi, lo + 0.15)
        mattes.append(np.clip((t - lo) / (top - lo), 0, 1).astype(np.float32))
        ranges.append((lo, top))
        # The screen's color at each pixel: its color, brighter or darker where it is lit more or less.
        level = max(float(_excess(color, key)), 0.05)
        colors.append(np.clip(color[None, None, :] * (np.maximum(screen, 0.02) / level)[..., None], 0, 1))
    out = []
    for i, a in enumerate(arrays):
        window = mattes[max(0, i - 1): i + 2]
        m = np.median(np.stack(window), axis=0) if len(window) == 3 else mattes[i]
        img = Image.fromarray((m * 255).astype(np.uint8), "L")
        img = img.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))  # remove specks
        img = img.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3))  # close pinholes
        # Only pixels with the screen behind them can be see-through: deep inside the solid part (a white shirt
        # with green reflections) the subject is opaque. Thin or faint parts (steam, hair) keep the soft matte.
        solid = img.point(lambda v: 255 if v >= 217 else 0).filter(ImageFilter.MinFilter(core))  # 85%: not steam
        m = np.maximum(np.asarray(img, dtype=np.float32), np.asarray(solid, dtype=np.float32)) / 255
        lo, top = ranges[i]
        # How see-through the pixel really is (the matte starts later, above the screen's noise): take that much
        # of the screen's color out of it.
        real = np.where(m >= 1, 1.0, lo + m * (top - lo))[..., None]
        unmixed = np.clip((a - (1 - real) * colors[i]) / np.maximum(real, 1e-3), 0, 1)
        blend = np.clip((m[..., None] - 0.02) / 0.2, 0, 1)  # the faintest pixels: unmixing is unsure there
        rgb = a + (unmixed - a) * blend
        level = max(float(_excess(colors[i][h // 2, w // 2], key)), 1e-3)
        rgb = _despill(rgb, m, key, screen=colors[i][h // 2, w // 2] if level > 0.05 else None)
        rgba = np.dstack([rgb, m])
        out.append(Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), "RGBA"))
        if progress is not None and i % 12 == 0:
            progress(i / len(arrays))
    return out


def write_webm(frames: list[Image.Image], path: str, fps: int, audio=None, sample_rate: int = 44100) -> None:
    """VP9 with an alpha channel (yuva420p) and Opus sound. Plays transparent in Chrome, Edge and Firefox."""
    import av

    with av.open(path, "w", format="webm") as c:
        v = c.add_stream("libvpx-vp9", rate=fps)
        v.width, v.height = frames[0].size
        v.pix_fmt = "yuva420p"
        v.options = {"crf": "30", "b": "0", "row-mt": "1", "cpu-used": "4", "auto-alt-ref": "0"}
        a = None
        if audio is not None:
            a = c.add_stream("libopus", rate=48000)
            a.layout = "stereo"
        for f in frames:
            frame = av.VideoFrame.from_ndarray(np.asarray(f.convert("RGBA")), format="rgba").reformat(format="yuva420p")
            for packet in v.encode(frame):
                c.mux(packet)
        for packet in v.encode():
            c.mux(packet)
        if a is not None:
            samples = np.asarray(audio, dtype=np.float32)
            if samples.ndim == 1:
                samples = samples[None]
            if samples.shape[0] == 1:
                samples = np.repeat(samples, 2, axis=0)
            src = av.AudioFrame.from_ndarray(np.ascontiguousarray(samples[:2]), format="fltp", layout="stereo")
            src.sample_rate = sample_rate
            resampler = av.AudioResampler(format="flt", layout="stereo", rate=48000)
            fifo = av.AudioFifo()
            for r in resampler.resample(src) + resampler.resample(None):
                fifo.write(r)
            size = a.codec_context.frame_size or 960
            while fifo.samples >= size:
                for packet in a.encode(fifo.read(size)):
                    c.mux(packet)
            rest = fifo.read()
            if rest is not None:
                for packet in a.encode(rest):
                    c.mux(packet)
            for packet in a.encode():
                c.mux(packet)


def write_webp(frames: list[Image.Image], path: str, src_fps: int, width: int = 480, fps: int = 12) -> None:
    """A small animated WebP that keeps the soft transparent edges."""
    step = max(1, round(src_fps / max(1, fps)))
    picked = frames[::step]
    w = min(width, picked[0].width)
    h = max(2, round(picked[0].height * w / picked[0].width / 2) * 2)
    small = [f.convert("RGBA").resize((w, h), Image.LANCZOS) for f in picked]
    small[0].save(path, format="WEBP", save_all=True, append_images=small[1:], duration=round(1000 * step / src_fps),
                  loop=0, quality=80, method=4)


def gif_frames(frames: list[Image.Image]) -> tuple[list[Image.Image], int]:
    """GIF frames with transparency: GIF has no soft edges, so a pixel is either shown or not (alpha >= 50%).
    One shared palette; index 255 is transparent."""
    rgba = [f.convert("RGBA") for f in frames]
    w, h = rgba[0].size
    sample = Image.new("RGB", (w, h * min(8, len(rgba))))
    for i, f in enumerate(rgba[:: max(1, len(rgba) // 8)][:8]):
        sample.paste(f.convert("RGB"), (0, i * h))
    palette = sample.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
    out = []
    for f in rgba:
        p = f.convert("RGB").quantize(palette=palette, dither=Image.Dither.FLOYDSTEINBERG)
        mask = Image.eval(f.getchannel("A"), lambda v: 255 if v < 128 else 0)
        p.paste(255, mask=mask)
        p.info["transparency"] = 255
        out.append(p)
    return out, 255
