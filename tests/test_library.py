"""The web page's gallery: listing, the settings of each result, trash and restore, thumbnails, zip downloads, and the
routes that change files only answering this server's own page."""

import asyncio
import io
import zipfile
from types import SimpleNamespace

from PIL import Image
from starlette.testclient import TestClient

from imagegen_mcp.config import Config
from imagegen_mcp.jobs import JobManager
from imagegen_mcp.library import Library, kind_of
from imagegen_mcp.server import build_app
from imagegen_mcp.service import ImageService


def _png(path, size=(64, 48), mode="RGB", color=(200, 30, 30)):
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new(mode, size, color if mode == "RGB" else (*color, 0)).save(path)


def _outputs(root):
    _png(root / "2026-01-02" / "image-120000-aaaa1111.png", (1344, 768))
    _png(root / "2026-01-02" / "transparent-120100-bbbb2222.png", mode="RGBA")
    _png(root / "2026-01-01" / "edit-090000-cccc3333.png")
    _png(root / "2026-01-02" / "vector-120200-dddd4444.png")
    (root / "2026-01-02" / "vector-120200-dddd4444.svg").write_text("<svg/>", encoding="utf-8")
    _png(root / "uploads" / "2026-01-02" / "dog-eeee5555.png")
    _png(root / ".trash" / "2026-01-01" / "old-1.png")  # hidden: not listed
    (root / ".previews.json").write_text("{}", encoding="utf-8")


def test_kinds_come_from_the_file_name():
    assert kind_of("2026-01-01/image-1.png") == "image"
    assert kind_of("2026-01-01/unwatermarked-1.png") == "unwatermarked"
    assert kind_of("uploads/2026-01-01/image-1.png") == "upload"
    assert kind_of("2026-01-01/holiday.png") == "other"


def test_library_lists_every_folder_with_sizes_and_svg_twins(tmp_path):
    _outputs(tmp_path)
    lib = Library(tmp_path).library()
    files = {e["file"]: e for e in lib["items"]}
    assert set(files) == {"2026-01-02/image-120000-aaaa1111.png", "2026-01-02/transparent-120100-bbbb2222.png",
                          "2026-01-01/edit-090000-cccc3333.png", "2026-01-02/vector-120200-dddd4444.png",
                          "uploads/2026-01-02/dog-eeee5555.png"}
    assert files["2026-01-02/image-120000-aaaa1111.png"]["width"] == 1344
    assert files["2026-01-02/vector-120200-dddd4444.png"]["svg"] == "2026-01-02/vector-120200-dddd4444.svg"
    assert files["uploads/2026-01-02/dog-eeee5555.png"]["kind"] == "upload"
    assert [f["path"] for f in lib["folders"]] == ["2026-01-02", "2026-01-01", "uploads/2026-01-02"]
    assert lib["trash"] == 1


def test_results_keep_their_tool_and_settings(tmp_path):
    _outputs(tmp_path)
    lib = Library(tmp_path)
    saved = SimpleNamespace(filename="2026-01-02/image-120000-aaaa1111.png")
    lib.record("generate", SimpleNamespace(images=[saved], info={"prompt": "a red fox", "seed": 7, "big": [1, 2]}))
    lib.record("status", SimpleNamespace(images=[], info={}))  # nothing saved: nothing recorded
    item = next(e for e in lib.items() if e["file"] == saved.filename)
    assert item["tool"] == "generate" and item["info"] == {"prompt": "a red fox", "seed": 7}


def test_trash_restore_and_purge(tmp_path):
    _outputs(tmp_path)
    lib = Library(tmp_path)
    vec = "2026-01-02/vector-120200-dddd4444.png"
    moved = lib.trash([vec, "uploads/2026-01-02/dog-eeee5555.png", "../outside.png", ".previews.json", "nope.png"])
    assert moved == [vec, "uploads/2026-01-02/dog-eeee5555.png"]
    assert (tmp_path / ".trash" / "2026-01-02" / "vector-120200-dddd4444.svg").is_file()  # the SVG goes along
    assert not (tmp_path / "uploads").exists()  # emptied folders are removed
    assert {e["file"] for e in lib.trashed()} >= set(moved)
    assert lib.restore([vec]) == [vec]
    assert (tmp_path / vec).is_file() and (tmp_path / vec).with_suffix(".svg").is_file()
    assert lib.purge(["uploads/2026-01-02/dog-eeee5555.png"]) == 1
    assert lib.purge() == 1  # the hidden old-1.png left from before
    assert lib.trashed() == []


def test_thumbnails_are_small_cached_and_keep_transparency(tmp_path):
    _outputs(tmp_path)
    lib = Library(tmp_path)
    data = lib.thumbnail("2026-01-02/transparent-120100-bbbb2222.png", 256)
    im = Image.open(io.BytesIO(data))
    assert im.format == "WEBP" and "A" in im.getbands()
    big = Image.open(io.BytesIO(lib.thumbnail("2026-01-02/image-120000-aaaa1111.png", 300)))
    assert max(big.size) == 256  # the nearest size
    assert list((tmp_path / ".thumbs").rglob("*.webp"))
    assert lib.thumbnail("../escape.png", 256) is None


def test_zip_holds_the_images_and_their_svgs(tmp_path):
    _outputs(tmp_path)
    out = tmp_path / "x.zip"
    assert Library(tmp_path).zip(["2026-01-02/vector-120200-dddd4444.png", "../nope.png"], out) == 1
    assert sorted(zipfile.ZipFile(out).namelist()) == ["2026-01-02/vector-120200-dddd4444.png",
                                                        "2026-01-02/vector-120200-dddd4444.svg"]


async def test_finished_jobs_are_handed_to_on_result():
    got = []
    jobs = JobManager(on_result=lambda kind, result: got.append((kind, result)))
    job = jobs.submit("generate", lambda progress: asyncio.sleep(0, result="done"))
    await job.done.wait()
    assert got == [("generate", "done")]


class _Svc(ImageService):
    def __init__(self, cfg, tmp_path):
        super().__init__(cfg)
        self.outputs = tmp_path
        self.state = "ready"


def _client(tmp_path, **outputs):
    cfg = Config.model_validate({"outputs_dir": str(tmp_path), "models_dir": str(tmp_path / "m"),
                                 "outputs": outputs})
    _, app = build_app(_Svc(cfg, tmp_path))
    return TestClient(app)


def test_page_and_library_routes(tmp_path):
    _outputs(tmp_path)
    with _client(tmp_path) as c:
        page = c.get("/", headers={"Accept": "text/html"}).text
        assert "<svg" in page and "__LOGO" not in page and "__MCP_PATH__" not in page and "api/library" in page
        lib = c.get("/api/library").json()
        assert len(lib["items"]) == 5 and lib["allow_delete"] is True
        r = c.get("/thumbs/2026-01-02/image-120000-aaaa1111.png?s=256")
        assert r.status_code == 200 and r.headers["content-type"] == "image/webp"
        assert c.get("/thumbs/.previews.json").status_code == 404


def test_only_the_own_page_can_change_files(tmp_path):
    _outputs(tmp_path)
    f = "2026-01-02/image-120000-aaaa1111.png"
    with _client(tmp_path) as c:
        assert c.post("/api/delete", json={"files": [f]}, headers={"Origin": "http://evil.example"}).status_code == 403
        assert c.post("/api/delete", json={"files": [f]}, headers={"Sec-Fetch-Site": "cross-site"}).status_code == 403
        assert (tmp_path / f).is_file()
        same = {"Origin": "http://testserver", "Sec-Fetch-Site": "same-origin"}
        assert c.post("/api/delete", json={"files": [f]}, headers=same).json() == {"moved": [f]}
        assert c.get("/api/trash").json()["items"][0]["file"] == f
        assert c.post("/api/restore", json={"files": [f]}, headers=same).json() == {"restored": [f]}
        assert c.post("/api/delete", json={"nope": 1}, headers=same).status_code == 400
        r = c.post("/api/zip", json={"files": [f]})
        assert r.status_code == 200 and zipfile.ZipFile(io.BytesIO(r.content)).namelist() == [f]


def test_deleting_can_be_turned_off(tmp_path):
    _outputs(tmp_path)
    with _client(tmp_path, allow_delete=False) as c:
        r = c.post("/api/delete", json={"files": ["2026-01-02/image-120000-aaaa1111.png"]})
        assert r.status_code == 403 and "allow_delete" in r.json()["error"]
        assert c.get("/api/library").json()["allow_delete"] is False
