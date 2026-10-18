"""Prepare the den-homeassistant repository, and its release zip, from the Den repository.

HACS installs an integration only from the root of a repository, so Den's Home Assistant
integration is published from its own repository, github.com/xattribution/den-homeassistant.
This writes that repository's files into OUT_DIR:

    hacs.json               HACS settings: install from the den.zip attached to each release
    README.md               this integration's README, which HACS shows
    LICENSE                 Den's license (AGPL-3.0)
    custom_components/den/  the integration, with its brand images in brand/

With --zip it also writes den.zip: the contents of custom_components/den at the zip's root,
which HACS unpacks into config/custom_components/den/.

    python scripts/prepare_hacs_repo.py OUT_DIR [--zip PATH] [--version X] [--force]

Python 3.10+ standard library only, so it runs the same in CI and on Windows.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import zipfile
from pathlib import Path

DEN_REPO = Path(__file__).resolve().parents[3]
INTEGRATION = Path("integrations") / "homeassistant"
ZIP_NAME = "den.zip"
SKIP = shutil.ignore_patterns("__pycache__", "*.pyc")


class PrepareError(Exception):
    """Something to fix before the repository can be prepared."""


def hacs_settings(integration: Path) -> dict:
    """The integration's hacs.json, for a repository with custom_components/den at its root."""
    settings = json.loads((integration / "hacs.json").read_text(encoding="utf-8"))
    settings["content_in_root"] = False
    # HACS downloads the release asset named `filename` and unpacks it into
    # custom_components/den.
    settings["zip_release"] = True
    settings["filename"] = ZIP_NAME
    return settings


def write_json(path: Path, data: dict) -> None:
    text = json.dumps(data, indent=2) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")


def prepare(
    out: Path,
    *,
    version: str | None = None,
    set_version: bool = False,
    force: bool = False,
    zip_path: Path | None = None,
    den_repo: Path = DEN_REPO,
) -> str:
    """Write the repository into `out`, and den.zip to `zip_path`; return the version."""
    integration = den_repo / INTEGRATION
    component = integration / "custom_components" / "den"
    manifest = json.loads((component / "manifest.json").read_text(encoding="utf-8"))

    if version is not None:
        version = version.removeprefix("v")  # so a tag like v0.1.0 can be passed as is
        if version != manifest["version"] and not set_version:
            raise PrepareError(
                f"version {version} doesn't match manifest.json's {manifest['version']}; "
                "bump it in manifest.json or pass --set-version"
            )
    if out.resolve() == integration.resolve():
        raise PrepareError(f"{out} is the integration's own folder; choose another")
    if out.exists() and any(out.iterdir()) and not force:
        raise PrepareError(f"{out} isn't empty; pass --force to refresh it (a clone, say)")

    out.mkdir(parents=True, exist_ok=True)
    write_json(out / "hacs.json", hacs_settings(integration))
    shutil.copyfile(integration / "README.md", out / "README.md")
    shutil.copyfile(den_repo / "LICENSE", out / "LICENSE")

    # Replace the whole folder so files removed from the integration go away here too.
    target = out / "custom_components" / "den"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(component, target, ignore=SKIP)
    if version is not None and version != manifest["version"]:
        manifest["version"] = version
        write_json(target / "manifest.json", manifest)

    if not (target / "brand" / "icon.png").exists():
        print(
            "note: custom_components/den/brand/icon.png is missing; render the brand images "
            "from Den's mark with `flutter test --update-goldens test/icon` in app/",
            file=sys.stderr,
        )

    if zip_path is not None:
        write_zip(target, zip_path)
    return manifest["version"]


def write_zip(component: Path, zip_path: Path) -> None:
    """Zip the files in `component` with paths relative to it, so manifest.json is at the root."""
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for file in sorted(component.rglob("*")):
            if file.is_file():
                zf.write(file, file.relative_to(component).as_posix())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Prepare the den-homeassistant repository (for HACS) from Den's."
    )
    parser.add_argument("out", type=Path, metavar="OUT_DIR", help="where to write it")
    parser.add_argument(
        "--zip", type=Path, metavar="PATH", help=f"also write the release zip, {ZIP_NAME}"
    )
    parser.add_argument(
        "--version", help="the release's version (0.1.0 or v0.1.0); must match manifest.json"
    )
    parser.add_argument(
        "--set-version",
        action="store_true",
        help="put --version in the copied manifest.json instead of refusing a mismatch",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="write into a non-empty OUT_DIR, such as a clone of den-homeassistant: replaces "
        "hacs.json, README.md, LICENSE and custom_components/den, leaves the rest (.git) alone",
    )
    args = parser.parse_args(argv)
    if args.set_version and args.version is None:
        parser.error("--set-version needs --version")

    try:
        version = prepare(
            args.out,
            version=args.version,
            set_version=args.set_version,
            force=args.force,
            zip_path=args.zip,
        )
    except PrepareError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    print(f"Wrote den-homeassistant {version} to {args.out}")
    if args.zip is not None:
        print(f"Wrote {args.zip}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
