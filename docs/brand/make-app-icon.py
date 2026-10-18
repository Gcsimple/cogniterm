#!/usr/bin/env python3
"""生成 CogniTerm 的 App 图标（macOS AppIcon.appiconset）。

风格来源：ChatGPT for macOS 的图标（拆它的 icns 量的）
  - 底板是**近白**（#FFFFFF 顶部 → #ECECF0 底部），不是彩色
  - 字形是**近黑偏冷**的实心色（#3A3F52 → #0A0C12），不是纯黑
  - 字形有**材质感**：上缘一道柔和高光 + 底部投影，像一根有厚度的管子
  - 零装饰，画面里只有「底板 + 一个字形」

自有识别点（不照抄 ChatGPT 的结）
  - 字形是「> 提示符 + 实心圆点（认知节点）」，对应 CogniTerm 的终端 + 节点语义
  - 圆点与箭头分离、等重，缩小后不会糊成一个疙瘩（16/32px 另出简化版，去掉圆点）

⚠️ 为什么底板必须满幅（而不是像 ChatGPT 那样只画一个圆角方板）
   macOS 26 起系统接管图标外形：asset 带透明 → 系统补一张浅灰玻璃底板，图标会发灰。
   满幅铺白后系统只做 squircle 遮罩 + 高光，结果就是 ChatGPT 那种白板效果。
   PNG 也必须**不带 alpha 通道**。

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

CHEVRON = "M 366 372 L 504 512 L 366 652"
NODE = (654, 512, 68)

# (文件名, 像素尺寸, 是否简化字形)
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

HEAD = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>CogniTerm</title>
  <desc>Near-white plate with a charcoal prompt chevron and an agent node.</desc>
  <defs>
    <linearGradient id="plate" x1="512" y1="0" x2="512" y2="1024" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="0.55" stop-color="#FAFAFB"/>
      <stop offset="1" stop-color="#ECECF0"/>
    </linearGradient>
    <linearGradient id="ink" x1="512" y1="300" x2="512" y2="770" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#3A3F52"/>
      <stop offset="0.40" stop-color="#1D212B"/>
      <stop offset="1" stop-color="#0A0C12"/>
    </linearGradient>
    <filter id="cast" x="-40%%" y="-40%%" width="180%%" height="190%%">
      <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#0A0C12" flood-opacity="0.18"/>
    </filter>
    <filter id="blur" x="-40%%" y="-40%%" width="180%%" height="190%%">
      <feGaussianBlur stdDeviation="5"/>
    </filter>
    <mask id="inkMask"><rect width="1024" height="1024" fill="#000"/>%(white)s</mask>
  </defs>
  <rect width="1024" height="1024" fill="url(#plate)"/>
  <g transform="translate(512,512) scale(%(scale)s) translate(-514,-512)">
    <g filter="url(#cast)">%(ink)s</g>
    <g mask="url(#inkMask)">
      <g filter="url(#blur)" opacity="0.40">
        <path d="M 372 352 L 506 488 L 372 624" fill="none" stroke="#B9C0D2"
              stroke-width="32" stroke-linecap="round" stroke-linejoin="round"/>
        %(glow_node)s
      </g>
      <g filter="url(#blur)" opacity="0.26" transform="translate(0,30)">
        <path d="%(chevron)s" fill="none" stroke="#0A0C12" stroke-width="24"
              stroke-linecap="round" stroke-linejoin="round"/>
      </g>
    </g>
  </g>
</svg>
"""


def glyph(color_stroke, color_fill, stroke, node):
    markup = ('<path d="%s" fill="none" stroke="%s" stroke-width="%d" '
              'stroke-linecap="round" stroke-linejoin="round"/>'
              % (CHEVRON, color_stroke, stroke))
    if node:
        markup += '<circle cx="%d" cy="%d" r="%d" fill="%s"/>' % (
            NODE[0], NODE[1], NODE[2], color_fill)
    return markup


def svg(compact):
    """compact=True 时只留加粗的箭头（16/32px 用），否则箭头 + 认知节点。"""
    if compact:
        scale, stroke, node = 1.34, 120, False
        glow_node = ""
    else:
        scale, stroke, node = 1.34, 112, True
        glow_node = ('<circle cx="%d" cy="488" r="50" fill="#B9C0D2"/>' % NODE[0])
    return HEAD % {
        "white": glyph("#FFFFFF", "#FFFFFF", stroke, node),
        "ink": glyph("url(#ink)", "url(#ink)", stroke, node),
        "scale": scale,
        "glow_node": glow_node,
        "chevron": CHEVRON,
    }


def flatten(path):
    """去掉 alpha 通道：带 alpha 的图标在 macOS 26 仍会被判定为「无底板」而补灰底。"""
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
