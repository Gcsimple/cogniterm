#!/usr/bin/env python3
"""生成 CogniTerm 的 App 图标（macOS AppIcon.appiconset）。

为什么长这样
  Dock 里相邻的图标（ChatGPT、微信、纸飞机…）都是「一块有厚度的实体板 + 一个大而清晰
  的符号」。前两版都败在这一步：第一版是透明底上的有机云朵（macOS 26 会给它补一张灰
  玻璃底板）；第二版是白底上一个细笔画的 > 加圆点，画面太空，像文字而不像图标，在 Dock
  里明显比邻居单薄。

  现在的构图 = 深色终端窗口 + 高亮度提示符 + 认知节点：
    · 近白底板（#FFFFFF → #ECECF0）撑起 macOS 26 的满幅要求
    · 深炭窗口（#333849 → #0A0C12）占画布 66%，权重和邻居的深色图标对齐
    · 提示符用薄荷渐变（#6BFFD9 → #16C79A）——全场唯一的彩色，深色板上第一眼就能认出
    · 白圆点收尾，读作「光标指向的那个节点」，也是 CogniTerm 里 agent 的隐喻

  ⚠️ 16/32px 另出简化版（去掉圆点、加粗箭头），否则圆点和箭头在 16px 糊成一团。

⚠️ 两条硬约束（都踩过）
  1. 底板必须满幅且不带 alpha：macOS 26 会给带透明的图标补灰底板，PNG 的
     `hasAlpha` 必须为 no。
  2. 白色字形压在近白底板上会糊，符号必须整体反相成深色/高饱和色。

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

# 深色窗口铺满整张画布（macOS 只做 squircle 遮罩，不再叠一层白板）
WINDOW = (0, 0, 1024, 1024)
WINDOW_RADIUS = 0
GLYPH_SCALE = 1.75              # 符号占画布约 58%，和 Dock 里邻居的视觉重量对齐

# 完整字形：提示符 + 认知节点
CHEVRON = "M 394 384 L 510 512 L 394 640"
CHEVRON_WIDTH = 88
NODE = (634, 512, 52)

# 简化字形（16/32px）：去掉圆点，只留更粗、居中的提示符
CHEVRON_SMALL = "M 444 358 L 580 512 L 444 666"
CHEVRON_WIDTH_SMALL = 112

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
  <desc>Charcoal plate with a mint prompt chevron and an agent node.</desc>
  <defs>
    <linearGradient id="window" x1="512" y1="0" x2="512" y2="1024" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#3A4055"/>
      <stop offset="0.5" stop-color="#1B1F2A"/>
      <stop offset="1" stop-color="#0A0C12"/>
    </linearGradient>
    <linearGradient id="toplight" x1="512" y1="0" x2="512" y2="620" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.13"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="prompt" x1="512" y1="384" x2="512" y2="648" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#74FFDE"/>
      <stop offset="1" stop-color="#17C79C"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#window)"/>
  <rect width="1024" height="1024" fill="url(#toplight)"/>
  <g transform="translate(512,512) scale(@S@) translate(-514,-512)">
  @GLYPH@
  </g>
</svg>
"""


def svg(compact):
    if compact:
        glyph = ('<path d="%s" fill="none" stroke="url(#prompt)" stroke-width="%d" '
                 'stroke-linecap="round" stroke-linejoin="round"/>'
                 % (CHEVRON_SMALL, CHEVRON_WIDTH_SMALL))
    else:
        glyph = ('<path d="%s" fill="none" stroke="url(#prompt)" stroke-width="%d" '
                 'stroke-linecap="round" stroke-linejoin="round"/>'
                 '\n  <circle cx="%d" cy="%d" r="%d" fill="#FFFFFF"/>'
                 % (CHEVRON, CHEVRON_WIDTH, NODE[0], NODE[1], NODE[2]))
    return (TEMPLATE
            .replace("@S@", "%.2f" % GLYPH_SCALE)
            .replace("@GLYPH@", glyph))


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
