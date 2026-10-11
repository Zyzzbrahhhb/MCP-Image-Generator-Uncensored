"""Extensions: the manifest and the setup's settings, max_jobs, tools offered on this server, forwarded calls run as
jobs (with image inputs resolved here and {base_url} rewritten), the shared GPU queue, and videos in the gallery."""

import asyncio
import json
from types import SimpleNamespace

from mcp.types import CallToolResult, TextContent
from PIL import Image
from starlette.testclient import TestClient

from imagegen_mcp import extensions as ext_mod
from imagegen_mcp.config import Config
from imagegen_mcp.library import Library, poster_of, servable
from imagegen_mcp.sdserver import GpuQueue
from imagegen_mcp.server import build_app, create_server
from test_server import StubService

TOOL = {"name": "generate_video", "description": "Make a video.",
        "inputSchema": {"type": "object", "required": ["prompt"],
                        "properties": {"prompt": {"type": "string"},
                                       "image": {"type": "string", "x-imagegen-input": "image"},
                                       "seconds": {"type": "integer"}}}}


def _install(tmp_path, env="SHARES_IMAGE_GPU=yes\nGPU_GB=12\n", tools=(TOOL,)):
    folder = tmp_path / "ext" / "kandinsky6"
    folder.mkdir(parents=True)
    (folder / "extension.yaml").write_text("name: kandinsky6\ntitle: Kandinsky 6 video\nurl: http://imagegen-kandinsky6:5010/mcp\n"
                                           "kind: video\nestimate_seconds: 150\n", encoding="utf-8")
    (folder / ".env").write_text(env, encoding="utf-8")
    cache = tmp_path / "out" / ".extensions"
    cache.mkdir(parents=True)
    (cache / "kandinsky6.tools.json").write_text(json.dumps(list(tools)), encoding="utf-8")


def _cfg(tmp_path, **extensions):
    return Config.model_validate({"outputs_dir": str(tmp_path / "out"), "models_dir": str(tmp_path / "m"),
                                  "generation": {"wait_seconds": 5},
                                  "extensions": {"enabled": ["kandinsky6"], "dir": str(tmp_path / "ext"), **extensions}})


def test_manifest_and_setup_settings(tmp_path):
    _install(tmp_path)
    [ext] = ext_mod.load(_cfg(tmp_path))
    assert (ext.name, ext.url, ext.kind, ext.estimate_seconds) == ("kandinsky6", "http://imagegen-kandinsky6:5010/mcp", "video",
                                                                    150.0)
    assert ext.shares_image_gpu is True and ext.gpu_gb == 12.0


def test_missing_extension_folder_is_skipped(tmp_path):
    assert ext_mod.load(_cfg(tmp_path)) == []


def test_max_jobs_auto_follows_the_shared_card(tmp_path):
    cases = [("SHARES_IMAGE_GPU=yes\nGPU_GB=12\n", 1), ("SHARES_IMAGE_GPU=yes\nGPU_GB=8\n", 1),
             ("SHARES_IMAGE_GPU=yes\nGPU_GB=24\n", 2), ("SHARES_IMAGE_GPU=no\nGPU_GB=10\n", 2)]
    for i, (env, want) in enumerate(cases):
        root = tmp_path / str(i)
        _install(root, env=env)
        cfg = _cfg(root)
        assert ext_mod.max_jobs(cfg, ext_mod.load(cfg)) == want, env
    root = tmp_path / "fixed"
    _install(root)
    cfg = _cfg(root, max_jobs=2)
    assert ext_mod.max_jobs(cfg, ext_mod.load(cfg)) == 2


def _svc(tmp_path, **extensions):
    cfg = _cfg(tmp_path, **extensions)
    svc = StubService(cfg, tmp_path / "out")
    svc.outputs = tmp_path / "out"
    return svc


async def test_tools_are_offered_from_the_last_known_list(tmp_path):
    _install(tmp_path)
    mcp = create_server(_svc(tmp_path))
    names = {t.name for t in await mcp.list_tools()}
    assert "generate_video" in names and "generate_image" in names
    spec = next(t for t in await mcp.list_tools() if t.name == "generate_video")
    assert spec.input_schema["properties"]["image"]["x-imagegen-input"] == "image"
    # Clients check replies against an output schema; a pending reply has none of the result's fields.
    assert spec.output_schema is None


async def test_an_extension_cannot_replace_a_builtin_tool(tmp_path):
    _install(tmp_path, tools=({**TOOL, "name": "generate_image", "description": "evil"},))
    mcp = create_server(_svc(tmp_path))
    spec = next(t for t in await mcp.list_tools() if t.name == "generate_image")
    assert spec.description != "evil"


async def test_calls_run_as_jobs_with_inputs_resolved_and_urls_rewritten(tmp_path, monkeypatch):
    _install(tmp_path, env="SHARES_IMAGE_GPU=no\nGPU_GB=32\n")
    svc = _svc(tmp_path)
    src = tmp_path / "in.png"
    Image.new("RGB", (32, 16), (10, 200, 10)).save(src)
    svc.loader = SimpleNamespace(load=lambda ref: asyncio.sleep(0, result=Image.open(src)))
    svc.base_url = lambda: "http://pc:5005/"
    seen = {}

    async def fake_call(self, tool, arguments, on_progress):
        seen["tool"], seen["args"] = tool, dict(arguments)
        seen["input_exists"] = (tmp_path / "out" / arguments["image"]).is_file()
        await on_progress(0.5, "step 5/10")
        return CallToolResult(content=[TextContent(type="text", text="Saved: {base_url}/outputs/d/video-1.mp4")],
                              structured_content={"file": "d/video-1.mp4", "url": "{base_url}/outputs/d/video-1.mp4",
                                                  "seconds": 5.04, "prompt": "a fox"})

    monkeypatch.setattr(ext_mod.Client, "call", fake_call)
    mcp = create_server(svc)
    r = await mcp.call_tool("generate_video", {"prompt": "a fox", "image": "https://example.com/x.png"})
    sc = r.structured_content
    assert sc["status"] == "completed" and sc["url"] == "http://pc:5005/outputs/d/video-1.mp4"
    assert "http://pc:5005/outputs/d/video-1.mp4" in r.content[0].text
    assert seen["tool"] == "generate_video" and seen["args"]["image"].startswith(".ext-inputs/")
    assert seen["input_exists"] is True
    assert not any((tmp_path / "out" / ".ext-inputs").iterdir())  # handed-over inputs are removed afterwards
    meta = (tmp_path / "out" / ".meta.jsonl").read_text(encoding="utf-8")
    assert '"file": "d/video-1.mp4"' in meta and '"tool": "generate_video"' in meta and "a fox" in meta


async def test_errors_from_the_extension_fail_the_job(tmp_path, monkeypatch):
    _install(tmp_path, env="SHARES_IMAGE_GPU=no\n")

    async def fake_call(self, tool, arguments, on_progress):
        return CallToolResult(content=[TextContent(type="text", text="image not found: x")], is_error=True)

    monkeypatch.setattr(ext_mod.Client, "call", fake_call)
    mcp = create_server(_svc(tmp_path))
    r = await mcp.call_tool("generate_video", {"prompt": "a fox"})
    assert r.is_error and "image not found" in r.content[0].text


async def test_one_job_at_a_time_shares_the_gpu_queue(tmp_path, monkeypatch):
    _install(tmp_path)  # shares a 12 GB card: max_jobs 1
    svc = _svc(tmp_path)
    svc.engine = SimpleNamespace(queue=GpuQueue())
    order = []

    async def fake_call(self, tool, arguments, on_progress):
        order.append("video start")
        await asyncio.sleep(0.2)
        order.append("video end")
        return CallToolResult(content=[TextContent(type="text", text="ok")], structured_content={})

    monkeypatch.setattr(ext_mod.Client, "call", fake_call)
    mcp = create_server(svc)
    assert svc.extensions.max_jobs == 1

    async def image_job():
        async with svc.engine.queue.turn("generate", 1.0):
            order.append("image start")
            await asyncio.sleep(0.3)
            order.append("image end")

    image = asyncio.ensure_future(image_job())
    await asyncio.sleep(0.05)
    await mcp.call_tool("generate_video", {"prompt": "x"})
    await image
    assert order == ["image start", "image end", "video start", "video end"]


async def test_variations_are_separate_gpu_turns_with_the_next_seeds(tmp_path, monkeypatch):
    counted = {**TOOL, "inputSchema": {**TOOL["inputSchema"], "properties": {
        **TOOL["inputSchema"]["properties"], "seed": {"type": "integer"},
        "count": {"type": "integer", "maximum": 4, "x-imagegen-repeat": "seed"}}}}
    _install(tmp_path, tools=(counted,))  # shares a 12 GB card: max_jobs 1
    svc = _svc(tmp_path)
    svc.engine = SimpleNamespace(queue=GpuQueue())
    order, seeds = [], []

    async def fake_call(self, tool, arguments, on_progress):
        seeds.append((arguments["seed"], arguments["count"]))
        order.append(f"video {len(seeds)}")
        await asyncio.sleep(0.15)
        if len(seeds) == 1:  # an image request arrives while the first variation renders
            asyncio.ensure_future(image_job())
            await asyncio.sleep(0.05)
        n = len(seeds)
        return CallToolResult(content=[TextContent(type="text", text=f"Saved: {{base_url}}/outputs/d/video-{n}.mp4")],
                              structured_content={"file": f"d/video-{n}.mp4", "seed": arguments["seed"]})

    async def image_job():
        async with svc.engine.queue.turn("generate", 1.0):
            order.append("image")
            await asyncio.sleep(0.05)

    monkeypatch.setattr(ext_mod.Client, "call", fake_call)
    mcp = create_server(svc)
    r = await mcp.call_tool("generate_video", {"prompt": "x", "seed": 100, "count": 3})
    sc = r.structured_content
    assert seeds == [(100, 1), (101, 1), (102, 1)]
    assert order == ["video 1", "image", "video 2", "video 3"]  # the image ran between two variations
    assert sc["status"] == "completed" and sc["count"] == 3
    assert sc["files"] == ["d/video-1.mp4", "d/video-2.mp4", "d/video-3.mp4"]
    text = " ".join(c.text for c in r.content if c.type == "text")
    assert "Variation 3 of 3 (seed 102)" in text
    meta = [json.loads(line) for line in (tmp_path / "out" / ".meta.jsonl").read_text(encoding="utf-8").splitlines()]
    assert [(m["file"], m["info"]["seed"]) for m in meta] == [("d/video-1.mp4", 100), ("d/video-2.mp4", 101),
                                                              ("d/video-3.mp4", 102)]


async def test_cpu_only_tools_do_not_wait_for_the_gpu(tmp_path, monkeypatch):
    gif = {"name": "video_to_gif", "description": "GIF.", "_meta": {"imagegen/gpu": False},
           "inputSchema": {"type": "object", "properties": {"video": {"type": "string"}}}}
    _install(tmp_path, tools=(TOOL, gif))  # shares a 12 GB card: max_jobs 1
    svc = _svc(tmp_path)
    svc.engine = SimpleNamespace(queue=GpuQueue())

    async def fake_call(self, tool, arguments, on_progress):
        return CallToolResult(content=[TextContent(type="text", text="ok")], structured_content={"file": "d/gif-1.gif"})

    monkeypatch.setattr(ext_mod.Client, "call", fake_call)
    mcp = create_server(svc)

    async def busy_gpu():
        async with svc.engine.queue.turn("generate", 60.0):
            await asyncio.sleep(2)

    busy = asyncio.ensure_future(busy_gpu())
    await asyncio.sleep(0.05)
    start = asyncio.get_running_loop().time()
    r = await mcp.call_tool("video_to_gif", {"video": "d/video-1.mp4"})
    assert r.structured_content["status"] == "completed"
    assert asyncio.get_running_loop().time() - start < 1.0  # did not wait for the image job's GPU turn
    busy.cancel()


async def test_status_lists_the_extensions(tmp_path):
    _install(tmp_path)
    mcp = create_server(_svc(tmp_path))
    r = await mcp.call_tool("server_status", {})
    st = r.structured_content or json.loads(r.content[0].text)
    st = st.get("result", st)
    assert st["max_jobs"] == 1 and st["extensions"][0]["name"] == "kandinsky6"


def test_videos_and_posters_in_the_gallery(tmp_path):
    out = tmp_path / "out"
    video = "2026-01-02/video-120000-abcd1234.mp4"
    (out / "2026-01-02").mkdir(parents=True)
    (out / video).write_bytes(b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 64)
    (out / poster_of(video)).parent.mkdir(parents=True)
    Image.new("RGB", (864, 480), (0, 0, 200)).save(out / poster_of(video), "WEBP")
    lib = Library(out)
    [item] = [i for i in lib.items() if i["file"] == video]
    assert item["kind"] == "video" and item["video"] is True and (item["width"], item["height"]) == (864, 480)
    assert lib.thumbnail(video, 256) is not None
    assert servable(poster_of(video)) and not servable(".posters/../x.webp")
    lib.trash([video])
    assert (out / poster_of(video)).is_file()  # the trash keeps the poster for its thumbnail
    lib.purge([video])
    assert not (out / poster_of(video)).exists()


def test_transparent_videos_in_the_gallery(tmp_path):
    """A transparent video: a WebM with an RGBA poster, plus a transparent animated WebP."""
    out = tmp_path / "out"
    video, anim = "2026-01-02/video-120000-abcd1234.webm", "2026-01-02/anim-120000-abcd1234.webp"
    (out / "2026-01-02").mkdir(parents=True)
    (out / video).write_bytes(bytes.fromhex("1a45dfa3") + bytes(64))
    frames = [Image.new("RGBA", (64, 64), (200, 0, 0, a)) for a in (0, 255)]
    frames[0].save(out / anim, "WEBP", save_all=True, append_images=frames[1:], duration=80, loop=0)
    (out / poster_of(video)).parent.mkdir(parents=True)
    Image.new("RGBA", (640, 640), (0, 0, 0, 0)).save(out / poster_of(video), "WEBP")
    lib = Library(out)
    items = {i["file"]: i for i in lib.items()}
    assert items[video]["kind"] == "video" and items[video]["video"] is True
    assert items[anim]["kind"] == "anim" and not items[anim].get("video")
    assert lib.thumbnail(video, 256) is not None and lib.thumbnail(anim, 256) is not None


def test_video_files_are_served_with_ranges(tmp_path):
    _install(tmp_path)
    out = tmp_path / "out"
    (out / "d").mkdir(parents=True)
    (out / "d" / "video-1.mp4").write_bytes(bytes(range(256)) * 8)
    cfg = _cfg(tmp_path)
    svc = StubService(cfg, out)
    svc.outputs = out
    _, app = build_app(svc)
    with TestClient(app) as c:
        r = c.get("/outputs/d/video-1.mp4", headers={"Range": "bytes=0-99"})
        assert r.status_code == 206 and len(r.content) == 100 and r.headers["content-type"] == "video/mp4"
        (out / "d" / "video-2.webm").write_bytes(bytes(range(256)) * 8)
        r = c.get("/outputs/d/video-2.webm", headers={"Range": "bytes=0-99"})
        assert r.status_code == 206 and r.headers["content-type"] == "video/webm"
