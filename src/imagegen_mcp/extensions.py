"""Optional extensions: separate containers (folders in extensions/) whose MCP tools this server offers on its own
address. The setup installs an extension and lists it under extensions.enabled in config.yaml.

Each call to an extension tool runs as a job here (get_job and cancel_job work as for images). Image inputs are
resolved here (URLs, uploads, data URIs) into files in the shared outputs folder, and "{base_url}" in the
extension's reply becomes this server's public address. When max_jobs is 1, an extension job takes its turn in the
same GPU queue as the image jobs, so the two never run at once.

Marks an extension can put in its tool list: an input property with "x-imagegen-input": "image" is resolved here;
a tool with _meta {"imagegen/gpu": false} runs on the CPU and never waits for the GPU; a "count" property with
"x-imagegen-repeat": "seed" makes that many calls here, one after another with the next seed, each in its own GPU
turn.
"""

from __future__ import annotations

import asyncio
import copy
import json
import logging
import secrets
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable

import yaml
from mcp.types import CallToolResult, TextContent

log = logging.getLogger("imagegen.extensions")

INPUTS = ".ext-inputs"     # hidden folder in outputs/: images handed to an extension, deleted after the job
CACHE = ".extensions"      # hidden folder in outputs/: each extension's last tool list
SHARED_CARD_GB = 12        # max_jobs auto: one job at a time when an extension shares a card this small or smaller
CALL_TIMEOUT = 4 * 3600    # a 20 s video on a slow card takes well under an hour; this only stops a stuck call


@dataclass
class Extension:
    name: str
    title: str
    url: str
    health: str = ""
    kind: str = "extension"
    estimate_seconds: float = 120.0
    shares_image_gpu: bool = False
    gpu_gb: float | None = None
    tools: list[dict] = field(default_factory=list)  # MCP tool definitions (name, description, inputSchema, ...)
    online: bool = False
    error: str = ""


@dataclass
class ExtResult:
    """A finished extension call: the reply for the client, plus what the gallery records."""
    reply: CallToolResult
    images: list = field(default_factory=list)  # [SimpleNamespace(filename=...)] for Library.record
    info: dict = field(default_factory=dict)


def _env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                values[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def load(cfg) -> list[Extension]:
    """The enabled extensions, from extensions/<name>/extension.yaml and the setup's extensions/<name>/.env."""
    out = []
    for name in cfg.extensions.enabled:
        folder = Path(cfg.extensions.dir) / name
        try:
            manifest = yaml.safe_load((folder / "extension.yaml").read_text(encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError) as exc:
            log.warning("extension %s is enabled but %s/extension.yaml cannot be read (%s); skipped", name, folder, exc)
            continue
        env = _env(folder / ".env")
        try:
            gb = float(env["GPU_GB"]) if env.get("GPU_GB") else None
        except ValueError:
            gb = None
        ext = Extension(name=name, title=str(manifest.get("title") or name), url=str(manifest.get("url", "")),
                        health=str(manifest.get("health", "")), kind=str(manifest.get("kind") or name),
                        estimate_seconds=float(manifest.get("estimate_seconds") or 120),
                        shares_image_gpu=env.get("SHARES_IMAGE_GPU", "").lower() in ("yes", "true", "1"),
                        gpu_gb=gb)
        if not ext.url:
            log.warning("extension %s has no url in extension.yaml; skipped", name)
            continue
        out.append(ext)
    return out


def max_jobs(cfg, extensions: list[Extension]) -> int:
    """GPU jobs that may run at once, images and extensions together."""
    if cfg.extensions.max_jobs != "auto":
        return int(cfg.extensions.max_jobs)
    for ext in extensions:
        if ext.shares_image_gpu and (ext.gpu_gb is None or ext.gpu_gb <= SHARED_CARD_GB):
            return 1
    return 2


def _image_fields(schema: dict) -> list[str]:
    """Arguments the extension marks as image inputs: this server loads them (any URL, upload or data URI)."""
    props = (schema or {}).get("properties") or {}
    return [k for k, v in props.items() if isinstance(v, dict) and v.get("x-imagegen-input") == "image"]


def _rewrite(value: Any, base: str) -> Any:
    if isinstance(value, str):
        return value.replace("{base_url}", base)
    if isinstance(value, list):
        return [_rewrite(v, base) for v in value]
    if isinstance(value, dict):
        return {k: _rewrite(v, base) for k, v in value.items()}
    return value


class Client:
    """Talks MCP (streamable HTTP) to one extension. A session per call keeps restarts of either side harmless."""

    def __init__(self, ext: Extension):
        self.ext = ext

    async def list_tools(self) -> list[dict]:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamable_http_client

        async with streamable_http_client(self.ext.url) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                listed = await session.list_tools()
        tools = getattr(listed, "tools", listed)
        return [t.model_dump(by_alias=True, exclude_none=True) for t in tools]

    async def call(self, tool: str, arguments: dict, on_progress: Callable | None) -> CallToolResult:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamable_http_client

        async def progress(value: float, total: float | None, message: str | None) -> None:
            if on_progress is not None:
                await on_progress(value / total if total else value, message or "")

        async with streamable_http_client(self.ext.url) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                return await session.call_tool(tool, arguments, read_timeout_seconds=CALL_TIMEOUT,
                                               progress_callback=progress)


class Extensions:
    """The enabled extensions, their tools, and the calls into them."""

    def __init__(self, cfg, service):
        self.cfg, self.service = cfg, service
        self.items = load(cfg)
        self.max_jobs = max_jobs(cfg, self.items)
        self.clients = {e.name: Client(e) for e in self.items}
        for ext in self.items:
            ext.tools = self._cached_tools(ext)

    # ------------------------------------------------------------------ tool lists
    def _cache_file(self, ext: Extension) -> Path:
        return Path(self.cfg.outputs_dir) / CACHE / f"{ext.name}.tools.json"

    def _cached_tools(self, ext: Extension) -> list[dict]:
        try:
            tools = json.loads(self._cache_file(ext).read_text(encoding="utf-8"))
            return tools if isinstance(tools, list) else []
        except (OSError, ValueError):
            return []

    async def refresh(self, ext: Extension) -> bool:
        """Ask the extension for its tools; remember them so they are offered even while it is starting."""
        try:
            tools = await asyncio.wait_for(self.clients[ext.name].list_tools(), timeout=20)
        except Exception as exc:  # noqa: BLE001 - offline or starting: keep the cached list
            ext.online, ext.error = False, f"{type(exc).__name__}: {exc}"[:300]
            return False
        ext.online, ext.error, ext.tools = True, "", tools
        try:
            f = self._cache_file(ext)
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(tools), encoding="utf-8")
        except OSError as exc:
            log.debug("could not cache the %s tool list: %s", ext.name, exc)
        return True

    def status(self) -> list[dict]:
        return [{"name": e.name, "title": e.title, "online": e.online, "tools": [t.get("name") for t in e.tools],
                 "shares_image_gpu": e.shares_image_gpu, "gpu_gb": e.gpu_gb, **({"error": e.error} if e.error else {})}
                for e in self.items] if self.items else []

    # ------------------------------------------------------------------ calls
    async def _resolve_inputs(self, ext: Extension, tool: dict, args: dict) -> tuple[dict, list[Path]]:
        """Load image arguments here (this server can fetch URLs; the extension has no network) and hand the
        extension a file in the shared outputs folder."""
        args = dict(args)
        made: list[Path] = []
        folder = Path(self.cfg.outputs_dir) / INPUTS
        for key in _image_fields(tool.get("inputSchema") or {}):
            ref = args.get(key)
            if not ref:
                continue
            img = await self.service.loader.load(str(ref))
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / f"{ext.name}-{secrets.token_hex(8)}.png"
            # Keep transparency: the extension decides what the transparent area becomes.
            keep = img.mode in ("RGBA", "LA", "PA") or "transparency" in img.info
            await asyncio.to_thread(img.convert("RGBA" if keep else "RGB").save, path, "PNG")
            made.append(path)
            args[key] = f"{INPUTS}/{path.name}"
        return args, made

    async def run(self, ext: Extension, tool: dict, args: dict, progress) -> ExtResult:
        """One call, or several when the tool's ``count`` option is marked {"x-imagegen-repeat": "seed"}: then each
        variation is its own call with the next seed and takes its own GPU turn, so other jobs can run in between
        on a shared GPU."""
        option = ((tool.get("inputSchema") or {}).get("properties") or {}).get("count") or {}
        count = int(args.get("count") or 1) if option.get("x-imagegen-repeat") == "seed" else 1
        count = max(1, min(count, int(option.get("maximum") or 4)))
        if count == 1:
            return await self._run_once(ext, tool, args, progress)
        seed = args.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2**31 - 16)
        results: list[ExtResult] = []
        for i in range(count):
            async def part(value: float, message: str, i=i) -> None:
                await progress((i + value) / count, f"variation {i + 1} of {count}: {message}")

            try:
                results.append(await self._run_once(ext, tool, {**args, "count": 1, "seed": seed + i}, part))
            except RuntimeError as exc:
                if not results:
                    raise
                note = f"Variation {i + 1} of {count} failed, so the rest were not made: {exc}"
                results[-1].reply.content.append(TextContent(type="text", text=note))
                break
        return _merge(results, count)

    async def _run_once(self, ext: Extension, tool: dict, args: dict, progress) -> ExtResult:
        name = tool["name"]
        args, made = await self._resolve_inputs(ext, tool, args)
        try:
            engine = getattr(self.service, "engine", None)
            # A tool marked {"imagegen/gpu": false} (e.g. video_to_gif) runs on the CPU: no GPU turn.
            uses_gpu = (tool.get("_meta") or tool.get("meta") or {}).get("imagegen/gpu", True) is not False
            if self.max_jobs <= 1 and uses_gpu and engine is not None and getattr(engine, "queue", None) is not None:
                async def waiting(text: str) -> None:
                    await progress(0.0, f"waiting for the GPU: {text}")

                async with engine.queue.turn(ext.kind, ext.estimate_seconds, waiting):
                    reply = await self.clients[ext.name].call(name, args, progress)
            else:
                reply = await self.clients[ext.name].call(name, args, progress)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - connection errors come from several libraries (httpx, anyio, mcp)
            detail = f"{type(exc).__name__}: {exc}".strip()[:300]
            raise RuntimeError(f"the {ext.title} extension did not answer ({detail}). It may be stopped: run the "
                               "start script again, or see its page in docs/.") from exc
        finally:
            for p in made:
                p.unlink(missing_ok=True)
        base = self.service.base_url().rstrip("/")
        reply = CallToolResult(content=_rewrite([c.model_dump(by_alias=True) for c in reply.content], base),
                               structured_content=_rewrite(copy.deepcopy(reply.structured_content), base),
                               is_error=reply.is_error)
        if reply.is_error:
            text = " ".join(getattr(c, "text", "") for c in reply.content).strip()
            raise RuntimeError(text or f"the {ext.title} extension reported an error")
        sc = reply.structured_content or {}
        files = [sc["file"]] if isinstance(sc.get("file"), str) else []
        info = {k: v for k, v in sc.items() if isinstance(v, (str, int, float, bool)) and k not in ("file", "url")}
        return ExtResult(reply=reply, images=[SimpleNamespace(filename=f, info=info) for f in files], info=info)


def _merge(results: list[ExtResult], asked: int) -> ExtResult:
    """Variations as one result: each reply in turn under a heading, and every file in the gallery."""
    content, variations, images = [], [], []
    for i, r in enumerate(results, 1):
        sc = r.reply.structured_content or {}
        content.append(TextContent(type="text", text=f"Variation {i} of {asked} (seed {sc.get('seed', '?')}):"))
        content.extend(r.reply.content)
        variations.append(sc)
        images.extend(r.images)
    sc = {**variations[0], "count": len(results), "variations": variations,
          "files": [v["file"] for v in variations if isinstance(v.get("file"), str)]}
    return ExtResult(reply=CallToolResult(content=content, structured_content=sc), images=images,
                     info=results[0].info)
