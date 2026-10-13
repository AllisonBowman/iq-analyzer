"""List the real camera captures in a photo library: files with an EXIF camera model and at least ``min_mp`` megapixels.

    python -m iqa.select_captures photo_list.txt captures.txt --min-mp 5

Photos libraries are full of screenshots, saved images and thumbnails; this keeps the run to
images a camera actually produced, so by-camera and by-ISO comparisons mean something.
"""
from __future__ import annotations

import argparse
import logging
import sys

from PIL import Image

from .imageio import _exif_from_pil, _exif_with_exifread

logging.getLogger("exifread").setLevel(logging.ERROR)
try:
    import pillow_heif
    pillow_heif.register_heif_opener()
except Exception:  # pragma: no cover
    pass


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("inlist")
    ap.add_argument("outlist")
    ap.add_argument("--min-mp", type=float, default=5.0)
    args = ap.parse_args(argv)
    kept, total, by_cam = [], 0, {}
    with open(args.inlist) as fh:
        paths = [ln.strip() for ln in fh if ln.strip()]
    for p in paths:
        total += 1
        try:
            with Image.open(p) as im:
                w, h = im.size
                meta = _exif_from_pil(im)
        except Exception:
            continue
        if not meta.get("camera_model"):
            meta.update(_exif_with_exifread(p))
        cam = meta.get("camera_model")
        if cam and (w * h) / 1e6 >= args.min_mp:
            kept.append(p)
            by_cam[cam] = by_cam.get(cam, 0) + 1
    with open(args.outlist, "w") as fh:
        fh.write("\n".join(kept) + "\n")
    print(f"{len(kept)} camera captures of {total} files (>= {args.min_mp} MP with a camera model)")
    for cam, n in sorted(by_cam.items(), key=lambda kv: -kv[1]):
        print(f"  {n:5d}  {cam}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
