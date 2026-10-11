"""Image to SVG for logos, icons, line art and flat art.

AI images have soft edges, shading and noise, which a tracer turns into thousands of tiny shapes. So the image is first
cleaned up, then traced:
- Transparency becomes a hard mask, and the colour analysis uses only the visible pixels (a cut-out's transparent
  background once pulled a light grey rocket body to white).
- look() finds the colours that really make up the image: the solid ones, plus the colours of thin lines that are not
  anti-aliased blends of the others. It also finds the shades of shaded art, whether the image is a photo, and
  whether it has fine lines.
- clean() applies a light median filter, gives every pixel its nearest colour, and removes specks with a mode filter.
  Fine lines are cleaned at twice the size, and two-colour line art keeps its faint strokes.
- VTracer (MIT, visioncortex) traces the flat image into stacked SVG paths, and resvg (Apache-2.0 or MIT) renders a
  PNG preview.
Tested on 40 generated images (logos, icons, stencils, line art, cut-outs, flat illustrations, a pattern, photos): no
see-through areas, every colour area within delta E 10 of the source under it, lines kept within 1 px (recall 0.97 to
1.0), 3-1840 KB per SVG (photos and very detailed art get a note), 0.3-2.7 s on the CPU.
"""
from __future__ import annotations

import io
import re
from dataclasses import dataclass, field

import numpy as np
from PIL import Image, ImageFilter

# VTracer settings per preset. layer_difference stays low: higher values merge distinct colours (the rocket icon's
# yellow flame into its red fins), and the colour count is set by the clean-up step instead. path_precision 2 (0.01 px)
# makes the SVG about 12% smaller than 3, with no visible change.
_COMMON = dict(hierarchical="stacked", mode="spline", max_iterations=10, splice_threshold=45, path_precision=2,
               corner_threshold=60)
PRESETS: dict[str, dict] = {
    "logo": dict(colors=8, colormode="color", filter_speckle=8, color_precision=8, layer_difference=8,
                 length_threshold=4.0),
    "icon": dict(colors=12, colormode="color", filter_speckle=6, color_precision=8, layer_difference=8,
                 length_threshold=4.0),
    "illustration": dict(colors=24, colormode="color", filter_speckle=4, color_precision=8, layer_difference=8,
                         length_threshold=3.5),
    "bw": dict(colors=2, colormode="color", filter_speckle=6, color_precision=8, layer_difference=8,
               length_threshold=4.0),
}
PRESET_NAMES = ("auto", *PRESETS)
WORK_MIN, WORK_MAX = 768, 2048  # long side: small images are enlarged first (smoother curves), large ones reduced
PREVIEW_MAX = 1024  # long side of the PNG preview
MIN_HIDDEN = 0.001  # an image with fewer see-through pixels than this share is treated as opaque
# The real colours (look). Shares are of the visible pixels; a colour's solid share is the share of its pixels whose
# eight neighbours have the same colour.
MIN_SHARE_MINOR = 0.0005  # a solid colour counts from this share (an eye highlight, a door)
THIN_CORE = 0.5  # a colour with a smaller solid share lies only in thin bands: a line colour or an anti-aliased edge
MIN_SHARE_THIN = 0.002  # a thin colour counts from this share (smaller: noise)
NEAR_DE = 7.0  # perceptual distance (CIE76 delta E): closer than this to a kept colour is a near-duplicate. An RGB
# distance judged dark colours badly: a brown door and a red-brown chimney 28 apart in RGB (delta E 14) were merged
BLEND_DIST = 28.0  # RGB distance to the line between two kept colours: closer is a blend (a soft edge)
BLEND_DIST_THIN = 45.0  # a thin colour this close to the line between two kept colours is a blend (a soft edge)
WIDE_KEEP = 0.5  # ... unless this share of its pixels is in bands over 3 px wide (a highlight stripe, not an edge)
FRINGE = 0.6  # a thin colour with this share of its pixels along a cut-out's edge is a matting fringe
OFF_DIST = 30  # RGB distance: a pixel farther than this from every real colour is shading, a gradient or photo detail
PHOTO_OFF = 0.12  # this share of such pixels: a photo or painting
SHADE_MIN, SHADE_SHARE, SHADE_MAX = 0.01, 0.005, 6  # shaded art: shades that cover this share, at most this many
FINE_THIN = 0.25  # fine lines: this share of the colours other than the background is in parts under 3 px wide
LINE_T = 0.2  # two-colour line art: a pixel this far from the background towards the line colour is line (low:
# a 1 px stroke is faint after anti-aliasing and the enlargement, and a higher split breaks it into dashes)
MODE_SIZE = 3  # mode filter after the colour mapping: each pixel takes the most common colour around it
COMPLEX_PATHS, COMPLEX_BYTES = 400, 200 * 1024  # a larger SVG gets a note: detailed art or a photo
SEAM = 0.8  # px (of the traced size): every shape is outlined this wide in its own colour (see _seal)


@dataclass
class Vector:
    svg: str
    preview: Image.Image
    preset: str
    colors: int
    paths: int
    width: int
    height: int
    transparent: bool
    notes: list[str] = field(default_factory=list)


@dataclass
class Look:
    """What the image is made of. colors: the real colours, most common first, each with its share and solid share.
    shades: extra colours for the shading of shaded art. off: the share of visible pixels far from every real colour.
    thin: the share of the colours other than the background in parts under 3 px wide."""
    colors: list[tuple[tuple[int, int, int], float, float]]
    shades: list[tuple[int, int, int]]
    off: float
    thin: float

    @property
    def fine(self) -> bool:
        """Fine lines (line art, twigs, hairlines) that the clean-up would break at this size."""
        return self.thin >= FINE_THIN

    @property
    def photo(self) -> bool:
        return self.off >= PHOTO_OFF


def _work_size(img: Image.Image, at_least: int = WORK_MIN) -> Image.Image:
    long_side = max(img.size)
    target = min(max(long_side, at_least), WORK_MAX)
    if target == long_side:
        return img
    scale = target / long_side
    return img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.LANCZOS)


def _split(img: Image.Image) -> tuple[Image.Image, Image.Image | None]:
    """RGB pixels and a hard alpha mask (None when the image is opaque)."""
    rgba = img.convert("RGBA")
    alpha = rgba.getchannel("A")
    if alpha.getextrema()[0] >= 250:
        return rgba.convert("RGB"), None
    mask = alpha.point(lambda v: 255 if v > 127 else 0)
    if np.asarray(mask).mean() >= 255 * (1 - MIN_HIDDEN):  # a few stray see-through pixels: not a cut-out
        return rgba.convert("RGB"), None
    # Hidden pixels take white, so they never pull the visible colours towards black in the colour reduction.
    rgb = Image.new("RGB", rgba.size, (255, 255, 255))
    rgb.paste(rgba.convert("RGB"), mask=mask)
    return rgb, mask


def _opaque(img: Image.Image, mask: Image.Image | None) -> Image.Image | None:
    """The fully opaque part of a cut-out, for finding its colours. The half-transparent edge pixels of a cut-out
    are often darkened (premultiplied), and counted as a colour they drew a black band around a rocket's outline;
    they still belong to the shape (mask) and take their nearest real colour."""
    if mask is None:
        return None
    solid = img.convert("RGBA").getchannel("A").point(lambda v: 255 if v >= 250 else 0)
    return solid if np.asarray(solid).any() else mask


def _visible(rgb: Image.Image, mask: Image.Image | None) -> Image.Image:
    """Only the visible pixels (as a square image), so that a transparent background never takes palette colours."""
    if mask is None:
        return rgb
    px = np.asarray(rgb)[np.asarray(mask) > 0]
    if not len(px):
        return rgb
    side = int(np.ceil(np.sqrt(len(px))))
    px = np.concatenate([px, px[: side * side - len(px)]])  # pad with visible pixels again
    return Image.fromarray(px.reshape(side, side, 3))


def _octree(img: Image.Image, n: int) -> list[tuple[int, int, int]]:
    q = img.quantize(colors=n, method=Image.Quantize.FASTOCTREE, kmeans=3, dither=Image.Dither.NONE)
    pal = q.getpalette() or []
    used = sorted({c for _, c in q.getcolors(maxcolors=4096) or []})
    return [tuple(pal[i * 3:i * 3 + 3]) for i in used]


def _palette_image(palette: list[tuple[int, int, int]]) -> Image.Image:
    """A palette for Image.quantize; the unused entries repeat the first colour, so no pixel maps to them."""
    ref = Image.new("P", (1, 1))
    ref.putpalette([v for c in palette for v in c] + list(palette[0]) * (256 - len(palette)))
    return ref


def _core(idx: np.ndarray) -> np.ndarray:
    """The pixels whose eight neighbours all have the same colour."""
    h, w = idx.shape
    p = np.pad(idx, 1, mode="edge")
    same = np.ones(idx.shape, bool)
    for dy in range(3):
        for dx in range(3):
            if dy != 1 or dx != 1:
                same &= p[dy:dy + h, dx:dx + w] == idx
    return same


def look(rgb: Image.Image, mask: Image.Image | None, limit: int = 64) -> Look:
    ref = _visible(rgb, mask).quantize(colors=limit, method=Image.Quantize.FASTOCTREE, kmeans=3,
                                       dither=Image.Dither.NONE)
    idx = np.asarray(rgb.quantize(palette=ref, dither=Image.Dither.NONE))
    vis = np.ones(idx.shape, bool) if mask is None else np.asarray(mask) > 0
    # The colour reduction splits one flat colour into several near-identical entries (noise, slight shading). Merge
    # them first, so a small area (a chimney) keeps its whole share, and its solid share is measured on whole areas.
    pal = np.array((ref.getpalette() or [])[:768], dtype=float).reshape(-1, 3)
    counts = np.bincount(idx[vis], minlength=len(pal))
    groups: list[list[int]] = []
    for i in np.argsort(-counts):
        if not counts[i]:
            break
        lab = _lab(pal[i])
        for g in groups:
            if float(np.linalg.norm(_lab(pal[g[0]]) - lab)) < NEAR_DE:
                g.append(int(i))
                break
        else:
            groups.append([int(i)])
    to_group = np.zeros(len(pal), dtype=np.uint8)
    for gi, g in enumerate(groups):
        to_group[g] = gi
    idx = to_group[idx]
    means = np.array([np.average(pal[g], axis=0, weights=counts[g]) for g in groups])
    colour_of = [tuple(int(round(v)) for v in m) for m in means]
    group_of = {c: i for i, c in enumerate(colour_of)}
    core = _core(idx) & vis
    counts = np.bincount(idx[vis], minlength=len(groups))
    cores = np.bincount(idx[core], minlength=len(groups))
    total = int(counts.sum()) or 1
    found = sorted(((colour_of[i], int(n) / total, float(cores[i] / n))
                    for i, n in enumerate(counts) if n and n / total >= MIN_SHARE_MINOR), key=lambda c: -c[1])

    ring = None  # a cut-out's outer edge: the visible pixels within 2 px of the transparent part
    if mask is not None:
        inner = _grow(_grow(vis, True), True)
        ring = vis & ~inner

    def fringe(cand: tuple[int, int, int]) -> bool:
        """Whether a thin colour lies almost only along a cut-out's edge: the darkened half-transparent pixels left
        by the background removal (a black band around a rocket's grey outline), not a colour of the picture."""
        if ring is None or cand not in group_of:
            return False
        m = (idx == group_of[cand]) & vis
        n = int(m.sum())
        return n > 0 and int((m & ring).sum()) >= FRINGE * n

    def wide(cand: tuple[int, int, int], kept: list[tuple[int, int, int]]) -> bool:
        """Whether the pixels that would take this colour form bands wider than 3 px (a highlight stripe) rather
        than the 1-2 px of an anti-aliased edge."""
        k = np.array(kept + [cand], dtype=float)
        mine = np.flatnonzero(((means[:, None, :] - k[None]) ** 2).sum(-1).argmin(1) == len(kept))
        m = np.isin(idx, mine) & vis
        n = int(m.sum())
        return n > 0 and int((m & _opened(m)).sum()) >= WIDE_KEEP * n

    # Every second pixel each way is enough for the shares below.
    px = np.asarray(rgb.filter(ImageFilter.MedianFilter(3)), dtype=np.int32)[::2, ::2]
    v, c2 = vis[::2, ::2], core[::2, ::2]
    seen = int(v.sum()) or 1

    def far_from(colors: list) -> np.ndarray:
        d2 = np.full(v.shape, 1 << 30)
        for c, *_ in colors:
            d2 = np.minimum(d2, ((px - np.array(c, dtype=np.int32)) ** 2).sum(axis=-1))
        return (d2 > OFF_DIST ** 2) & v

    colors = _real_colors(found, fringe=fringe)
    far = far_from(colors)
    off = float(far.sum()) / seen
    if off < PHOTO_OFF:  # not a photo: keep the highlight stripes that the blend test took for soft edges
        colors = _real_colors(found, wide, fringe)
        far = far_from(colors)
    # Shading sits inside solid areas; the anti-aliased edges of lines are thin, and do not count.
    shades = _shades(px[far & c2], [c for c, *_ in colors], seen)
    return Look(colors, shades, off, _thin(rgb, vis, [c for c, *_ in colors]))


def _real_colors(found: list, wide=lambda cand, kept: False, fringe=lambda cand: False) -> list:
    """Solid colours count first, the large ones before the small ones; a near-duplicate of a kept colour never
    counts. Then the colours that lie only in thin bands, the most distinct first: a fine line's own colour comes
    before the anti-aliased shades between it and the background, which then count as blends (soft edges), unless
    they form wide bands (a highlight stripe on a fin). A thin colour along a cut-out's edge is a fringe."""
    keep, thin = [], []
    for f in found:
        if f[2] >= THIN_CORE:
            if not _near_kept(f[0], [c for c, *_ in keep], blends=False):
                keep.append(f)
        elif f[1] >= MIN_SHARE_THIN:
            thin.append(f)
    if not keep and thin:
        keep.append(thin.pop(0))
    while thin:
        kept = [np.array(c, dtype=float) for c, *_ in keep]
        far = max(thin, key=lambda f: min(np.linalg.norm(np.array(f[0], dtype=float) - k) for k in kept))
        thin.remove(far)
        kept = [c for c, *_ in keep]
        if fringe(far[0]):
            continue
        if not _near_kept(far[0], kept, blends=False) and (
                not _near_kept(far[0], kept, dist=BLEND_DIST_THIN) or wide(far[0], kept)):
            keep.append(far)
    return sorted(keep, key=lambda c: -c[1])


def _grow(a: np.ndarray, erode: bool) -> np.ndarray:
    """A 3x3 erosion (a pixel stays when its neighbours are set too) or dilation of a mask, with array shifts, one
    direction at a time: several times faster than Pillow's min and max filters."""
    out = a.copy()
    for axis in (0, 1):
        b = out.copy()
        lo, hi = [slice(None)] * 2, [slice(None)] * 2
        lo[axis], hi[axis] = slice(1, None), slice(None, -1)
        if erode:
            b[tuple(lo)] &= out[tuple(hi)]
            b[tuple(hi)] &= out[tuple(lo)]
        else:
            b[tuple(lo)] |= out[tuple(hi)]
            b[tuple(hi)] |= out[tuple(lo)]
        out = b
    return out


def _opened(m: np.ndarray) -> np.ndarray:
    """A 3x3 opening: what is left of a mask without its parts under 3 px wide."""
    return _grow(_grow(m, True), False)


def _shades(px: np.ndarray, colors: list[tuple[int, int, int]], seen: int) -> list[tuple[int, int, int]]:
    """The main shades of shaded art (the darker side of a rocket body, the soft parts of a pattern): solid areas far
    from every real colour, reduced to a few colours that each cover a fair share of the image."""
    if len(px) < SHADE_MIN * seen:
        return []
    side = int(np.ceil(np.sqrt(len(px))))
    px = np.concatenate([px, px[: side * side - len(px)]]).astype(np.uint8)
    q = Image.fromarray(px.reshape(side, side, 3)).quantize(colors=SHADE_MAX, method=Image.Quantize.FASTOCTREE,
                                                            kmeans=3, dither=Image.Dither.NONE)
    pal = q.getpalette() or []
    out: list[tuple[int, int, int]] = []
    for n, i in sorted(q.getcolors(maxcolors=256) or [], reverse=True):
        c = tuple(pal[i * 3:i * 3 + 3])
        if n >= SHADE_SHARE * seen and not _near_kept(c, colors + out, blends=False):
            out.append(c)
    return out


def _thin(rgb: Image.Image, vis: np.ndarray, palette: list[tuple[int, int, int]]) -> float:
    """The share of the pixels of all colours but the most common one that lie in parts under 3 px wide (what a
    3x3 opening removes), on the image mapped to its real colours. Line art is mostly such parts; a thin shading
    band in flat art is a small part of its colours."""
    if len(palette) < 2:
        return 0.0
    labels = np.asarray(rgb.quantize(palette=_palette_image(palette), dither=Image.Dither.NONE))
    thin = total = 0
    for i in range(1, len(palette)):
        m = (labels == i) & vis
        total += int(m.sum())
        thin += int((m & ~_opened(m)).sum())
    return thin / total if total else 0.0


def _lab(rgb: np.ndarray) -> np.ndarray:
    """sRGB (0-255, last axis) to CIE Lab (D65)."""
    c = np.asarray(rgb, dtype=float) / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    xyz = c @ np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]).T
    f = xyz / np.array([0.95047, 1.0, 1.08883])
    f = np.where(f > 0.008856, np.cbrt(f), 7.787 * f + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def _near_kept(c: tuple[int, int, int], kept: list[tuple[int, int, int]], blends: bool = True,
               dist: float = BLEND_DIST) -> bool:
    """Whether a colour is a near-duplicate of a kept colour (by perceptual distance), or (blends) lies near the line
    between two of them in RGB, where anti-aliasing mixes colours."""
    if kept and float(np.linalg.norm(_lab(np.array(kept)) - _lab(np.array(c)), axis=-1).min()) < NEAR_DE:
        return True
    p = np.array(c, dtype=float)
    pts = [np.array(k, dtype=float) for k in kept]
    if not blends:
        return False
    for i, a in enumerate(pts):
        for b in pts[i + 1:]:
            ab = b - a
            t = float(np.clip(np.dot(p - a, ab) / (np.dot(ab, ab) or 1.0), 0.0, 1.0))
            if np.linalg.norm(p - (a + t * ab)) < dist:
                return True
    return False


def _is_black_and_white(colors: list) -> bool:
    if len(colors) > 2:
        return False
    for (r, g, b), *_ in colors:
        if max(r, g, b) - min(r, g, b) > 40:  # a real hue, not grey
            return False
    lum = sorted(0.299 * r + 0.587 * g + 0.114 * b for (r, g, b), *_ in colors)
    return len(lum) == 1 or lum[-1] - lum[0] > 128


def _bw_palette(colors: list) -> list[tuple[int, int, int]]:
    """The ink and the paper of two-colour art, darkest first. Neutral ones become pure black and white; tinted ones
    keep their colour (a dark brown badge on cream stays brown on cream, not black on white)."""
    found = sorted((c for c, *_ in colors), key=lambda c: 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2])
    if len(found) < 2:
        return [(0, 0, 0), (255, 255, 255)]

    def snap(c: tuple[int, int, int], pure: tuple[int, int, int]) -> tuple[int, int, int]:
        return pure if max(c) - min(c) <= 12 else tuple(int(v) for v in c)

    return [snap(found[0], (0, 0, 0)), snap(found[-1], (255, 255, 255))]


def choose(rgb: Image.Image, mask: Image.Image | None, preset: str,
           colors: int | None) -> tuple[str, list[tuple[int, int, int]], Look]:
    """The preset and the palette: 'auto' picks the preset from what the image is made of."""
    seen = look(rgb, mask)
    real = [c for c, *_ in seen.colors]
    shaded = real + ([] if seen.photo else seen.shades)
    if preset == "auto":
        n = max(2, len(shaded))
        if _is_black_and_white(seen.colors):
            preset = "bw"
        elif seen.photo:
            preset = "illustration"
        elif n <= PRESETS["logo"]["colors"]:
            preset = "logo"
        elif n <= PRESETS["icon"]["colors"]:
            preset = "icon"
        else:
            preset = "illustration"
    if preset not in PRESETS:
        raise ValueError(f"unknown preset {preset!r}; use one of {', '.join(PRESET_NAMES)}")
    if preset == "bw":
        return preset, _bw_palette(seen.colors), seen
    if colors:  # the caller's colour count: an even colour reduction
        return preset, _octree(_visible(rgb, mask), int(colors)), seen
    cap = PRESETS[preset]["colors"]
    if not seen.photo and len(shaded) <= cap:
        return preset, shaded, seen  # the real colours (without the soft-edge blends) and the main shades
    # A photo or shaded art, or more colours than the preset holds: the main real colours stay exact, and the rest
    # of the colours go to the pixels far from them (gradients, shading, fur).
    base = real[: cap // 2]
    return preset, _fill(rgb, mask, base, cap - len(base)), seen


def _fill(rgb: Image.Image, mask: Image.Image | None, base: list[tuple[int, int, int]],
          n: int) -> list[tuple[int, int, int]]:
    """The base colours plus up to n colours for the pixels far from all of them."""
    px = np.asarray(rgb.filter(ImageFilter.MedianFilter(3)), dtype=np.int32)[::2, ::2]
    vis = (np.ones(px.shape[:2], bool) if mask is None else np.asarray(mask)[::2, ::2] > 0)
    d2 = np.full(px.shape[:2], 1 << 30)
    for c in base:
        d2 = np.minimum(d2, ((px - np.array(c, dtype=np.int32)) ** 2).sum(axis=-1))
    far = px[(d2 > OFF_DIST ** 2) & vis].astype(np.uint8)
    if n <= 0 or len(far) < 64:
        return base
    side = int(np.ceil(np.sqrt(len(far))))
    far = np.concatenate([far, far[: side * side - len(far)]]).reshape(side, side, 3)
    extra = _octree(Image.fromarray(far), n)
    return base + [c for c in extra if not _near_kept(c, base, blends=False)]


def clean(rgb: Image.Image, mask: Image.Image | None, palette: list[tuple[int, int, int]], binary: bool,
          lines: bool = False) -> Image.Image:
    """Light denoise, then every pixel takes its nearest palette colour (or black or white), then a mode filter
    removes the specks left where noise sits between two colours. lines: two-colour line art, where faint strokes
    count as line (see _two_tone). The hard mask is put back as alpha."""
    if lines and len(palette) == 2:
        flat = _two_tone(rgb, palette)
    elif binary:
        dark, light = palette[0], palette[-1]
        mid = (0.299 * (dark[0] + light[0]) + 0.587 * (dark[1] + light[1]) + 0.114 * (dark[2] + light[2])) / 2
        bits = _majority(rgb.convert("L").filter(ImageFilter.MedianFilter(3)).point(lambda v: 255 if v > mid else 0))
        flat = Image.fromarray(np.where(np.asarray(bits)[..., None] > 0, light, dark).astype(np.uint8))
    else:
        q = rgb.filter(ImageFilter.MedianFilter(3)).quantize(palette=_palette_image(palette), dither=Image.Dither.NONE)
        flat = q.filter(ImageFilter.ModeFilter(MODE_SIZE)).convert("RGB")
    if mask is None:
        return flat
    out = flat.convert("RGBA")
    out.putalpha(mask)
    return out


def _two_tone(img: Image.Image, palette: list[tuple[int, int, int]]) -> Image.Image:
    """Line art in two colours. A fine stroke is only partly dark after anti-aliasing, so the halfway split between
    the two colours breaks it into dashes; here a pixel is line from LINE_T of the way from the background. Measured
    on a blueprint with hatching, a tree with twigs and a colouring page: every line kept within 1 px (recall 0.98 to
    0.995), against 0.86 to 0.98 with the halfway split; strokes come out slightly bolder."""
    px = np.asarray(img, dtype=np.float32)
    bg, ink = (np.array(c, dtype=np.float32) for c in palette[:2])
    d = ink - bg
    t = ((px - bg) @ d) / float(d @ d or 1.0)
    if (t > 0.5).mean() > 0.5:  # the second colour is the background
        bg, ink, t = ink, bg, 1.0 - t
    # No median filter here: it erases 1 px strokes. The majority filter still removes lone specks.
    line = _majority(Image.fromarray(((t > LINE_T) * 255).astype(np.uint8)))
    return Image.fromarray(np.where(np.asarray(line)[..., None] > 0, ink, bg).astype(np.uint8))


def _majority(img: Image.Image) -> Image.Image:
    """The 3x3 mode filter of a black-and-white image (a pixel takes what most of its 3x3 block is), from a box
    blur: much faster than ImageFilter.ModeFilter on a large image."""
    return img.filter(ImageFilter.BoxBlur(1)).point(lambda v: 255 if v >= 128 else 0)


def available() -> bool:
    """Whether the tracer and the SVG renderer are installed (both are plain wheels, no GPU)."""
    try:
        import resvg_py  # noqa: F401
        import vtracer  # noqa: F401
    except ImportError:
        return False
    return True


def trace(img: Image.Image, preset: str) -> str:
    import vtracer  # imported here so the server starts even when the package is missing

    opts = {k: v for k, v in PRESETS[preset].items() if k != "colors"}
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return vtracer.convert_raw_image_to_svg(buf.getvalue(), img_format="png", **_COMMON, **opts)


def render(svg: str, width: int) -> Image.Image:
    import resvg_py

    png = bytes(resvg_py.svg_to_bytes(svg_string=svg, width=width))
    img = Image.open(io.BytesIO(png))
    img.load()
    return img.convert("RGBA")


def vectorize(img: Image.Image, preset: str = "auto", colors: int | None = None) -> Vector:
    """Trace an image into an SVG. preset: auto, logo, icon, illustration or bw; colors overrides the colour count."""
    if preset not in PRESET_NAMES:
        raise ValueError(f"unknown preset {preset!r}; use one of {', '.join(PRESET_NAMES)}")
    if colors is not None and not 2 <= int(colors) <= 64:
        raise ValueError("colors must be between 2 and 64")
    work = _work_size(img)
    rgb, mask = _split(work)
    name, palette, seen = choose(rgb, _opaque(work, mask), preset, colors)
    if seen.fine and (name == "bw" or not seen.photo) and max(work.size) < WORK_MAX:
        # Fine lines are 1-2 px wide at this size, and the clean-up would break them: work at twice the size.
        work = _work_size(img, 2 * max(work.size))
        rgb, mask = _split(work)
    flat = clean(rgb, mask, palette, binary=name == "bw", lines=seen.fine)
    svg = trace(flat, name)
    used = [c for _, c in flat.convert("RGB").getcolors(maxcolors=4096) or []]
    svg = snap_fills(svg, used)
    if len(used) > 2:  # with two colours a seam shows the background colour itself: nothing to hide
        svg = _seal(svg)
    scale = min(1.0, PREVIEW_MAX / max(work.size))
    preview = render(svg, max(1, round(work.width * scale)))
    if mask is None:  # an opaque source keeps an opaque preview
        preview = preview.convert("RGB")
    fills = set(re.findall(r'fill="(#[0-9A-Fa-f]{3,8})"', svg))
    paths = svg.count("<path")
    notes = []
    if paths > COMPLEX_PATHS or len(svg) > COMPLEX_BYTES:
        notes.append(f"the SVG has {paths} paths ({len(svg) // 1024} KB): detailed art or a photo makes a large SVG. "
                     "Vectorizing works best on logos, icons, line art and flat art with few colours")
    return Vector(svg=svg, preview=preview, preset=name, colors=len(fills) or len(palette), paths=paths,
                  width=work.width, height=work.height, transparent=mask is not None, notes=notes)


def _seal(svg: str) -> str:
    """Outline every shape in its own colour. Stacked tracing smooths each shape on its own, and where two
    neighbours do not meet exactly, the shape beneath shows through as a hairline (a dark line along the outer edge of
    a gold ring on a green disc). SEAM px covers those seams; less left a trace."""
    svg = re.sub(r'fill="(#[0-9A-Fa-f]{6})"', r'fill="\1" stroke="\1"', svg)
    svg = re.sub(r"(<svg[^>]*>)", rf'\1<g stroke-width="{SEAM}" stroke-linejoin="round">', svg, count=1)
    return svg.replace("</svg>", "</g></svg>")


def snap_fills(svg: str, palette: list[tuple[int, int, int]]) -> str:
    """Set every fill to the nearest colour of the cleaned image. VTracer averages each region a little differently,
    which leaves dozens of near-identical fills; one value per real colour keeps the SVG easy to recolour."""
    if not palette:
        return svg
    pal = np.array(palette, dtype=float)

    def nearest(m: re.Match) -> str:
        h = m.group(1)
        rgb = np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=float)
        r, g, b = (int(v) for v in pal[int(np.argmin(((pal - rgb) ** 2).sum(axis=1)))])
        return f'fill="#{r:02X}{g:02X}{b:02X}"'

    return re.sub(r'fill="#([0-9A-Fa-f]{6})"', nearest, svg)
