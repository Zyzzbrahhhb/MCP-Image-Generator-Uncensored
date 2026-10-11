"""The video extension's MCP server. The image server registers these tools on its own MCP address and forwards
calls here over a private network, so clients only ever talk to the image server.

Text that contains {base_url} is rewritten by the image server to its public address.
"""

from __future__ import annotations

import asyncio
import io
import logging
import os
import re
import secrets
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Annotated, Literal

from mcp.server.mcpserver import Context, MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import CallToolResult, ImageContent, TextContent, ToolAnnotations
from pydantic import Field
from starlette.requests import Request
from starlette.responses import JSONResponse

from . import alpha
from .pipeline import FPS, SEGMENT_FRAMES, SIZES, SMALL_SIZES, Cancelled, VideoPipeline

log = logging.getLogger("video.server")

OUTPUTS = Path(os.environ.get("VIDEO_OUTPUTS", "/outputs"))
POSTERS = ".posters"  # hidden folder: the gallery uses these as video thumbnails
IDLE_UNLOAD = int(os.environ.get("VIDEO_IDLE_UNLOAD_SECONDS", "600"))
MAX_SEGMENTS = 4      # 20 s

GUIDE = {
    "generate": (
        "Make a 5-20 s video with sound (MP4, 24 fps) from text, or from an image as the first frame.\n"
        "Prompt: the model follows it literally. Say where things are, which way each one moves, what the camera "
        "does ('static camera, no zoom' or 'slow pan right') and what stays still, then 'Audio: ...'. With an "
        "image, describe only what moves next.\n"
        "transparent: true (game assets, UI, stickers): give a transparent image and describe motion in place.\n"
        "Slow (1-3 min per 5 s): returns a job_id; then call get_job.\n"
        "Example: {\"prompt\": \"A red fox walks slowly from the left edge to the center of a snowy clearing and "
        "sits. Static camera. Audio: footsteps in snow, wind. No dialogue.\"}"),
    "extend": (
        "Make a video longer: new 5 s parts start on its last frame; returns the whole video with sound.\n"
        "Example: {\"video\": \"2026-10-11/video-120102-1a2b3c4d.mp4\", \"prompt\": \"The fox jumps into the "
        "snow. Audio: a soft thump.\"}"),
    "gif": (
        "Turn a video into an animated GIF (no sound). Runs on the CPU in seconds and does not wait for the GPU. "
        "New videos can get one with gif: true.\n"
        "Example: {\"video\": \"2026-10-11/video-120102-1a2b3c4d.mp4\", \"width\": 480}"),
}

_AUDIO = re.compile(r"\baudio\s*:", re.IGNORECASE)


def compose(prompt: str, sound: bool, extra: str = "") -> str:
    """The prompt in the form Kandinsky 6 was trained on: the video caption, then the sound inside
    <AUDCAP>...<ENDAUDCAP>. The last 'Audio: ...' in the prompt becomes that block; ``extra`` (the transparent
    background's text) joins the video caption. Without sound the audio caption is left out."""
    if "<AUDCAP>" in prompt:
        video, rest = prompt.split("<AUDCAP>", 1)
        audio, _, trailing = rest.partition("<ENDAUDCAP>")
        video = f"{video.strip()} {trailing.strip()}"
    else:
        found = list(_AUDIO.finditer(prompt))
        cut = found[-1] if found else None
        video, audio = (prompt[:cut.start()], prompt[cut.end():]) if cut else (prompt, "")
    video = f"{video.strip()}{extra}".strip()
    audio = audio.strip()
    return f"{video} <AUDCAP>{audio}<ENDAUDCAP>" if sound and audio else video


ImageRef = Annotated[str | None, Field(
    description="Optional first frame: a URL, outputs path, upload id or data URI.",
    json_schema_extra={"x-imagegen-input": "image"})]
Seconds = Annotated[Literal[5, 10, 15, 20], Field(description="Length (5 s parts).")]
Aspect = Annotated[Literal["16:9", "9:16", "1:1"] | None, Field(description="Default: 16:9, or the image's shape.")]
Quality = Annotated[Literal["standard", "draft"], Field(description="draft: 320p, 2.5x faster.")]
Gif = Annotated[bool, Field(description="Also save a GIF (480 px, no sound).")]
Transparent = Annotated[bool, Field(description="Transparent background: WebM + animated WebP (MP4 cannot be).")]
Count = Annotated[int, Field(ge=1, le=4, description="Variations, each with the next seed.",
                             json_schema_extra={"x-imagegen-repeat": "seed"})]
GIF_WIDTH, GIF_FPS = 480, 12


class Renderer:
    """One render at a time; unloads the model after an idle period."""

    def __init__(self):
        mode = os.environ.get("VIDEO_MODE", "low-memory")
        cap = os.environ.get("VIDEO_CAP_GB", "").strip()
        self.pipeline = VideoPipeline(mode, float(cap) if cap else None)
        self.lock = asyncio.Lock()
        self.busy_since: float | None = None

    def start_idle_watch(self) -> None:
        def watch() -> None:
            while True:
                time.sleep(30)
                p = self.pipeline
                if p.pipe is not None and self.busy_since is None and time.time() - p.last_used > IDLE_UNLOAD:
                    p.unload()

        if IDLE_UNLOAD > 0:
            threading.Thread(target=watch, name="idle-unload", daemon=True).start()


def _size(aspect: str | None, quality: str, image) -> tuple[int, int, str]:
    if aspect is None and image is not None:
        ratio = image.width / max(1, image.height)
        aspect = "9:16" if ratio < 0.8 else "1:1" if ratio < 1.25 else "16:9"
    aspect = aspect or "16:9"
    w, h = (SMALL_SIZES if quality == "draft" else SIZES)[aspect]
    return w, h, aspect


def _open_image(ref: str | None):
    """The image server resolves image inputs to a file in the shared outputs folder before forwarding."""
    if not ref:
        return None
    from PIL import Image

    path = Path(ref)
    if not path.is_absolute():
        path = OUTPUTS / ref
    path = path.resolve()
    if not path.is_relative_to(OUTPUTS.resolve()) or not path.is_file():
        raise ValueError(f"image not found: {ref}")
    with Image.open(path) as img:
        return img.convert("RGBA") if alpha.has_alpha(img) else img.convert("RGB")


def _read_video(rel: str):
    """Frames (PIL) and sound (tensor or None) of a video in the outputs folder. A transparent WebM gives RGBA
    frames."""
    import av
    import numpy as np
    import torch
    from PIL import Image

    path = (OUTPUTS / rel).resolve()
    if (not path.is_relative_to(OUTPUTS.resolve()) or not path.is_file()
            or path.suffix.lower() not in (".mp4", ".webm")):
        raise ValueError(f"video not found: {rel} (give an outputs path such as 2026-10-11/video-1.mp4)")
    frames, chunks, rate = [], [], None
    with av.open(str(path)) as container:
        stream = container.streams.video[0]
        if path.suffix.lower() == ".webm":  # FFmpeg's own VP9 decoder drops the alpha plane; libvpx keeps it
            ctx = av.CodecContext.create("libvpx-vp9", "r")
            decoded = (f for packet in container.demux(stream) for f in ctx.decode(packet))
        else:
            decoded = container.decode(stream)
        for frame in decoded:
            alpha = frame.format.name.startswith("yuva")
            frames.append(Image.fromarray(frame.to_ndarray(format="rgba" if alpha else "rgb24")))
    with av.open(str(path)) as container:
        if container.streams.audio:
            for frame in container.decode(audio=0):
                rate = frame.sample_rate
                chunks.append(frame.to_ndarray().astype(np.float32).reshape(frame.layout.nb_channels, -1)
                              if frame.format.is_planar else
                              frame.to_ndarray().astype(np.float32).reshape(-1, frame.layout.nb_channels).T)
    audio = torch.from_numpy(np.concatenate(chunks, axis=1)) if chunks else None
    return frames, audio, rate


def _save(frames, audio, sample_rate: int) -> tuple[str, str, bytes]:
    """Write the MP4 (H.264 + AAC) and a WebP poster. Returns (video rel path, poster rel path, small preview)."""
    from diffusers.utils import encode_video

    day = datetime.now().strftime("%Y-%m-%d")
    stem = f"video-{datetime.now().strftime('%H%M%S')}-{secrets.token_hex(4)}"
    (OUTPUTS / day).mkdir(parents=True, exist_ok=True)
    (OUTPUTS / POSTERS / day).mkdir(parents=True, exist_ok=True)
    rel = f"{day}/{stem}.mp4"
    tmp = OUTPUTS / day / f".{stem}.part.mp4"  # hidden until complete; the .mp4 ending sets the container format
    encode_video(frames, fps=FPS, output_path=str(tmp),
                 **({"audio": audio[None], "audio_sample_rate": sample_rate} if audio is not None else {}))
    tmp.replace(OUTPUTS / rel)
    poster = frames[len(frames) // 2].copy()
    poster_rel = f"{POSTERS}/{day}/{stem}.webp"
    poster.save(OUTPUTS / poster_rel, "WEBP", quality=88)
    preview = poster.copy()
    preview.thumbnail((512, 512))
    buf = io.BytesIO()
    preview.save(buf, "WEBP", quality=80)
    return rel, poster_rel, buf.getvalue()


def _write_gif(frames, width: int = GIF_WIDTH, fps: int = GIF_FPS, stem: str | None = None) -> tuple[str, int]:
    """An animated GIF of the frames: every n-th frame for the frame rate, scaled down, one shared 255-colour palette
    (steadier colours than a palette per frame). Returns (outputs path, bytes)."""
    from PIL import Image

    step = max(1, round(FPS / max(1, fps)))
    picked = frames[::step]
    w = min(width, picked[0].width)
    h = max(2, round(picked[0].height * w / picked[0].width / 2) * 2)
    if picked[0].mode == "RGBA":  # transparent: GIF shows a pixel fully or not at all
        small = [f.resize((w, h), Image.LANCZOS) for f in picked]
        frames_p, index = alpha.gif_frames(small)
        return _save_gif(frames_p, step, stem, transparency=index)
    small = [f.convert("RGB").resize((w, h), Image.LANCZOS) for f in picked]
    sample_frames = small[:: max(1, len(small) // 8)][:8]
    sample = Image.new("RGB", (w, h * len(sample_frames)))
    for i, f in enumerate(sample_frames):
        sample.paste(f, (0, i * h))
    palette = sample.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
    frames_p = [f.quantize(palette=palette, dither=Image.Dither.FLOYDSTEINBERG) for f in small]
    return _save_gif(frames_p, step, stem)


def _save_gif(frames_p, step: int, stem: str | None, transparency: int | None = None) -> tuple[str, int]:
    day = datetime.now().strftime("%Y-%m-%d")
    stem = stem or f"{datetime.now().strftime('%H%M%S')}-{secrets.token_hex(4)}"
    (OUTPUTS / day).mkdir(parents=True, exist_ok=True)
    rel = f"{day}/gif-{stem}.gif"
    tmp = OUTPUTS / day / f".gif-{stem}.gif.part"
    extra = {"transparency": transparency, "disposal": 2} if transparency is not None else {"disposal": 1}
    frames_p[0].save(tmp, format="GIF", save_all=True, append_images=frames_p[1:], loop=0,
                     duration=round(1000 * step / FPS), optimize=False, **extra)
    tmp.replace(OUTPUTS / rel)
    return rel, (OUTPUTS / rel).stat().st_size


def _add_gif(reply: CallToolResult, frames, rel: str) -> CallToolResult:
    """Make the GIF of a finished video and add its link to the reply."""
    stem = Path(rel).stem.removeprefix("video-")
    gif_rel, size = _write_gif(frames, stem=stem)
    reply.content[0].text += (f"\nGIF ({GIF_WIDTH} px, {GIF_FPS} fps, no sound, {size / 1e6:.1f} MB): "
                              f"{{base_url}}/outputs/{gif_rel}")
    reply.structured_content.update(gif=gif_rel, gif_url=f"{{base_url}}/outputs/{gif_rel}", gif_bytes=size)
    return reply


def _save_transparent(frames, audio, sample_rate: int) -> tuple[str, str, bytes, str]:
    """WebM (VP9 with alpha, Opus sound), a small transparent animated WebP and an RGBA poster."""
    day = datetime.now().strftime("%Y-%m-%d")
    stem = f"{datetime.now().strftime('%H%M%S')}-{secrets.token_hex(4)}"
    (OUTPUTS / day).mkdir(parents=True, exist_ok=True)
    (OUTPUTS / POSTERS / day).mkdir(parents=True, exist_ok=True)
    rel = f"{day}/video-{stem}.webm"
    tmp = OUTPUTS / day / f".video-{stem}.part.webm"
    alpha.write_webm(frames, str(tmp), FPS, audio, sample_rate)
    tmp.replace(OUTPUTS / rel)
    anim = f"{day}/anim-{stem}.webp"
    tmp = OUTPUTS / day / f".anim-{stem}.part.webp"
    alpha.write_webp(frames, str(tmp), FPS)
    tmp.replace(OUTPUTS / anim)
    poster = frames[len(frames) // 2].copy()
    poster_rel = f"{POSTERS}/{day}/video-{stem}.webp"
    poster.save(OUTPUTS / poster_rel, "WEBP", quality=88)
    preview = poster.copy()
    preview.thumbnail((512, 512))
    buf = io.BytesIO()
    preview.save(buf, "WEBP", quality=80)
    return rel, poster_rel, buf.getvalue(), anim


def _reply(rel: str, poster_rel: str, preview: bytes, info: dict) -> CallToolResult:
    import base64

    seconds = info["seconds"]
    text = (f"Saved {info['width']}x{info['height']} {seconds:.1f} s MP4{' with sound' if info['sound'] else ''}: "
            f"{{base_url}}/outputs/{rel}\nPoster: {{base_url}}/outputs/{poster_rel}\n"
            f"Rendered in {info['render_seconds']:.0f} s. Show the user the video link.")
    return CallToolResult(
        content=[TextContent(type="text", text=text),
                 ImageContent(type="image", data=base64.b64encode(preview).decode(), mimeType="image/webp")],
        structured_content={"file": rel, "poster": poster_rel, "url": f"{{base_url}}/outputs/{rel}", **info})


def create_server(renderer: Renderer) -> MCPServer:
    mcp = MCPServer(name="imagegen-kandinsky6", title="Kandinsky 6 video", version="1.0")

    async def run(ctx: Context, work, label: str) -> CallToolResult:
        """Render in a worker thread (the event loop stays free), report progress, stop at the next step when the
        caller goes away."""
        loop = asyncio.get_running_loop()
        stop = threading.Event()

        def progress(frac: float, message: str) -> None:
            loop.call_soon_threadsafe(asyncio.ensure_future, ctx.report_progress(frac, 1.0, message))

        async with renderer.lock:
            renderer.busy_since = time.time()
            log.info("render start: %s", label)
            try:
                return await asyncio.to_thread(work, progress, stop.is_set)
            except Cancelled:
                return CallToolResult(content=[TextContent(type="text", text="Cancelled.")], is_error=True)
            except asyncio.CancelledError:
                stop.set()  # the worker thread stops at its next step
                raise
            finally:
                renderer.busy_since = None
                log.info("render end: %s", label)

    @mcp.tool(description=GUIDE["generate"], annotations=ToolAnnotations(
        title="Generate video", readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False))
    async def generate_video(
        prompt: Annotated[str, Field(description="What happens, then 'Audio: ...'.")],
        ctx: Context,
        image: ImageRef = None,
        seconds: Seconds = 5,
        next_prompts: Annotated[list[str] | None, Field(
            description="For 10-20 s: what happens in each next 5 s part.")] = None,
        aspect_ratio: Aspect = None,
        quality: Quality = "standard",
        sound: bool = True,
        seed: Annotated[int | None, Field(description="Omit for a new video.")] = None,
        gif: Gif = False,
        transparent: Transparent = False,
        count: Count = 1,  # the image server makes the variations (each its own GPU turn); one video here
    ) -> CallToolResult:
        segments = max(1, min(MAX_SEGMENTS, seconds // 5))
        prompts = [prompt] + [(next_prompts or [])[i] if i < len(next_prompts or []) else prompt
                              for i in range(segments - 1)]
        source = _open_image(image)
        width, height, aspect = _size(aspect_ratio, quality, source)
        seed = seed if seed is not None else secrets.randbelow(2**31)
        key = alpha.choose_key(source) if transparent else None
        extra = alpha.KEEP_BACKGROUND.format(name=key) if transparent else ""
        prompts = [compose(p, sound, extra) for p in prompts]
        if transparent:
            if source is not None:
                source = alpha.fit(source, width, height)  # no crop: the cut-out keeps its whole shape
            first = alpha.flatten(source, key) if source is not None else None
        else:
            first = source.convert("RGB") if source is not None else None

        def work(progress, cancelled):
            start = time.perf_counter()
            clip = renderer.pipeline.render(prompts, width=width, height=height, seed=seed, image=first,
                                            sound=sound, progress=progress, cancelled=cancelled)
            if transparent:
                progress(1.0, "removing the background")
                frames = alpha.key_frames(clip.frames, key, source=source)
                rel, poster, preview, anim = _save_transparent(frames, clip.audio, clip.sample_rate)
                info = {"prompt": prompt, "seconds": round(len(frames) / FPS, 2), "width": width, "height": height,
                        "aspect_ratio": aspect, "quality": quality, "fps": FPS, "seed": seed, "sound": sound,
                        "segments": len(prompts), "render_seconds": round(time.perf_counter() - start, 1),
                        "segment_seconds": clip.segments, "mode": renderer.pipeline.mode, "image": image or "",
                        "transparent": True, "key": key}
                reply = _reply(rel, poster, preview, info)
                reply.content[0].text = reply.content[0].text.replace(
                    " MP4", " transparent WebM (VP9 with alpha)", 1) + (
                    f"\nTransparent animated WebP (480 px, 12 fps): {{base_url}}/outputs/{anim}\n"
                    "MP4 cannot be transparent. The WebM plays transparent in Chrome, Edge and Firefox (not Safari).")
                reply.structured_content.update(anim=anim, anim_url=f"{{base_url}}/outputs/{anim}")
                return _add_gif(reply, frames, rel) if gif else reply
            rel, poster, preview = _save(clip.frames, clip.audio, clip.sample_rate)
            info = {"prompt": prompt, "seconds": round(len(clip.frames) / FPS, 2), "width": width, "height": height,
                    "aspect_ratio": aspect, "quality": quality, "fps": FPS, "seed": seed, "sound": sound,
                    "segments": len(prompts), "render_seconds": round(time.perf_counter() - start, 1),
                    "segment_seconds": clip.segments, "mode": renderer.pipeline.mode,
                    "image": image or ""}
            reply = _reply(rel, poster, preview, info)
            return _add_gif(reply, clip.frames, rel) if gif else reply

        return await run(ctx, work, f"{seconds} s {width}x{height}{' from an image' if first else ''}")

    @mcp.tool(description=GUIDE["extend"], annotations=ToolAnnotations(
        title="Extend video", readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False))
    async def extend_video(
        video: Annotated[str, Field(description="Outputs path or URL.")],
        prompt: Annotated[str, Field(description="What happens next (repeat the subject), then 'Audio: ...'.")],
        ctx: Context,
        seconds: Annotated[Literal[5, 10, 15], Field(description="How much to add.")] = 5,
        sound: bool = True,
        seed: int | None = None,
        gif: Gif = False,
    ) -> CallToolResult:
        rel_in = video.split("/outputs/", 1)[-1]
        frames, audio, rate = await asyncio.to_thread(_read_video, rel_in)
        if not frames:
            raise ValueError("the video has no frames")
        if frames[0].mode == "RGBA":
            raise ValueError("extend_video does not support transparent videos yet: make a new one with "
                             "generate_video (transparent: true) and seconds 10-20")
        width, height = frames[0].width, frames[0].height
        segments = max(1, min(3, seconds // 5))
        seed = seed if seed is not None else secrets.randbelow(2**31)

        def work(progress, cancelled):
            import torch

            start = time.perf_counter()
            clip = renderer.pipeline.render([compose(prompt, sound)] * segments, width=width, height=height,
                                            seed=seed, image=frames[-1], sound=sound, progress=progress,
                                            cancelled=cancelled)
            # The new part starts on the old video's last frame: drop that repeat.
            new_frames = clip.frames[1:]
            new_audio = clip.audio
            if new_audio is not None:
                new_audio = new_audio[..., int(round(clip.sample_rate / FPS)):]
            if audio is not None and new_audio is not None and rate == clip.sample_rate:
                channels = new_audio.shape[0]
                old = audio if audio.shape[0] == channels else audio.mean(0, keepdim=True).expand(channels, -1)
                joined = torch.cat([old.to(new_audio.dtype), new_audio], dim=-1)
            else:
                joined = new_audio if audio is None else None  # keep it simple: no sound if formats differ
            rel, poster, preview = _save(frames + new_frames, joined, clip.sample_rate)
            info = {"prompt": prompt, "extends": rel_in, "seconds": round((len(frames) + len(new_frames)) / FPS, 2),
                    "width": width, "height": height, "fps": FPS, "seed": seed, "sound": joined is not None,
                    "segments": segments, "render_seconds": round(time.perf_counter() - start, 1),
                    "segment_seconds": clip.segments, "mode": renderer.pipeline.mode}
            reply = _reply(rel, poster, preview, info)
            return _add_gif(reply, frames + new_frames, rel) if gif else reply

        return await run(ctx, work, f"extend {rel_in} by {seconds} s")

    # CPU only: the image server does not give it a GPU turn ("imagegen/gpu": false), and it does not wait for a render.
    @mcp.tool(description=GUIDE["gif"], meta={"imagegen/gpu": False}, annotations=ToolAnnotations(
        title="Video to GIF", readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=False))
    async def video_to_gif(
        video: Annotated[str, Field(description="Outputs path or URL.")],
        width: Annotated[int, Field(ge=160, le=864)] = GIF_WIDTH,
        fps: Annotated[int, Field(ge=4, le=24)] = GIF_FPS,
        start: Annotated[float, Field(ge=0, description="Start second.")] = 0,
        seconds: Annotated[float | None, Field(gt=0, description="Default: to the end.")] = None,
    ) -> CallToolResult:
        rel_in = video.split("/outputs/", 1)[-1]

        def work():
            frames, _, _ = _read_video(rel_in)
            first = int(start * FPS)
            last = len(frames) if seconds is None else min(len(frames), first + int(seconds * FPS))
            clip = frames[first:last]
            if not clip:
                raise ValueError(f"no frames from {start} s on (the video is {len(frames) / FPS:.1f} s long)")
            rel, size = _write_gif(clip, width, fps)
            return rel, size, len(clip[:: max(1, round(FPS / fps))]), clip[0].width, clip[0].height

        rel, size, n, w0, h0 = await asyncio.to_thread(work)
        w = min(width, w0)
        h = max(2, round(h0 * w / w0 / 2) * 2)
        rate = round(FPS / max(1, round(FPS / fps)))
        text = (f"Saved GIF {w}x{h}, {n} frames at {rate} fps, {size / 1e6:.1f} MB, no sound: "
                f"{{base_url}}/outputs/{rel}")
        return CallToolResult(content=[TextContent(type="text", text=text)],
                              structured_content={"file": rel, "url": f"{{base_url}}/outputs/{rel}", "bytes": size,
                                                  "width": w, "height": h, "frames": n, "video": rel_in})

    @mcp.custom_route("/health", methods=["GET"], include_in_schema=False)
    async def health(request: Request) -> JSONResponse:
        p = renderer.pipeline
        return JSONResponse({"status": "ready", "mode": p.mode, "loaded": p.pipe is not None,
                             "busy_seconds": round(time.time() - renderer.busy_since) if renderer.busy_since else None,
                             "segment_frames": SEGMENT_FRAMES, "fps": FPS})

    return mcp


def serve() -> None:
    import uvicorn

    renderer = Renderer()
    renderer.start_idle_watch()
    app = create_server(renderer).streamable_http_app(
        streamable_http_path="/mcp", stateless_http=True, json_response=False,
        # Reached only by the image server over the private extension network (no published port).
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False), host="0.0.0.0")
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("VIDEO_PORT", "5010")), log_level="info")
