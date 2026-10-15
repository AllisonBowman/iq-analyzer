"""Image loading: RAW (rawpy), JPEG/PNG/TIFF (Pillow), HEIC/HEIF (pillow-heif), plus EXIF.

Every image is returned in two forms:

* ``rgb8``  — display-referred sRGB, uint8, HxWx3: what a viewer shows.  Noise,
  clipping and colour statistics are computed on this so that RAW and JPEG
  files are comparable.
* ``lin_luma`` — scene-linear luminance, float32, HxW.  The slanted-edge SFR
  is computed on this, as ISO 12233 requires linear data.
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from fractions import Fraction

import numpy as np
from PIL import Image, ImageOps

try:
    import pillow_heif
    pillow_heif.register_heif_opener()
    HAVE_HEIF = True
except Exception:  # pragma: no cover
    HAVE_HEIF = False

try:
    import rawpy
    HAVE_RAWPY = True
except Exception:  # pragma: no cover
    HAVE_RAWPY = False

RAW_EXT = {".cr2", ".cr3", ".nef", ".nrw", ".arw", ".srf", ".sr2", ".dng", ".raf",
           ".orf", ".rw2", ".pef", ".3fr", ".iiq", ".erf", ".mos", ".x3f"}
PIL_EXT = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".webp", ".heic", ".heif", ".gif"}
IMAGE_EXT = RAW_EXT | PIL_EXT

logging.getLogger("exifread").setLevel(logging.ERROR)

LUMA_W = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def srgb_decode(v: np.ndarray) -> np.ndarray:
    """sRGB (0..1 encoded) -> linear (0..1)."""
    v = np.asarray(v, dtype=np.float32)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4).astype(np.float32)


def srgb_encode(v: np.ndarray) -> np.ndarray:
    """linear (0..1) -> sRGB encoded (0..1)."""
    v = np.clip(np.asarray(v, dtype=np.float32), 0.0, 1.0)
    return np.where(v <= 0.0031308, 12.92 * v, 1.055 * np.power(v, 1 / 2.4) - 0.055).astype(np.float32)


@dataclass
class LoadedImage:
    path: str
    rgb8: np.ndarray
    lin_luma: np.ndarray
    is_raw: bool
    meta: dict = field(default_factory=dict)

    @property
    def height(self) -> int:
        return int(self.rgb8.shape[0])

    @property
    def width(self) -> int:
        return int(self.rgb8.shape[1])


def is_image_file(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in IMAGE_EXT


def _ratio(v):
    try:
        if isinstance(v, tuple) and len(v) == 2:
            return float(v[0]) / float(v[1]) if v[1] else float("nan")
        return float(v)
    except Exception:
        return float("nan")


def _exif_from_pil(im: Image.Image) -> dict:
    meta: dict = {}
    try:
        ex = im.getexif()
    except Exception:
        return meta
    if not ex:
        return meta
    meta["camera_make"] = str(ex.get(271, "")).strip() or None
    meta["camera_model"] = str(ex.get(272, "")).strip() or None
    meta["datetime"] = str(ex.get(306, "")) or None
    try:
        sub = ex.get_ifd(0x8769)  # Exif IFD
    except Exception:
        sub = {}
    if sub:
        meta["iso"] = _ratio(sub.get(34855)) if sub.get(34855) is not None else None
        meta["exposure_s"] = _ratio(sub.get(33434)) if sub.get(33434) is not None else None
        meta["f_number"] = _ratio(sub.get(33437)) if sub.get(33437) is not None else None
        meta["focal_mm"] = _ratio(sub.get(37386)) if sub.get(37386) is not None else None
        lens = sub.get(42036)
        meta["lens"] = str(lens).strip() if lens else None
        meta["datetime"] = str(sub.get(36867, meta.get("datetime") or "")) or None
    return {k: v for k, v in meta.items() if v not in (None, "", "nan")}


def _exif_with_exifread(path: str) -> dict:
    try:
        import exifread
    except Exception:  # pragma: no cover
        return {}
    meta: dict = {}
    try:
        with open(path, "rb") as fh:
            tags = exifread.process_file(fh, details=False)
    except Exception:
        return meta

    def get(name):
        t = tags.get(name)
        return None if t is None else t

    def num(t):
        if t is None:
            return None
        try:
            v = t.values[0]
            return float(Fraction(v.num, v.den)) if hasattr(v, "num") else float(v)
        except Exception:
            try:
                return float(str(t))
            except Exception:
                return None

    if get("Image Make"):
        meta["camera_make"] = str(get("Image Make")).strip()
    if get("Image Model"):
        meta["camera_model"] = str(get("Image Model")).strip()
    if get("EXIF LensModel"):
        meta["lens"] = str(get("EXIF LensModel")).strip()
    if num(get("EXIF ISOSpeedRatings")) is not None:
        meta["iso"] = num(get("EXIF ISOSpeedRatings"))
    if num(get("EXIF ExposureTime")) is not None:
        meta["exposure_s"] = num(get("EXIF ExposureTime"))
    if num(get("EXIF FNumber")) is not None:
        meta["f_number"] = num(get("EXIF FNumber"))
    if num(get("EXIF FocalLength")) is not None:
        meta["focal_mm"] = num(get("EXIF FocalLength"))
    if get("EXIF DateTimeOriginal"):
        meta["datetime"] = str(get("EXIF DateTimeOriginal"))
    return meta


def _to_srgb(im: Image.Image) -> tuple[Image.Image, str]:
    """Convert an image with an embedded ICC profile (Display P3 on most iPhone
    HEICs, Adobe RGB on many camera JPEGs) to sRGB, so the sRGB linearisation
    and Rec. 709 luma weights used everywhere else are correct.

    Returns the converted image and a label for the source profile.  An image
    without a profile is assumed to be sRGB.
    """
    icc = im.info.get("icc_profile")
    if not icc:
        return im, "assumed-sRGB"
    try:
        from io import BytesIO
        from PIL import ImageCms
        src = ImageCms.ImageCmsProfile(BytesIO(icc))
        desc = ImageCms.getProfileDescription(src).strip() or "embedded"
        if "srgb" in desc.lower():
            return im, desc
        dst = ImageCms.createProfile("sRGB")
        out = ImageCms.profileToProfile(im, src, dst, renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC,
                                        outputMode="RGB")
        return out, f"{desc} -> sRGB"
    except Exception as exc:  # unreadable profile: carry on as sRGB, but say so
        return im, f"profile-unreadable ({type(exc).__name__}); assumed-sRGB"


def _downscale(rgb: np.ndarray, max_side: int | None) -> np.ndarray:
    if not max_side:
        return rgb
    h, w = rgb.shape[:2]
    s = max(h, w)
    if s <= max_side:
        return rgb
    import cv2
    scale = max_side / s
    return cv2.resize(rgb, (int(round(w * scale)), int(round(h * scale))), interpolation=cv2.INTER_AREA)


def load_image(path: str, max_side: int | None = None) -> LoadedImage:
    """Load any supported image.  ``max_side`` (optional) downsamples long images.

    Downsampling changes measured sharpness; leave it unset for SFR work.
    """
    ext = os.path.splitext(path)[1].lower()
    meta: dict = {"format": ext.lstrip(".")}
    if ext in RAW_EXT:
        if not HAVE_RAWPY:
            raise RuntimeError("rawpy is not installed; cannot read RAW files")
        with rawpy.imread(path) as raw:
            lin16 = raw.postprocess(use_camera_wb=True, no_auto_bright=True, output_bps=16,
                                    gamma=(1, 1), output_color=rawpy.ColorSpace.sRGB,
                                    user_flip=None)
        lin = lin16.astype(np.float32) / 65535.0
        lin = _downscale(lin, max_side)
        rgb8 = np.clip(np.round(srgb_encode(lin) * 255.0), 0, 255).astype(np.uint8)
        meta.update(_exif_with_exifread(path))
        meta["color_profile"] = "camera -> sRGB (rawpy, linear, camera WB)"
        is_raw = True
    else:
        im = Image.open(path)
        meta.update(_exif_from_pil(im))
        im = ImageOps.exif_transpose(im)
        if im.mode not in ("RGB",):
            im = im.convert("RGB")
        # Saturation belongs to the file's own encoding: a Display P3 or Adobe RGB colour that lies
        # outside sRGB clips to 255 in the conversion below and must not count as a blown highlight.
        meta["native_clip_high_pct"], meta["native_clip_low_pct"] = native_clip_stats(np.asarray(im, dtype=np.uint8))
        im, meta["color_profile"] = _to_srgb(im)
        rgb8 = np.asarray(im, dtype=np.uint8)
        rgb8 = _downscale(rgb8, max_side)
        lin = srgb_decode(rgb8.astype(np.float32) / 255.0)
        if not meta.get("camera_model"):
            meta.update({k: v for k, v in _exif_with_exifread(path).items() if k not in meta})
        is_raw = False
    lin_luma = (lin.astype(np.float32) @ LUMA_W).astype(np.float32)
    meta["width"], meta["height"] = int(rgb8.shape[1]), int(rgb8.shape[0])
    return LoadedImage(path=path, rgb8=rgb8, lin_luma=lin_luma, is_raw=is_raw, meta=meta)


def native_clip_stats(rgb8: np.ndarray) -> tuple[float, float]:
    """(% of pixels with any channel >= 254, % with all channels <= 1) in the array's own encoding."""
    mx = rgb8.max(axis=2)
    mn = rgb8.min(axis=2)
    return float(100.0 * np.mean(mx >= 254)), float(100.0 * np.mean(mn <= 1))


def rgb8_from_linear(lin: np.ndarray) -> np.ndarray:
    return np.clip(np.round(srgb_encode(lin) * 255.0), 0, 255).astype(np.uint8)


def lin_luma_from_rgb8(rgb8: np.ndarray) -> np.ndarray:
    return (srgb_decode(rgb8.astype(np.float32) / 255.0) @ LUMA_W).astype(np.float32)
