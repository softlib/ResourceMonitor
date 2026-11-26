# -*- coding: utf-8 -*-
"""
ResourceMonitor 应用图标生成器
--------------------------------------------------
设计含义：
  * 圆角方形深色底板 —— 现代 Windows 应用图标语言
  * 三段彩色圆弧 —— CPU（蓝）/ 内存（青）/ 磁盘（橙），组成开放式仪表盘
  * 中心心电脉冲波形 —— 实时、健康、持续监控
  * 底部三色圆点 —— 与三段弧呼应，标注三大资源

输出：
  ResourceMonitor.ico  —— 多分辨率图标（16/24/32/48/64/128/256）
  icon_preview.png     —— 512px 预览图
运行：python build_icon.py （仅构建时需要，运行时不依赖）
"""
import io
import math
import os
import struct

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SS = 4  # 超采样倍率，先大后小以保证抗锯齿质量

CPU_COLOR = (74, 165, 255, 255)
MEM_COLOR = (54, 226, 194, 255)
DISK_COLOR = (255, 193, 74, 255)
BG_TOP = (21, 38, 76, 255)
BG_BOTTOM = (9, 16, 36, 255)
WAVE_COLOR = (233, 248, 255, 255)

SEGMENTS = [(135, 225, CPU_COLOR), (225, 315, MEM_COLOR), (315, 405, DISK_COLOR)]


def mix(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(4))


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=radius, fill=255
    )
    return mask


def build_background(S, mask):
    strip = Image.new("RGBA", (1, S))
    pix = strip.load()
    for y in range(S):
        pix[0, y] = mix(BG_TOP, BG_BOTTOM, y / max(1, S - 1))
    grad = strip.resize((S, S))
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)

    # 顶部柔光，增加玻璃质感
    glow = Image.new("RGBA", (S, S), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([S * 0.06, -S * 0.34, S * 0.94, S * 0.52], fill=(126, 176, 255, 44))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.055))
    out = Image.alpha_composite(out, glow)

    # 内描边高光
    d = ImageDraw.Draw(out)
    inset = max(1, int(S * 0.018))
    d.rounded_rectangle(
        [inset, inset, S - 1 - inset, S - 1 - inset],
        radius=int(S * 0.203),
        outline=(142, 194, 255, 66),
        width=max(1, int(S * 0.006)),
    )
    return out


def point_on_arc(box, angle):
    cx = (box[0] + box[2]) / 2
    cy = (box[1] + box[3]) / 2
    rx = (box[2] - box[0]) / 2
    ry = (box[3] - box[1]) / 2
    a = math.radians(angle)
    return cx + rx * math.cos(a), cy + ry * math.sin(a)


def build_arcs(S, detailed):
    box = [S * 0.19, S * 0.19, S * 0.81, S * 0.81]
    width = max(2, int(S * (0.082 if detailed else 0.105)))
    layer = Image.new("RGBA", (S, S), 0)
    d = ImageDraw.Draw(layer)
    for a1, a2, color in SEGMENTS:
        d.arc(box, a1 + 3.5, a2 - 3.5, fill=color, width=width)
        if detailed:
            # 平滑圆头端点
            for ang in (a1 + 3.5, a2 - 3.5):
                x, y = point_on_arc(box, ang)
                r = width / 2
                d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    return layer


def build_ticks(S):
    layer = Image.new("RGBA", (S, S), 0)
    d = ImageDraw.Draw(layer)
    cx = cy = S / 2
    for i in range(13):
        ang = math.radians(135 + 270 * i / 12)
        r1 = S * 0.348
        r2 = S * (0.382 if i % 3 == 0 else 0.368)
        x1, y1 = cx + r1 * math.cos(ang), cy + r1 * math.sin(ang)
        x2, y2 = cx + r2 * math.cos(ang), cy + r2 * math.sin(ang)
        d.line([x1, y1, x2, y2], fill=(198, 224, 255, 150),
               width=max(1, int(S * 0.005)))
    return layer


def build_wave(S, detailed):
    layer = Image.new("RGBA", (S, S), 0)
    d = ImageDraw.Draw(layer)
    c = S / 2
    scale = S * 0.275
    shape = [(-0.62, 0.10), (-0.32, 0.10), (-0.18, -0.27),
             (0.0, 0.32), (0.18, -0.32), (0.32, 0.10), (0.62, 0.10)]
    points = [(c + x * scale, c + y * scale) for x, y in shape]
    d.line(points, fill=WAVE_COLOR, width=max(2, int(S * (0.029 if detailed else 0.05))),
           joint="curve")
    return layer


def build_dots(S):
    layer = Image.new("RGBA", (S, S), 0)
    d = ImageDraw.Draw(layer)
    c = S / 2
    y = c + S * 0.155
    r = S * 0.021
    for i, color in enumerate((CPU_COLOR, MEM_COLOR, DISK_COLOR)):
        x = c + (i - 1) * S * 0.135
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    return layer


def render(size, detailed=True):
    S = size * SS
    mask = rounded_mask(S, int(S * 0.22))
    img = build_background(S, mask)

    arcs = build_arcs(S, detailed)
    wave = build_wave(S, detailed)

    if detailed:
        # 发光层：先模糊再叠加，营造霓虹仪表质感
        arc_glow = arcs.filter(ImageFilter.GaussianBlur(S * 0.028))
        arc_glow.putalpha(ImageChops.multiply(arc_glow.getchannel("A"),
                                              Image.new("L", (S, S), 140)))
        img = Image.alpha_composite(img, arc_glow)
        wave_glow = wave.filter(ImageFilter.GaussianBlur(S * 0.032))
        wave_glow.putalpha(ImageChops.multiply(wave_glow.getchannel("A"),
                                               Image.new("L", (S, S), 150)))
        img = Image.alpha_composite(img, wave_glow)

    img = Image.alpha_composite(img, arcs)
    if detailed:
        img = Image.alpha_composite(img, build_ticks(S))
    img = Image.alpha_composite(img, wave)
    if detailed:
        img = Image.alpha_composite(img, build_dots(S))

    # 严格裁剪到圆角轮廓内
    img.putalpha(ImageChops.multiply(img.getchannel("A"), mask))
    return img.resize((size, size), Image.LANCZOS)


def write_ico(path, images):
    """手写 ICO 容器，逐尺寸嵌入 PNG，精确控制每一档，无第三方工具依赖。"""
    chunks = []
    for im in images:
        buf = io.BytesIO()
        im.save(buf, format="PNG", optimize=True)
        chunks.append(buf.getvalue())
    count = len(images)
    header = struct.pack("<HHH", 0, 1, count)
    offset = 6 + 16 * count
    entries = bytearray()
    for im, data in zip(images, chunks):
        w = 0 if im.width == 256 else im.width
        h = 0 if im.height == 256 else im.height
        entries += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    with open(path, "wb") as f:
        f.write(header + entries + b"".join(chunks))


def main():
    sizes = [16, 24, 32, 48, 64, 128, 256]
    images = [render(s, detailed=(s >= 48)) for s in sizes]
    write_ico(os.path.join(HERE, "ResourceMonitor.ico"), images)
    render(512, detailed=True).save(os.path.join(HERE, "icon_preview.png"))
    print("generated:", ", ".join(f"{s}px" for s in sizes))


if __name__ == "__main__":
    main()
