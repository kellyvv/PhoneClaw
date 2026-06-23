#!/usr/bin/env python3
from __future__ import annotations

import shutil
import struct
import subprocess
from pathlib import Path

from PIL import Image

ASSETS_DIR = Path(__file__).resolve().parent
# 透明圆角主图(奶白卡片 + 金爪, 圆角外透明), 由 extract_card.py 从渲染图裁出。
MASTER_PNG = ASSETS_DIR / "MacAppIcon-1024.png"
ICONSET_DIR = ASSETS_DIR / "AppIcon.iconset"
ICNS_PATH = ASSETS_DIR / "AppIcon.icns"
RUNTIME_ICNS_PATH = ASSETS_DIR.parent / "Sources" / "PhoneClawGateway" / "Resources" / "AppIcon.icns"


def load_master() -> Image.Image:
    image = Image.open(MASTER_PNG).convert("RGBA")
    if image.size != (1024, 1024):
        image = image.resize((1024, 1024), Image.Resampling.LANCZOS)
    return image


def write_iconset(source: Image.Image) -> None:
    if ICONSET_DIR.exists():
        shutil.rmtree(ICONSET_DIR)
    ICONSET_DIR.mkdir(parents=True)

    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    for name, side in sizes.items():
        source.resize((side, side), Image.Resampling.LANCZOS).save(ICONSET_DIR / name)


def write_icns_fallback() -> None:
    entries = [
        ("icp4", "icon_16x16.png"),
        ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"),
        ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png"),
    ]

    chunks: list[bytes] = []
    for icon_type, file_name in entries:
        data = (ICONSET_DIR / file_name).read_bytes()
        chunks.append(icon_type.encode("ascii") + struct.pack(">I", len(data) + 8) + data)

    payload = b"".join(chunks)
    ICNS_PATH.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)


def write_icns() -> None:
    iconutil = shutil.which("iconutil")
    if iconutil is None:
        write_icns_fallback()
        return

    try:
        subprocess.run(
            [iconutil, "-c", "icns", str(ICONSET_DIR), "-o", str(ICNS_PATH)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        write_icns_fallback()


def main() -> None:
    if not MASTER_PNG.exists():
        raise FileNotFoundError(f"Missing master: {MASTER_PNG} (run extract_card.py first)")

    master = load_master()
    write_iconset(master)
    write_icns()
    RUNTIME_ICNS_PATH.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ICNS_PATH, RUNTIME_ICNS_PATH)

    print(f"Master  {MASTER_PNG}")
    print(f"Wrote   {ICNS_PATH}")
    print(f"Wrote   {RUNTIME_ICNS_PATH}")


if __name__ == "__main__":
    main()
