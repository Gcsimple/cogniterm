#!/usr/bin/env python3
"""生成 CogniTerm 的 App 图标（macOS AppIcon.appiconset）。

设计语言：与 Codex 同族
  - 竖向三段渐变（浅 → 中 → 深），单一主色，白色镂空字形
  - 零装饰：没有 sparkles、没有粒子、没有 3D 立体投影
刻意不同之处（避免「抄形状 + 抄配色」）
  - 字形是「> 提示符 + 认知节点（实心圆点）」，不是 Codex 的「> + 短横线」
  - 主色走紫，不用 Codex 的 #B1A7FF / #7A9DFF / #3941FF

⚠️ 为什么是满幅方形、而不是 Codex 那种「透明背景 + 有机云朵」
   macOS 26 起系统接管图标外形：asset 里带透明的图标会被塞进一张系统生成的
   浅灰「玻璃底板」上（实测 NSWorkspace 解析出来的就是灰底 + 小紫花），既难看
   又失去深色对比。要拿到正常的圆角方板，必须自己铺满整张画布（full-bleed），
   让系统只做 squircle 遮罩与高光，不再补底板。
   实测代价：有机轮廓（Codex 最显眼的特征）必须让位给满幅底板；保住的是渐变、
   白色字形与零装饰，以及「大圆点 = 认知节点」这个自有识别点。
   另外底色不能太浅：白字压在 #CDBEFF 上，16px 直接糊成一片（对比度约 1.6:1）。
   现在顶部 #9484FF，白字对比度约 3.3:1，16px 仍能读出箭头。

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

GRADIENT = (("#9484FF", 0.0), ("#6559FF", 0.46), ("#2A1DB8", 1.0))

# 字形：> 提示符（圆头圆角）+ 认知节点。整体绕画布中心放大 1.10，
# 让标识在满幅底板里占到约 45% 宽度（系统还会再内缩一圈做 squircle）。
CHEVRON = "M 366 372 L 504 512 L 366 652"
STROKE = 108
NODE = (650, 512, 66)
GLYPH_TRANSFORM = "translate(512,512) scale(1.10) translate(-514,-512)"

# (文件名, 像素尺寸)
SLOTS = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def svg():
    stops = "\n".join('      <stop offset="%s" stop-color="%s"/>' % (offset, color)
                      for color, offset in GRADIENT)
    return """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>CogniTerm</title>
  <desc>Full-bleed violet gradient plate with a white terminal prompt and an agent node.</desc>
  <defs>
    <linearGradient id="plate" x1="512" y1="0" x2="512" y2="1024" gradientUnits="userSpaceOnUse">
%s
    </linearGradient>
    <radialGradient id="glow" cx="320" cy="240" r="600" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/>
      <stop offset="0.6" stop-color="#FFFFFF" stop-opacity="0.04"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#plate)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  <g transform="%s">
    <path d="%s" fill="none" stroke="#FFFFFF" stroke-width="%d"
          stroke-linecap="round" stroke-linejoin="round"/>
    <circle cx="%d" cy="%d" r="%d" fill="#FFFFFF"/>
  </g>
</svg>
""" % (stops, GLYPH_TRANSFORM, CHEVRON, STROKE, NODE[0], NODE[1], NODE[2])


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


def flatten(path):
    """去掉 alpha 通道：带 alpha 的图标在 macOS 26 仍会被判定为「无底板」而补灰底。"""
    try:
        from PIL import Image
    except ImportError:
        return
    Image.open(path).convert("RGB").save(path)


def main():
    if not os.path.exists(CHROME):
        sys.exit("找不到 Google Chrome：%s" % CHROME)
    os.makedirs(SVG_DIR, exist_ok=True)
    with open(os.path.join(SVG_DIR, "app-icon.svg"), "w") as handle:
        handle.write(svg())
    os.makedirs(ASSET_DIR, exist_ok=True)
    for name, size in SLOTS:
        render(os.path.join(ASSET_DIR, name), size, svg())
        print("%-22s %4dpx" % (name, size))


if __name__ == "__main__":
    main()
