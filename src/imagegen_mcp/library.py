"""The image library behind the web page: every image under outputs/ with its folder, kind, size and the settings
that made it, small cached thumbnails, and a trash folder, so a deleted image can be restored.

Hidden paths hold the library's own files and are never listed or served as images: .trash/ (deleted images, with
their original paths), .thumbs/ (cached thumbnails) and .meta.jsonl (one line per result: its tool and settings).
The outputs cleanup removes old files from all of them by age, like any other output.
"""
from __future__ import annotations

import hashlib
import io
import json
import logging
import os
import shutil
import threading
import time
import zipfile
from pathlib import Path

from PIL import Image

from . import panorama

log = logging.getLogger("imagegen.library")

TRASH, THUMBS, META = ".trash", ".thumbs", ".meta.jsonl"
TRASH_INDEX = ".index.json"  # inside .trash: original path -> when it was deleted
IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp")
VIDEO_SUFFIXES = (".mp4", ".webm")  # from the video extension (WebM: transparent)
POSTERS = ".posters"  # a video's thumbnail: .posters/<the video's path>.webp (written by the video extension)
# The first word of a result's file name is the kind of result (see ImageService._save).
KINDS = {"image": "Generated", "edit": "Edit", "transparent": "Transparent", "tile": "Tile", "panorama": "Panorama",
         "upscaled": "Upscaled", "unwatermarked": "Watermark removed", "cutout": "Background removed",
         "vector": "SVG", "video": "Video", "gif": "GIF", "anim": "Animation", "upload": "Upload"}
THUMB_SIZES = (256, 512)
MAX_FILES_PER_REQUEST = 5000


def listed(rel: str) -> bool:
    """An image or video file outside hidden folders: what the library lists and the /outputs route serves."""
    parts = rel.replace("\\", "/").split("/")
    return (not any(p.startswith(".") or not p for p in parts)
            and Path(parts[-1]).suffix.lower() in IMAGE_SUFFIXES + VIDEO_SUFFIXES)


def is_video(rel: str) -> bool:
    return Path(rel).suffix.lower() in VIDEO_SUFFIXES


def poster_of(rel: str) -> str:
    """The poster image of a video (served, never listed)."""
    return f"{POSTERS}/{rel[: -len(Path(rel).suffix)]}.webp"


def servable(rel: str) -> bool:
    """What the /outputs route serves: listed files, plus video posters."""
    rel = rel.replace("\\", "/")
    if rel.startswith(POSTERS + "/"):
        inner = rel[len(POSTERS) + 1:]
        return listed(inner) and Path(inner).suffix.lower() == ".webp"
    return listed(rel)


def kind_of(rel: str) -> str:
    if rel.startswith("uploads/"):
        return "upload"
    first = rel.rsplit("/", 1)[-1].split("-", 1)[0].lower()
    return first if first in KINDS else "other"


class Library:
    def __init__(self, outputs: Path):
        self.root = outputs.resolve()
        self._lock = threading.Lock()
        self._headers: dict[str, tuple] = {}  # rel -> (mtime_ns, size, width, height, panorama)
        self._meta: dict[str, dict] = {}
        self._meta_stamp: tuple | None = None

    # ------------------------------------------------------------------ paths
    def path(self, rel: str, trash: bool = False) -> Path | None:
        """The file for a listed path (in the trash when trash=True), or None for anything else: hidden files,
        other file types, paths that leave outputs/."""
        if not isinstance(rel, str) or not listed(rel):
            return None
        base = self.root / TRASH if trash else self.root
        try:
            p = (base / rel).resolve()
            ok = base.resolve() in p.parents and p.is_file()
        except (OSError, ValueError, RuntimeError):
            return None
        return p if ok else None

    # ------------------------------------------------------------------ listing
    def _header(self, rel: str, p: Path, st: os.stat_result) -> tuple[int | None, int | None, bool]:
        key = (st.st_mtime_ns, st.st_size)
        hit = self._headers.get(rel)
        if hit and hit[:2] == key:
            return hit[2:]
        w = h = None
        sphere = False
        if is_video(rel.lstrip("~")):
            p = self.root / poster_of(rel.lstrip("~"))  # same size as the video
        try:
            with Image.open(p) as im:
                w, h = im.size
                sphere = panorama.is_two_to_one(w, h) and panorama.sphere_xmp(im) is not None
        except Exception:  # noqa: BLE001 - an unreadable file is listed without its size
            pass
        self._headers[rel] = (*key, w, h, sphere)
        return w, h, sphere

    def _scan(self, base: Path) -> list[dict]:
        out = []
        if not base.exists():
            return out
        for p in base.rglob("*"):
            try:
                rel = p.relative_to(base).as_posix()
                if not listed(rel) or not p.is_file():
                    continue
                st = p.stat()
            except OSError:
                continue
            w, h, sphere = self._header(("~" if base != self.root else "") + rel, p, st)
            folder = rel.rsplit("/", 1)[0] if "/" in rel else ""
            svg = p.with_suffix(".svg")
            out.append({"file": rel, "folder": folder, "name": p.name, "kind": kind_of(rel), "bytes": st.st_size,
                        "modified": int(st.st_mtime * 1000), "width": w, "height": h, "panorama": sphere,
                        "svg": rel[: -len(p.suffix)] + ".svg" if svg.is_file() else None,
                        **({"video": True,
                            "poster": poster_of(rel) if (self.root / poster_of(rel)).is_file() else None}
                           if is_video(rel) else {})})
        return out

    def items(self) -> list[dict]:
        """Every listed image, newest first, with the tool and settings that made it when they are known."""
        with self._lock:
            entries = self._scan(self.root)
            meta = self._load_meta()
        for e in entries:
            m = meta.get(e["file"])
            if m:
                e["tool"] = m.get("tool")
                e["info"] = m.get("info")
        entries.sort(key=lambda e: e["modified"], reverse=True)
        return entries

    def library(self) -> dict:
        items = self.items()
        counts: dict[str, int] = {}
        for e in items:
            if e["folder"]:
                counts[e["folder"]] = counts.get(e["folder"], 0) + 1
        # results by day, newest first, then the upload folders
        results = sorted((f for f in counts.items() if not f[0].startswith("uploads")), reverse=True)
        uploads = sorted((f for f in counts.items() if f[0].startswith("uploads")), reverse=True)
        return {"items": items, "kinds": KINDS,
                "folders": [{"path": f, "count": n} for f, n in results + uploads],
                "trash": len(self._trash_entries())}

    # ------------------------------------------------------------------ settings of each result
    def record(self, tool: str, result) -> None:
        """Remember the tool and settings of a finished result (an OpResult), for the web page's info panel and
        search. Results without saved images (a status call, a failed job) are skipped."""
        images = getattr(result, "images", None)
        if not images:
            return
        def settings(s) -> dict:  # a file's own settings if it has them (video variations), else the result's
            own = getattr(s, "info", None) if isinstance(getattr(s, "info", None), dict) else None
            return {k: v for k, v in (own or getattr(result, "info", None) or {}).items()
                    if isinstance(v, (str, int, float, bool))}

        lines = [json.dumps({"file": s.filename, "tool": tool, "info": settings(s), "time": int(time.time())},
                            ensure_ascii=False) for s in images if getattr(s, "filename", None)]
        if not lines:
            return
        with self._lock:
            try:
                with open(self.root / META, "a", encoding="utf-8") as f:
                    f.write("\n".join(lines) + "\n")
            except OSError as exc:
                log.debug("could not record %s: %s", lines, exc)

    def _load_meta(self) -> dict[str, dict]:
        p = self.root / META
        try:
            st = p.stat()
        except OSError:
            self._meta, self._meta_stamp = {}, None
            return self._meta
        stamp = (st.st_mtime_ns, st.st_size)
        if stamp != self._meta_stamp:
            meta: dict[str, dict] = {}
            try:
                for line in p.read_text(encoding="utf-8").splitlines():
                    try:
                        d = json.loads(line)
                        meta[d["file"]] = d
                    except (ValueError, KeyError, TypeError):
                        continue
            except OSError:
                pass
            self._meta, self._meta_stamp = meta, stamp
        return self._meta

    # ------------------------------------------------------------------ trash
    def _index(self) -> dict[str, float]:
        try:
            return json.loads((self.root / TRASH / TRASH_INDEX).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def _save_index(self, index: dict[str, float]) -> None:
        d = self.root / TRASH
        d.mkdir(parents=True, exist_ok=True)
        tmp = d / (TRASH_INDEX + ".tmp")
        tmp.write_text(json.dumps(index), encoding="utf-8")
        os.replace(tmp, d / TRASH_INDEX)

    def _trash_entries(self) -> list[dict]:
        entries = self._scan(self.root / TRASH)
        index = self._index()
        for e in entries:
            e["deleted"] = int(index.get(e["file"], e["modified"] / 1000) * 1000)
        entries.sort(key=lambda e: e["deleted"], reverse=True)
        return entries

    def trashed(self) -> list[dict]:
        with self._lock:
            return self._trash_entries()

    def _move(self, src: Path, dst: Path) -> None:
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists():
            dst.unlink()
        shutil.move(str(src), str(dst))
        stop = {self.root, (self.root / TRASH).resolve()}
        parent = src.parent.resolve()  # drop the folders the move left empty
        try:
            while parent not in stop and self.root in parent.parents and not any(parent.iterdir()):
                parent.rmdir()
                parent = parent.parent
        except OSError:
            pass

    def trash(self, files: list[str]) -> list[str]:
        """Move images (and the SVG next to a vectorize_image result) to the trash. Returns the moved paths."""
        moved = []
        with self._lock:
            index = self._index()
            for rel in files[:MAX_FILES_PER_REQUEST]:
                p = self.path(rel)
                if p is None:
                    continue
                self._move(p, self.root / TRASH / rel)
                svg = p.with_suffix(".svg")
                if svg.is_file():
                    self._move(svg, (self.root / TRASH / rel).with_suffix(".svg"))
                index[rel] = time.time()
                moved.append(rel)
            if moved:
                self._save_index(index)
        return moved

    def restore(self, files: list[str]) -> list[str]:
        """Move images back from the trash to where they were. An image whose place is taken stays in the trash."""
        restored = []
        with self._lock:
            index = self._index()
            for rel in files[:MAX_FILES_PER_REQUEST]:
                p = self.path(rel, trash=True)
                dst = self.root / rel
                if p is None or dst.exists():
                    continue
                self._move(p, dst)
                svg = p.with_suffix(".svg")
                if svg.is_file() and not dst.with_suffix(".svg").exists():
                    self._move(svg, dst.with_suffix(".svg"))
                index.pop(rel, None)
                restored.append(rel)
            if restored:
                self._save_index(index)
        return restored

    def purge(self, files: list[str] | None = None) -> int:
        """Delete images from the trash for good: the given ones, or all of them."""
        with self._lock:
            index = self._index()
            rels = [e["file"] for e in self._scan(self.root / TRASH)] if files is None else files[:MAX_FILES_PER_REQUEST]
            n = 0
            for rel in rels:
                p = self.path(rel, trash=True)
                if p is None:
                    continue
                p.unlink(missing_ok=True)
                p.with_suffix(".svg").unlink(missing_ok=True)
                if is_video(rel):
                    (self.root / poster_of(rel)).unlink(missing_ok=True)
                index.pop(rel, None)
                n += 1
            self._save_index(index)
            # drop the folders this left empty
            for d in sorted((x for x in (self.root / TRASH).rglob("*") if x.is_dir()), key=lambda x: len(x.parts),
                            reverse=True):
                try:
                    if not any(d.iterdir()):
                        d.rmdir()
                except OSError:
                    pass
        return n

    # ------------------------------------------------------------------ thumbnails and downloads
    def thumbnail(self, rel: str, size: int, trash: bool = False) -> bytes | None:
        """A small WebP of an image (transparency kept), made once and cached under .thumbs/."""
        size = min(THUMB_SIZES, key=lambda s: abs(s - size))
        p = self.path(rel, trash=trash)
        if p is None:
            return None
        if is_video(rel):
            p = self.root / poster_of(rel)  # a video's thumbnail is made from its poster
            if not p.is_file():
                return None
        st = p.stat()
        key = hashlib.sha1(f"{'~' if trash else ''}{rel}|{st.st_mtime_ns}|{st.st_size}|{size}".encode()).hexdigest()
        cached = self.root / THUMBS / key[:2] / f"{key}.webp"
        try:
            return cached.read_bytes()
        except OSError:
            pass
        try:
            with Image.open(p) as im:
                im.draft("RGB", (size * 2, size * 2))  # JPEG: decode at a reduced size
                im = im.convert("RGBA" if "A" in im.getbands() or im.mode == "P" else "RGB")
                im.thumbnail((size, size), Image.LANCZOS)
                buf = io.BytesIO()
                im.save(buf, "WEBP", quality=80, method=4)
        except Exception as exc:  # noqa: BLE001 - an unreadable image has no thumbnail
            log.debug("thumbnail %s: %s", rel, exc)
            return None
        data = buf.getvalue()
        try:
            cached.parent.mkdir(parents=True, exist_ok=True)
            tmp = cached.with_suffix(".tmp")
            tmp.write_bytes(data)
            os.replace(tmp, cached)
        except OSError:
            pass
        return data

    def zip(self, files: list[str], out: Path) -> int:
        """Write the given images (and their SVGs) to a zip file; returns how many images it holds."""
        n = 0
        with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_STORED) as z:
            for rel in files[:MAX_FILES_PER_REQUEST]:
                p = self.path(rel)
                if p is None:
                    continue
                z.write(p, rel)
                if p.with_suffix(".svg").is_file():
                    z.write(p.with_suffix(".svg"), rel[: -len(p.suffix)] + ".svg")
                n += 1
        return n
