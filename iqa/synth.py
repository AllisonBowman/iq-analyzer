"""Synthetic images with known ground truth.

Used by the test-suite and by ``iqa demo`` so the whole pipeline can be
exercised without any real photographs.
"""
from __future__ import annotations

import numpy as np
from scipy.special import erf


def slanted_edge(h: int = 120, w: int = 80, angle_deg: float = 5.0, sigma_px: float = 1.0,
                 low: float = 0.2, high: float = 0.8, noise: float = 0.0,
                 seed: int = 0, pixel_aperture: bool = False, shading: float = 0.0,
                 sharpen: float = 0.0, offset_px: float = 0.0) -> np.ndarray:
    """A Gaussian-blurred step edge, running top-to-bottom, tilted ``angle_deg`` from vertical.

    With ``pixel_aperture=False`` the edge is point-sampled from the analytic ESF
    (error function), so the exact MTF is ``exp(-2 pi^2 sigma^2 f^2)`` and MTF50
    is :func:`iqa.sfr.gaussian_mtf50`.  With ``pixel_aperture=True`` each pixel
    integrates the ESF over its 100 %-fill square aperture (8x8 supersampling),
    which multiplies the MTF by ``sinc(f)`` as a real sensor does:
    :func:`iqa.sfr.gaussian_pixel_mtf50`.

    ``shading`` adds a linear gradient of that fraction of the step across the
    ROI width (natural scenes); ``sharpen`` applies unsharp masking of that
    amount (radius 1 px) to create overshoot; ``offset_px`` moves the edge off
    the ROI centre.  Values are linear intensity in [0, 1] before shading.
    """
    rng = np.random.default_rng(seed)
    theta = np.radians(angle_deg)
    ss = 8 if pixel_aperture else 1
    yy, xx = np.mgrid[0:h * ss, 0:w * ss].astype(np.float64)
    yy = (yy + 0.5) / ss - 0.5                     # pixel-centre coordinates
    xx = (xx + 0.5) / ss - 0.5
    x_edge = (w - 1) / 2.0 + offset_px + np.tan(theta) * (yy - (h - 1) / 2.0)
    dist = (xx - x_edge) * np.cos(theta)          # signed distance along the normal
    esf = 0.5 * (1.0 + erf(dist / (sigma_px * np.sqrt(2.0))))
    if ss > 1:
        esf = esf.reshape(h, ss, w, ss).mean(axis=(1, 3))
    img = low + (high - low) * esf
    if sharpen > 0:
        from scipy.ndimage import gaussian_filter
        img = img + sharpen * (img - gaussian_filter(img, 1.0))
    if shading != 0.0:
        img = img + shading * (high - low) * (np.arange(w) - (w - 1) / 2.0) / (w - 1)
    if noise > 0:
        img = img + rng.normal(0.0, noise, img.shape)
    return img


def flat_field(h: int, w: int, level: float, sigma: float, seed: int = 0) -> np.ndarray:
    """Uniform field with Gaussian noise (linear intensity)."""
    rng = np.random.default_rng(seed)
    return level + rng.normal(0.0, sigma, (h, w))


def synthetic_scene(size: int = 1400, sigma_px: float = 1.1, noise_8bit: float = 3.0,
               seed: int = 0) -> np.ndarray:
    """A synthetic 'photo' (sRGB uint8 HxWx3) with known blur and noise.

    Layout: a soft luminance gradient background, several slanted dark/bright
    squares (edges at 4-9 degrees), a fine-texture patch (should be rejected by
    the noise-patch selector), a clipped white block and a black block.
    """
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    lin = 0.18 + 0.12 * (xx / size)                              # gentle gradient, linear
    lin = np.repeat(lin[..., None], 3, axis=2)
    lin[..., 2] *= 1.15                                           # slightly blue scene

    def put_square(cx, cy, half, angle, level):
        th = np.radians(angle)
        c, s = np.cos(th), np.sin(th)
        u = (xx - cx) * c + (yy - cy) * s
        v = -(xx - cx) * s + (yy - cy) * c
        mask = (np.abs(u) < half) & (np.abs(v) < half)
        for ch in range(3):
            lin[..., ch][mask] = level

    f = size / 1400.0
    for cx, cy, ang, lvl in [(300, 300, 5, 0.02), (1000, 320, 7, 0.75), (350, 1000, 4, 0.60), (1050, 1050, 9, 0.03)]:
        put_square(cx * f, cy * f, 110 * f, ang, lvl)

    # Gaussian blur (the "lens"), applied in linear space.
    from scipy.ndimage import gaussian_filter
    for ch in range(3):
        lin[..., ch] = gaussian_filter(lin[..., ch], sigma_px)

    # Fine texture patch (should NOT be mistaken for noise).
    tex = 0.30 + 0.06 * np.sin(xx / 2.3) * np.sin(yy / 2.9)
    region = (slice(int(size * 600 / 1400), int(size * 800 / 1400)), slice(int(size * 600 / 1400), int(size * 800 / 1400)))
    for ch in range(3):
        lin[..., ch][region] = tex[region]

    # Clipped blocks (each 150/1400 x 200/1400 of the frame = 1.53 % of pixels).
    r0, r1 = int(size * 1200 / 1400), int(size * 1350 / 1400)
    lin[r0:r1, int(size * 100 / 1400):int(size * 300 / 1400), :] = 1.5
    lin[r0:r1, int(size * 400 / 1400):int(size * 600 / 1400), :] = 0.0

    from .imageio import srgb_encode
    srgb = srgb_encode(np.clip(lin, 0, 1)) * 255.0
    srgb = srgb + rng.normal(0.0, noise_8bit, srgb.shape)        # output-referred noise
    return np.clip(np.round(srgb), 0, 255).astype(np.uint8)


def render_colorchecker(size: int = 1600, tilt: float = 0.15, seed: int = 0,
                        background: float = 110.0) -> tuple[np.ndarray, np.ndarray]:
    """A ColorChecker Classic rendered from its reference L*a*b* values and photographed through
    a mild perspective (``tilt`` controls how much the far side shrinks, plus a small rotation).

    Returns ``(rgb8, centres)``: the sRGB uint8 image (size x size x 3) with a plain grey
    background, and the 24 patch centres in image pixels, row-major (dark skin first).
    No blur, noise or compression: the caller adds those.
    """
    import cv2
    from .color import COLORCHECKER_LAB, canonical_centres, lab_to_srgb8
    rng = np.random.default_rng(seed)
    pitch = 100                                    # canonical pixels per patch
    patch = 0.80 * pitch
    frame = int(0.35 * pitch)
    W, Hh = 6 * pitch + 2 * frame, 4 * pitch + 2 * frame
    canon = np.full((Hh, W, 3), 28, dtype=np.uint8)         # the chart's black frame and gutters
    colours = lab_to_srgb8(COLORCHECKER_LAB)
    for i, (u, v) in enumerate(canonical_centres()):
        cx, cy = frame + u * pitch, frame + v * pitch
        x0, y0 = int(round(cx - patch / 2)), int(round(cy - patch / 2))
        canon[y0:y0 + int(patch), x0:x0 + int(patch)] = colours[i]
    # Place the chart on the frame: scale to ~45 % of the width, perspective, rotation.
    scale = 0.45 * size / W
    src = np.array([[0, 0], [W, 0], [W, Hh], [0, Hh]], dtype=np.float32)
    cxy = np.array([size / 2, size / 2])
    half = np.array([W, Hh]) * scale / 2
    dst = np.array([[-half[0], -half[1]], [half[0], -half[1]], [half[0], half[1]], [-half[0], half[1]]])
    dst[:, 0] *= np.array([1 - tilt, 1 - tilt, 1 + tilt, 1 + tilt])     # far side (top) narrower
    dst[:, 1] *= 1 - 0.3 * tilt
    ang = np.radians(8.0 * tilt + rng.uniform(-2, 2))
    R = np.array([[np.cos(ang), -np.sin(ang)], [np.sin(ang), np.cos(ang)]])
    dst = (dst @ R.T + cxy + rng.uniform(-size * 0.03, size * 0.03, 2)).astype(np.float32)
    M = cv2.getPerspectiveTransform(src, dst)
    bg = np.full((size, size, 3), background, dtype=np.uint8)
    warped = cv2.warpPerspective(canon, M, (size, size), flags=cv2.INTER_LINEAR,
                                 borderMode=cv2.BORDER_TRANSPARENT, dst=bg.copy())
    # chart-unit centres -> canonical pixels -> image pixels
    cc = canonical_centres() * pitch + frame
    pts = cv2.perspectiveTransform(cc.reshape(-1, 1, 2).astype(np.float64), M.astype(np.float64)).reshape(-1, 2)
    return warped, pts
