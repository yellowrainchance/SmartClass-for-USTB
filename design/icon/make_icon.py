"""把生成的图标整图拆成「干净渐变底 + 居中前景」，同时去掉水印。

思路：
1. 用二次曲面最小二乘拟合背景（背景是平滑渐变，拟合比分块估计稳，边角无噪点）
2. alpha = (min(R,G,B) - bg_minC) / (255 - bg_minC)   —— 白图形在蓝底上分离度最好
3. 用高阈值求包围盒（排除边缘弱噪点），行列需有足够多像素才算数
4. 前景用纯白 + 柔和 alpha（不做反预乘，避免放大噪声导致光晕出现脏块）
5. 重建干净的合成渐变底，把图形按安全区居中摆放
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)

CANVAS = 1024
GLYPH_RATIO = 0.60          # 图形占画布比例（HarmonyOS 分层图标前景建议 55%~62%）
WATERMARK = (860, 935)      # 水印区域左上角：x>=860 且 y>=935 一律清除
BOX_T = 0.50                # 求包围盒的 alpha 阈值
MIN_RUN = 4                 # 某行/列至少这么多像素超阈值才计入包围盒


def fit_quadratic_bg(obs: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """对每个通道拟合 bg = c0 + c1*x + c2*y + c3*x^2 + c4*xy + c5*y^2（归一化坐标）。"""
    h, w, _ = obs.shape
    yy, xx = np.mgrid[0:h, 0:w]
    xn = (xx / (w - 1)).ravel()
    yn = (yy / (h - 1)).ravel()
    A = np.stack([np.ones_like(xn), xn, yn, xn * xn, xn * yn, yn * yn], axis=1)

    m = mask.ravel()
    A_fit = A[m]
    bg = np.zeros_like(obs)
    for ch in range(3):
        b = obs[..., ch].ravel()[m]
        coef, *_ = np.linalg.lstsq(A_fit, b, rcond=None)
        bg[..., ch] = (A @ coef).reshape(h, w)
    return bg


src = Image.open(SRC).convert('RGB')
if src.size != (CANVAS, CANVAS):
    src = src.resize((CANVAS, CANVAS), Image.LANCZOS)
obs = np.asarray(src).astype(np.float64)

# 水印区域先置为 NaN 排除，避免污染背景拟合
wm = np.zeros(obs.shape[:2], dtype=bool)
wm[WATERMARK[1]:, WATERMARK[0]:] = True

lum = obs.min(axis=2)
bg_mask = (lum < 145.0) & (~wm)          # 只拿“明显是背景”的像素参与拟合
print(f'背景拟合样本: {bg_mask.sum()} px ({100.0 * bg_mask.mean():.1f}%)')

bg = fit_quadratic_bg(obs, bg_mask)
bg_min = np.clip(bg.min(axis=2), 0.0, 254.0)

# ---------- alpha ----------
alpha = np.clip((lum - bg_min) / np.clip(255.0 - bg_min, 1.0, None), 0.0, 1.0)
# 柔化中间调：光晕更通透，纯白图形仍然保持 1.0
alpha = np.clip((alpha - 0.08) / 0.74, 0.0, 1.0)

raw_a = Image.fromarray((alpha * 255).astype(np.uint8))
alpha = np.asarray(raw_a.filter(ImageFilter.GaussianBlur(0.6))).astype(np.float64) / 255.0

# ---------- 去水印 ----------
alpha[WATERMARK[1]:, WATERMARK[0]:] = 0.0

# ---------- 包围盒：行列需有足够多超阈值像素 ----------
strong = alpha > BOX_T
col_cnt = strong.sum(axis=0)
row_cnt = strong.sum(axis=1)
cols = np.where(col_cnt >= MIN_RUN)[0]
rows = np.where(row_cnt >= MIN_RUN)[0]
if len(cols) == 0 or len(rows) == 0:
    raise SystemExit('未找到前景图形，检查阈值')
x0, x1, y0, y1 = int(cols[0]), int(cols[-1]), int(rows[0]), int(rows[-1])
gw, gh = x1 - x0 + 1, y1 - y0 + 1
print(f'图形包围盒: x[{x0},{x1}] y[{y0},{y1}]  宽{gw} 高{gh}')
print(f'图形中心: ({(x0+x1)/2:.0f}, {(y0+y1)/2:.0f})   画布中心: (512, 512)')


def hexof(c):
    return '#%02X%02X%02X' % tuple(int(round(v)) for v in c)


# ---------- 重建干净渐变底 ----------
def patch(x0_, x1_, y0_, y1_):
    return bg[y0_:y1_, x0_:x1_].reshape(-1, 3).mean(axis=0)

tl, tr = patch(8, 120, 8, 120), patch(CANVAS - 180, CANVAS - 40, 8, 120)
bl, br = patch(8, 120, CANVAS - 180, CANVAS - 40), patch(CANVAS - 250, CANVAS - 130, CANVAS - 250, CANVAS - 130)
print(f'底色: TL={hexof(tl)} TR={hexof(tr)} BL={hexof(bl)} BR={hexof(br)}')

yy, xx = np.mgrid[0:CANVAS, 0:CANVAS]
tx = (xx / (CANVAS - 1))[..., None]
ty = (yy / (CANVAS - 1))[..., None]
top = tl * (1 - tx) + tr * tx
bot = bl * (1 - tx) + br * tx
new_bg = np.clip(top * (1 - ty) + bot * ty, 0, 255)

# ---------- 图形居中缩放 ----------
scale = (CANVAS * GLYPH_RATIO) / max(gw, gh)
nw, nh = max(1, int(round(gw * scale))), max(1, int(round(gh * scale)))
ox, oy = (CANVAS - nw) // 2, (CANVAS - nh) // 2
print(f'缩放 {gw}x{gh} -> {nw}x{nh}   偏移 ({ox},{oy})')

a_crop = Image.fromarray((alpha * 255).astype(np.uint8)).crop((x0, y0, x1 + 1, y1 + 1))
a_rs = np.asarray(a_crop.resize((nw, nh), Image.LANCZOS)).astype(np.float64)

fg_layer = np.zeros((CANVAS, CANVAS, 4), dtype=np.uint8)
fg_layer[oy:oy + nh, ox:ox + nw, :3] = 255            # 纯白前景，干净利落
fg_layer[oy:oy + nh, ox:ox + nw, 3] = a_rs.astype(np.uint8)

fg_img = Image.fromarray(fg_layer, 'RGBA')
bg_img = Image.fromarray(new_bg.astype(np.uint8), 'RGB').convert('RGBA')

bg_img.save(OUT / 'background.png')
fg_img.save(OUT / 'foreground.png')

comp = Image.alpha_composite(bg_img, fg_img).convert('RGB')
comp.save(OUT / 'preview_square.png')

mask = Image.new('L', (CANVAS, CANVAS), 0)
ImageDraw.Draw(mask).ellipse((0, 0, CANVAS - 1, CANVAS - 1), fill=255)
circ = Image.new('RGB', (CANVAS, CANVAS), (245, 245, 247))
circ.paste(comp, (0, 0), mask)
circ.save(OUT / 'preview_circle.png')

comp.resize((152, 152), Image.LANCZOS).save(OUT / 'startIcon.png')

small = Image.new('RGB', (188, 68), (245, 245, 247))
for i, s in enumerate([40, 56, 64]):
    small.paste(comp.resize((s, s), Image.LANCZOS), (6 + i * 62, (68 - s) // 2))
small.save(OUT / 'preview_sizes.png')

print('OK ->', OUT)
print('前景有效像素占比: %.1f%%' % (100.0 * (alpha > 0.06).mean()))
