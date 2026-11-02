#!/usr/bin/env python3
"""Install *approved* AI-Orchestrator v1 icons into existing Flutter platforms.

Usage (on a clean worktree/PR branch):
  python3 scripts/install_platform_icons.py /path/to/AI-Orchestrator-Platform-Icons-v1.zip --dry-run
  python3 scripts/install_platform_icons.py /path/to/AI-Orchestrator-Platform-Icons-v1.zip --apply

This script never reads an arbitrary URL or installs packages. It validates the
exact archived icon pack authored 2026-09-16 before touching anything.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import sys
from zipfile import ZipFile

PACK_SHA256 = "c4355dd078a26861f98f8f643c9a88aa947d8a13b95c14e2dd292e21e84bd414"
PREFIX = "AI-Orchestrator-Platform-Icons/"
COLOR_NAME = "ic_launcher_background"
COLOR_VALUE = "#010509"


def destinations(archive: ZipFile, root: Path) -> list[tuple[str, Path]]:
    """Map allowlisted ZIP members only to known Flutter platform destinations."""
    mappings: list[tuple[str, Path]] = []

    def add_group(src: str, target: str, enabled: bool, allowed: tuple[str, ...]):
        if not enabled:
            return
        for member in archive.namelist():
            if not member.startswith(PREFIX + src):
                continue
            suffix = member[len(PREFIX + src):]
            if not suffix or "/" in suffix or not suffix.endswith(allowed):
                continue
            mappings.append((member, root / target / suffix))

    res = root / "android/app/src/main/res"
    if res.exists():
        for member in archive.namelist():
            prefix = PREFIX + "Android/res/"
            if not member.startswith(prefix):
                continue
            subpath = member[len(prefix):]
            bits = subpath.split("/")
            if len(bits) != 2:
                continue
            dirname, filename = bits
            if dirname.startswith("mipmap-") and (
                filename in ("ic_launcher.png", "ic_launcher_round.png",
                             "ic_launcher_foreground.png", "ic_launcher.xml",
                             "ic_launcher_round.xml")
            ):
                mappings.append((member, res / dirname / filename))

    add_group("macOS/AppIcon.appiconset/",
              "macos/Runner/Assets.xcassets/AppIcon.appiconset",
              (root / "macos/Runner/Assets.xcassets").is_dir(),
              (".png", ".json"))
    add_group("iOS/AppIcon.appiconset/",
              "ios/Runner/Assets.xcassets/AppIcon.appiconset",
              (root / "ios/Runner/Assets.xcassets").is_dir(),
              (".png", ".json"))
    add_group("Web_PWA/icons/",
              "web/icons", (root / "web").is_dir(), (".png",))
    if (root / "web").is_dir():
        mappings.append((PREFIX + "Web_PWA/favicon-32x32.png", root / "web/favicon.png"))

    if (root / "windows/runner/resources").is_dir():
        mappings.append((PREFIX + "Windows/app_icon.ico",
                         root / "windows/runner/resources/app_icon.ico"))
    return sorted(mappings, key=lambda p: str(p[1]))


def update_background_color(root: Path, *, apply: bool) -> str | None:
    """Preserve existing Android resource definitions when adding icon background."""
    res = root / "android/app/src/main/res"
    if not res.is_dir():
        return None
    colors = res / "values/colors.xml"
    line = f'    <color name="{COLOR_NAME}">{COLOR_VALUE}</color>'
    if colors.exists():
        original = colors.read_text(encoding="utf-8")
        pattern = rf'<color\\s+name="{COLOR_NAME}"[^>]*>[^<]*</color>'
        if re.search(pattern, original):
            updated = re.sub(pattern, line.strip(), original, count=1)
        else:
            if "</resources>" not in original:
                raise ValueError("Android colors.xml has no resources closing tag")
            updated = original.replace("</resources>", line + "\n</resources>", 1)
    else:
        updated = '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n' + line + '\n</resources>\n'
        original = None
    if apply and original != updated:
        colors.parent.mkdir(parents=True, exist_ok=True)
        colors.write_text(updated, encoding="utf-8")
    return str(colors)


def install(pack: Path, root: Path, *, apply: bool,
            expected_digest: str = PACK_SHA256) -> list[Path]:
    if not pack.is_file():
        raise FileNotFoundError(pack)
    actual = hashlib.sha256(pack.read_bytes()).hexdigest()
    if actual != expected_digest:
        raise ValueError(f"Unapproved icon pack: SHA256 {actual} != {expected_digest}")

    with ZipFile(pack) as archive:
        targets = destinations(archive, root)
        if not targets:
            raise ValueError("No supported Flutter platform scaffold found")
        missing = [name for name, _ in targets if name not in archive.namelist()]
        if missing:
            raise ValueError(f"Missing approved asset(s): {missing}")

        # Validate every source entry and bytes BEFORE modifying the repository.
        pending = [(dest, archive.read(name)) for name, dest in targets]
        color_target = update_background_color(root, apply=False)
        if apply:
            for dest, data in pending:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
            update_background_color(root, apply=True)
        paths = [p for p, _ in pending]
        if color_target is not None:
            paths.append(Path(color_target))
        return paths


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pack", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--dry-run", action="store_true")
    action.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        paths = install(args.pack, args.root, apply=args.apply)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"{'Installed' if args.apply else 'Would install'} {len(paths)} icon resources")
    for path in paths:
        print(path.relative_to(args.root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
