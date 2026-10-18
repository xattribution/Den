"""scripts/prepare_hacs_repo.py: the den-homeassistant repository layout and den.zip."""

from __future__ import annotations

import importlib.util
import json
import shutil
import struct
import zipfile
from pathlib import Path

import pytest

INTEGRATION = Path(__file__).resolve().parents[1]
COMPONENT = INTEGRATION / "custom_components" / "den"
SOURCE_MANIFEST = json.loads((COMPONENT / "manifest.json").read_text(encoding="utf-8"))
SOURCE_HACS = json.loads((INTEGRATION / "hacs.json").read_text(encoding="utf-8"))

_spec = importlib.util.spec_from_file_location(
    "prepare_hacs_repo", INTEGRATION / "scripts" / "prepare_hacs_repo.py"
)
prepare_hacs_repo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(prepare_hacs_repo)
main = prepare_hacs_repo.main

EXPECTED_HACS = {
    "name": "Den",
    "render_readme": True,
    "homeassistant": SOURCE_HACS["homeassistant"],
    "content_in_root": False,
    "zip_release": True,
    "filename": "den.zip",
}


@pytest.fixture(autouse=True)
def auto_enable_custom_integrations() -> None:
    """These tests don't start Home Assistant (overrides the conftest fixture)."""


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def bytecode(paths: list[str]) -> list[str]:
    return [p for p in paths if "__pycache__" in p or p.endswith(".pyc")]


def test_writes_the_repository_layout(tmp_path: Path) -> None:
    """hacs.json, README, LICENSE and custom_components/den sit at the root."""
    out = tmp_path / "den-homeassistant"
    assert main([str(out)]) == 0

    assert sorted(p.name for p in out.iterdir()) == [
        "LICENSE",
        "README.md",
        "custom_components",
        "hacs.json",
    ]
    assert read_json(out / "hacs.json") == EXPECTED_HACS
    assert [p.name for p in (out / "custom_components").iterdir()] == ["den"]
    assert read_json(out / "custom_components" / "den" / "manifest.json") == SOURCE_MANIFEST
    assert (out / "custom_components" / "den" / "__init__.py").is_file()
    assert (out / "README.md").read_bytes() == (INTEGRATION / "README.md").read_bytes()
    license_text = (out / "LICENSE").read_text(encoding="utf-8")
    assert license_text.lstrip().startswith("GNU AFFERO GENERAL PUBLIC LICENSE")


def test_zip_holds_the_integration_at_its_root(tmp_path: Path) -> None:
    """den.zip has the contents of custom_components/den, which HACS unpacks in place."""
    out = tmp_path / "den-homeassistant"
    zip_path = tmp_path / "dist" / "den.zip"
    assert main([str(out), "--zip", str(zip_path)]) == 0

    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        manifest = json.loads(zf.read("manifest.json"))
    assert "manifest.json" in names
    assert "__init__.py" in names
    assert "translations/en.json" in names
    assert not [n for n in names if n.startswith("custom_components/")]
    assert manifest == SOURCE_MANIFEST
    copied = out / "custom_components" / "den"
    assert sorted(names) == sorted(
        p.relative_to(copied).as_posix() for p in copied.rglob("*") if p.is_file()
    )


def png_size(data: bytes) -> tuple[int, int]:
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">II", data[16:24])


def test_carries_the_brand_images(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """brand/ reaches the repository and the zip at the sizes Home Assistant asks for."""
    out = tmp_path / "den-homeassistant"
    zip_path = tmp_path / "den.zip"
    assert main([str(out), "--zip", str(zip_path)]) == 0
    assert "brand" not in capsys.readouterr().err

    brand = out / "custom_components" / "den" / "brand"
    with zipfile.ZipFile(zip_path) as zf:
        for theme in ("", "dark_"):
            for suffix, scale in (("", 1), ("@2x", 2)):
                icon = zf.read(f"brand/{theme}icon{suffix}.png")
                assert icon == (brand / f"{theme}icon{suffix}.png").read_bytes()
                assert png_size(icon) == (256 * scale, 256 * scale)
                width, height = png_size(zf.read(f"brand/{theme}logo{suffix}.png"))
                assert min(width, height) in range(128 * scale, 256 * scale + 1)


def test_notes_missing_brand_images(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """Without brand/icon.png the repository is still written, with a note on how to render it."""
    den = tmp_path / "den"
    source = den / "integrations" / "homeassistant"
    shutil.copytree(
        COMPONENT, source / "custom_components" / "den", ignore=shutil.ignore_patterns("brand")
    )
    shutil.copyfile(INTEGRATION / "hacs.json", source / "hacs.json")
    shutil.copyfile(INTEGRATION / "README.md", source / "README.md")
    (den / "LICENSE").write_text("license\n", encoding="utf-8")

    prepare_hacs_repo.prepare(tmp_path / "out", den_repo=den)
    err = capsys.readouterr().err
    assert "brand/icon.png is missing" in err
    assert "flutter test --update-goldens test/icon" in err


def test_leaves_out_bytecode(tmp_path: Path) -> None:
    """__pycache__ folders and .pyc files stay behind, in the tree and in the zip."""
    den = tmp_path / "den"
    source = den / "integrations" / "homeassistant"
    shutil.copytree(COMPONENT, source / "custom_components" / "den")
    shutil.copyfile(INTEGRATION / "hacs.json", source / "hacs.json")
    shutil.copyfile(INTEGRATION / "README.md", source / "README.md")
    (den / "LICENSE").write_text("license\n", encoding="utf-8")
    pycache = source / "custom_components" / "den" / "__pycache__"
    pycache.mkdir(exist_ok=True)
    (pycache / "const.cpython-313.pyc").write_bytes(b"\0")
    (source / "custom_components" / "den" / "stray.pyc").write_bytes(b"\0")

    out = tmp_path / "out"
    zip_path = tmp_path / "den.zip"
    prepare_hacs_repo.prepare(out, zip_path=zip_path, den_repo=den)

    assert bytecode([p.as_posix() for p in out.rglob("*")]) == []
    with zipfile.ZipFile(zip_path) as zf:
        assert bytecode(zf.namelist()) == []
        assert "manifest.json" in zf.namelist()


def test_accepts_the_manifest_version(tmp_path: Path) -> None:
    """The version may be given as in manifest.json or as a tag."""
    version = SOURCE_MANIFEST["version"]
    assert main([str(tmp_path / "a"), "--version", version]) == 0
    assert main([str(tmp_path / "b"), "--version", f"v{version}"]) == 0


def test_refuses_another_version(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """A version that isn't manifest.json's is refused, and nothing is written."""
    out = tmp_path / "out"
    assert main([str(out), "--version", "99.0.0"]) == 1
    assert "doesn't match manifest.json's" in capsys.readouterr().err
    assert not out.exists()


def test_set_version_changes_only_the_copy(tmp_path: Path) -> None:
    """--set-version stamps the copied manifest.json (and the zip's), not the source."""
    out = tmp_path / "out"
    zip_path = tmp_path / "den.zip"
    args = [str(out), "--version", "v99.0.0", "--set-version", "--zip", str(zip_path)]
    assert main(args) == 0

    copied = read_json(out / "custom_components" / "den" / "manifest.json")
    assert copied == {**SOURCE_MANIFEST, "version": "99.0.0"}
    with zipfile.ZipFile(zip_path) as zf:
        assert json.loads(zf.read("manifest.json"))["version"] == "99.0.0"
    assert read_json(COMPONENT / "manifest.json") == SOURCE_MANIFEST


def test_set_version_needs_a_version(tmp_path: Path) -> None:
    with pytest.raises(SystemExit):
        main([str(tmp_path / "out"), "--set-version"])


def test_refuses_a_non_empty_directory(
    tmp_path: Path, capsys: pytest.CaptureFixture
) -> None:
    """Without --force, a directory with anything in it is left alone."""
    out = tmp_path / "out"
    out.mkdir()
    (out / "notes.txt").write_text("mine\n", encoding="utf-8")

    assert main([str(out)]) == 1
    assert "isn't empty" in capsys.readouterr().err
    assert [p.name for p in out.iterdir()] == ["notes.txt"]


def test_force_refreshes_a_clone(tmp_path: Path) -> None:
    """--force rewrites the published files and leaves the rest of the clone alone."""
    out = tmp_path / "den-homeassistant"
    (out / ".git").mkdir(parents=True)
    (out / ".git" / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
    old = out / "custom_components" / "den"
    old.mkdir(parents=True)
    (old / "removed.py").write_text("", encoding="utf-8")
    (out / "hacs.json").write_text("{}\n", encoding="utf-8")

    assert main([str(out), "--force"]) == 0
    assert (out / ".git" / "HEAD").read_text(encoding="utf-8") == "ref: refs/heads/main\n"
    assert not (old / "removed.py").exists()
    assert (old / "manifest.json").is_file()
    assert read_json(out / "hacs.json") == EXPECTED_HACS
