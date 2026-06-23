#!/usr/bin/env python3
"""One-time derivation: AI render (cream backdrop) -> transparent 1024 master.

把 AI 生成的整图(奶白圆角底板 + 金色爪痕, 卡片四周还有一圈灰色背景)裁成
macOS 图标用的透明主图: 只保留奶白圆角卡片本体, 圆角外 + 外圈灰底全部透明。

裁切框是针对 MacAppIcon-ImageGen.png 这一张渲染图标定的(卡片近似居中、略偏上)。
卡片内部是均匀奶白, 爪痕居中, 所以裁切框只要"卡在奶白内、爪痕外"即可, 不需要
像素级精确; 若以后换一张构图不同的渲染图, 重新标定下面的 EDGES / RADIUS_RATIO。
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ASSETS = Path(__file__).resolve().parent
SOURCE = ASSETS / "MacAppIcon-ImageGen.png"   # 原始渲染图(带背景)
MASTER = ASSETS / "MacAppIcon-1024.png"       # 输出: 透明圆角主图

# 卡片在原图中的四边, 用占整图宽高的比例表示(与分辨率无关), 针对当前这张渲染标定。
EDGES = dict(left=0.16188, right=0.83493, top=0.15949, bottom=0.80702)
INSET_PX = 8           # 四边再往里收一点, 避开卡片外圈的高光/投影, 不漏灰底
RADIUS_RATIO = 0.185   # 圆角半径 / 卡片边长, 贴近原卡片的圆角观感
SUPERSAMPLE = 4        # 蒙版超采样后缩回, 得到抗锯齿的圆角边缘
MARGIN_PX = 100        # macOS 标准留白: 1024 画布里主体 824 + 四周各 100px, Dock 里和别的图标一样大


def extract() -> Image.Image:
    src = Image.open(SOURCE).convert("RGB")
    width, height = src.size
    left = EDGES["left"] * width
    right = EDGES["right"] * width
    top = EDGES["top"] * height
    bottom = EDGES["bottom"] * height
    center_x, center_y = (left + right) / 2, (top + bottom) / 2
    side = min(right - left, bottom - top) - 2 * INSET_PX      # 取正方形主体
    box = [
        round(center_x - side / 2), round(center_y - side / 2),
        round(center_x + side / 2), round(center_y + side / 2),
    ]
    radius = round(side * RADIUS_RATIO)

    scale = SUPERSAMPLE
    mask = Image.new("L", (width * scale, height * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [c * scale for c in box], radius=radius * scale, fill=255
    )
    mask = mask.resize((width, height), Image.Resampling.LANCZOS)

    card = src.convert("RGBA")
    card.putalpha(mask)
    cropped = card.crop(tuple(box))

    # 缩到 824 主体并居中放进 1024 透明画布, 四周留 100px(macOS 标准), 否则 Dock 里比别人大一圈
    body = 1024 - 2 * MARGIN_PX
    card_body = cropped.resize((body, body), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    canvas.paste(card_body, (MARGIN_PX, MARGIN_PX), card_body)
    return canvas


def main() -> None:
    if not SOURCE.exists():
        raise FileNotFoundError(f"Missing render: {SOURCE}")
    master = extract()
    master.save(MASTER)
    print(f"Wrote {MASTER}  ({master.size[0]}x{master.size[1]}, RGBA)")


if __name__ == "__main__":
    main()
