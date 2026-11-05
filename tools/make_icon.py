#!/usr/bin/env python3
"""生成 Perch 的 macOS 图标：深色 squircle + 菜单栏/刘海 + 刘海右侧的眼球 Pip。"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4
W = SIZE * SS

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")
ICONSET = os.path.join(OUT_DIR, "AppIcon.iconset")

SHAPE_FRAC = 1.0
SQUIRCLE_N = 5.0

BG_TOP = np.array([40, 43, 51], dtype=np.float64)
BG_BOTTOM = np.array([11, 12, 15], dtype=np.float64)

BAND_H_FRAC = 0.135      # 顶部菜单栏黑带（相对形状宽）
NOTCH_W_FRAC = 0.26      # 刘海宽度
NOTCH_DROP_FRAC = 0.062  # 刘海向下凸出
BALL_D_FRAC = 0.215
BALL_GAP_FRAC = 0.042


def superellipse_mask(size, frac, n):
    half = size * frac / 2.0
    c = size / 2.0
    y, x = np.mgrid[0:size, 0:size].astype(np.float64)
    u = np.abs(x + 0.5 - c) / half
    v = np.abs(y + 0.5 - c) / half
    return (u ** n + v ** n) <= 1.0


def erode(mask, px):
    m = mask.copy()
    for _ in range(px):
        m = (m
             & np.roll(m, 1, axis=0) & np.roll(m, -1, axis=0)
             & np.roll(m, 1, axis=1) & np.roll(m, -1, axis=1))
    return m


def build_ball(diameter):
    pad = int(diameter * 0.22)
    bw = int(diameter) + pad * 2
    yy, xx = np.mgrid[0:bw, 0:bw].astype(np.float64)
    cc = (bw - 1) / 2.0
    rad = diameter / 2.0
    dist = np.sqrt((xx - cc) ** 2 + (yy - cc) ** 2)
    alpha = np.clip((rad - dist) * (2.0 / SS) * 1.6, 0, 1)
    light = np.sqrt((xx - cc + rad * 0.36) ** 2 + (yy - cc + rad * 0.42) ** 2) / (rad * 1.95)
    shade = np.clip(1.07 - light * 0.52, 0.42, 1.0)
    rgb = np.stack([shade * 253.0, shade * 253.0, shade * 255.0], axis=-1)
    ball = Image.fromarray(np.concatenate(
        [np.clip(rgb, 0, 255).astype(np.uint8),
         (alpha * 255).astype(np.uint8)[..., None]], axis=-1), "RGBA")

    d = ImageDraw.Draw(ball)
    eye_r = diameter * 0.135
    eye_dx = diameter * 0.16
    eye_y = cc - diameter * 0.015
    for sign in (-1, 1):
        ex = cc + sign * eye_dx
        d.ellipse([ex - eye_r, eye_y - eye_r, ex + eye_r, eye_y + eye_r], fill=(12, 13, 16, 255))
        hr = eye_r * 0.40
        d.ellipse([ex - eye_r * 0.30 - hr, eye_y - eye_r * 0.62 - hr,
                   ex - eye_r * 0.30 + hr, eye_y - eye_r * 0.62 + hr], fill=(255, 255, 255, 240))
    return ball


def main():
    shape = superellipse_mask(W, SHAPE_FRAC, SQUIRCLE_N)

    rgba = np.zeros((W, W, 4), dtype=np.float64)
    t = (np.mgrid[0:W, 0:W][0].astype(np.float64) / (W - 1))[..., None]
    grad = BG_TOP * (1.0 - t) + BG_BOTTOM * t
    ring = shape & ~erode(shape, SS * 2)
    grad = grad + ring[..., None] * np.array([28.0, 29.0, 32.0])
    rgba[..., :3] = grad
    rgba[..., 3] = shape * 255.0
    img = Image.fromarray(np.clip(rgba, 0, 255).astype(np.uint8), "RGBA")

    box_off = W * (1 - SHAPE_FRAC) / 2
    shape_w = W * SHAPE_FRAC
    top = box_off
    cx = W / 2.0

    overlay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)

    band_h = shape_w * BAND_H_FRAC
    od.rectangle([box_off, top, box_off + shape_w, top + band_h], fill=(0, 0, 0, 255))

    nw = shape_w * NOTCH_W_FRAC
    drop = shape_w * NOTCH_DROP_FRAC
    r = drop * 0.85
    nx0, nx1 = cx - nw / 2, cx + nw / 2
    od.rounded_rectangle([nx0, top, nx1, top + band_h + drop], radius=r, fill=(0, 0, 0, 255))
    od.rectangle([nx0, top, nx1, top + band_h + drop - r], fill=(0, 0, 0, 255))

    bd = shape_w * BALL_D_FRAC
    bx = nx1 + shape_w * BALL_GAP_FRAC + bd / 2
    by = top + band_h + drop * 0.62
    ball = build_ball(bd)

    shadow_pad = int(bd * 0.5)
    shadow = Image.new("RGBA", (ball.width + shadow_pad * 2, ball.height + shadow_pad * 2), (0, 0, 0, 0))
    shadow.alpha_composite(ball, (shadow_pad, shadow_pad))
    shadow = shadow.filter(ImageFilter.GaussianBlur(bd * 0.10))
    black = Image.new("RGBA", shadow.size, (0, 0, 0, 255))
    black.putalpha(shadow.getchannel("A").point(lambda v: int(v * 0.55)))
    overlay.alpha_composite(black, (int(bx - black.width / 2), int(by - black.height / 2 + bd * 0.05)))

    overlay.alpha_composite(ball, (int(bx - ball.width / 2), int(by - ball.height / 2)))

    img.alpha_composite(overlay)

    # 整体按 squircle 裁切
    alpha = np.array(img.getchannel("A"), dtype=np.float64) * shape
    img.putalpha(Image.fromarray(np.clip(alpha, 0, 255).astype(np.uint8), "L"))

    final = img.resize((SIZE, SIZE), Image.LANCZOS)
    final.save(os.path.join(OUT_DIR, "AppIcon-1024.png"))

    os.makedirs(ICONSET, exist_ok=True)
    for base_pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base_pt * scale
            name = f"icon_{base_pt}x{base_pt}{'@2x' if scale == 2 else ''}.png"
            final.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))
    print("wrote", ICONSET)


if __name__ == "__main__":
    main()
