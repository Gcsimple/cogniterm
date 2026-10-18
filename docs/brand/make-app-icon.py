#!/usr/bin/env python3
"""生成 CogniTerm 的 App 图标（macOS AppIcon.appiconset）。

为什么长这样
  用户第三次给的方向是「参考数据/公式的图形化展现」。所以符号从「终端提示符」换成了
  **一条上扬的曲线**：带浅网格的坐标系 + 薄荷色 S 形曲线 + 三个数据点 + 末端实心节点。
  它同时满足两件事——一眼能读成「数据/公式被画出来了」，以及在大尺寸下有足够的细节，
  不像一条纯字形那样在 Dock 里显得空。

  配色沿用上一轮定稿（这一版没有改颜色，只改了符号）：
    · 满幅深炭板 #3A4055 → #1B1F2A → #0A0C12，顶部一道线性柔光
    · 曲线用薄荷渐变 #74FFDE → #17C79C —— 全场唯一的彩色
    · 网格与坐标轴是白色低透明度，只做陪衬，不抢主体

  ⚠️ 16/32px 另出简化版：去掉网格和数据点、把曲线加粗、末端节点放大，否则三条细线在
     16px 会糊成一片噪点。

⚠️ 两条硬约束（都踩过）
  1. 底板必须满幅且不带 alpha：macOS 26 会给带透明的图标补灰底板，PNG 的
     `hasAlpha` 必须为 no。
  2. 光效用**线性**渐变，别用径向——径向铺满整张画布会露出方形边界。

用法（需要本机装有 Google Chrome，用它逐尺寸直渲，避免位图缩放损失）：
    /Users/Admin/.workbuddy/binaries/python/envs/default/bin/python docs/brand/make-app-icon.py
"""
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ASSET_DIR = os.path.join(ROOT, "App/Resources/Assets.xcassets/AppIcon.appiconset")
SVG_DIR = os.path.join(ROOT, "docs/brand")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# 曲线由两段三次贝塞尔接成，控制点固定，采样点在下面用同一组参数算出来
SEGMENTS = [
    ((262, 724), (372, 724), (400, 560), (520, 540)),
    ((520, 540), (640, 520), (690, 400), (776, 352)),
]
CURVE_PATH = "M 262 724 C 372 724 400 560 520 540 C 640 520 690 400 776 352"
CURVE_PATH_SMALL = "M 262 720 C 372 720 400 556 520 536 C 640 516 690 396 776 348"

GRID_Y = (428, 536, 644, 752)
AXIS = (262, 760, 520, 6)

SLOTS = [
    ("icon_16x16.png", 16, True),
    ("icon_16x16@2x.png", 32, True),
    ("icon_32x32.png", 32, True),
    ("icon_32x32@2x.png", 64, False),
    ("icon_128x128.png", 128, False),
    ("icon_128x128@2x.png", 256, False),
    ("icon_256x256.png", 256, False),
    ("icon_256x256@2x.png", 512, False),
    ("icon_512x512.png", 512, False),
    ("icon_512x512@2x.png", 1024, False),
]

TEMPLATE = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>CogniTerm</title>
  <desc>Charcoal plate with a rising mint data curve and sample nodes.</desc>
  <defs>
    <linearGradient id="plate" x1="512" y1="0" x2="512" y2="1024" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#3A4055"/>
      <stop offset="0.5" stop-color="#1B1F2A"/>
      <stop offset="1" stop-color="#0A0C12"/>
    </linearGradient>
    <linearGradient id="toplight" x1="512" y1="0" x2="512" y2="620" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.13"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="mint" x1="512" y1="340" x2="512" y2="760" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#74FFDE"/>
      <stop offset="1" stop-color="#17C79C"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#plate)"/>
  <rect width="1024" height="1024" fill="url(#toplight)"/>
@BODY@
</svg>
"""


def bezier(segment, t):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = segment
    mt = 1 - t
    return (mt ** 3 * x0 + 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t ** 3 * x3,
            mt ** 3 * y0 + 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t ** 3 * y3)


def svg(compact):
    ax, ay, aw, ah = AXIS
    if compact:
        body = ('  <rect x="%d" y="%d" width="%d" height="8" fill="#FFFFFF" fill-opacity="0.18"/>\n'
                '  <path d="%s" fill="none" stroke="url(#mint)" stroke-width="78" '
                'stroke-linecap="round"/>\n'
                '  <circle cx="776" cy="348" r="64" fill="#FFFFFF"/>'
                % (ax, ay, aw, CURVE_PATH_SMALL))
    else:
        grid = "\n".join(
            '  <rect x="%d" y="%d" width="%d" height="4" fill="#FFFFFF" fill-opacity="0.09"/>'
            % (ax, y, aw) for y in GRID_Y)
        dots = "\n".join(
            '  <circle cx="%d" cy="%d" r="26" fill="#FFFFFF"/>' % (round(x), round(y))
            for x, y in (bezier(SEGMENTS[0], 0.42), bezier(SEGMENTS[1], 0.28), bezier(SEGMENTS[1], 0.62)))
        body = ('%s\n'
                '  <rect x="%d" y="%d" width="%d" height="%d" fill="#FFFFFF" fill-opacity="0.20"/>\n'
                '  <path d="%s" fill="none" stroke="url(#mint)" stroke-width="70" '
                'stroke-linecap="round"/>\n'
                '%s\n'
                '  <circle cx="776" cy="352" r="56" fill="#FFFFFF"/>'
                % (grid, ax, ay, aw, ah, CURVE_PATH, dots))
    return TEMPLATE.replace("@BODY@", body)


def flatten(path):
    """去掉 alpha 通道：带 alpha 的图标在 macOS 26 会被判定为「无底板」而补灰底。"""
    try:
        from PIL import Image
    except ImportError:
        return
    Image.open(path).convert("RGB").save(path)


def render(path, size, markup):
    """用 Chrome 无头模式按目标像素直渲（不缩放位图，小尺寸更锐利）。"""
    html = ("<!doctype html><meta charset=\"utf-8\">"
            "<style>html,body{margin:0;padding:0}"
            "svg{display:block;width:%dpx;height:%dpx}</style>\n%s" % (size, size, markup))
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as handle:
        handle.write(html)
        page = handle.name
    try:
        subprocess.run([
            CHROME, "--headless=new", "--no-sandbox",
            "--force-device-scale-factor=1", "--hide-scrollbars",
            "--window-size=%d,%d" % (size, size),
            "--screenshot=%s" % path,
            "file://%s" % page,
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        os.unlink(page)
    flatten(path)


def main():
    if not os.path.exists(CHROME):
        sys.exit("找不到 Google Chrome：%s" % CHROME)
    os.makedirs(SVG_DIR, exist_ok=True)
    with open(os.path.join(SVG_DIR, "app-icon.svg"), "w") as handle:
        handle.write(svg(compact=False))
    with open(os.path.join(SVG_DIR, "app-icon-small.svg"), "w") as handle:
        handle.write(svg(compact=True))
    os.makedirs(ASSET_DIR, exist_ok=True)
    for name, size, compact in SLOTS:
        render(os.path.join(ASSET_DIR, name), size, svg(compact))
        print("%-22s %4dpx%s" % (name, size, "  (简化字形)" if compact else ""))


if __name__ == "__main__":
    main()
